-- iptvs cloud sync — non-destructive device push (field-preserving merge).
--
-- Background: an earlier release (commit d45d350) stripped credentials out of
-- every device→cloud payload — a device pushed only the "cloud-safe" projection
-- of each source (e.g. an Xtream `host` with no `username`/`password`, no m3u
-- `playlistUrl` at all) and only the non-secret half of the metadata config.
-- That kept secrets off the wire, but it made the two-way sync lossy: a device
-- push replaced the stored row wholesale, so pushing a stripped payload BLANKED
-- the credentials a user had entered in the web panel. The device also stripped
-- on pull and re-overlaid whatever local secrets it happened to have, which only
-- masked the loss on the pushing device.
--
-- This migration is Phase 1 of the agreed remediation: devices now carry the
-- FULL fields (both directions), and the server refuses to let a push blank a
-- stored non-empty value. The blast radius is unchanged — a paired device may
-- already READ all of its own owner's credentials, so writing that same owner's
-- row upstream adds no cross-account exposure (see harden_cloud.sql's threat
-- model). Cloud secrets remain protected by RLS + TLS only; they are NOT
-- end-to-end encrypted. Phase 2 (isolated secrets table + accessor RPC) and
-- Phase 3 (opt-in passphrase E2EE) are the planned hardening ladder.
--
-- What this migration changes (no behavior change for a valid FULL-fields push):
--   1. Adds public.merge_preserving_nonempty(old, new) — overlays every stored
--      key whose incoming value is absent / JSON null / empty string, so a push
--      can never clear a stored field; a genuinely changed non-empty value in
--      the incoming object still wins.
--   2. Recreates push_sources(jsonb, uuid) and push_metadata(jsonb, uuid)
--      VERBATIM from harden_cloud.sql (same search_path='', the same
--      count/size/rate guards, the same delete-of-removed-ids + insert), changing
--      ONLY the ON CONFLICT update of the credential-bearing column (`fields` /
--      `config`) to merge through merge_preserving_nonempty(). Every other column
--      is untouched. The legacy 1-arg wrappers delegate to these 2-arg forms, so
--      they inherit the fix unchanged and are intentionally NOT recreated here.
--
-- Rationale for merge-on-the-server (not the client): only the panel edits a row
-- directly (RLS write), so a panel edit that deliberately CLEARS a field still
-- wins — the merge only fires on the push RPC's ON CONFLICT path. Net effect: a
-- device push never destroys a panel-entered credential; only a panel edit can.
-- Idempotent throughout (create-or-replace).

-- ---------------------------------------------------------------------------
-- Field-preserving merge. Pure (inspects only its two jsonb arguments, holds no
-- secret, touches no table). IMMUTABLE + search_path=''.
--
-- Semantics: start from the incoming object `new`, then overlay any key from the
-- stored object `old` whose incoming value is absent, JSON null, or an empty
-- string. A non-empty incoming value therefore always wins (a real edit), while
-- a missing/blank incoming value can never overwrite a stored non-empty value.
-- Edge cases: new null -> everything preserved from old; old null -> new as-is;
-- key only in new -> kept; key in both non-empty -> new wins.
-- ---------------------------------------------------------------------------

create or replace function public.merge_preserving_nonempty(old jsonb, new jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(new, '{}'::jsonb)
       || coalesce(
            (select jsonb_object_agg(o.key, o.value)
               from jsonb_each(coalesce(old, '{}'::jsonb)) as o
              where (coalesce(new, '{}'::jsonb) -> o.key) is null
                 or coalesce(coalesce(new, '{}'::jsonb) ->> o.key, '') = ''),
            '{}'::jsonb)
$$;

-- Internal helper: only the DEFINER push RPCs (owned by this role) ever call it,
-- and an owner always retains EXECUTE on its own functions, so no client role
-- needs a grant. Mirrors the check_push_rate lock-down in harden_cloud.sql.
revoke all on function public.merge_preserving_nonempty(jsonb, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- push_sources: verbatim from harden_cloud.sql; the ONLY change is the ON
-- CONFLICT `fields` assignment, which now merges through
-- merge_preserving_nonempty(stored, incoming) instead of overwriting. All
-- guards (owner/profile check, rate limit, top-level shape/count/size guards,
-- id/position syntax guards, delete-of-removed-ids) are unchanged, and per-row
-- field bounds are still enforced by the sources_validate BEFORE trigger when
-- the insert/update executes (it re-validates the MERGED fields on update).
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
            -- Field-preserving merge: a push can update or add fields but can
            -- never blank a stored non-empty credential. Only a panel edit
            -- (a direct RLS write, not this RPC) can clear one.
            fields = public.merge_preserving_nonempty(public.sources.fields, excluded.fields),
            settings = excluded.settings,
            position = excluded.position,
            profile_id = excluded.profile_id,
            updated_at = now()
      where public.sources.owner = o;
end;
$$;

-- ---------------------------------------------------------------------------
-- push_metadata: verbatim from harden_cloud.sql; the ONLY change is the ON
-- CONFLICT `config` assignment, which now merges through
-- merge_preserving_nonempty(stored, incoming). The pre-mutation
-- assert_metadata_valid guard and the metadata_validate BEFORE trigger (which
-- re-validates the MERGED config on update) are unchanged.
-- ---------------------------------------------------------------------------

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
        set config = public.merge_preserving_nonempty(public.metadata_configs.config, excluded.config),
            owner = excluded.owner,
            updated_at = now()
      where public.metadata_configs.owner = o;
end;
$$;

-- ---------------------------------------------------------------------------
-- Re-affirm execution grants for the recreated push RPCs (create-or-replace
-- keeps existing grants; this is defence in depth and documents intent, exactly
-- as harden_cloud.sql does). No grant is given to anon. The legacy 1-arg
-- wrappers are unchanged and keep their existing grants.
-- ---------------------------------------------------------------------------

revoke all on function public.push_sources(jsonb, uuid)  from public, anon;
revoke all on function public.push_metadata(jsonb, uuid) from public, anon;
grant execute on function public.push_sources(jsonb, uuid)  to authenticated;
grant execute on function public.push_metadata(jsonb, uuid) to authenticated;
