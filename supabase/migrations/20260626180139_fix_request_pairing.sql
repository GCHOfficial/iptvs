-- Fix: in request_pairing the RETURNS TABLE OUT column `expires_at` shadowed
-- pairings.expires_at, making the cleanup DELETE's WHERE clause ambiguous
-- ("column reference \"expires_at\" is ambiguous") — the function errored on
-- every call. Alias the table in the DELETE so the column is unambiguous.
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
