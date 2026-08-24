-- Optional 4-digit PIN on a profile.
--
-- What this is
-- ------------
-- A gate on a shared television: a profile can require four digits before a
-- device will switch into it. It is deliberately NOT a security boundary, and
-- the column below is a **broad** (non-secret) field for that reason:
--
--   * A four-digit PIN has ten thousand possible values, so anyone holding the
--     verifier recovers the PIN by trying all of them, whatever the KDF cost.
--     Treating it as a secret would be a claim we cannot keep.
--   * The credentials a PIN sits in front of are protected independently — by
--     RLS, by the secret store, and by end-to-end encryption when the account
--     opts in. None of that changes with or without a PIN.
--   * A secret (E2EE) column would be unreadable on a **locked** device, which
--     is precisely the device that still has to enforce the gate. Fail-closed
--     there would mean "no profile can be opened", i.e. a lockout, not a gate.
--
-- So the server stores an opaque verifier string, checks only its *shape*, and
-- never sees a PIN. Verification happens on the device
-- (`lib/data/profile_pin.dart`); the panel derives the same format through
-- WebCrypto (`panel/src/pin.js`).
--
-- Write paths
-- -----------
--   * Panel: a direct `update` under the existing owner-scoped
--     `profiles_update` policy, validated by the `profiles_validate` trigger
--     re-declared below.
--   * Device: `set_profile_pin`, a SECURITY DEFINER RPC — devices hold zero
--     direct table writes, and this is the only new write path.
--
-- Revision
-- --------
-- A PIN change advances `profiles.updated_at` (the snapshot revision) like any
-- other profile edit. It is deliberately NOT given the favorites-style
-- exemption: the exemption exists because favorites are device-owned and push
-- constantly, while a PIN changes once in a profile's life. One extra
-- "changed on the panel" prompt is a fair price for not adding a second hole
-- to a guard that protects against overwriting real panel edits.

alter table public.profiles
  add column if not exists pin text;

-- ---------------------------------------------------------------------------
-- Shape validation. Verbatim from 20260716000000_harden_cloud.sql plus the pin
-- check; `create or replace` keeps the existing trigger binding.
-- ---------------------------------------------------------------------------

create or replace function public.profiles_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  max_name constant int := 256;  -- realistic profile name <= 64 chars
  max_pin  constant int := 256;  -- the verifier format is ~90 chars
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
  -- The PIN column is nullable and an empty string means the same as null;
  -- normalise so a client clearing it either way lands on one representation
  -- (the app's `locked` test is `pin is not null`).
  if new.pin is not null and length(btrim(new.pin)) = 0 then
    new.pin = null;
  end if;
  if new.pin is not null then
    if length(new.pin) > max_pin then
      raise exception 'iptvs: profile pin too long (max % chars)', max_pin
        using errcode = 'check_violation';
    end if;
    -- `pbkdf2-sha256$<iterations>$<base64 salt>$<base64 hash>`. The server
    -- cannot check a PIN, only that what it is asked to store is a verifier of
    -- the shape every client knows how to read — so a malformed write is
    -- rejected here rather than becoming a profile nobody can open.
    -- The iteration bound is deliberately *narrower* than the app's parser
    -- (which rejects anything above 1,000,000): a verifier this side accepts
    -- but the device cannot read is a profile nobody can open — the exact
    -- outcome this check exists to prevent. Six digits keeps it a strict subset.
    if new.pin !~ '^pbkdf2-sha256\$[0-9]{1,6}\$[A-Za-z0-9+/]{8,88}={0,2}\$[A-Za-z0-9+/]{43}=$' then
      raise exception 'iptvs: profile pin is not a recognised verifier'
        using errcode = 'check_violation';
    end if;
  end if;
  perform public.assert_favorites_valid(new.favorites);
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Device write path
-- ---------------------------------------------------------------------------

-- Set (p_pin = a verifier) or clear (p_pin = null) the PIN on a profile this
-- device's account owns. Guard order matches the push RPCs: owner resolution,
-- then profile ownership, then the rate limit. The shape check is the
-- `profiles_validate` trigger's, so panel and device writes cannot diverge.
create or replace function public.set_profile_pin(p_profile_id uuid, p_pin text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
begin
  if o is null then
    raise exception 'only a paired device can set a profile pin';
  end if;
  if not exists (
    select 1 from public.profiles where id = p_profile_id and owner = o
  ) then
    raise exception 'profile not found for this account';
  end if;

  perform public.check_push_rate('push', 30, interval '1 minute');

  update public.profiles
     set pin = p_pin
   where id = p_profile_id and owner = o;
end;
$$;

revoke all on function public.set_profile_pin(uuid, text) from public, anon;
grant execute on function public.set_profile_pin(uuid, text) to authenticated;
