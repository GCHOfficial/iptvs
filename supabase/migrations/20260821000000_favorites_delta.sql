-- Favorites: per-row delta push.
--
-- Why this exists
-- ---------------
-- `push_favorites` replaces the whole `profiles.favorites` array. That is safe
-- while pushing is a deliberate, manual act (the user pushes when they mean
-- to), but it cannot survive *automatic* pushing: two devices that both push a
-- whole set race, and the later push silently erases favorites the earlier one
-- added. Unlike `sources`, favorites have no `merge_preserving_nonempty`
-- equivalent to fall back on — a missing element is indistinguishable from a
-- deletion when all you have is the final set.
--
-- A delta removes that ambiguity at the source: the payload says `remove` or
-- `add` outright, so the server never has to infer intent from an absence. Two
-- devices touching different favorites cannot collide; two touching the same
-- one resolve by which push the server saw last.
--
-- Why there are no tombstones
-- ---------------------------
-- An earlier draft of this migration carried soft-deleted entries (`deleted_at`)
-- so other devices could learn about a deletion. They are not needed, and were
-- removed before this ever shipped.
--
-- Tombstones earn their keep in a "fetch changes since T" model, where a device
-- that missed the delete would otherwise never hear about it. This sync is not
-- that: `pullFavorites` mirrors the profile — it clears the cloud-managed
-- sources and re-applies the stored set — so a favorite the server no longer
-- holds is already, by construction, removed from every device that pulls.
-- Deleting the element outright says the same thing with less machinery, and
-- drops the tombstone pruning, the timestamp keys and their validation with it.
--
-- It also keeps `profiles.favorites` in exactly the shape every already-shipped
-- client expects. Shipped `pullFavorites` reads only `source_id`/`kind`/
-- `item_id` and has no notion of `deleted_at`, so a tombstone would have looked
-- like an ordinary favorite to it — an older build would have pulled a deleted
-- favorite straight back and then pushed the resurrection to everyone else.
-- Nothing here changes what an old client reads or writes.
--
-- Compatibility
-- -------------
-- `push_favorites` (whole-set) stays, unchanged and supported forever: app
-- installs are arbitrarily old, and a mixed fleet is normal while a store
-- release waits on review. A legacy whole-set push still overwrites the set,
-- which is today's last-write-wins behaviour and no worse than today.
--
-- This is a **new function name**, deliberately not an overload of
-- `push_favorites`. PostgREST resolves overloads on the parameter-name set and
-- answers PGRST203 when a call is ambiguous; a distinct name cannot collide
-- with the existing 1- and 2-arg forms.
--
-- The panel never reads or writes `profiles.favorites` (it only mentions them
-- in copy), so nothing here implies a panel-side change.

-- ---------------------------------------------------------------------------
-- Pure merge helper
-- ---------------------------------------------------------------------------

-- Applies an add/remove delta to a stored favorites array.
--
-- Keyed on (source_id, kind, item_id). Elements keep the exact shape they have
-- today — no extra keys are introduced or preserved.
--
-- A key appearing in both `added` and `removed` resolves to removed. A
-- well-behaved client never sends that, but resolving it deterministically
-- beats leaving it to array order.
create or replace function public.merge_favorites(
  p_stored jsonb,
  p_added jsonb,
  p_removed jsonb
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with stored as (
    select distinct
      e ->> 'source_id' as source_id,
      e ->> 'kind'      as kind,
      e ->> 'item_id'   as item_id
    from jsonb_array_elements(coalesce(p_stored, '[]'::jsonb)) e
    where jsonb_typeof(e) = 'object'
      and (e ->> 'source_id') is not null
  ),
  added as (
    select distinct
      e ->> 'source_id' as source_id,
      e ->> 'kind'      as kind,
      e ->> 'item_id'   as item_id
    from jsonb_array_elements(coalesce(p_added, '[]'::jsonb)) e
    where jsonb_typeof(e) = 'object'
      and (e ->> 'source_id') is not null
      and (e ->> 'kind') is not null
      and (e ->> 'item_id') is not null
  ),
  removed as (
    select distinct
      e ->> 'source_id' as source_id,
      e ->> 'kind'      as kind,
      e ->> 'item_id'   as item_id
    from jsonb_array_elements(coalesce(p_removed, '[]'::jsonb)) e
    where jsonb_typeof(e) = 'object'
      and (e ->> 'source_id') is not null
      and (e ->> 'kind') is not null
      and (e ->> 'item_id') is not null
  ),
  merged as (
    -- Everything the delta does not mention...
    select s.source_id, s.kind, s.item_id
      from stored s
     where not exists (
       select 1 from added a
        where a.source_id is not distinct from s.source_id
          and a.kind is not distinct from s.kind
          and a.item_id is not distinct from s.item_id)
       and not exists (
       select 1 from removed r
        where r.source_id is not distinct from s.source_id
          and r.kind is not distinct from s.kind
          and r.item_id is not distinct from s.item_id)
    union all
    -- ...plus the additions that were not also removed. A removal is simply
    -- absent from the result: there is nothing left behind to represent it.
    select a.source_id, a.kind, a.item_id
      from added a
     where not exists (
       select 1 from removed r
        where r.source_id is not distinct from a.source_id
          and r.kind is not distinct from a.kind
          and r.item_id is not distinct from a.item_id)
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'source_id', source_id,
        'kind', kind,
        'item_id', item_id
      )
      order by source_id, kind, item_id
    ),
    '[]'::jsonb
  )
  from merged;
$$;

-- ---------------------------------------------------------------------------
-- Delta push RPC
-- ---------------------------------------------------------------------------

create or replace function public.push_favorites_delta(
  p_added jsonb,
  p_removed jsonb,
  p_profile_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  o uuid := public.current_device_owner();
  stored jsonb;
  merged jsonb;
  -- A delta is small by construction (what changed since the last push). This
  -- is not the ceiling on the stored set — assert_favorites_valid still bounds
  -- the merged result — only on how much one call may carry.
  max_delta constant int := 20000;
begin
  if o is null then
    raise exception 'only a paired device can push favorites';
  end if;

  if jsonb_typeof(coalesce(p_added, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_removed, '[]'::jsonb)) <> 'array' then
    raise exception 'iptvs: favorites delta must be JSON arrays'
      using errcode = 'check_violation';
  end if;
  if jsonb_array_length(coalesce(p_added, '[]'::jsonb)) > max_delta
     or jsonb_array_length(coalesce(p_removed, '[]'::jsonb)) > max_delta then
    raise exception 'iptvs: favorites delta too large (max % entries)', max_delta
      using errcode = 'check_violation';
  end if;

  -- Shares the 'push' bucket with every other push: an auto-pushing device
  -- must not get a larger budget than a manual one just by pushing smaller
  -- payloads.
  perform public.check_push_rate('push', 30, interval '1 minute');

  -- Read-modify-write under the row lock, so two concurrent pushes to the same
  -- profile serialise instead of interleaving. Without the lock both could read
  -- the same stored array and the second write would drop the first's changes —
  -- reintroducing, at a smaller scale, exactly the clobber this replaces.
  select p.favorites
    into stored
    from public.profiles p
   where p.id = p_profile_id and p.owner = o
     for update;
  if not found then
    raise exception 'profile not found for this account';
  end if;

  merged := public.merge_favorites(stored, p_added, p_removed);

  perform public.assert_favorites_valid(merged);

  -- `updated_at` advances, exactly as the legacy whole-set push_favorites makes
  -- it advance. Note this is not optional: `profiles_touch` is a BEFORE UPDATE
  -- trigger that sets it unconditionally, so omitting the column here would
  -- change nothing.
  --
  -- KNOWN LIMITATION: `profiles.updated_at` is also the revision the *manual*
  -- push compares to warn "this profile changed on the panel — pushing will
  -- replace those newer changes" before a destructive sources/metadata
  -- overwrite. Favorites are device-owned (the panel never touches them), so a
  -- favorites-only change can never be one of the panel edits that warning is
  -- about — yet it advances the same timestamp, and automatic pushes make that
  -- far more frequent than manual ones ever did. Fixing it properly means a
  -- profiles-specific touch trigger that leaves the revision alone when only
  -- `favorites` differs (comparing `to_jsonb(new) - 'favorites' - 'updated_at'`
  -- against the same on OLD, so it stays correct as columns are added).
  -- Deliberately not done here: it is surgery on the mechanism that guards
  -- against overwriting panel edits, and wants its own reviewed change.
  update public.profiles
     set favorites = merged, updated_at = now()
   where id = p_profile_id and owner = o;
end;
$$;

revoke all on function public.merge_favorites(jsonb, jsonb, jsonb)
  from public, anon, authenticated;
revoke all on function public.push_favorites_delta(jsonb, jsonb, uuid) from public, anon;
grant execute on function public.push_favorites_delta(jsonb, jsonb, uuid) to authenticated;
