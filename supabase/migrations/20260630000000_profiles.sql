-- iptvs cloud sync — multiple profiles per account.
--
-- Until now an account held exactly one source list (sources.owner-scoped),
-- one metadata config (metadata_configs PK = owner), and devices paired to an
-- account synced that single set. This adds a `profiles` dimension: an account
-- holds several named profiles, each its own complete "device setup" — source
-- list + metadata config + disabled categories (sources.settings) + favorites
-- (profiles.favorites). A device pairs to the account, then picks which profile
-- it syncs (devices.active_profile_id).
--
-- Security model (unchanged guarantees): owner-scoping remains the boundary on
-- sources/metadata_configs — profile_id is only an extra filter, and a paired
-- device may already read all of its owner's data. Profiles themselves are
-- owner-scoped with the same deny-by-default RLS. Devices still hold ZERO direct
-- writes; the new write paths are SECURITY DEFINER RPCs that resolve the owner
-- via current_device_owner() and reject any profile not owned by that account.
--
-- Idempotent: column adds use IF NOT EXISTS, policies/triggers are dropped first,
-- functions use CREATE OR REPLACE, the PK swap and backfill are guarded.

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null references auth.users(id) on delete cascade,
  name       text not null default 'Default',
  position   int  not null default 0,
  favorites  jsonb not null default '[]'::jsonb,  -- [{source_id, kind, item_id}]
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists profiles_owner_idx on public.profiles(owner);

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- New columns on existing tables
-- ---------------------------------------------------------------------------

alter table public.sources
  add column if not exists profile_id uuid references public.profiles(id) on delete cascade;
-- Per-source preferences (e.g. hidden categories). Mirrors SourceConfig.settings.
alter table public.sources
  add column if not exists settings jsonb not null default '{}'::jsonb;
create index if not exists sources_profile_idx on public.sources(profile_id);

alter table public.metadata_configs
  add column if not exists profile_id uuid references public.profiles(id) on delete cascade;

alter table public.devices
  add column if not exists active_profile_id uuid references public.profiles(id) on delete set null;

-- ---------------------------------------------------------------------------
-- Backfill: one "Default" profile per existing owner, then point existing rows
-- at it. Leaves the current single-profile state behaving exactly as before.
-- ---------------------------------------------------------------------------

insert into public.profiles (owner, name, position)
select distinct o.owner, 'Default', 0
  from (
    select owner from public.sources
    union select owner from public.metadata_configs
    union select owner from public.devices
  ) o
 where not exists (select 1 from public.profiles p where p.owner = o.owner);

update public.sources s
   set profile_id = (
     select p.id from public.profiles p
      where p.owner = s.owner order by p.position, p.created_at limit 1)
 where s.profile_id is null;

update public.metadata_configs m
   set profile_id = (
     select p.id from public.profiles p
      where p.owner = m.owner order by p.position, p.created_at limit 1)
 where m.profile_id is null;

update public.devices d
   set active_profile_id = (
     select p.id from public.profiles p
      where p.owner = d.owner order by p.position, p.created_at limit 1)
 where d.active_profile_id is null;

-- Re-key metadata_configs to one row per profile (was one per owner). Guarded so
-- re-running is a no-op once profile_id is already the primary key.
do $$
begin
  if not exists (
    select 1
      from pg_index i
      join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey)
     where i.indrelid = 'public.metadata_configs'::regclass
       and i.indisprimary
       and a.attname = 'profile_id'
  ) then
    alter table public.metadata_configs alter column profile_id set not null;
    alter table public.metadata_configs drop constraint if exists metadata_configs_pkey;
    alter table public.metadata_configs add primary key (profile_id);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- profiles RLS (deny-by-default; owner controls, paired device may read)
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select using (owner = auth.uid() or owner = public.current_device_owner());

drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles
  for insert with check (owner = auth.uid() and public.is_real_user());

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update using (owner = auth.uid() and public.is_real_user())
            with check (owner = auth.uid() and public.is_real_user());

drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles
  for delete using (owner = auth.uid() and public.is_real_user());

-- ---------------------------------------------------------------------------
-- Profile-scoped push RPCs (replace the owner-wide ones; SECURITY DEFINER)
-- ---------------------------------------------------------------------------

-- Replace the given profile's sources with p_sources (a JSON array of
-- {id, kind, label, fields, settings, position}). Full replace within the
-- profile: rows absent from the payload are deleted. Owner- and profile-scoped.
create or replace function public.push_sources(p_sources jsonb, p_profile_id uuid)
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
  if not exists (select 1 from public.profiles where id = p_profile_id and owner = o) then
    raise exception 'profile not found for this account';
  end if;

  select coalesce(array_agg((elem ->> 'id')::uuid), '{}')
    into ids
    from jsonb_array_elements(coalesce(p_sources, '[]'::jsonb)) as elem;

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
    from jsonb_array_elements(coalesce(p_sources, '[]'::jsonb)) as elem
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

-- Upsert the given profile's metadata config.
create or replace function public.push_metadata(p_config jsonb, p_profile_id uuid)
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
  if not exists (select 1 from public.profiles where id = p_profile_id and owner = o) then
    raise exception 'profile not found for this account';
  end if;

  insert into public.metadata_configs (owner, profile_id, config)
    values (o, p_profile_id, coalesce(p_config, '{}'::jsonb))
  on conflict (profile_id) do update
        set config = excluded.config,
            owner = excluded.owner,
            updated_at = now()
      where public.metadata_configs.owner = o;
end;
$$;

-- Replace the given profile's favorites (a JSON array of {source_id, kind, item_id}).
create or replace function public.push_favorites(p_favorites jsonb, p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o uuid := public.current_device_owner();
begin
  if o is null then
    raise exception 'only a paired device can push favorites';
  end if;
  update public.profiles
     set favorites = coalesce(p_favorites, '[]'::jsonb), updated_at = now()
   where id = p_profile_id and owner = o;
  if not found then
    raise exception 'profile not found for this account';
  end if;
end;
$$;

-- Set which profile the calling device syncs. Devices RLS forbids a device
-- updating its own row directly, so this is the write path.
create or replace function public.set_device_profile(p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public
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

-- Legacy 1-arg compatibility: older app builds call push_sources(jsonb) /
-- push_metadata(jsonb) with no profile. Delegate to the calling device's active
-- profile so their push stays scoped to one profile instead of nuking all of
-- them. (Older builds' pull returns all profiles merged once >1 profile exists —
-- update devices after creating profiles.)
create or replace function public.push_sources(p_sources jsonb)
returns void
language plpgsql
security definer
set search_path = public
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
set search_path = public
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

-- Grants: authenticated only (the owner/profile checks inside do the gating).
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
