-- iptvs cloud sync — opt-in passphrase E2EE (Phase 3 of the hardening ladder).
--
-- Builds on secrets_store.sql (Phase 2), which isolated every credential into
-- source_secrets / metadata_secrets with a `format` column (0 = plaintext,
-- 1 = E2EE envelope v1). This migration adds the key-management layer that lets
-- an account flip a profile's secrets to format 1:
--
--   * profile_crypto — one row per E2EE-enabled profile. Holds the passphrase
--     KDF parameters (salt + iterations) and the content key (CK) wrapped by the
--     passphrase-derived KEK (wrapped_ck). `ck_version` is bumped by a CK
--     rotation. The passphrase itself NEVER leaves the client; the server stores
--     only wrapped material and can decrypt nothing.
--   * device_ck — CK wrapped for each paired device's public key, so a device
--     can obtain CK without the passphrase (it decrypts wrapped_ck with its
--     device private key). One row per (device, profile).
--   * devices.public_key — the device's long-lived public key, owner-readable
--     via the existing devices_select policy (owner = auth.uid()), so the panel
--     can wrap CK for each device during enable / provision / rotation.
--
-- Trust boundary: the server is honest-but-curious. It enforces structure,
-- ownership, revision gates and the format/ck invariants, but holds no key that
-- decrypts a format-1 payload. RLS on the two new tables is deny-all (zero
-- policies); every access is a SECURITY DEFINER RPC. All rejection errors use
-- errcode 'check_violation' with the stable 'iptvs: ' prefix and never echo a
-- payload value. Idempotent throughout.
--
-- Enforcement invariant (authoritative version of secrets_store.sql's Phase-2
-- gate): a secret's format must match the profile's E2EE state — 1 when enabled,
-- 0 when disabled — and a format-1 payload's top-level "ckv" integer must equal
-- profile_crypto.ck_version. The push / set RPCs are recreated below with that
-- full gate; the direct-write RPCs (enable/disable/rotate) maintain it by
-- construction and reconcile against concurrent device writes.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.profile_crypto (
  profile_id     uuid primary key references public.profiles(id) on delete cascade,
  owner          uuid not null references auth.users(id) on delete cascade,
  enabled        boolean not null default false,
  kdf            text not null default 'PBKDF2-SHA256',
  kdf_iterations int  not null default 600000,
  salt           text not null,
  wrapped_ck     jsonb not null,
  ck_version     int  not null default 1,
  updated_at     timestamptz not null default now()
);

create table if not exists public.device_ck (
  device_uid uuid not null references public.devices(device_uid) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  ck_version int  not null default 1,
  wrapped_ck jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (device_uid, profile_id)
);
create index if not exists device_ck_profile_idx on public.device_ck(profile_id);

-- Owner-readable via the existing devices_select policy (owner = auth.uid() or
-- device_uid = auth.uid()); a device sets it via set_device_public_key below.
alter table public.devices add column if not exists public_key text;

-- ---------------------------------------------------------------------------
-- RLS: deny-all (zero policies). Reachable only through the DEFINER RPCs.
-- ---------------------------------------------------------------------------

alter table public.profile_crypto enable row level security;
alter table public.device_ck      enable row level security;

-- ---------------------------------------------------------------------------
-- Triggers.
--   * touch_updated_at BEFORE UPDATE on both.
--   * snapshot-revision AFTER I/U/D on profile_crypto ONLY: it carries owner +
--     profile_id, so the helper's dereferences are safe, and enable/rotate
--     bumping profiles.updated_at -> one intended device re-pull. device_ck has
--     NO owner column (adversarial finding M8), so attaching the snapshot-
--     revision trigger there would make touch_profile_snapshot_revision error on
--     new.owner — deliberately omitted.
-- ---------------------------------------------------------------------------

drop trigger if exists profile_crypto_touch on public.profile_crypto;
create trigger profile_crypto_touch before update on public.profile_crypto
  for each row execute function public.touch_updated_at();

drop trigger if exists device_ck_touch on public.device_ck;
create trigger device_ck_touch before update on public.device_ck
  for each row execute function public.touch_updated_at();

drop trigger if exists profile_crypto_touch_profile_revision on public.profile_crypto;
create trigger profile_crypto_touch_profile_revision
  after insert or update or delete on public.profile_crypto
  for each row execute function public.touch_profile_snapshot_revision();

-- ---------------------------------------------------------------------------
-- set_device_public_key: device-scoped (no device-id parameter — M5). The
-- calling device is auth.uid(); a device cannot update its own devices row via
-- RLS (devices_update requires a real user), so this DEFINER path is required.
-- ---------------------------------------------------------------------------

create or replace function public.set_device_public_key(p_public_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- A base64 P-256 point is ~88 chars; 512 leaves generous headroom for larger
  -- key types while bounding the column.
  if p_public_key is null or length(p_public_key) > 512 then
    raise exception 'iptvs: public key invalid'
      using errcode = 'check_violation';
  end if;
  update public.devices set public_key = p_public_key where device_uid = auth.uid();
  if not found then
    raise exception 'iptvs: device not paired'
      using errcode = 'check_violation';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_crypto_state: owner-or-paired-device. { enabled, ck_version }, or
-- { enabled: false } when no profile_crypto row exists.
-- ---------------------------------------------------------------------------

create or replace function public.get_crypto_state(p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  resolved_owner uuid;
  result jsonb;
begin
  select p.owner into resolved_owner
    from public.profiles p
   where p.id = p_profile_id
     and (p.owner = auth.uid() or p.owner = public.current_device_owner());
  if resolved_owner is null then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;

  select jsonb_build_object('enabled', pc.enabled, 'ck_version', pc.ck_version)
    into result
    from public.profile_crypto pc
   where pc.profile_id = p_profile_id and pc.owner = resolved_owner;

  return coalesce(result, jsonb_build_object('enabled', false));
end;
$$;

-- ---------------------------------------------------------------------------
-- get_device_ck: the calling device's own wrapped CK for a profile (null if
-- none). Scoped to auth.uid() as the device AND the profile belonging to the
-- device's owner.
-- ---------------------------------------------------------------------------

create or replace function public.get_device_ck(p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
  result jsonb;
begin
  if o is null then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = o
  ) then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;

  select jsonb_build_object('ck_version', d.ck_version, 'wrapped_ck', d.wrapped_ck)
    into result
    from public.device_ck d
   where d.device_uid = auth.uid() and d.profile_id = p_profile_id;

  return result;  -- null when the device has no CK yet
end;
$$;

-- ---------------------------------------------------------------------------
-- get_profile_crypto: real user + owner only. Full KDF material for the panel to
-- unwrap CK from the passphrase. Never device-readable. Null when not enabled.
-- ---------------------------------------------------------------------------

create or replace function public.get_profile_crypto(p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if not public.is_real_user() then
    raise exception 'iptvs: only a signed-in account can read crypto material'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = auth.uid()
  ) then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;

  select jsonb_build_object(
           'enabled', pc.enabled,
           'kdf', pc.kdf,
           'kdf_iterations', pc.kdf_iterations,
           'salt', pc.salt,
           'wrapped_ck', pc.wrapped_ck,
           'ck_version', pc.ck_version)
    into result
    from public.profile_crypto pc
   where pc.profile_id = p_profile_id and pc.owner = auth.uid();

  return result;  -- null when no row
end;
$$;

-- ---------------------------------------------------------------------------
-- list_device_ck: owner-side provisioning-state view for the panel. Real user +
-- owner (same gate as get_profile_crypto). Returns one entry per device of this
-- owner LEFT JOINed to its device_ck row for p_profile_id, so the panel can show
-- "already has CK / needs key / stale ckv" authoritatively instead of inferring
-- from devices.public_key presence. STATE ONLY — no wrapped_ck material is ever
-- returned. `stale` is precomputed against the profile's current ck_version
-- (false when E2EE is disabled / the profile has no crypto row).
-- ---------------------------------------------------------------------------

create or replace function public.list_device_ck(p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cur_ckv int;
  result jsonb;
begin
  if not public.is_real_user() then
    raise exception 'iptvs: only a signed-in account can list device keys'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = auth.uid()
  ) then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;

  -- Null when E2EE is not enabled for this profile; makes every `stale` false.
  select pc.ck_version into cur_ckv
    from public.profile_crypto pc
   where pc.profile_id = p_profile_id and pc.owner = auth.uid();

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'device_uid', d.device_uid,
               'label', d.label,
               'has_public_key', d.public_key is not null,
               'has_ck', dc.device_uid is not null,
               'ck_version', dc.ck_version,
               'stale', (dc.device_uid is not null
                         and cur_ckv is not null
                         and dc.ck_version <> cur_ckv))
             order by d.created_at, d.device_uid),
           '[]'::jsonb)
    into result
    from public.devices d
    left join public.device_ck dc
      on dc.device_uid = d.device_uid and dc.profile_id = p_profile_id
   where d.owner = auth.uid();

  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- provision_device_ck: the panel wraps CK for one device's public key and
-- stores it. Real user + owner, and BOTH the profile AND the device must belong
-- to the caller (M5). The supplied ck_version must equal the profile's current
-- ck_version.
-- ---------------------------------------------------------------------------

create or replace function public.provision_device_ck(
  p_device_uid uuid, p_profile_id uuid, p_ck_version int, p_wrapped_ck jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cur_ckv int;
begin
  if not public.is_real_user() then
    raise exception 'iptvs: only a signed-in account can provision a device'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = auth.uid()
  ) then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.devices where device_uid = p_device_uid and owner = auth.uid()
  ) then
    raise exception 'iptvs: device not found'
      using errcode = 'check_violation';
  end if;

  select pc.ck_version into cur_ckv
    from public.profile_crypto pc
   where pc.profile_id = p_profile_id and pc.owner = auth.uid();
  if cur_ckv is null then
    raise exception 'iptvs: e2ee not enabled'
      using errcode = 'check_violation';
  end if;
  if p_ck_version <> cur_ckv then
    raise exception 'iptvs: stale content key'
      using errcode = 'check_violation';
  end if;
  perform public.assert_secret_valid(p_wrapped_ck);

  insert into public.device_ck (device_uid, profile_id, ck_version, wrapped_ck)
    values (p_device_uid, p_profile_id, p_ck_version, coalesce(p_wrapped_ck, '{}'::jsonb))
  on conflict (device_uid, profile_id) do update
        set ck_version = excluded.ck_version,
            wrapped_ck = excluded.wrapped_ck,
            updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- enable_e2ee: flip a profile to E2EE in one transaction. Real user + owner.
--   * Revision gate (M1): SELECT profiles.updated_at FOR UPDATE and reject if it
--     differs from p_expected_revision — the client re-encrypted against a known
--     snapshot; an intervening panel/device change must force a re-read. The row
--     lock also serializes concurrent device pushes (their snapshot-revision
--     trigger blocks on this lock).
--   * KDF floor (M6): iterations >= 100000.
--   * Writes profile_crypto (enabled, ck_version=1), replaces the profile's
--     secrets as format 1 (each assert_secret_valid'd), and installs per-device
--     wrapped CKs (each device verified as the owner's).
--   * Reconciliation (M1): after the rewrite, assert no source_secrets row for
--     this profile remains at format <> 1 — a device that inserted a plaintext
--     secret between the client's read and this call would otherwise be silently
--     left un-encrypted; raising rolls the whole transaction back.
--
-- p_source_secrets shape: { "<source_id>": {envelope jsonb with "ckv":1}, ... }.
-- p_device_cks shape: [ { "device_uid": uuid, "wrapped_ck": {jsonb} }, ... ].
-- ---------------------------------------------------------------------------

create or replace function public.enable_e2ee(
  p_profile_id uuid,
  p_expected_revision timestamptz,
  p_salt text,
  p_kdf_iterations int,
  p_wrapped_ck jsonb,
  p_source_secrets jsonb,
  p_metadata_secret jsonb,
  p_device_cks jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cur_rev timestamptz;
  kv record;
  dc jsonb;
begin
  if not public.is_real_user() then
    raise exception 'iptvs: only a signed-in account can enable e2ee'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = auth.uid()
  ) then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;

  -- E2EE state changes are rare; a modest throttle bounds abuse without
  -- affecting real use.
  perform public.check_push_rate('e2ee', 10, interval '1 minute');

  if p_kdf_iterations is null or p_kdf_iterations < 100000 then
    raise exception 'iptvs: kdf iterations too low (min %)', 100000
      using errcode = 'check_violation';
  end if;
  if p_salt is null or length(p_salt) > 512 then
    raise exception 'iptvs: salt invalid'
      using errcode = 'check_violation';
  end if;
  perform public.assert_secret_valid(p_wrapped_ck);

  -- Revision gate (locks the profiles row for the rest of the transaction).
  select p.updated_at into cur_rev
    from public.profiles p
   where p.id = p_profile_id and p.owner = auth.uid()
   for update;
  if cur_rev is distinct from p_expected_revision then
    raise exception 'iptvs: profile changed since read — retry'
      using errcode = 'check_violation';
  end if;

  -- profile_crypto (ck_version resets to 1 on a fresh enable).
  insert into public.profile_crypto
      (profile_id, owner, enabled, kdf, kdf_iterations, salt, wrapped_ck, ck_version)
    values (p_profile_id, auth.uid(), true, 'PBKDF2-SHA256',
            p_kdf_iterations, p_salt, coalesce(p_wrapped_ck, '{}'::jsonb), 1)
  on conflict (profile_id) do update
        set enabled = true,
            kdf = 'PBKDF2-SHA256',
            kdf_iterations = excluded.kdf_iterations,
            salt = excluded.salt,
            wrapped_ck = excluded.wrapped_ck,
            ck_version = 1,
            updated_at = now()
      where public.profile_crypto.owner = auth.uid();

  -- Validate the provided source secrets: well-formed uuid keys that belong to
  -- this profile, each envelope valid and stamped with ckv = 1.
  for kv in select key, value from jsonb_each(coalesce(p_source_secrets, '{}'::jsonb))
  loop
    if kv.key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'iptvs: source secret id must be a UUID'
        using errcode = 'check_violation';
    end if;
    if not exists (
      select 1 from public.sources s
       where s.id = kv.key::uuid and s.profile_id = p_profile_id and s.owner = auth.uid()
    ) then
      raise exception 'iptvs: unknown source secret'
        using errcode = 'check_violation';
    end if;
    perform public.assert_secret_valid(kv.value);
    if coalesce(kv.value ->> 'ckv', '') !~ '^[0-9]+$'
       or (kv.value ->> 'ckv')::int <> 1 then
      raise exception 'iptvs: stale content key'
        using errcode = 'check_violation';
    end if;
  end loop;

  -- Replace all of this profile's source secrets with the format-1 envelopes.
  delete from public.source_secrets ss
   using public.sources s
   where ss.source_id = s.id and s.profile_id = p_profile_id and s.owner = auth.uid();
  insert into public.source_secrets (source_id, owner, profile_id, format, payload)
  select se.key::uuid, auth.uid(), p_profile_id, 1, se.value
    from jsonb_each(coalesce(p_source_secrets, '{}'::jsonb)) as se;

  -- Replace the metadata secret (null => remove it entirely).
  delete from public.metadata_secrets where profile_id = p_profile_id and owner = auth.uid();
  if p_metadata_secret is not null then
    perform public.assert_secret_valid(p_metadata_secret);
    if coalesce(p_metadata_secret ->> 'ckv', '') !~ '^[0-9]+$'
       or (p_metadata_secret ->> 'ckv')::int <> 1 then
      raise exception 'iptvs: stale content key'
        using errcode = 'check_violation';
    end if;
    insert into public.metadata_secrets (profile_id, owner, format, payload)
      values (p_profile_id, auth.uid(), 1, p_metadata_secret);
  end if;

  -- Install per-device wrapped CKs (replace the whole set).
  delete from public.device_ck where profile_id = p_profile_id;
  for dc in select value from jsonb_array_elements(coalesce(p_device_cks, '[]'::jsonb))
  loop
    if (dc ->> 'device_uid') is null
       or (dc ->> 'device_uid') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'iptvs: device ck id must be a UUID'
        using errcode = 'check_violation';
    end if;
    if not exists (
      select 1 from public.devices
       where device_uid = (dc ->> 'device_uid')::uuid and owner = auth.uid()
    ) then
      raise exception 'iptvs: device not found'
        using errcode = 'check_violation';
    end if;
    perform public.assert_secret_valid(dc -> 'wrapped_ck');
    insert into public.device_ck (device_uid, profile_id, ck_version, wrapped_ck)
      values ((dc ->> 'device_uid')::uuid, p_profile_id, 1,
              coalesce(dc -> 'wrapped_ck', '{}'::jsonb));
  end loop;

  -- Reconciliation: no plaintext secret may survive for this profile.
  if exists (
    select 1 from public.source_secrets ss
     join public.sources s on s.id = ss.source_id
    where s.profile_id = p_profile_id and s.owner = auth.uid() and ss.format <> 1
  ) then
    raise exception 'iptvs: concurrent secret change — retry'
      using errcode = 'check_violation';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- disable_e2ee: mirror of enable. Rewrites every secret back to plaintext
-- (format 0), clears the wrapped CK (sentinel empty object — profile_crypto.
-- wrapped_ck is NOT NULL, so '{}' marks "no usable material" while keeping the
-- row for history/ck_version), removes all device CKs, and reconciles that no
-- format-1 secret survives.
-- ---------------------------------------------------------------------------

create or replace function public.disable_e2ee(
  p_profile_id uuid,
  p_expected_revision timestamptz,
  p_source_secrets jsonb,
  p_metadata_secret jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cur_rev timestamptz;
  kv record;
begin
  if not public.is_real_user() then
    raise exception 'iptvs: only a signed-in account can disable e2ee'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = auth.uid()
  ) then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;

  perform public.check_push_rate('e2ee', 10, interval '1 minute');

  select p.updated_at into cur_rev
    from public.profiles p
   where p.id = p_profile_id and p.owner = auth.uid()
   for update;
  if cur_rev is distinct from p_expected_revision then
    raise exception 'iptvs: profile changed since read — retry'
      using errcode = 'check_violation';
  end if;

  update public.profile_crypto
     set enabled = false,
         wrapped_ck = '{}'::jsonb,
         updated_at = now()
   where profile_id = p_profile_id and owner = auth.uid();
  if not found then
    raise exception 'iptvs: e2ee not enabled'
      using errcode = 'check_violation';
  end if;

  -- Validate provided plaintext secrets belong to this profile.
  for kv in select key, value from jsonb_each(coalesce(p_source_secrets, '{}'::jsonb))
  loop
    if kv.key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'iptvs: source secret id must be a UUID'
        using errcode = 'check_violation';
    end if;
    if not exists (
      select 1 from public.sources s
       where s.id = kv.key::uuid and s.profile_id = p_profile_id and s.owner = auth.uid()
    ) then
      raise exception 'iptvs: unknown source secret'
        using errcode = 'check_violation';
    end if;
    perform public.assert_secret_valid(kv.value);
  end loop;

  delete from public.source_secrets ss
   using public.sources s
   where ss.source_id = s.id and s.profile_id = p_profile_id and s.owner = auth.uid();
  insert into public.source_secrets (source_id, owner, profile_id, format, payload)
  select se.key::uuid, auth.uid(), p_profile_id, 0, se.value
    from jsonb_each(coalesce(p_source_secrets, '{}'::jsonb)) as se;

  delete from public.metadata_secrets where profile_id = p_profile_id and owner = auth.uid();
  if p_metadata_secret is not null then
    perform public.assert_secret_valid(p_metadata_secret);
    insert into public.metadata_secrets (profile_id, owner, format, payload)
      values (p_profile_id, auth.uid(), 0, p_metadata_secret);
  end if;

  delete from public.device_ck where profile_id = p_profile_id;

  -- Reconciliation: no E2EE envelope may survive after disabling.
  if exists (
    select 1 from public.source_secrets ss
     join public.sources s on s.id = ss.source_id
    where s.profile_id = p_profile_id and s.owner = auth.uid() and ss.format <> 0
  ) then
    raise exception 'iptvs: concurrent secret change — retry'
      using errcode = 'check_violation';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- rotate_passphrase: change the KDF material (salt/iterations) and re-wrap CK
-- under the new passphrase-derived KEK. CK itself is UNCHANGED, so the secrets
-- are untouched and NO revision gate is needed. Device CKs (CK wrapped per
-- device public key) are also unchanged by CK, but the panel re-provisions them
-- here for convenience; the ck_version is carried through unchanged.
-- ---------------------------------------------------------------------------

create or replace function public.rotate_passphrase(
  p_profile_id uuid,
  p_salt text,
  p_kdf_iterations int,
  p_wrapped_ck jsonb,
  p_device_cks jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cur_ckv int;
  dc jsonb;
begin
  if not public.is_real_user() then
    raise exception 'iptvs: only a signed-in account can rotate the passphrase'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = auth.uid()
  ) then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;

  perform public.check_push_rate('e2ee', 10, interval '1 minute');

  if p_kdf_iterations is null or p_kdf_iterations < 100000 then
    raise exception 'iptvs: kdf iterations too low (min %)', 100000
      using errcode = 'check_violation';
  end if;
  if p_salt is null or length(p_salt) > 512 then
    raise exception 'iptvs: salt invalid'
      using errcode = 'check_violation';
  end if;
  perform public.assert_secret_valid(p_wrapped_ck);

  update public.profile_crypto
     set salt = p_salt,
         kdf_iterations = p_kdf_iterations,
         wrapped_ck = coalesce(p_wrapped_ck, '{}'::jsonb),
         updated_at = now()
   where profile_id = p_profile_id and owner = auth.uid()
     and enabled = true
  returning ck_version into cur_ckv;
  if cur_ckv is null then
    raise exception 'iptvs: e2ee not enabled'
      using errcode = 'check_violation';
  end if;

  -- Replace device CKs (ck_version unchanged).
  delete from public.device_ck where profile_id = p_profile_id;
  for dc in select value from jsonb_array_elements(coalesce(p_device_cks, '[]'::jsonb))
  loop
    if (dc ->> 'device_uid') is null
       or (dc ->> 'device_uid') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'iptvs: device ck id must be a UUID'
        using errcode = 'check_violation';
    end if;
    if not exists (
      select 1 from public.devices
       where device_uid = (dc ->> 'device_uid')::uuid and owner = auth.uid()
    ) then
      raise exception 'iptvs: device not found'
        using errcode = 'check_violation';
    end if;
    perform public.assert_secret_valid(dc -> 'wrapped_ck');
    insert into public.device_ck (device_uid, profile_id, ck_version, wrapped_ck)
      values ((dc ->> 'device_uid')::uuid, p_profile_id, cur_ckv,
              coalesce(dc -> 'wrapped_ck', '{}'::jsonb));
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- rotate_content_key: mint a new CK, bump ck_version by exactly 1, and rewrite
-- every secret + device CK under it in one transaction (revision-gated, since
-- the secrets change). Every new envelope must be stamped with the new ck_version.
-- ---------------------------------------------------------------------------

create or replace function public.rotate_content_key(
  p_profile_id uuid,
  p_expected_revision timestamptz,
  p_wrapped_ck jsonb,
  p_ck_version int,
  p_source_secrets jsonb,
  p_metadata_secret jsonb,
  p_device_cks jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cur_rev timestamptz;
  cur_ckv int;
  kv record;
  dc jsonb;
begin
  if not public.is_real_user() then
    raise exception 'iptvs: only a signed-in account can rotate the content key'
      using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = auth.uid()
  ) then
    raise exception 'iptvs: profile not found'
      using errcode = 'check_violation';
  end if;

  perform public.check_push_rate('e2ee', 10, interval '1 minute');
  perform public.assert_secret_valid(p_wrapped_ck);

  select p.updated_at into cur_rev
    from public.profiles p
   where p.id = p_profile_id and p.owner = auth.uid()
   for update;
  if cur_rev is distinct from p_expected_revision then
    raise exception 'iptvs: profile changed since read — retry'
      using errcode = 'check_violation';
  end if;

  select ck_version into cur_ckv
    from public.profile_crypto
   where profile_id = p_profile_id and owner = auth.uid() and enabled = true;
  if cur_ckv is null then
    raise exception 'iptvs: e2ee not enabled'
      using errcode = 'check_violation';
  end if;
  if p_ck_version <> cur_ckv + 1 then
    raise exception 'iptvs: stale content key'
      using errcode = 'check_violation';
  end if;

  update public.profile_crypto
     set ck_version = p_ck_version,
         wrapped_ck = coalesce(p_wrapped_ck, '{}'::jsonb),
         updated_at = now()
   where profile_id = p_profile_id and owner = auth.uid();

  -- Rewrite source secrets under the new CK (each stamped ckv = p_ck_version).
  for kv in select key, value from jsonb_each(coalesce(p_source_secrets, '{}'::jsonb))
  loop
    if kv.key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'iptvs: source secret id must be a UUID'
        using errcode = 'check_violation';
    end if;
    if not exists (
      select 1 from public.sources s
       where s.id = kv.key::uuid and s.profile_id = p_profile_id and s.owner = auth.uid()
    ) then
      raise exception 'iptvs: unknown source secret'
        using errcode = 'check_violation';
    end if;
    perform public.assert_secret_valid(kv.value);
    if coalesce(kv.value ->> 'ckv', '') !~ '^[0-9]+$'
       or (kv.value ->> 'ckv')::int <> p_ck_version then
      raise exception 'iptvs: stale content key'
        using errcode = 'check_violation';
    end if;
  end loop;

  delete from public.source_secrets ss
   using public.sources s
   where ss.source_id = s.id and s.profile_id = p_profile_id and s.owner = auth.uid();
  insert into public.source_secrets (source_id, owner, profile_id, format, payload)
  select se.key::uuid, auth.uid(), p_profile_id, 1, se.value
    from jsonb_each(coalesce(p_source_secrets, '{}'::jsonb)) as se;

  delete from public.metadata_secrets where profile_id = p_profile_id and owner = auth.uid();
  if p_metadata_secret is not null then
    perform public.assert_secret_valid(p_metadata_secret);
    if coalesce(p_metadata_secret ->> 'ckv', '') !~ '^[0-9]+$'
       or (p_metadata_secret ->> 'ckv')::int <> p_ck_version then
      raise exception 'iptvs: stale content key'
        using errcode = 'check_violation';
    end if;
    insert into public.metadata_secrets (profile_id, owner, format, payload)
      values (p_profile_id, auth.uid(), 1, p_metadata_secret);
  end if;

  delete from public.device_ck where profile_id = p_profile_id;
  for dc in select value from jsonb_array_elements(coalesce(p_device_cks, '[]'::jsonb))
  loop
    if (dc ->> 'device_uid') is null
       or (dc ->> 'device_uid') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'iptvs: device ck id must be a UUID'
        using errcode = 'check_violation';
    end if;
    if not exists (
      select 1 from public.devices
       where device_uid = (dc ->> 'device_uid')::uuid and owner = auth.uid()
    ) then
      raise exception 'iptvs: device not found'
        using errcode = 'check_violation';
    end if;
    perform public.assert_secret_valid(dc -> 'wrapped_ck');
    insert into public.device_ck (device_uid, profile_id, ck_version, wrapped_ck)
      values ((dc ->> 'device_uid')::uuid, p_profile_id, p_ck_version,
              coalesce(dc -> 'wrapped_ck', '{}'::jsonb));
  end loop;

  -- Reconciliation: every surviving secret must be a format-1 envelope.
  if exists (
    select 1 from public.source_secrets ss
     join public.sources s on s.id = ss.source_id
    where s.profile_id = p_profile_id and s.owner = auth.uid() and ss.format <> 1
  ) then
    raise exception 'iptvs: concurrent secret change — retry'
      using errcode = 'check_violation';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- AUTHORITATIVE format enforcement (B2): recreate the four secret-writing RPCs
-- from secrets_store.sql with the full gate. For the target profile read
-- profile_crypto (absent row = disabled, ck_version irrelevant) and require:
--   * every secret's format == (enabled ? 1 : 0), else 'secret format mismatch';
--   * a format-1 payload's top-level "ckv" == profile_crypto.ck_version, else
--     'stale content key'.
-- Format-0 merges through merge_preserving_nonempty; format-1 replaces; an
-- absent secret preserves the stored one. Everything else is verbatim.
-- ---------------------------------------------------------------------------

create or replace function public.set_source_secret(
  p_source_id uuid, p_profile_id uuid, p_format int, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  pc_enabled boolean;
  pc_ckv int;
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

  select pc.enabled, pc.ck_version into pc_enabled, pc_ckv
    from public.profile_crypto pc
   where pc.profile_id = p_profile_id and pc.owner = auth.uid();
  pc_enabled := coalesce(pc_enabled, false);

  if p_format is null or p_format <> (case when pc_enabled then 1 else 0 end) then
    raise exception 'iptvs: secret format mismatch'
      using errcode = 'check_violation';
  end if;
  if p_format = 1 then
    if coalesce(p_payload ->> 'ckv', '') !~ '^[0-9]+$'
       or (p_payload ->> 'ckv')::int <> pc_ckv then
      raise exception 'iptvs: stale content key'
        using errcode = 'check_violation';
    end if;
  end if;

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
declare
  pc_enabled boolean;
  pc_ckv int;
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

  select pc.enabled, pc.ck_version into pc_enabled, pc_ckv
    from public.profile_crypto pc
   where pc.profile_id = p_profile_id and pc.owner = auth.uid();
  pc_enabled := coalesce(pc_enabled, false);

  if p_format is null or p_format <> (case when pc_enabled then 1 else 0 end) then
    raise exception 'iptvs: secret format mismatch'
      using errcode = 'check_violation';
  end if;
  if p_format = 1 then
    if coalesce(p_payload ->> 'ckv', '') !~ '^[0-9]+$'
       or (p_payload ->> 'ckv')::int <> pc_ckv then
      raise exception 'iptvs: stale content key'
        using errcode = 'check_violation';
    end if;
  end if;

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
  pc_enabled boolean;
  pc_ckv int;
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
    perform public.assert_secret_valid(p_secret -> 'payload');

    select pc.enabled, pc.ck_version into pc_enabled, pc_ckv
      from public.profile_crypto pc
     where pc.profile_id = p_profile_id;
    pc_enabled := coalesce(pc_enabled, false);

    if sfmt <> (case when pc_enabled then 1 else 0 end) then
      raise exception 'iptvs: secret format mismatch'
        using errcode = 'check_violation';
    end if;
    if sfmt = 1 then
      if coalesce(p_secret -> 'payload' ->> 'ckv', '') !~ '^[0-9]+$'
         or (p_secret -> 'payload' ->> 'ckv')::int <> pc_ckv then
        raise exception 'iptvs: stale content key'
          using errcode = 'check_violation';
      end if;
    end if;

    insert into public.metadata_secrets (profile_id, owner, format, payload)
      values (p_profile_id, o, sfmt, coalesce(p_secret -> 'payload', '{}'::jsonb))
    on conflict (profile_id) do update
          set owner = excluded.owner,
              format = excluded.format,
              payload = case when public.metadata_secrets.format = 0 and excluded.format = 0
                             then public.merge_preserving_nonempty(
                                    public.metadata_secrets.payload, excluded.payload)
                             else excluded.payload end,
              updated_at = now()
        where public.metadata_secrets.owner = o;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants: authenticated only. No grant to anon/public; the crypto tables have
-- no policy at all.
-- ---------------------------------------------------------------------------

revoke all on function public.set_device_public_key(text)                          from public, anon;
revoke all on function public.get_crypto_state(uuid)                               from public, anon;
revoke all on function public.get_device_ck(uuid)                                  from public, anon;
revoke all on function public.get_profile_crypto(uuid)                             from public, anon;
revoke all on function public.list_device_ck(uuid)                                 from public, anon;
revoke all on function public.provision_device_ck(uuid, uuid, int, jsonb)          from public, anon;
revoke all on function public.enable_e2ee(uuid, timestamptz, text, int, jsonb, jsonb, jsonb, jsonb) from public, anon;
revoke all on function public.disable_e2ee(uuid, timestamptz, jsonb, jsonb)        from public, anon;
revoke all on function public.rotate_passphrase(uuid, text, int, jsonb, jsonb)     from public, anon;
revoke all on function public.rotate_content_key(uuid, timestamptz, jsonb, int, jsonb, jsonb, jsonb) from public, anon;
revoke all on function public.set_source_secret(uuid, uuid, int, jsonb)            from public, anon;
revoke all on function public.set_metadata_secret(uuid, int, jsonb)                from public, anon;
revoke all on function public.push_sources(jsonb, uuid)                            from public, anon;
revoke all on function public.push_metadata(jsonb, uuid, jsonb)                    from public, anon;

grant execute on function public.set_device_public_key(text)                          to authenticated;
grant execute on function public.get_crypto_state(uuid)                               to authenticated;
grant execute on function public.get_device_ck(uuid)                                  to authenticated;
grant execute on function public.get_profile_crypto(uuid)                             to authenticated;
grant execute on function public.list_device_ck(uuid)                                 to authenticated;
grant execute on function public.provision_device_ck(uuid, uuid, int, jsonb)          to authenticated;
grant execute on function public.enable_e2ee(uuid, timestamptz, text, int, jsonb, jsonb, jsonb, jsonb) to authenticated;
grant execute on function public.disable_e2ee(uuid, timestamptz, jsonb, jsonb)        to authenticated;
grant execute on function public.rotate_passphrase(uuid, text, int, jsonb, jsonb)     to authenticated;
grant execute on function public.rotate_content_key(uuid, timestamptz, jsonb, int, jsonb, jsonb, jsonb) to authenticated;
grant execute on function public.set_source_secret(uuid, uuid, int, jsonb)            to authenticated;
grant execute on function public.set_metadata_secret(uuid, int, jsonb)                to authenticated;
grant execute on function public.push_sources(jsonb, uuid)                            to authenticated;
grant execute on function public.push_metadata(jsonb, uuid, jsonb)                    to authenticated;
