-- Make profiles.updated_at a revision for the complete profile snapshot, not
-- just the profiles row.  The app uses this value to warn before a destructive
-- device push, so panel edits to child sources/metadata must advance it too.

-- `now()` is fixed at transaction start and can move a revision backwards when
-- a long-running transaction commits after a newer writer. Recreate the shared
-- touch helper with wall-clock time so every table revision remains monotonic
-- with actual mutation order.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = greatest(
    old.updated_at + interval '1 microsecond',
    clock_timestamp()
  );
  return new;
end;
$$;

create or replace function public.touch_profile_snapshot_revision()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_profile uuid := coalesce(new.profile_id, old.profile_id);
  target_owner uuid := coalesce(new.owner, old.owner);
begin
  if target_profile is not null and target_owner is not null then
    update public.profiles
       set updated_at = clock_timestamp()
     where id = target_profile and owner = target_owner;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.touch_profile_snapshot_revision() from public;

drop trigger if exists sources_touch_profile_revision on public.sources;
create trigger sources_touch_profile_revision
after insert or update or delete on public.sources
for each row execute function public.touch_profile_snapshot_revision();

drop trigger if exists metadata_touch_profile_revision on public.metadata_configs;
create trigger metadata_touch_profile_revision
after insert or update or delete on public.metadata_configs
for each row execute function public.touch_profile_snapshot_revision();
