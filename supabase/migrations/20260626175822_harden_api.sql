-- Tighten the cloud-sync API surface flagged by the Supabase security advisor.

-- current_device_owner only reads the caller's *own* devices row, which the
-- devices RLS policy already permits (device_uid = auth.uid()). Running it
-- SECURITY INVOKER keeps it off the privileged-function list with identical
-- behaviour: a non-device caller simply matches no row → null, and there's no
-- recursion (the devices policy never references sources).
create or replace function public.current_device_owner()
returns uuid
language sql
stable
security invoker
set search_path = public
as $$
  select owner from public.devices where device_uid = auth.uid()
$$;

-- The pairing RPCs are for *authenticated* callers only: devices sign in
-- anonymously (→ authenticated role, is_anonymous = true) and the panel signs
-- in as a real account. Unauthenticated `anon` requests have no business here.
-- (The remaining "authenticated can execute SECURITY DEFINER" advisor warnings
-- on these three are intentional — they are the privileged pairing API.)
revoke execute on function public.request_pairing()    from anon;
revoke execute on function public.pairing_status(text) from anon;
revoke execute on function public.claim_pairing(text)  from anon;
