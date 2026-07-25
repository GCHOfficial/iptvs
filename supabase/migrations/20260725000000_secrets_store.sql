-- iptvs cloud sync — isolated secrets store (Phase 2 of the hardening ladder).
--
-- Background: through Phase 1 (nondestructive_push.sql) credentials still lived
-- inline in sources.fields / metadata_configs.config, protected by RLS + TLS
-- only. Phase 2 moves every credential-bearing key out of those broadly-readable
-- columns into two dedicated tables (source_secrets / metadata_secrets) that
-- have RLS enabled with ZERO policies — reachable ONLY through the SECURITY
-- DEFINER accessor RPCs below. This is the structural prerequisite for Phase 3
-- (opt-in passphrase E2EE, e2ee.sql): once secrets are isolated, a `format`
-- column can flip a profile's secrets from plaintext (0) to E2EE envelope (1)
-- without disturbing the non-secret catalog.
--
-- Threat model is unchanged from harden_cloud.sql: the anon key is public, a
-- paired device may already READ all of its owner's data, so the blast radius of
-- any device write is that one account. New invariants this migration adds:
--   * A credential key can NEVER be stored in sources.fields / metadata_configs.
--     config again — sources_validate() / metadata_validate() STRIP the known
--     credential keys off the final NEW row on every write (RPC and panel), so
--     this is a single authoritative enforcement point independent of the
--     client. The secrets tables are the only home for those values.
--   * Secrets are readable only via get_secrets() (owner-or-paired-device) and
--     writable only via the push RPCs / set_*_secret RPCs (owner or the device's
--     push path). No table has a permissive policy.
--
-- All rejection errors use errcode 'check_violation' and a stable 'iptvs: '
-- message prefix carrying the LIMIT ONLY — never the offending value. Idempotent
-- throughout (create-or-replace / IF NOT EXISTS / ON CONFLICT DO NOTHING).
--
-- Phase 2 stores plaintext (format 0). The push/set RPCs here reject format != 0
-- ('secret format not supported') because profile_crypto does not exist yet;
-- e2ee.sql recreates these same RPC bodies with the full format-vs-enabled
-- enforcement. Keeping the format gate out of migration 1 lets it run standalone.

-- ---------------------------------------------------------------------------
-- Tables: source_secrets (one row per source that has any credential) and
-- metadata_secrets (one row per profile). `format` is 0 = plaintext jsonb map,
-- 1 = E2EE envelope v1 (added by e2ee.sql). `payload` is the credential map (or
-- the encrypted envelope). NOTE on scoping: source_secrets.profile_id is
-- advisory / denormalized for locality only — the AUTHORITATIVE profile scope is
-- always the join to public.sources (see get_secrets); never trust the column.
-- ---------------------------------------------------------------------------

create table if not exists public.source_secrets (
  source_id  uuid primary key references public.sources(id) on delete cascade,
  owner      uuid not null references auth.users(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  format     smallint not null default 0,
  payload    jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create index if not exists source_secrets_profile_idx on public.source_secrets(profile_id);
create index if not exists source_secrets_owner_idx   on public.source_secrets(owner);

create table if not exists public.metadata_secrets (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  owner      uuid not null references auth.users(id) on delete cascade,
  format     smallint not null default 0,
  payload    jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create index if not exists metadata_secrets_owner_idx on public.metadata_secrets(owner);

-- ---------------------------------------------------------------------------
-- RLS: enabled with DELIBERATELY ZERO policies. Deny-by-default means no client
-- role (anon device or authenticated account) can SELECT/INSERT/UPDATE/DELETE
-- these tables directly. Every access goes through the SECURITY DEFINER RPCs
-- below, which do their own owner/device resolution. This is stricter than the
-- sources/metadata_configs tables (which the panel writes directly) precisely
-- because these hold the raw credentials.
-- ---------------------------------------------------------------------------

alter table public.source_secrets   enable row level security;
alter table public.metadata_secrets enable row level security;

-- ---------------------------------------------------------------------------
-- Triggers.
--   * touch_updated_at BEFORE UPDATE keeps updated_at honest (references OLD, so
--     UPDATE only — matches the shared helper).
--   * touch_profile_snapshot_revision AFTER I/U/D advances profiles.updated_at
--     so a secret change is visible to the destructive-push revision gate. Both
--     tables carry profile_id AND owner, so the helper's coalesce(new/old ...)
--     dereferences are safe on both.
--   * secrets_validate BEFORE I/U bounds the payload shape/size (a clean 'iptvs:'
--     error instead of a NOT NULL / type DETAIL that could echo the payload).
-- ---------------------------------------------------------------------------

drop trigger if exists source_secrets_touch on public.source_secrets;
create trigger source_secrets_touch before update on public.source_secrets
  for each row execute function public.touch_updated_at();

drop trigger if exists metadata_secrets_touch on public.metadata_secrets;
create trigger metadata_secrets_touch before update on public.metadata_secrets
  for each row execute function public.touch_updated_at();

drop trigger if exists source_secrets_touch_profile_revision on public.source_secrets;
create trigger source_secrets_touch_profile_revision
  after insert or update or delete on public.source_secrets
  for each row execute function public.touch_profile_snapshot_revision();

drop trigger if exists metadata_secrets_touch_profile_revision on public.metadata_secrets;
create trigger metadata_secrets_touch_profile_revision
  after insert or update or delete on public.metadata_secrets
  for each row execute function public.touch_profile_snapshot_revision();

-- Pure validator (inspects only its jsonb argument; holds no secret, touches no
-- table). A secret payload must be a JSON object and stay within a generous
-- bound: realistic plaintext credential maps are < 1 KB, and an E2EE envelope
-- (salt + iv + wrapped key + ciphertext, all base64) is a few KB.
create or replace function public.assert_secret_valid(p_payload jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  max_payload_bytes constant int := 65536;  -- 64 KB; realistic < 4 KB
  p jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  if jsonb_typeof(p) <> 'object' then
    raise exception 'iptvs: secret payload must be a JSON object'
      using errcode = 'check_violation';
  end if;
  if octet_length(p::text) > max_payload_bytes then
    raise exception 'iptvs: secret payload too large (max % bytes)', max_payload_bytes
      using errcode = 'check_violation';
  end if;
end;
$$;

create or replace function public.secrets_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- An explicit null payload would reach the column NOT NULL, whose error DETAIL
  -- echoes the whole row — reject cleanly first.
  if new.payload is null then
    raise exception 'iptvs: secret payload must not be null'
      using errcode = 'check_violation';
  end if;
  perform public.assert_secret_valid(new.payload);
  return new;
end;
$$;

drop trigger if exists source_secrets_validate on public.source_secrets;
create trigger source_secrets_validate before insert or update on public.source_secrets
  for each row execute function public.secrets_validate();

drop trigger if exists metadata_secrets_validate on public.metadata_secrets;
create trigger metadata_secrets_validate before insert or update on public.metadata_secrets
  for each row execute function public.secrets_validate();

-- Internal validator: the trigger fires only inside the DEFINER RPCs below (the
-- tables have no direct-write policy), which run as the table owner and always
-- retain EXECUTE on their own functions. No client role needs a grant.
revoke all on function public.assert_secret_valid(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Strip guarantee: recreate sources_validate() / metadata_validate() VERBATIM
-- from harden_cloud.sql, adding ONE line before the assert call that removes the
-- known credential keys from the final NEW row. This BEFORE-trigger fires on the
-- post-merge NEW row (so it strips even a device push that merged credentials
-- via merge_preserving_nonempty) AND on panel direct writes — the single
-- authoritative point that guarantees a credential can never persist in
-- sources.fields / metadata_configs.config again. Everything else is unchanged.
-- ---------------------------------------------------------------------------

create or replace function public.sources_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Explicit nulls would pass through to the columns' NOT NULL constraints,
  -- whose error DETAIL echoes the full row (credentials included) — reject
  -- them here first with a clean error.
  if new.label is null or new.fields is null or new.settings is null
     or new.position is null then
    raise exception 'iptvs: source row has null fields'
      using errcode = 'check_violation';
  end if;
  -- Phase 2 strip: credential keys live only in source_secrets from now on.
  new.fields := coalesce(new.fields, '{}'::jsonb)
    - array['mac', 'username', 'password', 'playlistUrl', 'epgUrl', 'userAgent'];
  perform public.assert_source_valid(new.kind, new.label, new.fields, new.settings);
  return new;
end;
$$;

create or replace function public.metadata_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.config is null then
    raise exception 'iptvs: metadata config must not be null'
      using errcode = 'check_violation';
  end if;
  -- Phase 2 strip: metadata API keys live only in metadata_secrets from now on.
  new.config := coalesce(new.config, '{}'::jsonb)
    - array['tmdbApiKey', 'tvdbApiKey', 'tvdbPin', 'mdblistApiKey'];
  perform public.assert_metadata_valid(new.config);
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- One-time data migration: move existing inline credentials into the secrets
-- tables, then strip them from the catalog columns. ORDER MATTERS — INSERT the
-- secrets (reading the still-present credentials) BEFORE the UPDATE that removes
-- them. Re-entrant: ON CONFLICT DO NOTHING never clobbers an already-moved or
-- panel-edited secret, and after the first run the source rows no longer carry
-- the keys so the `?|` predicate is false and both statements become no-ops.
-- The mass UPDATE fires the snapshot-revision trigger once per affected profile
-- (a one-time device re-pull storm — benign and expected).
-- ---------------------------------------------------------------------------

insert into public.source_secrets (source_id, owner, profile_id, format, payload)
select s.id, s.owner, s.profile_id, 0, sec.payload
  from public.sources s
  cross join lateral (
    select coalesce(jsonb_object_agg(kv.key, kv.value), '{}'::jsonb) as payload
      from jsonb_each(coalesce(s.fields, '{}'::jsonb)) as kv
     where kv.key in ('mac', 'username', 'password', 'playlistUrl', 'epgUrl', 'userAgent')
  ) sec
 where s.profile_id is not null
   and s.fields ?| array['mac', 'username', 'password', 'playlistUrl', 'epgUrl', 'userAgent']
on conflict (source_id) do nothing;

update public.sources s
   set fields = coalesce(s.fields, '{}'::jsonb)
     - array['mac', 'username', 'password', 'playlistUrl', 'epgUrl', 'userAgent']
 where s.fields ?| array['mac', 'username', 'password', 'playlistUrl', 'epgUrl', 'userAgent'];

insert into public.metadata_secrets (profile_id, owner, format, payload)
select m.profile_id, m.owner, 0, sec.payload
  from public.metadata_configs m
  cross join lateral (
    select coalesce(jsonb_object_agg(kv.key, kv.value), '{}'::jsonb) as payload
      from jsonb_each(coalesce(m.config, '{}'::jsonb)) as kv
     where kv.key in ('tmdbApiKey', 'tvdbApiKey', 'tvdbPin', 'mdblistApiKey')
  ) sec
 where m.profile_id is not null
   and m.config ?| array['tmdbApiKey', 'tvdbApiKey', 'tvdbPin', 'mdblistApiKey']
on conflict (profile_id) do nothing;

update public.metadata_configs m
   set config = coalesce(m.config, '{}'::jsonb)
     - array['tmdbApiKey', 'tvdbApiKey', 'tvdbPin', 'mdblistApiKey']
 where m.config ?| array['tmdbApiKey', 'tvdbApiKey', 'tvdbPin', 'mdblistApiKey'];

-- ---------------------------------------------------------------------------
-- get_secrets: the only read path for a profile's secrets. Owner-or-paired-
-- device scoped (a device must fetch credentials to play). Source secrets are
-- scoped by JOINING public.sources — never by source_secrets.profile_id, which
-- is advisory and could be stale after a cross-profile move (adversarial finding
-- M2). Returns { "sources": { "<uuid>": {format,payload}, ... },
--                "metadata": {format,payload} | null }.
-- ---------------------------------------------------------------------------

create or replace function public.get_secrets(p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  resolved_owner uuid;
  src jsonb;
  meta jsonb;
begin
  select p.owner into resolved_owner
    from public.profiles p
   where p.id = p_profile_id
     and (p.owner = auth.uid() or p.owner = public.current_device_owner());
  if resolved_owner is null then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;

  -- Reads return raw secrets, so they are deliberately throttled generously
  -- (a sync pull touches this once per profile switch, not per channel).
  perform public.check_push_rate('secrets_read', 120, interval '1 minute');

  select coalesce(
           jsonb_object_agg(
             ss.source_id::text,
             jsonb_build_object('format', ss.format, 'payload', ss.payload)),
           '{}'::jsonb)
    into src
    from public.source_secrets ss
    join public.sources s on s.id = ss.source_id
   where s.profile_id = p_profile_id
     and s.owner = resolved_owner;

  select jsonb_build_object('format', m.format, 'payload', m.payload)
    into meta
    from public.metadata_secrets m
   where m.profile_id = p_profile_id
     and m.owner = resolved_owner;

  return jsonb_build_object('sources', src, 'metadata', meta);
end;
$$;

-- ---------------------------------------------------------------------------
-- Single-secret write RPCs for the panel (real user only). Replace, no merge —
-- a direct panel edit is authoritative (matches the "only a panel edit can clear
-- a credential" rule). Format enforcement (format must match the profile's E2EE
-- enabled state) is DELIBERATELY absent here and added by e2ee.sql's recreation
-- of these two functions — profile_crypto does not exist in this migration, and
-- keeping the gate in one place (Phase 3) is cleaner than a to_regclass guard.
-- ---------------------------------------------------------------------------

create or replace function public.set_source_secret(
  p_source_id uuid, p_profile_id uuid, p_format int, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_real_user() then
    raise exception 'iptvs: only a signed-in account can set a secret'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = auth.uid()
  ) then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.sources
     where id = p_source_id and owner = auth.uid() and profile_id = p_profile_id
  ) then
    raise exception 'iptvs: source not found'
      using errcode = 'check_violation';
  end if;
  perform public.assert_secret_valid(p_payload);

  insert into public.source_secrets (source_id, owner, profile_id, format, payload)
    values (p_source_id, auth.uid(), p_profile_id, p_format, coalesce(p_payload, '{}'::jsonb))
  on conflict (source_id) do update
        set owner = excluded.owner,
            profile_id = excluded.profile_id,
            format = excluded.format,
            payload = excluded.payload,
            updated_at = now()
      where public.source_secrets.owner = auth.uid();
end;
$$;

create or replace function public.set_metadata_secret(
  p_profile_id uuid, p_format int, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_real_user() then
    raise exception 'iptvs: only a signed-in account can set a secret'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = auth.uid()
  ) then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;
  perform public.assert_secret_valid(p_payload);

  insert into public.metadata_secrets (profile_id, owner, format, payload)
    values (p_profile_id, auth.uid(), p_format, coalesce(p_payload, '{}'::jsonb))
  on conflict (profile_id) do update
        set owner = excluded.owner,
            format = excluded.format,
            payload = excluded.payload,
            updated_at = now()
      where public.metadata_secrets.owner = auth.uid();
end;
$$;

-- ---------------------------------------------------------------------------
-- push_sources(jsonb, uuid): recreate the LATEST body (nondestructive_push.sql)
-- VERBATIM — every existing guard, the field-preserving merge, the
-- delete-of-removed-ids, the rate limit, the error style — and ADD:
--   (a) optional per-element "secret" object handling. Element shape:
--       { ..., "secret": { "format": int, "payload": {jsonb} } }. Absent
--       "secret" => source_secrets untouched. Phase 2 accepts only format 0
--       (rejects otherwise: 'secret format not supported' — e2ee.sql adds the
--       enabled-aware check). Format-0 upsert merges through
--       merge_preserving_nonempty when the stored row is format 0, else replaces.
--   (b) M2 cross-profile-move handling: the ON CONFLICT source update can move a
--       source between this owner's profiles. When it does AND the source's
--       secret is a format-1 E2EE envelope, DELETE that secret — the envelope's
--       AAD binds the old profile, so the panel must re-encrypt after a move.
-- ---------------------------------------------------------------------------

create or replace function public.push_sources(p_sources jsonb, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
  ids uuid[];
  moved_ids uuid[];
  sec_elem jsonb;
  payload jsonb := coalesce(p_sources, '[]'::jsonb);
  max_sources       constant int := 1000;      -- realistic <= 50 providers
  max_payload_bytes constant int := 16777216;  -- 16 MB; realistic ~2 MB
begin
  if o is null then
    raise exception 'only a paired device can push sources';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile_id and owner = o) then
    raise exception 'profile not found for this account';
  end if;

  perform public.check_push_rate('push', 30, interval '1 minute');

  -- Top-level shape/size guards (fail before any mutation). Per-source bounds
  -- are enforced by the sources_validate trigger on the inserts below.
  if jsonb_typeof(payload) <> 'array' then
    raise exception 'iptvs: sources payload must be a JSON array'
      using errcode = 'check_violation';
  end if;
  if octet_length(payload::text) > max_payload_bytes then
    raise exception 'iptvs: sources payload too large (max % bytes)', max_payload_bytes
      using errcode = 'check_violation';
  end if;
  if jsonb_array_length(payload) > max_sources then
    raise exception 'iptvs: too many sources (max %)', max_sources
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(payload) e where jsonb_typeof(e) <> 'object') then
    raise exception 'iptvs: each source must be a JSON object'
      using errcode = 'check_violation';
  end if;
  -- Reject malformed ids up front so the ::uuid casts below never raise a raw
  -- "invalid input syntax for type uuid" error to the client.
  if exists (
    select 1 from jsonb_array_elements(payload) e
     where (e ->> 'id') is null
        or (e ->> 'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) then
    raise exception 'iptvs: source id must be a UUID'
      using errcode = 'check_violation';
  end if;
  -- Same for position: the ::int cast below would otherwise raise a raw
  -- "invalid input syntax" error echoing the value. The length bound keeps the
  -- cast inside int range.
  if exists (
    select 1 from jsonb_array_elements(payload) e
     where (e ->> 'position') is not null
       and (e ->> 'position') !~ '^-?[0-9]{1,9}$'
  ) then
    raise exception 'iptvs: source position must be an integer'
      using errcode = 'check_violation';
  end if;

  select coalesce(array_agg((elem ->> 'id')::uuid), '{}')
    into ids
    from jsonb_array_elements(payload) as elem;

  -- M2: sources currently in a DIFFERENT profile of this owner that the upsert
  -- below will pull into p_profile_id. Captured before the upsert changes them.
  select coalesce(array_agg(s.id), '{}')
    into moved_ids
    from public.sources s
   where s.owner = o
     and s.profile_id is distinct from p_profile_id
     and s.id = any (ids);

  delete from public.sources
    where owner = o and profile_id = p_profile_id and not (id = any (ids));

  insert into public.sources (id, owner, profile_id, kind, label, fields, settings, position)
  select (elem ->> 'id')::uuid,
         o,
         p_profile_id,
         elem ->> 'kind',
         coalesce(elem ->> 'label', ''),
         coalesce(elem -> 'fields', '{}'::jsonb),
         coalesce(elem -> 'settings', '{}'::jsonb),
         coalesce((elem ->> 'position')::int, 0)
    from jsonb_array_elements(payload) as elem
  on conflict (id) do update
        set kind = excluded.kind,
            label = excluded.label,
            -- Field-preserving merge: a push can update or add fields but can
            -- never blank a stored non-empty credential. Only a panel edit
            -- (a direct RLS write, not this RPC) can clear one. (Post-strip the
            -- credential keys no longer live here, but the merge is retained so
            -- any non-secret field a device omits is preserved.)
            fields = public.merge_preserving_nonempty(public.sources.fields, excluded.fields),
            settings = excluded.settings,
            position = excluded.position,
            profile_id = excluded.profile_id,
            updated_at = now()
      where public.sources.owner = o;

  -- M2: a moved source's format-1 envelope is bound (AAD) to its old profile;
  -- drop it so the panel re-encrypts under the new profile. Format-0 (plaintext)
  -- secrets carry no such binding and are left in place.
  if array_length(moved_ids, 1) is not null then
    delete from public.source_secrets ss
     where ss.source_id = any (moved_ids) and ss.format = 1;
  end if;

  -- Per-element secret handling (optional). Only elements carrying a "secret"
  -- key touch source_secrets; every source row referenced already exists above,
  -- so the FK is satisfied.
  for sec_elem in select value from jsonb_array_elements(payload) where value ? 'secret'
  loop
    if (sec_elem -> 'secret' ->> 'format') is null
       or (sec_elem -> 'secret' ->> 'format') !~ '^[0-9]+$' then
      raise exception 'iptvs: secret format invalid'
        using errcode = 'check_violation';
    end if;
    -- Phase 2 stores plaintext only; e2ee.sql widens this to the enabled-aware
    -- check (format must be 1 when E2EE is on).
    if (sec_elem -> 'secret' ->> 'format')::int <> 0 then
      raise exception 'iptvs: secret format not supported'
        using errcode = 'check_violation';
    end if;
    perform public.assert_secret_valid(sec_elem -> 'secret' -> 'payload');

    insert into public.source_secrets (source_id, owner, profile_id, format, payload)
      values ((sec_elem ->> 'id')::uuid, o, p_profile_id, 0,
              coalesce(sec_elem -> 'secret' -> 'payload', '{}'::jsonb))
    on conflict (source_id) do update
          set owner = excluded.owner,
              profile_id = excluded.profile_id,
              format = excluded.format,
              payload = case when public.source_secrets.format = 0
                             then public.merge_preserving_nonempty(
                                    public.source_secrets.payload, excluded.payload)
                             else excluded.payload end,
              updated_at = now()
        where public.source_secrets.owner = o;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- push_metadata(jsonb, uuid, jsonb): NEW 3-arg overload carrying an optional
-- metadata secret. The 2-arg push_metadata (nondestructive_push.sql) is left
-- untouched. Same guards as the 2-arg (owner/profile, rate limit, config
-- validate, field-preserving config merge) plus secret handling: null secret =>
-- metadata_secrets untouched; Phase 2 accepts only format 0; format-0 upsert
-- merges through merge_preserving_nonempty when the stored row is format 0.
-- ---------------------------------------------------------------------------

create or replace function public.push_metadata(
  p_config jsonb, p_profile_id uuid, p_secret jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
  sfmt int;
begin
  if o is null then
    raise exception 'only a paired device can push metadata';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile_id and owner = o) then
    raise exception 'profile not found for this account';
  end if;

  perform public.check_push_rate('push', 30, interval '1 minute');
  perform public.assert_metadata_valid(coalesce(p_config, '{}'::jsonb));

  insert into public.metadata_configs (owner, profile_id, config)
    values (o, p_profile_id, coalesce(p_config, '{}'::jsonb))
  on conflict (profile_id) do update
        set config = public.merge_preserving_nonempty(
                       public.metadata_configs.config, excluded.config),
            owner = excluded.owner,
            updated_at = now()
      where public.metadata_configs.owner = o;

  if p_secret is not null then
    if (p_secret ->> 'format') is null or (p_secret ->> 'format') !~ '^[0-9]+$' then
      raise exception 'iptvs: secret format invalid'
        using errcode = 'check_violation';
    end if;
    sfmt := (p_secret ->> 'format')::int;
    if sfmt <> 0 then
      raise exception 'iptvs: secret format not supported'
        using errcode = 'check_violation';
    end if;
    perform public.assert_secret_valid(p_secret -> 'payload');

    insert into public.metadata_secrets (profile_id, owner, format, payload)
      values (p_profile_id, o, 0, coalesce(p_secret -> 'payload', '{}'::jsonb))
    on conflict (profile_id) do update
          set owner = excluded.owner,
              format = excluded.format,
              payload = case when public.metadata_secrets.format = 0
                             then public.merge_preserving_nonempty(
                                    public.metadata_secrets.payload, excluded.payload)
                             else excluded.payload end,
              updated_at = now()
        where public.metadata_secrets.owner = o;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants: authenticated only (the owner/device checks inside gate access). No
-- grant to anon or public; the secrets tables have no policy at all.
-- ---------------------------------------------------------------------------

revoke all on function public.get_secrets(uuid)                          from public, anon;
revoke all on function public.set_source_secret(uuid, uuid, int, jsonb)  from public, anon;
revoke all on function public.set_metadata_secret(uuid, int, jsonb)      from public, anon;
revoke all on function public.push_sources(jsonb, uuid)                  from public, anon;
revoke all on function public.push_metadata(jsonb, uuid, jsonb)          from public, anon;
grant execute on function public.get_secrets(uuid)                          to authenticated;
grant execute on function public.set_source_secret(uuid, uuid, int, jsonb)  to authenticated;
grant execute on function public.set_metadata_secret(uuid, int, jsonb)      to authenticated;
grant execute on function public.push_sources(jsonb, uuid)                  to authenticated;
grant execute on function public.push_metadata(jsonb, uuid, jsonb)          to authenticated;
