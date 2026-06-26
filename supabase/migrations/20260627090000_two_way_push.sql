-- iptvs cloud sync — optional device→cloud push (two-way sync).
--
-- Until now devices were read-only by construction (anonymous sessions can't
-- write; only real accounts own/write data). This adds a *narrow, auditable*
-- write path so a paired device can push its source list and metadata config
-- back to the panel — without granting devices any direct table writes.
--
-- Security model (unchanged guarantees):
--   * Devices still hold ZERO direct INSERT/UPDATE/DELETE grants on any table.
--     The two functions below are SECURITY DEFINER and are the only write path.
--   * Each function resolves its target owner via current_device_owner() — the
--     account that claimed the calling device. An UNPAIRED anonymous caller has
--     no owner, so the functions reject it: holding the public anon key alone
--     grants nothing. An attacker can't claim someone else's account (claiming
--     requires the real user to enter the device's code), so they can't push to
--     a victim's data. A paired device can already READ all of its owner's
--     credentials, so also writing that SAME owner's list adds no cross-account
--     blast radius — the scope is exactly one account, the device's own owner.
--   * Writes are owner-scoped on every row: inserts force owner = o, and the
--     upsert's DO UPDATE is guarded by `owner = o`, so a crafted payload can
--     never hijack a row belonging to another account.
--   * Conflict resolution is last-write-wins (the push replaces the owner's set).

-- Replace the calling device's owner's sources with p_sources (a JSON array of
-- {id, kind, label, fields, position}). Full replace: rows absent from the
-- payload are deleted (so on-device deletions propagate). Idempotent — the
-- device sends stable UUID ids it shares with the cloud.
create or replace function public.push_sources(p_sources jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o uuid := public.current_device_owner();
  ids uuid[];
begin
  if o is null then
    raise exception 'only a paired device can push sources';
  end if;

  select coalesce(array_agg((elem ->> 'id')::uuid), '{}')
    into ids
    from jsonb_array_elements(coalesce(p_sources, '[]'::jsonb)) as elem;

  -- Drop this owner's sources that the device no longer has.
  delete from public.sources where owner = o and not (id = any (ids));

  -- Upsert each incoming source under this owner. The DO UPDATE is owner-guarded
  -- so a payload can never rewrite another account's row via a colliding id.
  insert into public.sources (id, owner, kind, label, fields, position)
  select (elem ->> 'id')::uuid,
         o,
         elem ->> 'kind',
         coalesce(elem ->> 'label', ''),
         coalesce(elem -> 'fields', '{}'::jsonb),
         coalesce((elem ->> 'position')::int, 0)
    from jsonb_array_elements(coalesce(p_sources, '[]'::jsonb)) as elem
  on conflict (id) do update
        set kind = excluded.kind,
            label = excluded.label,
            fields = excluded.fields,
            position = excluded.position,
            updated_at = now()
      where public.sources.owner = o;
end;
$$;

-- Upsert the calling device's owner's metadata config.
create or replace function public.push_metadata(p_config jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o uuid := public.current_device_owner();
begin
  if o is null then
    raise exception 'only a paired device can push metadata';
  end if;

  insert into public.metadata_configs (owner, config)
    values (o, coalesce(p_config, '{}'::jsonb))
  on conflict (owner) do update
        set config = excluded.config,
            updated_at = now();
end;
$$;

-- Only authenticated sessions may call; the owner check inside each function
-- does the real gating. Anonymous devices are *signed-in* anonymous users and
-- carry the `authenticated` role (is_anonymous = true), NOT the `anon` role, so
-- we revoke `anon` explicitly (matching the pairing RPCs in 0002_harden_api):
-- a request with only the publishable key and no session can't reach these.
revoke all on function public.push_sources(jsonb)  from public, anon;
revoke all on function public.push_metadata(jsonb) from public, anon;
grant execute on function public.push_sources(jsonb)  to authenticated;
grant execute on function public.push_metadata(jsonb) to authenticated;
