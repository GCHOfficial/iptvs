-- iptvs cloud sync — cap profiles per account.
--
-- The backend is a free Supabase project, so profile creation must be bounded.
-- Profiles are only ever created from the web panel (real user), but enforce the
-- cap in the database so neither the panel nor a crafted client can exceed it.
--
-- A BEFORE INSERT trigger counts the owner's existing profiles and rejects the
-- insert at the limit. SECURITY DEFINER + fixed search_path, matching the
-- existing function/trigger pattern in 20260630000000_profiles.sql. Idempotent:
-- CREATE OR REPLACE on the function, drop-then-create on the trigger.

create or replace function public.enforce_profile_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cap constant int := 20;
begin
  if (select count(*) from public.profiles where owner = NEW.owner) >= cap then
    raise exception 'profile limit reached (%)', cap
      using errcode = 'check_violation';
  end if;
  return NEW;
end;
$$;

drop trigger if exists profiles_cap on public.profiles;
create trigger profiles_cap before insert on public.profiles
  for each row execute function public.enforce_profile_cap();
