-- iptvs cloud sync — schema, row-level security, and pairing RPCs.
--
-- Security model (this repo is open source; the anon/publishable key ships in
-- the app and the web panel, so correctness rests entirely on this file):
--   * Every table has RLS enabled with NO permissive default — no policy = no
--     access. The anon key can do nothing that a policy doesn't explicitly allow.
--   * A "device" is an anonymous Supabase auth user. Anonymous sessions are
--     read-only by construction (write policies require is_anonymous = false).
--   * Real accounts (the web panel) own the data and are the only writers.
--   * Devices gain read access only after a real account claims their pairing
--     code via claim_pairing(); the link lives in `devices`.
--   * The service_role key must NEVER be embedded in any client.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- True when the current JWT is a real (non-anonymous) account. Anonymous
-- sign-ins carry is_anonymous = true; everything else is treated as a real user.
create or replace function public.is_real_user()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
$$;

-- BEFORE UPDATE trigger: keep updated_at honest regardless of what the client sends.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- One row per saved provider. Maps 1:1 to the app's SourceConfig
-- (id / kind / label / fields). `fields` holds credentials (Stalker MAC,
-- Xtream user/pass, M3U URLs) — isolated per-user by RLS + HTTPS.
create table if not exists public.sources (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('stalker', 'xtream', 'm3u', 'demo')),
  label      text not null default '',
  fields     jsonb not null default '{}'::jsonb,
  position   int  not null default 0,
  updated_at timestamptz not null default now()
);
create index if not exists sources_owner_idx on public.sources(owner);

-- Per-user metadata provider config (TMDB/TVDB/MDBList keys), one row per user.
create table if not exists public.metadata_configs (
  owner      uuid primary key references auth.users(id) on delete cascade,
  config     jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- A paired device. device_uid is the device's anonymous auth user id; owner is
-- the real account it was claimed by. Deleting the row revokes the device.
create table if not exists public.devices (
  device_uid uuid primary key,
  owner      uuid not null references auth.users(id) on delete cascade,
  label      text not null default '',
  created_at timestamptz not null default now(),
  last_seen  timestamptz
);
create index if not exists devices_owner_idx on public.devices(owner);

-- Short-lived one-time pairing codes. A device inserts one (via request_pairing)
-- and polls it; a real account claims it (via claim_pairing).
create table if not exists public.pairings (
  code       text primary key,
  device_uid uuid not null,
  claimed_by uuid references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists pairings_device_idx on public.pairings(device_uid);

create trigger sources_touch        before update on public.sources
  for each row execute function public.touch_updated_at();
create trigger metadata_touch       before update on public.metadata_configs
  for each row execute function public.touch_updated_at();

-- The account that owns the calling device (its paired owner), or null if the
-- caller isn't a paired device. SECURITY DEFINER so the `sources` SELECT policy
-- can resolve the device→owner link without recursing into `devices` RLS.
-- Defined after `devices` so its body validates. (SQL functions resolve their
-- relation references at creation time, unlike plpgsql.)
create or replace function public.current_device_owner()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select owner from public.devices where device_uid = auth.uid()
$$;

-- ---------------------------------------------------------------------------
-- Row-level security (deny-by-default: RLS on, only the policies below allow)
-- ---------------------------------------------------------------------------

alter table public.sources          enable row level security;
alter table public.metadata_configs enable row level security;
alter table public.devices          enable row level security;
alter table public.pairings         enable row level security;

-- sources: owner has full control (real accounts only for writes); a paired
-- device may read its owner's rows.
create policy sources_select on public.sources
  for select using (
    owner = auth.uid() or owner = public.current_device_owner()
  );
create policy sources_insert on public.sources
  for insert with check (owner = auth.uid() and public.is_real_user());
create policy sources_update on public.sources
  for update using (owner = auth.uid() and public.is_real_user())
            with check (owner = auth.uid() and public.is_real_user());
create policy sources_delete on public.sources
  for delete using (owner = auth.uid() and public.is_real_user());

-- metadata_configs: same shape as sources.
create policy metadata_select on public.metadata_configs
  for select using (
    owner = auth.uid() or owner = public.current_device_owner()
  );
create policy metadata_insert on public.metadata_configs
  for insert with check (owner = auth.uid() and public.is_real_user());
create policy metadata_update on public.metadata_configs
  for update using (owner = auth.uid() and public.is_real_user())
            with check (owner = auth.uid() and public.is_real_user());
create policy metadata_delete on public.metadata_configs
  for delete using (owner = auth.uid() and public.is_real_user());

-- devices: the owner manages (rename/revoke) their devices; a device may read
-- its own row (to learn it's still paired). The link is *created* only by
-- claim_pairing (SECURITY DEFINER) — there is deliberately no INSERT policy.
create policy devices_select on public.devices
  for select using (owner = auth.uid() or device_uid = auth.uid());
create policy devices_update on public.devices
  for update using (owner = auth.uid() and public.is_real_user())
            with check (owner = auth.uid() and public.is_real_user());
-- The owner may revoke any of their devices; a device may also self-unpair.
create policy devices_delete on public.devices
  for delete using (
    (owner = auth.uid() and public.is_real_user()) or device_uid = auth.uid()
  );

-- pairings: a device manages only its own rows. Claiming is not a direct write
-- (no UPDATE policy) — it goes through claim_pairing().
create policy pairings_select on public.pairings
  for select using (device_uid = auth.uid());
create policy pairings_insert on public.pairings
  for insert with check (device_uid = auth.uid());
create policy pairings_delete on public.pairings
  for delete using (device_uid = auth.uid());

-- ---------------------------------------------------------------------------
-- Pairing RPCs (the only privileged code; runs in Postgres)
-- ---------------------------------------------------------------------------

-- Generate an unambiguous random code (no 0/O/1/I/L). 8 chars from a 30-char
-- alphabet ≈ 39 bits of entropy; paired with a 10-minute TTL and rate limiting.
create or replace function public.gen_pairing_code()
returns text
language plpgsql
set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  out text := '';
  i int;
begin
  for i in 1..8 loop
    out := out || substr(alphabet,
      1 + (get_byte(extensions.gen_random_bytes(1), 0) % length(alphabet)), 1);
  end loop;
  return out;
end;
$$;

-- Called by a device's anonymous session. Returns a fresh code (and its expiry)
-- for the caller to display. Rate-limited; old/expired codes for this device are
-- cleared first so a device only ever has one live code.
create or replace function public.request_pairing()
returns table (code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public
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
  delete from public.pairings
    where device_uid = dev and (claimed_by is null or expires_at < now());

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

-- Polled by the device's anonymous session: has my code been claimed yet?
-- Returns true once a real account has linked this device.
create or replace function public.pairing_status(p_code text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.pairings
    where code = p_code
      and device_uid = auth.uid()
      and claimed_by is not null
  )
$$;

-- Called by the web panel's authenticated (real) user. Validates the code is
-- live and unclaimed, then links the device to this account. This is the only
-- path that creates a devices row.
create or replace function public.claim_pairing(p_code text)
returns void
language plpgsql
security definer
set search_path = public
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

-- Lock down execution: only authenticated sessions (incl. anonymous) may call.
revoke all on function public.request_pairing()       from public;
revoke all on function public.pairing_status(text)    from public;
revoke all on function public.claim_pairing(text)     from public;
grant execute on function public.request_pairing()    to authenticated;
grant execute on function public.pairing_status(text) to authenticated;
grant execute on function public.claim_pairing(text)  to authenticated;
