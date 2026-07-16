-- iptvs cloud sync — RLS / RPC / payload hardening (PR 11).
--
-- Threat model (this repo is open source; the anon/publishable key ships in the
-- app and the web panel, so correctness rests entirely on the SQL boundary):
--   * A holder of the public anon key can open an anonymous (device) session and
--     a real account can sign in via magic link. Neither may exceed what RLS +
--     these SECURITY DEFINER RPCs allow. A paired device may already READ all of
--     its own owner's data, so the blast radius of any device write is exactly
--     that one account — but a crafted payload must never (a) touch another
--     account's rows, (b) exhaust the free-tier Postgres instance, or (c) echo
--     credential-bearing input back through an error.
--
-- What this migration changes (no behavior change for valid callers):
--   1. Pins `search_path = ''` on every SECURITY DEFINER / DEFINER-reachable
--      function and schema-qualifies every reference (Supabase advisor-clean).
--   2. Adds shape/length/count/size validation for every device→cloud write,
--      enforced by BEFORE triggers on the tables (so it binds BOTH the panel's
--      direct RLS writes AND the RPC writes) plus cheap top-level array/size
--      guards in the push RPCs (so an oversized push fails before any mutation).
--   3. Adds a DB-side token-window rate limit on the three push RPCs.
--   4. Makes the profile cap concurrency-safe (advisory lock) and INVOKER.
--
-- Sizing philosophy (NON-NEGOTIABLE): the thing being protected is the free-tier
-- database, never the user. Every limit is sized with >=10x headroom over a
-- realistic maximum measured against the project's 250,000-channel validation
-- corpus (docs/validation-baseline.md). The two fields that scale with portal
-- size — a power user's accumulated favorites, and per-source hidden-category
-- lists on a portal exposing thousands of categories — get the most headroom.
-- Each constant below states the realistic maximum it was sized against.
--
-- All rejection errors use errcode 'check_violation' and a stable 'iptvs: '
-- message prefix that carries the LIMIT ONLY — never the offending value — so
-- the Flutter client and panel can surface them without leaking credentials
-- (matches the enforce_profile_cap pattern). Idempotent throughout.

-- ---------------------------------------------------------------------------
-- Rate limiting: one row per calling session per bucket, updated in place
-- (no unbounded growth, unlike an append-only log).
-- ---------------------------------------------------------------------------

-- `subject` is the calling session (auth.uid()) — the anonymous device session
-- for a push, i.e. the entity we actually throttle. Not the account owner: two
-- devices on one account are two independent, human-driven callers.
create table if not exists public.push_rate (
  subject      uuid        not null,
  bucket       text        not null,
  window_start timestamptz not null default now(),
  count        int         not null default 0,
  primary key (subject, bucket)
);

-- Deny-by-default: RLS on, ZERO policies. Only the SECURITY DEFINER functions
-- below (owned by the migration role) ever read/write this table.
alter table public.push_rate enable row level security;

-- Token-window rate limit. Concurrent-safe: the INSERT .. ON CONFLICT DO UPDATE
-- takes a row lock on the conflicting row for the rest of the transaction, so
-- concurrent increments for the same subject serialize. Returns nothing; raises
-- when the post-increment count exceeds p_limit within the window.
--
-- SECURITY DEFINER + revoked from every client role (below): it is only ever
-- called from the push RPCs, which are themselves DEFINER and owned by the same
-- role — an owner always retains EXECUTE on its own functions regardless of the
-- REVOKEs, so no client role needs a grant.
create or replace function public.check_push_rate(
  p_bucket text, p_limit int, p_window interval)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := auth.uid();
  cur int;
begin
  if o is null then
    return; -- no session to meter; the callers already reject unpaired callers
  end if;

  insert into public.push_rate as pr (subject, bucket, window_start, count)
    values (o, p_bucket, now(), 1)
  on conflict (subject, bucket) do update
    set window_start = case when pr.window_start < now() - p_window
                            then now() else pr.window_start end,
        count        = case when pr.window_start < now() - p_window
                            then 1 else pr.count + 1 end
  returning pr.count into cur;

  if cur > p_limit then
    raise exception 'iptvs: too many requests, slow down'
      using errcode = 'check_violation';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Validation helpers (pure: inspect their jsonb argument, touch no table, hold
-- no secret). Called from the INVOKER validation triggers below AND from the
-- DEFINER push RPCs. Because the triggers run as the writing (authenticated)
-- user, that role must be able to EXECUTE these — they are harmless argument
-- validators, so granting EXECUTE to authenticated leaks nothing.
-- Every shape is checked defensively (jsonb_typeof before any structural op) so
-- a malformed payload yields a clean 'iptvs: ' error, never a raw cast/type
-- error. That includes anything the table's own constraints would otherwise
-- catch (the sources_kind_check CHECK, NOT NULL columns): those constraint
-- errors carry a "Failing row contains (...)" DETAIL that would echo the
-- caller's credential-bearing row back over the wire, so the validators and
-- triggers must reject first (BEFORE row triggers run before constraints).
-- ---------------------------------------------------------------------------

create or replace function public.assert_source_valid(
  p_kind text, p_label text, p_fields jsonb, p_settings jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  -- Realistic maxima on the 250k-channel corpus -> >=10x ceilings:
  max_label        constant int := 1024;    -- realistic label <= 64 chars
  max_field_keys   constant int := 64;      -- realistic <= 8 keys per source
  max_field_value  constant int := 8192;    -- realistic <= 2048 (a long URL)
  max_fields_bytes constant int := 65536;   -- realistic <= 8 KB of fields
  -- settings.hiddenCategories scales with portal size (thousands of categories):
  max_settings_bytes  constant int := 8388608;  -- 8 MB; realistic ~600 KB (3 kinds x 5000 ids)
  max_hidden_per_kind constant int := 50000;     -- realistic <= 5000 hidden ids per kind
  max_hidden_id_len   constant int := 256;       -- realistic <= 100 (an M3U group-title id)
  f jsonb := coalesce(p_fields, '{}'::jsonb);
  s jsonb := coalesce(p_settings, '{}'::jsonb);
  hc jsonb;
begin
  -- Reject before the table's own sources_kind_check CHECK constraint can fire
  -- (its error DETAIL echoes the whole row, credentials included).
  if p_kind is null or p_kind not in ('stalker', 'xtream', 'm3u', 'demo') then
    raise exception 'iptvs: unknown source kind'
      using errcode = 'check_violation';
  end if;

  if length(coalesce(p_label, '')) > max_label then
    raise exception 'iptvs: source label too long (max % chars)', max_label
      using errcode = 'check_violation';
  end if;

  -- fields
  if jsonb_typeof(f) <> 'object' then
    raise exception 'iptvs: source fields must be a JSON object'
      using errcode = 'check_violation';
  end if;
  if octet_length(f::text) > max_fields_bytes then
    raise exception 'iptvs: source fields too large (max % bytes)', max_fields_bytes
      using errcode = 'check_violation';
  end if;
  if (select count(*) from jsonb_object_keys(f)) > max_field_keys then
    raise exception 'iptvs: too many source fields (max %)', max_field_keys
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_each_text(f) e where length(e.value) > max_field_value) then
    raise exception 'iptvs: source field value too long (max % chars)', max_field_value
      using errcode = 'check_violation';
  end if;

  -- settings
  if jsonb_typeof(s) <> 'object' then
    raise exception 'iptvs: source settings must be a JSON object'
      using errcode = 'check_violation';
  end if;
  if octet_length(s::text) > max_settings_bytes then
    raise exception 'iptvs: source settings too large (max % bytes)', max_settings_bytes
      using errcode = 'check_violation';
  end if;
  if s ? 'hiddenCategories' then
    hc := s -> 'hiddenCategories';
    if jsonb_typeof(hc) <> 'object' then
      raise exception 'iptvs: hiddenCategories must be a JSON object'
        using errcode = 'check_violation';
    end if;
    -- Every per-kind entry must be an array (checked first so the length probe
    -- below never calls jsonb_array_length on a non-array).
    if exists (select 1 from jsonb_each(hc) e where jsonb_typeof(e.value) <> 'array') then
      raise exception 'iptvs: hiddenCategories entries must be arrays'
        using errcode = 'check_violation';
    end if;
    if exists (select 1 from jsonb_each(hc) e where jsonb_array_length(e.value) > max_hidden_per_kind) then
      raise exception 'iptvs: too many hidden categories (max % per kind)', max_hidden_per_kind
        using errcode = 'check_violation';
    end if;
    if exists (
      select 1
        from jsonb_each(hc) e,
             lateral jsonb_array_elements_text(e.value) as cid
       where length(cid) > max_hidden_id_len
    ) then
      raise exception 'iptvs: hidden category id too long (max % chars)', max_hidden_id_len
        using errcode = 'check_violation';
    end if;
  end if;
end;
$$;

create or replace function public.assert_favorites_valid(p_favorites jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  -- A power user accumulates favorites one at a time over months; on a 250k
  -- portal that realistically reaches tens of thousands.
  max_favorites       constant int := 200000;    -- realistic <= 20000 favorites
  max_favorites_bytes constant int := 16777216;  -- 16 MB; realistic ~2 MB
  max_item_id_len     constant int := 512;        -- realistic <= 128 chars
  max_kind_len        constant int := 16;         -- 'live'/'movie'/'series'
  max_source_id_len   constant int := 64;         -- a UUID is 36 chars
  fav jsonb := coalesce(p_favorites, '[]'::jsonb);
begin
  if jsonb_typeof(fav) <> 'array' then
    raise exception 'iptvs: favorites must be a JSON array'
      using errcode = 'check_violation';
  end if;
  if octet_length(fav::text) > max_favorites_bytes then
    raise exception 'iptvs: favorites payload too large (max % bytes)', max_favorites_bytes
      using errcode = 'check_violation';
  end if;
  if jsonb_array_length(fav) > max_favorites then
    raise exception 'iptvs: too many favorites (max %)', max_favorites
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(fav) e where jsonb_typeof(e) <> 'object') then
    raise exception 'iptvs: each favorite must be a JSON object'
      using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from jsonb_array_elements(fav) e
     where (e ->> 'source_id') is null
        or length(e ->> 'source_id') > max_source_id_len
  ) then
    raise exception 'iptvs: favorite source id invalid'
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(fav) e where length(coalesce(e ->> 'kind', '')) > max_kind_len) then
    raise exception 'iptvs: favorite kind too long (max % chars)', max_kind_len
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(fav) e where length(coalesce(e ->> 'item_id', '')) > max_item_id_len) then
    raise exception 'iptvs: favorite item id too long (max % chars)', max_item_id_len
      using errcode = 'check_violation';
  end if;
end;
$$;

create or replace function public.assert_metadata_valid(p_config jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  max_config_bytes constant int := 65536;  -- 64 KB; realistic < 1 KB
  max_value_len    constant int := 1024;   -- realistic <= 256 (an API key)
  c jsonb := coalesce(p_config, '{}'::jsonb);
begin
  if jsonb_typeof(c) <> 'object' then
    raise exception 'iptvs: metadata config must be a JSON object'
      using errcode = 'check_violation';
  end if;
  if octet_length(c::text) > max_config_bytes then
    raise exception 'iptvs: metadata config too large (max % bytes)', max_config_bytes
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_each_text(c) e where length(e.value) > max_value_len) then
    raise exception 'iptvs: metadata value too long (max % chars)', max_value_len
      using errcode = 'check_violation';
  end if;
end;
$$;

-- Only the internal callers touch these; the trigger context (authenticated)
-- needs EXECUTE, everything else does not.
revoke all on function public.check_push_rate(text, int, interval) from public, anon, authenticated;
revoke all on function public.assert_source_valid(text, text, jsonb, jsonb) from public, anon;
revoke all on function public.assert_favorites_valid(jsonb) from public, anon;
revoke all on function public.assert_metadata_valid(jsonb) from public, anon;
grant execute on function public.assert_source_valid(text, text, jsonb, jsonb) to authenticated;
grant execute on function public.assert_favorites_valid(jsonb) to authenticated;
grant execute on function public.assert_metadata_valid(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Validation triggers (INVOKER: run as the writing user; they only inspect NEW
-- and call the pure validators). BEFORE INSERT OR UPDATE binds both the panel's
-- direct RLS writes and the RPC writes. Using a trigger (not a CHECK constraint)
-- avoids Postgres's "Failing row contains (...)" DETAIL, which would echo
-- credential-bearing `fields` back through the client, and needs no table
-- rewrite / NOT VALID+VALIDATE dance to deploy on a live table.
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
  perform public.assert_source_valid(new.kind, new.label, new.fields, new.settings);
  return new;
end;
$$;

create or replace function public.profiles_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  max_name constant int := 256;  -- realistic profile name <= 64 chars
begin
  -- Explicit nulls would reach the NOT NULL constraints, whose error DETAIL
  -- echoes the full row (the favorites blob included) — reject cleanly first.
  if new.name is null or new.favorites is null or new.position is null then
    raise exception 'iptvs: profile row has null fields'
      using errcode = 'check_violation';
  end if;
  if length(new.name) > max_name then
    raise exception 'iptvs: profile name too long (max % chars)', max_name
      using errcode = 'check_violation';
  end if;
  perform public.assert_favorites_valid(new.favorites);
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
  perform public.assert_metadata_valid(new.config);
  return new;
end;
$$;

drop trigger if exists sources_validate on public.sources;
create trigger sources_validate before insert or update on public.sources
  for each row execute function public.sources_validate();

drop trigger if exists profiles_validate on public.profiles;
create trigger profiles_validate before insert or update on public.profiles
  for each row execute function public.profiles_validate();

drop trigger if exists metadata_validate on public.metadata_configs;
create trigger metadata_validate before insert or update on public.metadata_configs
  for each row execute function public.metadata_validate();

-- ---------------------------------------------------------------------------
-- search_path='' sweep of the existing SECURITY DEFINER / DEFINER-reachable
-- functions. Bodies are copied verbatim from the latest migration that defines
-- each (init / fix_request_pairing / profiles), changing ONLY search_path and
-- adding the new guard calls where noted. `create or replace` preserves grants;
-- they are re-affirmed at the end for defence in depth.
-- ---------------------------------------------------------------------------

-- current_device_owner: unchanged logic (SECURITY INVOKER, from harden_api);
-- only search_path is tightened to ''.
create or replace function public.current_device_owner()
returns uuid
language sql
stable
security invoker
set search_path = ''
as $$
  select owner from public.devices where device_uid = auth.uid()
$$;

-- request_pairing: verbatim from fix_request_pairing; search_path -> ''. Its own
-- per-device rate limit (5/min) is unchanged.
create or replace function public.request_pairing()
returns table (code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  dev uuid := auth.uid();
  new_code text;
  recent int;
begin
  if dev is null then
    raise exception 'not authenticated';
  end if;

  -- Rate limit: at most 5 requests per device per minute.
  select count(*) into recent
    from public.pairings
    where device_uid = dev and created_at > now() - interval '1 minute';
  if recent >= 5 then
    raise exception 'too many pairing requests, slow down';
  end if;

  -- Drop this device's previous unclaimed/expired codes.
  delete from public.pairings as p
    where p.device_uid = dev and (p.claimed_by is null or p.expires_at < now());

  -- Generate a unique code (retry on the rare collision).
  loop
    new_code := public.gen_pairing_code();
    begin
      insert into public.pairings (code, device_uid, expires_at)
        values (new_code, dev, now() + interval '10 minutes');
      exit;
    exception when unique_violation then
      -- try again
    end;
  end loop;

  return query
    select p.code, p.expires_at from public.pairings p where p.code = new_code;
end;
$$;

-- pairing_status: verbatim from init; search_path -> ''. Still filtered by
-- device_uid = auth.uid(), so p_code alone can't probe another device's status.
create or replace function public.pairing_status(p_code text)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.pairings
    where code = p_code
      and device_uid = auth.uid()
      and claimed_by is not null
  )
$$;

-- claim_pairing: verbatim from init; search_path -> ''. Single-use/transactional
-- (FOR UPDATE + claimed_by-null guard) unchanged.
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

-- ---------------------------------------------------------------------------
-- Push RPCs: verbatim bodies from profiles.sql; search_path -> '' plus the new
-- guards. Guard ORDER is deliberate: owner resolution and profile-ownership
-- checks run FIRST (so an unpaired caller / cross-account profile gets the same
-- existing error), THEN the rate limit, THEN the top-level shape/count/size
-- guards — so a valid-but-throttled caller is rejected before we scan the
-- payload, and an oversized payload fails before any row is touched. Per-row
-- field/settings/favorite bounds are enforced by the BEFORE triggers above when
-- the insert/update executes (rolling back the whole transaction atomically).
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
            fields = excluded.fields,
            settings = excluded.settings,
            position = excluded.position,
            profile_id = excluded.profile_id,
            updated_at = now()
      where public.sources.owner = o;
end;
$$;

create or replace function public.push_metadata(p_config jsonb, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
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
        set config = excluded.config,
            owner = excluded.owner,
            updated_at = now()
      where public.metadata_configs.owner = o;
end;
$$;

create or replace function public.push_favorites(p_favorites jsonb, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
begin
  if o is null then
    raise exception 'only a paired device can push favorites';
  end if;

  perform public.check_push_rate('push', 30, interval '1 minute');
  perform public.assert_favorites_valid(coalesce(p_favorites, '[]'::jsonb));

  update public.profiles
     set favorites = coalesce(p_favorites, '[]'::jsonb), updated_at = now()
   where id = p_profile_id and owner = o;
  if not found then
    raise exception 'profile not found for this account';
  end if;
end;
$$;

-- set_device_profile: verbatim from profiles.sql; search_path -> ''.
create or replace function public.set_device_profile(p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
begin
  if o is null then
    raise exception 'only a paired device can set its profile';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile_id and owner = o) then
    raise exception 'profile not found for this account';
  end if;
  update public.devices set active_profile_id = p_profile_id where device_uid = auth.uid();
end;
$$;

-- Legacy 1-arg delegates (older app builds): verbatim from profiles.sql;
-- search_path -> ''. They delegate to the 2-arg forms, so validation + rate
-- limiting apply to them too, without breaking valid legacy payloads.
create or replace function public.push_sources(p_sources jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  pid uuid;
begin
  select active_profile_id into pid from public.devices where device_uid = auth.uid();
  if pid is null then
    raise exception 'no active profile for this device';
  end if;
  perform public.push_sources(p_sources, pid);
end;
$$;

create or replace function public.push_metadata(p_config jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  pid uuid;
begin
  select active_profile_id into pid from public.devices where device_uid = auth.uid();
  if pid is null then
    raise exception 'no active profile for this device';
  end if;
  perform public.push_metadata(p_config, pid);
end;
$$;

-- ---------------------------------------------------------------------------
-- Profile cap: recreate as SECURITY INVOKER (a user can always SELECT its own
-- profiles under profiles_select, and can only INSERT its own under
-- profiles_insert, so the INVOKER count is exact and this leaves the advisor's
-- SECURITY DEFINER list) with search_path='' and an advisory lock keyed on the
-- owner so concurrent inserts for the same account serialize and cannot race
-- past the cap (the previous count-then-insert was a TOCTOU gap).
-- ---------------------------------------------------------------------------

create or replace function public.enforce_profile_cap()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  cap constant int := 20;
begin
  -- Serialize concurrent inserts for this owner within the transaction.
  perform pg_advisory_xact_lock(hashtextextended(new.owner::text, 0));
  if (select count(*) from public.profiles where owner = new.owner) >= cap then
    raise exception 'profile limit reached (%)', cap
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_cap on public.profiles;
create trigger profiles_cap before insert on public.profiles
  for each row execute function public.enforce_profile_cap();

-- ---------------------------------------------------------------------------
-- delete_account: verbatim from account_deletion (already search_path='');
-- only addition is reaping the deleted devices' push_rate rows, which have no
-- FK to cascade on (keeps the "no unbounded growth" property honest).
-- ---------------------------------------------------------------------------

create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  account_id uuid := auth.uid();
  paired_device_ids uuid[];
begin
  if account_id is null or not public.is_real_user() then
    raise exception 'only a signed-in account can delete itself';
  end if;

  select coalesce(array_agg(d.device_uid), '{}'::uuid[])
    into paired_device_ids
    from public.devices as d
   where d.owner = account_id;

  -- This is intentionally the current caller only. The owner FKs delete all
  -- cloud rows before the function removes the paired anonymous identities.
  delete from auth.users where id = account_id;
  -- Claimed pairing rows cascade with the account. Remove any expired or
  -- newly requested unclaimed rows for those same devices as well.
  delete from public.pairings where device_uid = any(paired_device_ids);
  -- Rate-limit rows are keyed by device session and have no FK; reap them too.
  delete from public.push_rate where subject = any(paired_device_ids);
  -- A forged/legacy devices row must never let one account delete another real
  -- account. Only anonymous identities are device identities.
  delete from auth.users
   where id = any(paired_device_ids)
     and is_anonymous is true;
end;
$$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- ---------------------------------------------------------------------------
-- Re-affirm execution grants for every recreated function (create-or-replace
-- keeps existing grants; this is defence in depth and documents intent). No new
-- grant is given to `anon`; the anon role can reach nothing added here.
-- ---------------------------------------------------------------------------

revoke all on function public.request_pairing()       from public, anon;
revoke all on function public.pairing_status(text)     from public, anon;
revoke all on function public.claim_pairing(text)      from public, anon;
grant execute on function public.request_pairing()     to authenticated;
grant execute on function public.pairing_status(text)  to authenticated;
grant execute on function public.claim_pairing(text)   to authenticated;

revoke all on function public.push_sources(jsonb, uuid)   from public, anon;
revoke all on function public.push_metadata(jsonb, uuid)  from public, anon;
revoke all on function public.push_favorites(jsonb, uuid) from public, anon;
revoke all on function public.set_device_profile(uuid)    from public, anon;
revoke all on function public.push_sources(jsonb)         from public, anon;
revoke all on function public.push_metadata(jsonb)        from public, anon;
grant execute on function public.push_sources(jsonb, uuid)   to authenticated;
grant execute on function public.push_metadata(jsonb, uuid)  to authenticated;
grant execute on function public.push_favorites(jsonb, uuid) to authenticated;
grant execute on function public.set_device_profile(uuid)    to authenticated;
grant execute on function public.push_sources(jsonb)         to authenticated;
grant execute on function public.push_metadata(jsonb)        to authenticated;
