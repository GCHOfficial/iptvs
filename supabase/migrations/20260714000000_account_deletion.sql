-- Let a signed-in panel user permanently delete their cloud account and all
-- data owned by it. The owner foreign keys cascade profiles, sources,
-- metadata, favorites, devices, and claimed pairing rows. Paired devices are
-- anonymous auth users, so remove those identities as well instead of leaving
-- inaccessible accounts behind.

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
  -- A forged/legacy devices row must never let one account delete another real
  -- account. Only anonymous identities are device identities.
  delete from auth.users
   where id = any(paired_device_ids)
     and is_anonymous is true;
end;
$$;

revoke all on function public.delete_account() from public;
revoke all on function public.delete_account() from anon;
grant execute on function public.delete_account() to authenticated;
