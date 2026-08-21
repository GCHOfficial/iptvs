-- A favorites-only change must not advance the profile's snapshot revision.
--
-- Why
-- ---
-- `profiles.updated_at` is the whole-snapshot revision the **manual** push
-- compares against: the cloud screen reads it before pushing and, if it moved
-- since this device last synced, warns "this profile changed on the panel —
-- pushing will replace those newer changes" before a destructive
-- sources/metadata overwrite.
--
-- Favorites are device-owned: the panel never reads or writes
-- `profiles.favorites`, so a favorites change can never be one of the panel
-- edits that warning is about. But `profiles_touch` advanced `updated_at` on
-- *any* update, so every favorite push moved the revision — and now that
-- favorites sync automatically (this device's pushes and every other paired
-- device's), that dialog would fire on a profile nobody had edited. A
-- confirmation that cries wolf is worse than none: it trains the user to click
-- through the one prompt standing between a device push and overwriting real
-- panel edits.
--
-- How
-- ---
-- A profiles-specific BEFORE UPDATE trigger. It compares the row with
-- `favorites` and `updated_at` projected out; if nothing else moved, the
-- revision is preserved. Comparing `to_jsonb(NEW) - keys` rather than naming
-- the other columns keeps it correct as columns are added: a new column joins
-- the comparison automatically, so forgetting to revisit this function fails in
-- the safe direction (the revision advances).
--
-- `updated_at` is projected out because the statement itself may set it — the
-- push RPCs pass `updated_at = now()` — and including it would make every such
-- update look like a real change.
--
-- The shared `touch_updated_at` is deliberately left alone: `sources`,
-- `metadata_configs` and the rest still use it, and none of them has a column
-- that should be exempt.
--
-- The child-revision path
-- ----------------------
-- `touch_profile_snapshot_revision` (AFTER INSERT/UPDATE/DELETE on `sources`
-- and `metadata_configs`) bumps the profile by writing `updated_at` and nothing
-- else — which is precisely the shape the exemption above suppresses. Left
-- as-is, a source or metadata edit would silently stop advancing the revision
-- and the overwrite guard would go quiet: the opposite of the intent, and a
-- data-loss risk rather than a nuisance.
--
-- So that path sets a transaction-local flag the trigger honours, and it is
-- re-declared here (body otherwise verbatim from
-- `20260716230000_profile_snapshot_revision.sql`) to do so. Both directions are
-- pinned by `supabase/tests/15_profiles_favorites_revision.test.sql`.

create or replace function public.profiles_touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- An explicit bump from the child-revision trigger always wins: a source or
  -- metadata change *is* a snapshot change, and it arrives as an
  -- `updated_at`-only write that would otherwise be exempt.
  if coalesce(current_setting('iptvs.force_profile_revision', true), '') = 'on'
  then
    new.updated_at = greatest(
      old.updated_at + interval '1 microsecond',
      clock_timestamp()
    );
    return new;
  end if;

  -- Cheap short-circuit before the row comparison below: if `favorites` did not
  -- change, this cannot be a favorites-only write, so there is nothing to
  -- exempt. Worth its own branch because the comparison materialises
  -- `to_jsonb(NEW)`/`to_jsonb(OLD)`, each of which embeds a full copy of the
  -- favorites array (bounded at 16 MB, realistically ~2 MB) — and every panel
  -- edit and every child-revision bump would otherwise pay to serialise it
  -- twice only to discard it.
  if new.favorites is not distinct from old.favorites then
    new.updated_at = greatest(
      old.updated_at + interval '1 microsecond',
      clock_timestamp()
    );
    return new;
  end if;

  -- Favorites did change. Project them (and the revision itself) out: if what
  -- remains is unchanged, this was a favorites-only write.
  if ((to_jsonb(new) - 'favorites') - 'updated_at')
     is not distinct from
     ((to_jsonb(old) - 'favorites') - 'updated_at')
  then
    new.updated_at = old.updated_at;
    return new;
  end if;

  -- Same monotonic clock the shared helper uses: `now()` is fixed at
  -- transaction start and can move a revision backwards when a long-running
  -- transaction commits after a newer writer.
  new.updated_at = greatest(
    old.updated_at + interval '1 microsecond',
    clock_timestamp()
  );
  return new;
end;
$$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.profiles_touch_updated_at();

-- Verbatim from 20260716230000_profile_snapshot_revision.sql, plus the
-- transaction-local flag so the profile trigger does not exempt this write.
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
    -- `true` = transaction-local, so it cannot leak into an unrelated
    -- statement on a pooled connection.
    perform set_config('iptvs.force_profile_revision', 'on', true);
    update public.profiles
       set updated_at = clock_timestamp()
     where id = target_profile and owner = target_owner;
    perform set_config('iptvs.force_profile_revision', 'off', true);
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.profiles_touch_updated_at() from public;
revoke all on function public.touch_profile_snapshot_revision() from public;
