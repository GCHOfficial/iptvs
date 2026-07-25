-- Two residuals left open by 20260727000000_tenant_isolation.sql, both
-- same-owner correctness rather than cross-tenant security.
--
-- 1. A moved source's PLAINTEXT secret kept its old profile_id.
--
--    push_sources' M2 branch deletes a moved source's format-1 envelope
--    (correct — its AAD binds the old profile id, so it could never be
--    decrypted under the new one), but a format-0 row is left untouched and
--    keeps pointing at the profile the source has LEFT.
--
--    That is not cosmetic: `source_secrets.profile_id` is
--    `references public.profiles(id) on delete cascade`
--    (20260725000000_secrets_store.sql:46). So deleting the old profile
--    cascades away the credential of a source that is alive and in use in a
--    different profile — a silent credential loss with no error anywhere, and
--    the user only discovers it when that source stops playing.
--
--    Fixed with an AFTER UPDATE trigger rather than by patching push_sources,
--    deliberately: the panel writes `sources` DIRECTLY under RLS as well, so a
--    per-RPC fix would leave the panel's own move path broken. A trigger holds
--    the invariant on every path, including any added later. It also avoids
--    transcribing ~150 lines of push_sources verbatim for a two-line change,
--    which is its own risk.
--
--    Ordering note: inside push_sources the M2 delete runs BEFORE the upsert
--    that changes profile_id, so by the time this trigger fires the format-1
--    rows are already gone and it only re-points format-0. On the panel's
--    direct path nothing has been deleted, so the trigger does both halves
--    itself — which is why it deletes format 1 rather than assuming M2 ran.
--
-- 2. Expired, unclaimed `pairings` rows accumulated forever.
--
--    `request_pairing` only ever purged the CALLING device's rows, so codes
--    minted by devices that never returned were never reaped. Bounded now that
--    the direct INSERT policy is gone (5/min/device via request_pairing), so
--    this is housekeeping, not a leak — but it grows monotonically otherwise.
--    A statement-level AFTER INSERT trigger reaps on the same path that
--    creates rows, with a one-day grace so it can never race a live code.

-- ---------------------------------------------------------------------------
-- 1. Keep a source's secret attached to the profile the source actually lives
--    in.
-- ---------------------------------------------------------------------------

create or replace function public.sources_sync_secret_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- format 1: the envelope's AAD binds the OLD profile id, so it is
  -- undecryptable under the new one no matter what we do with the row. Delete
  -- it — "absent secret = preserve" does not apply to a secret that can never
  -- be opened, and the panel/device re-supplies it on the next push. Same
  -- semantics as push_sources' M2 branch.
  delete from public.source_secrets
   where source_id = new.id
     and format = 1;

  -- format 0: plaintext and still perfectly valid — just re-point it, so the
  -- row stops hanging off a profile this source has left (and stops being
  -- collateral damage when that profile is deleted).
  update public.source_secrets
     set profile_id = new.profile_id,
         updated_at = now()
   where source_id = new.id
     and profile_id is distinct from new.profile_id;

  return null;
end;
$$;

-- SECURITY DEFINER above is load-bearing: `source_secrets` has zero policies
-- and, since 20260727000000, no table-level grants to anon/authenticated. A
-- panel UPDATE on `sources` runs as `authenticated`, so without DEFINER this
-- trigger could not touch the secret row at all.
drop trigger if exists sources_sync_secret_profile on public.sources;
create trigger sources_sync_secret_profile
  after update of profile_id on public.sources
  for each row
  when (new.profile_id is distinct from old.profile_id)
  execute function public.sources_sync_secret_profile();

-- ---------------------------------------------------------------------------
-- 2. Reap expired, unclaimed pairing codes.
-- ---------------------------------------------------------------------------

create or replace function public.pairings_reap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Statement-level, so this runs once per insert rather than once per row,
  -- and only ever removes codes that are BOTH unclaimed and a full day past
  -- expiry — a live or recently-expired code is never touched, and a claimed
  -- row is left alone because it is the audit trail of a real pairing.
  delete from public.pairings
   where claimed_by is null
     and expires_at < now() - interval '1 day';
  return null;
end;
$$;

drop trigger if exists pairings_reap on public.pairings;
create trigger pairings_reap
  after insert on public.pairings
  for each statement
  execute function public.pairings_reap();

-- ---------------------------------------------------------------------------
-- 3. One-time repair of rows that already drifted, for both cases above.
--    Idempotent and safe to re-run: both statements are no-ops once clean.
-- ---------------------------------------------------------------------------

-- Re-point plaintext secrets that are already stranded on a stale profile.
update public.source_secrets ss
   set profile_id = s.profile_id,
       updated_at = now()
  from public.sources s
 where s.id = ss.source_id
   and ss.format = 0
   and ss.profile_id is distinct from s.profile_id;

-- Drop already-stranded format-1 envelopes: bound to a profile their source has
-- left, so they cannot be decrypted and are only waiting to be re-pushed.
delete from public.source_secrets ss
 using public.sources s
 where s.id = ss.source_id
   and ss.format = 1
   and ss.profile_id is distinct from s.profile_id;

-- Clear the historical backlog of dead codes in one pass.
delete from public.pairings
 where claimed_by is null
   and expires_at < now() - interval '1 day';

-- ---------------------------------------------------------------------------
-- 4. Grants. Both functions are trigger-only: nothing may call them as an RPC.
--    (Unlike harden_cloud.sql's validation triggers, which kept PostgreSQL's
--    default PUBLIC EXECUTE, these are revoked outright — a trigger function
--    has no legitimate direct caller.)
-- ---------------------------------------------------------------------------

revoke all on function public.sources_sync_secret_profile() from public, anon, authenticated;
revoke all on function public.pairings_reap()               from public, anon, authenticated;
