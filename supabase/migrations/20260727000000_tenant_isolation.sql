-- iptvs cloud sync — cross-tenant isolation (Phase 4 of the hardening ladder).
--
-- Background: through Phase 3 (e2ee.sql) every RPC resolved its target account
-- (`current_device_owner()` for devices, `auth.uid()` for the panel) and every
-- *catalog* write was owner-scoped. But ownership was enforced only by those
-- per-call-site predicates — the SCHEMA itself never correlated a child row's
-- `owner` with its parent's. `sources.profile_id`, `metadata_configs.profile_id`,
-- `source_secrets.source_id`, `metadata_secrets.profile_id` and
-- `profile_crypto.profile_id` are all plain single-column foreign keys, so the
-- database considered `(my owner, your parent)` a perfectly valid row. Wherever a
-- call site forgot the correlation, a caller could write across tenants.
--
-- The audited consequences this migration closes:
--
--   F1 (HIGH) push_sources planted another account's secret. The per-element
--      `"secret"` loop (e2ee.sql) only checked that `secret.id` was UUID-shaped.
--      The `sources` upsert above it IS owner-guarded — but an owner-guarded
--      `ON CONFLICT ... WHERE sources.owner = o` SILENTLY SKIPS a foreign id
--      instead of failing, so control still reached the loop, which inserted
--      `source_secrets(source_id = <victim's source>, owner = <attacker>)`.
--      `source_secrets.source_id` is FK to `sources(id)` — existence, not
--      ownership — so the row landed. `get_secrets` then handed it to the VICTIM
--      (it scoped the SOURCE by owner but never `ss.owner`), i.e. an attacker
--      could choose the `playlistUrl`/`epgUrl`/credentials a victim's player
--      uses. Secondary: the victim's own `set_source_secret` no-ops forever
--      against the planted row (`WHERE source_secrets.owner = auth.uid()`), and
--      the format gate is read from the ATTACKER's `profile_crypto`, so a
--      plaintext (format 0) row could land inside an E2EE-enabled profile.
--      Precondition: the attacker must KNOW the victim's source id (a v4 UUID —
--      see `newSourceId()` / `gen_random_uuid()`). Not guessable, but a device
--      that was ever paired to the victim's profile, or a panel account that
--      once listed it, knows it.
--
--   F2 (MEDIUM/HIGH) PK squatting. Nothing stopped account B inserting a
--      `sources` / `metadata_configs` row whose `profile_id` is account A's
--      profile. `metadata_configs.profile_id` is the PRIMARY KEY, so one squatted
--      row permanently blocks the victim's own upsert — their push_metadata
--      silently no-ops (`WHERE metadata_configs.owner = o`) forever.
--
--   F3 (MEDIUM) unbounded direct pairing inserts. `pairings_insert` let ANY
--      anonymous session INSERT a row with a caller-chosen `code` and
--      `expires_at`, bypassing `request_pairing`'s 5/min limit and 10-minute TTL
--      — an attacker-chosen, long-lived, memorable code for social engineering.
--
--   F4 (MEDIUM/HIGH) device identity was mutable. `devices_update` pins `owner`
--      (both USING and WITH CHECK) but not `device_uid`, and `devices` had no
--      trigger. An account could repoint its own device row at an arbitrary uuid.
--      Because `current_device_owner()` resolves `devices.device_uid =
--      auth.uid()`, squatting the uuid of a device that is NOT currently paired
--      makes that device believe it is paired to the ATTACKER: it then pulls the
--      attacker's sources and PUSHES ITS OWN provider credentials into the
--      attacker's profile. Realistic path: a panel owner sees every paired
--      device_uid in the Devices list, revokes one, and squats it after the
--      device is re-paired elsewhere.
--
--   F5 (LOW) the five RPC-only tables (`source_secrets`, `metadata_secrets`,
--      `profile_crypto`, `device_ck`, `push_rate`) were protected by exactly one
--      layer — "RLS enabled, zero policies" — while `anon`/`authenticated` still
--      held full default table privileges including TRUNCATE.
--
--   F6 (LOW) `claim_pairing` had no `check_push_rate` (the only unthrottled way
--      to guess a live code), and `gen_pairing_code()` kept its default PUBLIC
--      EXECUTE, exposing it as a PostgREST RPC.
--
-- Approach — STRUCTURE FIRST. F1/F2 are fixed by making the illegal state
-- unrepresentable rather than by adding another predicate to another call site:
-- `profiles` and `sources` gain a redundant `unique (id, owner)`, and every
-- owner-bearing child gains a COMPOSITE foreign key `(parent_id, owner)`. After
-- this, `source_secrets.owner` cannot disagree with `sources.owner`, and a
-- child's `profile_id` cannot point outside its own account — for the RPCs, for
-- the panel's direct RLS writes, and for anything added later. The explicit
-- checks added to `push_sources` are belt-and-braces: they turn what would be a
-- raw `foreign_key_violation` (whose DETAIL echoes ids) into a value-free
-- `iptvs: ` error, and they fail BEFORE any mutation.
--
-- DELIBERATELY NOT DONE: `alter table ... force row level security`. The five
-- RPC-only tables have ZERO policies and every accessor is a `SECURITY DEFINER`
-- function running as `postgres`, which is also the table owner. FORCE would
-- apply the (empty) policy set to the owner too, so every one of those RPCs
-- would read and write nothing. F5's table-level REVOKE is the correct
-- defence-in-depth for that layer.
--
-- PRE-FLIGHT / FAILURE MODE: the composite FKs cannot be added over rows that
-- already violate them. The DO block in section 0 counts violators per relation
-- FIRST and raises a value-free `iptvs: ` error naming only the relation. The
-- migration is applied inside a transaction (Supabase CLI / GitHub integration),
-- so that raise rolls the whole file back — it never half-applies. It is
-- deliberately NON-destructive: it will not delete a squatted row on the
-- operator's behalf, because "delete rows that look wrong" is not a decision an
-- unattended migration should make. If it fires, run the matching diagnostic and
-- decide manually:
--
--   -- squatted / mismatched children (each returns the rows to resolve):
--   select s.id from public.sources s left join public.profiles p on p.id = s.profile_id
--    where s.profile_id is not null and (p.id is null or p.owner is distinct from s.owner);
--   select m.profile_id from public.metadata_configs m left join public.profiles p on p.id = m.profile_id
--    where p.id is null or p.owner is distinct from m.owner;
--   select ss.source_id from public.source_secrets ss left join public.sources s on s.id = ss.source_id
--    where s.id is null or s.owner is distinct from ss.owner;   -- F1 plants live here
--   select ss.source_id from public.source_secrets ss left join public.profiles p on p.id = ss.profile_id
--    where p.id is null or p.owner is distinct from ss.owner;
--   select ms.profile_id from public.metadata_secrets ms left join public.profiles p on p.id = ms.profile_id
--    where p.id is null or p.owner is distinct from ms.owner;
--   select pc.profile_id from public.profile_crypto pc left join public.profiles p on p.id = pc.profile_id
--    where p.id is null or p.owner is distinct from pc.owner;
--
-- A `source_secrets` / `metadata_secrets` mismatch is recoverable by DELETing the
-- row and re-entering the credential in the panel; a `sources` mismatch is user
-- configuration and should be re-pointed (`update ... set profile_id = <a profile
-- of that row's owner>`), not deleted. As of authoring, production
-- (ctoyxtjhejobhvqasett) has ZERO violators for all six checks.
--
-- All rejection errors use errcode 'check_violation' with the stable `iptvs: `
-- prefix and never echo a payload value or an id (`friendlyError` /
-- `friendlyCloudError` render `iptvs: ` messages verbatim). Idempotent
-- throughout: guarded `alter`, `drop ... if exists` before create,
-- `create or replace` for every function.

-- ---------------------------------------------------------------------------
-- 0. Pre-flight: verify no existing row violates the constraints added below.
--    Runs before ANY DDL so a violating database fails loudly and atomically
--    rather than half-applying. Messages name the relation only — never a value.
-- ---------------------------------------------------------------------------

do $$
declare
  bad int;
begin
  select count(*) into bad
    from public.sources s
    left join public.profiles p on p.id = s.profile_id
   where s.profile_id is not null
     and (p.id is null or p.owner is distinct from s.owner);
  if bad > 0 then
    raise exception 'iptvs: sources.profile_id points outside its own account — resolve before migrating'
      using errcode = 'check_violation';
  end if;

  select count(*) into bad
    from public.metadata_configs m
    left join public.profiles p on p.id = m.profile_id
   where p.id is null or p.owner is distinct from m.owner;
  if bad > 0 then
    raise exception 'iptvs: metadata_configs.profile_id points outside its own account — resolve before migrating'
      using errcode = 'check_violation';
  end if;

  select count(*) into bad
    from public.source_secrets ss
    left join public.sources s on s.id = ss.source_id
   where s.id is null or s.owner is distinct from ss.owner;
  if bad > 0 then
    raise exception 'iptvs: source_secrets.owner disagrees with its source owner — resolve before migrating'
      using errcode = 'check_violation';
  end if;

  select count(*) into bad
    from public.source_secrets ss
    left join public.profiles p on p.id = ss.profile_id
   where p.id is null or p.owner is distinct from ss.owner;
  if bad > 0 then
    raise exception 'iptvs: source_secrets.profile_id points outside its own account — resolve before migrating'
      using errcode = 'check_violation';
  end if;

  select count(*) into bad
    from public.metadata_secrets ms
    left join public.profiles p on p.id = ms.profile_id
   where p.id is null or p.owner is distinct from ms.owner;
  if bad > 0 then
    raise exception 'iptvs: metadata_secrets.profile_id points outside its own account — resolve before migrating'
      using errcode = 'check_violation';
  end if;

  select count(*) into bad
    from public.profile_crypto pc
    left join public.profiles p on p.id = pc.profile_id
   where p.id is null or p.owner is distinct from pc.owner;
  if bad > 0 then
    raise exception 'iptvs: profile_crypto.profile_id points outside its own account — resolve before migrating'
      using errcode = 'check_violation';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Composite parent keys. `id` is already the PRIMARY KEY on both tables, so
--    `unique (id, owner)` is logically redundant — it exists solely to give the
--    composite foreign keys in section 2 something to reference. It can never
--    fail on existing data (a superset of an already-unique column).
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'profiles_id_owner_key' and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles add constraint profiles_id_owner_key unique (id, owner);
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'sources_id_owner_key' and conrelid = 'public.sources'::regclass
  ) then
    alter table public.sources add constraint sources_id_owner_key unique (id, owner);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Composite foreign keys — the structural fix for F1 and F2.
--
--    Each one ADDS to (does not replace) the existing single-column FK. Keeping
--    both is deliberate: the single-column FKs carry auto-generated names this
--    migration would have to hard-code to drop, and a second `on delete cascade`
--    to the same child row is a no-op, so the redundancy costs nothing and the
--    coverage is strictly stronger. `on update` is left at the default (NO
--    ACTION / error): neither `profiles.id`, `profiles.owner`, `sources.id` nor
--    `sources.owner` is ever updated by any RPC, policy or client — `owner` is
--    pinned by every write policy's WITH CHECK (`owner = auth.uid()`) and no
--    upsert assigns it — so an owner change should surface as an error, not
--    silently rewrite children.
--
--    `sources.profile_id` is nullable; MATCH SIMPLE (the default) skips the check
--    when any referencing column is NULL, so pre-profiles legacy rows are
--    unaffected. Every other referencing column is NOT NULL, so those FKs are
--    always checked.
--
--    POSTGREST CAVEAT: keeping both FKs means each affected table pair now has
--    TWO relationships, so PostgREST *resource embedding* between them becomes
--    ambiguous (PGRST201, "more than one relationship was found"). Verified safe
--    today — neither client embeds anything (every `.select()` in `panel/src/`
--    and `lib/data/cloud_sync.dart` lists plain columns). A future embed must
--    disambiguate by constraint name, e.g.
--    `.select('*, profiles!sources_profile_id_fkey(*)')`.
-- ---------------------------------------------------------------------------

do $$
begin
  -- F2: a source may only sit in a profile owned by the same account.
  if not exists (
    select 1 from pg_constraint
     where conname = 'sources_profile_owner_fkey' and conrelid = 'public.sources'::regclass
  ) then
    alter table public.sources
      add constraint sources_profile_owner_fkey
      foreign key (profile_id, owner) references public.profiles(id, owner)
      on delete cascade;
  end if;

  -- F2: `profile_id` is metadata_configs' PRIMARY KEY, so this is what stops a
  -- foreign account permanently occupying the victim's only metadata row.
  if not exists (
    select 1 from pg_constraint
     where conname = 'metadata_configs_profile_owner_fkey'
       and conrelid = 'public.metadata_configs'::regclass
  ) then
    alter table public.metadata_configs
      add constraint metadata_configs_profile_owner_fkey
      foreign key (profile_id, owner) references public.profiles(id, owner)
      on delete cascade;
  end if;

  -- F1: THE fix. A secret row's owner is now structurally forced to equal the
  -- owner of the source it belongs to, so the planted
  -- `(victim source, attacker owner)` row is rejected by the database itself —
  -- in push_sources, in set_source_secret, and in anything added later.
  if not exists (
    select 1 from pg_constraint
     where conname = 'source_secrets_source_owner_fkey'
       and conrelid = 'public.source_secrets'::regclass
  ) then
    alter table public.source_secrets
      add constraint source_secrets_source_owner_fkey
      foreign key (source_id, owner) references public.sources(id, owner)
      on delete cascade;
  end if;

  -- `source_secrets.profile_id` is documented as advisory (the authoritative
  -- scope is the join to `sources`), but advisory should still not mean
  -- cross-tenant: pin it to a profile of the same owner.
  if not exists (
    select 1 from pg_constraint
     where conname = 'source_secrets_profile_owner_fkey'
       and conrelid = 'public.source_secrets'::regclass
  ) then
    alter table public.source_secrets
      add constraint source_secrets_profile_owner_fkey
      foreign key (profile_id, owner) references public.profiles(id, owner)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'metadata_secrets_profile_owner_fkey'
       and conrelid = 'public.metadata_secrets'::regclass
  ) then
    alter table public.metadata_secrets
      add constraint metadata_secrets_profile_owner_fkey
      foreign key (profile_id, owner) references public.profiles(id, owner)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'profile_crypto_profile_owner_fkey'
       and conrelid = 'public.profile_crypto'::regclass
  ) then
    alter table public.profile_crypto
      add constraint profile_crypto_profile_owner_fkey
      foreign key (profile_id, owner) references public.profiles(id, owner)
      on delete cascade;
  end if;
end $$;

-- `device_ck` is deliberately left alone: it has NO owner column (e2ee.sql
-- finding M8 — adding one would break `touch_profile_snapshot_revision`), so
-- there is nothing to correlate. Its (device, profile) pair is verified against
-- `auth.uid()` on BOTH sides by every write path (`provision_device_ck`,
-- `enable_e2ee`, `rotate_passphrase`, `rotate_content_key`) and its only read
-- path (`get_device_ck`) is scoped to the calling device.

-- ---------------------------------------------------------------------------
-- 3. push_sources(jsonb, uuid): body copied VERBATIM from e2ee.sql, with two
--    additions and nothing else changed.
--
--    (a) Before any mutation, reject a payload id that already exists under a
--        DIFFERENT account. This is the silent-no-op that let F1 reach the secret
--        loop, and on its own it lets a foreign account squat a source id so the
--        victim's push never lands. Explicit check, not ROW_COUNT accounting: it
--        fails before the delete/upsert, consistent with the file's other
--        top-level guards, and produces a value-free error.
--    (b) In the per-element secret loop, verify the source is this owner's AND in
--        this profile before touching `source_secrets`. Redundant with (a) and
--        with the composite FK from section 2 — kept because a bare FK violation
--        would surface as a raw `foreign_key_violation` whose DETAIL echoes ids.
--
--    Everything else — the rate limit, the shape/count/size/id/position guards,
--    the M2 moved-secret delete, the field-preserving merge, the format/ckv gate,
--    the owner-guarded ON CONFLICTs — is unchanged.
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
  sfmt int;
  pc_enabled boolean;
  pc_ckv int;
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
  if exists (
    select 1 from jsonb_array_elements(payload) e
     where (e ->> 'id') is null
        or (e ->> 'id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) then
    raise exception 'iptvs: source id must be a UUID'
      using errcode = 'check_violation';
  end if;
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

  -- (a) Cross-tenant id guard. The upsert below is owner-guarded, but an
  -- owner-guarded ON CONFLICT SKIPS a foreign row instead of failing — which is
  -- exactly what let a crafted payload carry another account's source id all the
  -- way into the secret loop (F1), and what would silently drop a squatted id
  -- from an otherwise valid push (F2). Fail loudly, before any mutation, with no
  -- value in the message.
  if exists (select 1 from public.sources s where s.id = any (ids) and s.owner <> o) then
    raise exception 'iptvs: source id belongs to another account'
      using errcode = 'check_violation';
  end if;

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
            fields = public.merge_preserving_nonempty(public.sources.fields, excluded.fields),
            settings = excluded.settings,
            position = excluded.position,
            profile_id = excluded.profile_id,
            updated_at = now()
      where public.sources.owner = o;

  -- M2: a moved source's format-1 envelope is bound to its old profile.
  if array_length(moved_ids, 1) is not null then
    delete from public.source_secrets ss
     where ss.source_id = any (moved_ids) and ss.format = 1;
  end if;

  -- Format gate for any secrets in this push.
  select pc.enabled, pc.ck_version into pc_enabled, pc_ckv
    from public.profile_crypto pc
   where pc.profile_id = p_profile_id;
  pc_enabled := coalesce(pc_enabled, false);

  for sec_elem in select value from jsonb_array_elements(payload) where value ? 'secret'
  loop
    -- (b) F1: the secret's source must belong to THIS account and THIS profile.
    -- After the upsert above every legitimately pushed id satisfies this, so a
    -- failure here means the element referenced a foreign source. Checked before
    -- anything is read out of the secret so the error carries no payload value.
    if not exists (
      select 1 from public.sources s
       where s.id = (sec_elem ->> 'id')::uuid
         and s.owner = o
         and s.profile_id = p_profile_id
    ) then
      raise exception 'iptvs: secret refers to a source outside this profile'
        using errcode = 'check_violation';
    end if;

    if (sec_elem -> 'secret' ->> 'format') is null
       or (sec_elem -> 'secret' ->> 'format') !~ '^[0-9]+$' then
      raise exception 'iptvs: secret format invalid'
        using errcode = 'check_violation';
    end if;
    sfmt := (sec_elem -> 'secret' ->> 'format')::int;
    perform public.assert_secret_valid(sec_elem -> 'secret' -> 'payload');

    if sfmt <> (case when pc_enabled then 1 else 0 end) then
      raise exception 'iptvs: secret format mismatch'
        using errcode = 'check_violation';
    end if;
    if sfmt = 1 then
      if coalesce(sec_elem -> 'secret' -> 'payload' ->> 'ckv', '') !~ '^[0-9]+$'
         or (sec_elem -> 'secret' -> 'payload' ->> 'ckv')::int <> pc_ckv then
        raise exception 'iptvs: stale content key'
          using errcode = 'check_violation';
      end if;
    end if;

    insert into public.source_secrets (source_id, owner, profile_id, format, payload)
      values ((sec_elem ->> 'id')::uuid, o, p_profile_id, sfmt,
              coalesce(sec_elem -> 'secret' -> 'payload', '{}'::jsonb))
    on conflict (source_id) do update
          set owner = excluded.owner,
              profile_id = excluded.profile_id,
              format = excluded.format,
              payload = case when public.source_secrets.format = 0 and excluded.format = 0
                             then public.merge_preserving_nonempty(
                                    public.source_secrets.payload, excluded.payload)
                             else excluded.payload end,
              updated_at = now()
        where public.source_secrets.owner = o;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. get_secrets(uuid): body copied VERBATIM from secrets_store.sql, adding ONE
--    predicate — `ss.owner = resolved_owner`. This is the read half of F1: the
--    query scoped the SOURCE by owner but never the secret row itself, so a
--    planted row was returned to the victim as if it were their own credential.
--    Section 2's composite FK now makes the two owners provably equal, but the
--    reader must not depend on a constraint it doesn't state; the metadata half
--    already filters `m.owner = resolved_owner` and this makes the two symmetric.
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
     and s.owner = resolved_owner
     and ss.owner = resolved_owner;

  select jsonb_build_object('format', m.format, 'payload', m.payload)
    into meta
    from public.metadata_secrets m
   where m.profile_id = p_profile_id
     and m.owner = resolved_owner;

  return jsonb_build_object('sources', src, 'metadata', meta);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. F3 — pairings: remove the direct INSERT path and bound the row shape.
--
--    `request_pairing()` is SECURITY DEFINER and therefore bypasses RLS, so it
--    never needed `pairings_insert`; the policy existed only as an unintended
--    direct write path. Verified against both clients before dropping: the ONLY
--    direct `pairings` access anywhere is `.from('pairings').delete()`
--    (`lib/data/cloud_sync.dart` `unpair`) — no client inserts or selects it
--    (`pairing_status`, itself DEFINER, is the read path).
--
--    NOTE on the obvious alternative: adding `is_real_user()` to the policy would
--    be WRONG — devices are anonymous users by design, so that would break the
--    intended caller rather than the attacker. Dropping is the correct fix.
--
--    `pairings_select` and `pairings_delete` are KEPT: both are strictly
--    self-scoped (`device_uid = auth.uid()`), neither is a cross-tenant surface,
--    and `pairings_delete` is actively used by `unpair` — some client/PostgREST
--    configurations request a representation on DELETE, which needs SELECT, so
--    dropping it for zero security gain would risk breaking unpair.
--
--    The trigger is belt-and-braces: it binds `request_pairing` itself and any
--    policy re-added later. Bounds are chosen so the real caller passes with
--    room — `gen_pairing_code()` emits 8 chars and `request_pairing` sets
--    `now() + interval '10 minutes'` (evaluated at the same transaction `now()`),
--    against a 64-char / 15-minute ceiling.
-- ---------------------------------------------------------------------------

drop policy if exists pairings_insert on public.pairings;

create or replace function public.pairings_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  max_code_len constant int      := 64;                  -- gen_pairing_code emits 8
  max_ttl      constant interval := interval '15 minutes'; -- request_pairing uses 10
begin
  if tg_op = 'INSERT' then
    if new.code is null or length(new.code) > max_code_len then
      raise exception 'iptvs: pairing code invalid (max % chars)', max_code_len
        using errcode = 'check_violation';
    end if;
    if new.device_uid is null then
      raise exception 'iptvs: pairing row has null fields'
        using errcode = 'check_violation';
    end if;
    if new.expires_at is null or new.expires_at > now() + max_ttl then
      raise exception 'iptvs: pairing code lifetime too long'
        using errcode = 'check_violation';
    end if;
    -- Only claim_pairing may set claimed_by, and only via UPDATE.
    if new.claimed_by is not null then
      raise exception 'iptvs: pairing code cannot be pre-claimed'
        using errcode = 'check_violation';
    end if;
  else
    -- claim_pairing updates claimed_by and nothing else; freeze the rest so a
    -- claimed code can never be re-pointed or have its TTL extended.
    if new.code is distinct from old.code
       or new.device_uid is distinct from old.device_uid
       or new.expires_at is distinct from old.expires_at then
      raise exception 'iptvs: pairing row is immutable'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists pairings_validate on public.pairings;
create trigger pairings_validate before insert or update on public.pairings
  for each row execute function public.pairings_validate();

-- ---------------------------------------------------------------------------
-- 6. F4 — devices: pin the device identity.
--
--    `devices_update` already pins `owner` in BOTH its USING and WITH CHECK
--    clauses, so an account cannot hand its device to another account or seize
--    one. The gap was `device_uid`: an RLS policy cannot correlate NEW with OLD,
--    so only a trigger can express "this column is immutable". Squatting an
--    unpaired device's uuid made `current_device_owner()` resolve that device to
--    the squatter — the device would then pull the attacker's sources and push
--    its own credentials into the attacker's profile.
--
--    Safe for every existing writer: `claim_pairing`'s `on conflict (device_uid)
--    do update set owner = excluded.owner` re-points OWNER (legitimate re-pair)
--    and never `device_uid`; `set_device_profile` writes `active_profile_id`;
--    `set_device_public_key` writes `public_key`; the panel's rename writes
--    `label`. Owner changes are intentionally NOT blocked here — re-pairing is a
--    supported flow and the policy already prevents a cross-account change.
--
--    The label/public_key bounds are the missing half of harden_cloud.sql's
--    "every client-writable column is bounded" rule: `label` is written by the
--    panel's direct RLS UPDATE and was unbounded. 512 matches the ceiling
--    `set_device_public_key` already enforces; 256 matches `profiles_validate`'s
--    name limit (longest label in production is 10 chars).
--
--    Deliberately NOT checked here: that `active_profile_id` belongs to the
--    row's owner. It is the same squatting class as F2, but it has no
--    cross-tenant effect — every consumer re-verifies profile ownership
--    (`push_sources`/`push_metadata`/`push_favorites`/`set_device_profile` all
--    reject a profile not owned by `current_device_owner()`, and pulls are
--    RLS-scoped) — while a check here would have to read `public.profiles` from
--    an INVOKER trigger under RLS, adding a real failure mode to the panel's
--    rename path for no security gain. Recorded as an accepted residual.
-- ---------------------------------------------------------------------------

create or replace function public.devices_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  max_label      constant int := 256;  -- realistic device label <= 32 chars
  max_public_key constant int := 512;  -- a base64 P-256 point is ~88 chars
begin
  -- Nested, NOT `tg_op = 'UPDATE' and new.device_uid is distinct from old.…`:
  -- PL/pgSQL evaluates an IF condition as one SQL expression with no guaranteed
  -- short-circuit, and OLD is unassigned during INSERT — touching old.device_uid
  -- there raises `record "old" is not assigned yet`.
  if tg_op = 'UPDATE' then
    if new.device_uid is distinct from old.device_uid then
      raise exception 'iptvs: device identity is immutable'
        using errcode = 'check_violation';
    end if;
  end if;
  -- An explicit null would reach the column NOT NULL, whose error DETAIL echoes
  -- the whole row — reject cleanly first (matches sources_validate).
  if new.label is null or length(new.label) > max_label then
    raise exception 'iptvs: device label invalid (max % chars)', max_label
      using errcode = 'check_violation';
  end if;
  if new.public_key is not null and length(new.public_key) > max_public_key then
    raise exception 'iptvs: device public key invalid (max % chars)', max_public_key
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists devices_validate on public.devices;
create trigger devices_validate before insert or update on public.devices
  for each row execute function public.devices_validate();

-- ---------------------------------------------------------------------------
-- 7. F6 — claim_pairing rate limit + gen_pairing_code lock-down.
--
--    claim_pairing was the only unthrottled guessing oracle in the API: a code is
--    8 chars from a 30-char alphabet (~39 bits) with a 10-minute TTL, and an
--    authenticated account could try them as fast as PostgREST would answer.
--    10/min per calling account is far above human use (a person types one code)
--    and reduces an online search to nothing against a 10-minute window.
--
--    Body otherwise VERBATIM from harden_cloud.sql. The guard order matches the
--    push RPCs: identity check first (so an anonymous caller gets the same error
--    it always did), then the throttle, then the work. `check_push_rate` is
--    revoked from every client role but claim_pairing is DEFINER and owned by the
--    same role, which always retains EXECUTE on its own functions.
--
--    `gen_pairing_code()` kept PostgreSQL's default PUBLIC EXECUTE, which
--    PostgREST exposes as a callable RPC. It leaks nothing (it is a CSPRNG
--    string), but it is API surface with no client caller — `request_pairing`
--    reaches it as the owning role.
-- ---------------------------------------------------------------------------

create or replace function public.claim_pairing(p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  claimer uuid := auth.uid();
  dev uuid;
begin
  if claimer is null or not public.is_real_user() then
    raise exception 'only a signed-in account can claim a device';
  end if;

  -- Bound online code guessing (F6). Keyed on the calling account.
  perform public.check_push_rate('claim', 10, interval '1 minute');

  select device_uid into dev
    from public.pairings
    where code = upper(p_code)
      and claimed_by is null
      and expires_at > now()
    for update;

  if dev is null then
    raise exception 'invalid or expired code';
  end if;

  insert into public.devices (device_uid, owner)
    values (dev, claimer)
    on conflict (device_uid) do update set owner = excluded.owner;

  update public.pairings set claimed_by = claimer where code = upper(p_code);
end;
$$;

revoke all on function public.gen_pairing_code() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. F5 — table-level REVOKE (defence in depth).
--
--    The five RPC-only tables are protected today by exactly one mechanism:
--    "RLS enabled, zero policies". That is correct but single-layer — a policy
--    added by mistake, or a future `alter table ... disable row level security`,
--    immediately exposes raw credentials, wrapped content keys and device key
--    material to any holder of the public anon key. Removing the underlying
--    grants makes the tables unreachable to `anon`/`authenticated` even then.
--
--    Safe for every accessor: all of them are SECURITY DEFINER functions owned by
--    the same role that owns the tables, and an owner's privileges do not come
--    from these grants. The BEFORE/AFTER triggers on the secret tables likewise
--    only ever fire inside those DEFINER calls. `service_role` is untouched (it
--    backs the dashboard and is never shipped to a client).
--
--    The five client-facing tables keep their DML grants (the panel writes them
--    directly under RLS) but lose the privileges no client path uses: TRUNCATE
--    (which RLS does NOT filter — a truncate ignores policies entirely, so
--    holding it on an RLS-protected table is a latent full-wipe primitive),
--    plus REFERENCES and TRIGGER.
-- ---------------------------------------------------------------------------

revoke all on table
  public.source_secrets,
  public.metadata_secrets,
  public.profile_crypto,
  public.device_ck,
  public.push_rate
from anon, authenticated;

revoke truncate, references, trigger on table
  public.sources,
  public.metadata_configs,
  public.devices,
  public.pairings,
  public.profiles
from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 9. Re-affirm execution grants for the recreated functions. `create or replace`
--    preserves existing grants; this documents intent and matches the pattern in
--    harden_cloud.sql / secrets_store.sql / e2ee.sql. No grant to `anon`.
--    The two new trigger functions get no grant at all, unlike harden_cloud.sql's
--    `assert_*` validators. The difference is what they CALL: firing a trigger is
--    not privilege-checked (EXECUTE is required only to CREATE the trigger), but a
--    function the trigger body invokes is checked against the writing role — which
--    is why `assert_source_valid` needed a grant to `authenticated`. Neither
--    `pairings_validate` nor `devices_validate` calls anything outside pg_catalog,
--    so no role needs EXECUTE on them. (`pairings_validate` only ever fires under
--    `request_pairing`/`claim_pairing`, both DEFINER, since DELETE — the one direct
--    client write left on `pairings` — has no trigger; `devices_validate` also
--    fires under the panel's direct RLS rename.)
-- ---------------------------------------------------------------------------

revoke all on function public.push_sources(jsonb, uuid) from public, anon;
revoke all on function public.get_secrets(uuid)         from public, anon;
revoke all on function public.claim_pairing(text)       from public, anon;
grant execute on function public.push_sources(jsonb, uuid) to authenticated;
grant execute on function public.get_secrets(uuid)         to authenticated;
grant execute on function public.claim_pairing(text)       to authenticated;
