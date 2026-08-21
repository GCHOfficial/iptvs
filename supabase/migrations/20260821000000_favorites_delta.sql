-- Favorites: per-row delta merge with tombstones.
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
-- So deletions become representable. An element carries an optional
-- `deleted_at`, which makes it a tombstone: still present in the array (so the
-- other devices learn the favorite is gone) but not a favorite. Devices then
-- push *changes* rather than state, and two devices touching different rows can
-- no longer clobber each other.
--
-- Timestamp authority stays server-side
-- -------------------------------------
-- Clients still send no timestamps — the repo-wide rule, because device clocks
-- are not trustworthy. `deleted_at`/`updated_at` are stamped by this function
-- with `now()`, and any client-supplied value for either key is **discarded**,
-- not merged. Ordering between two devices touching the *same* row is therefore
-- "whichever push arrived last", decided by the server, which is exactly the
-- semantics wanted.
--
-- Compatibility
-- -------------
-- `push_favorites` (whole-set) stays, unchanged and supported forever: app
-- installs are arbitrarily old. A legacy client pushing a whole set drops
-- tombstones, which can resurrect a favorite another device deleted — that is
-- today's behaviour and is no worse than today. New clients use the delta RPC.
--
-- This is a **new function name**, deliberately not an overload of
-- `push_favorites`. PostgREST resolves overloads on the parameter-name set and
-- answers PGRST203 when a call is ambiguous; a distinct name cannot collide
-- with the existing 1- and 2-arg forms.
--
-- The panel never reads or writes `profiles.favorites` (it only mentions them
-- in copy), so no panel-side change is implied by the richer element shape.

-- ---------------------------------------------------------------------------
-- Validator: verbatim from harden_cloud, plus the two tombstone keys
-- ---------------------------------------------------------------------------
--
-- Re-declared rather than left alone because the element shape grew. Both new
-- keys are server-generated, so the only way a malformed one arrives is the
-- legacy whole-set `push_favorites` (or a direct panel write) — and a
-- `deleted_at` that is not a timestamp would otherwise sit in the array
-- poisoning later merges. Bounding it here closes every write path at once:
-- the RPCs call this, and so does the BEFORE INSERT/UPDATE trigger.
create or replace function public.assert_favorites_valid(p_favorites jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  -- A power user accumulates favorites one at a time over months; on a 250k
  -- portal that realistically reaches tens of thousands. Tombstones share this
  -- budget — they are pruned after 90 days, so they cannot accumulate forever.
  max_favorites       constant int := 200000;    -- realistic <= 20000 favorites
  max_favorites_bytes constant int := 16777216;  -- 16 MB; realistic ~2 MB
  max_item_id_len     constant int := 512;        -- realistic <= 128 chars
  max_kind_len        constant int := 16;         -- 'live'/'movie'/'series'
  max_source_id_len   constant int := 64;         -- a UUID is 36 chars
  max_stamp_len       constant int := 64;         -- a timestamptz renders ~29
  fav jsonb := coalesce(p_favorites, '[]'::jsonb);
begin
  if jsonb_typeof(fav) <> 'array' then
    raise exception 'iptvs: favorites must be a JSON array'
      using errcode = 'check_violation';
  end if;
  if octet_length(fav::text) > max_favorites_bytes then
    raise exception 'iptvs: favorites payload too large (max % bytes)', max_favorites_bytes
      using errcode = 'check_violation';
  end if;
  if jsonb_array_length(fav) > max_favorites then
    raise exception 'iptvs: too many favorites (max %)', max_favorites
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(fav) e where jsonb_typeof(e) <> 'object') then
    raise exception 'iptvs: each favorite must be a JSON object'
      using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from jsonb_array_elements(fav) e
     where (e ->> 'source_id') is null
        or length(e ->> 'source_id') > max_source_id_len
  ) then
    raise exception 'iptvs: favorite source id invalid'
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(fav) e where length(coalesce(e ->> 'kind', '')) > max_kind_len) then
    raise exception 'iptvs: favorite kind too long (max % chars)', max_kind_len
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(fav) e where length(coalesce(e ->> 'item_id', '')) > max_item_id_len) then
    raise exception 'iptvs: favorite item id too long (max % chars)', max_item_id_len
      using errcode = 'check_violation';
  end if;
  -- New: the tombstone/versioning keys. Absent is fine (a plain favorite, and
  -- every row written before this migration); present must be a plausible
  -- timestamp string, so the merge's expiry comparison can never raise.
  if exists (
    select 1 from jsonb_array_elements(fav) e
     where (e ? 'deleted_at' or e ? 'updated_at')
       and (
         (e ? 'deleted_at' and (
            jsonb_typeof(e -> 'deleted_at') <> 'string'
            or length(e ->> 'deleted_at') > max_stamp_len
            or (e ->> 'deleted_at') !~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}'))
         or (e ? 'updated_at' and (
            jsonb_typeof(e -> 'updated_at') <> 'string'
            or length(e ->> 'updated_at') > max_stamp_len
            or (e ->> 'updated_at') !~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}'))
       )
  ) then
    raise exception 'iptvs: favorite timestamp invalid'
      using errcode = 'check_violation';
  end if;
end;
$$;

revoke all on function public.assert_favorites_valid(jsonb) from public, anon;
grant execute on function public.assert_favorites_valid(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Pure merge helper
-- ---------------------------------------------------------------------------

-- Applies an add/remove delta to a stored favorites array.
--
-- Keyed on (source_id, kind, item_id). Removals win over additions within a
-- single call only when the same key appears in both, which a well-behaved
-- client never sends; resolving it deterministically (remove) beats leaving it
-- to array order.
--
-- Tombstones older than `p_keep_tombstones` are dropped. They exist only so a
-- device that has been offline learns about a deletion; past that window the
-- blob would grow without bound for no benefit. A device offline longer than
-- the window can resurrect a deleted favorite — the same trade every
-- tombstone-GC scheme makes, and the reason the window is generous.
create or replace function public.merge_favorites(
  p_stored jsonb,
  p_added jsonb,
  p_removed jsonb,
  p_now timestamptz,
  p_keep_tombstones interval default interval '90 days'
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with stored as (
    select
      e ->> 'source_id' as source_id,
      e ->> 'kind'      as kind,
      e ->> 'item_id'   as item_id,
      e ->> 'deleted_at' as deleted_at,
      e ->> 'updated_at' as updated_at
    from jsonb_array_elements(coalesce(p_stored, '[]'::jsonb)) e
    where jsonb_typeof(e) = 'object'
  ),
  -- Client-supplied timestamps are ignored on the way in: only the identity
  -- triple is read from the delta payloads.
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
  -- Everything the delta does not mention, minus expired tombstones.
  untouched as (
    select s.*
      from stored s
     where not exists (
       select 1 from added a
        where a.source_id = s.source_id and a.kind = s.kind and a.item_id = s.item_id)
       and not exists (
       select 1 from removed r
        where r.source_id = s.source_id and r.kind = s.kind and r.item_id = s.item_id)
       and (
         s.deleted_at is null
         -- Guarded cast, not a bare one. `assert_favorites_valid` rejects a
         -- malformed `deleted_at` at every write boundary, but the legacy
         -- whole-set `push_favorites` can have stored one before this migration
         -- existed — and an unguarded `::timestamptz` on that value would raise
         -- here, wedging *every* later delta push on that profile. Junk is
         -- treated as expired (dropped) instead.
         or (
           s.deleted_at ~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}'
           and (s.deleted_at)::timestamptz > p_now - p_keep_tombstones
         )
       )
  ),
  merged as (
    select source_id, kind, item_id, deleted_at, updated_at from untouched
    union all
    -- A re-added favorite loses its tombstone.
    select a.source_id, a.kind, a.item_id, null::text, (p_now)::text
      from added a
     where not exists (
       select 1 from removed r
        where r.source_id = a.source_id and r.kind = a.kind and r.item_id = a.item_id)
    union all
    select r.source_id, r.kind, r.item_id, (p_now)::text, (p_now)::text
      from removed r
  )
  select coalesce(
    jsonb_agg(
      jsonb_strip_nulls(
        jsonb_build_object(
          'source_id', source_id,
          'kind', kind,
          'item_id', item_id,
          'deleted_at', deleted_at,
          'updated_at', updated_at
        )
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

  merged := public.merge_favorites(stored, p_added, p_removed, now());

  perform public.assert_favorites_valid(merged);

  -- `updated_at` advances, exactly as the legacy whole-set push_favorites makes
  -- it advance. Note this is not optional here: `profiles_touch` is a BEFORE
  -- UPDATE trigger that sets `new.updated_at` unconditionally, so omitting the
  -- column from this statement would change nothing.
  --
  -- KNOWN LIMITATION: `profiles.updated_at` is also the revision the *manual*
  -- push compares to warn "this profile changed on the panel — pushing will
  -- replace those newer changes" before a destructive sources/metadata
  -- overwrite. Favorites are device-owned (the panel never touches them), so a
  -- favorites-only change can never be one of the panel edits that warning is
  -- about — yet it now advances the same timestamp, and automatic pushes make
  -- that far more frequent than manual ones ever did. Fixing it properly means
  -- a profiles-specific touch trigger that leaves the revision alone when only
  -- `favorites` differs (comparing `to_jsonb(new) - 'favorites' - 'updated_at'`
  -- against the same on OLD, so it stays correct as columns are added).
  -- Deliberately not done in this migration: it is surgery on the mechanism
  -- that guards against overwriting panel edits, and none of this SQL can be
  -- executed locally to verify it.
  update public.profiles
     set favorites = merged, updated_at = now()
   where id = p_profile_id and owner = o;
end;
$$;

revoke all on function public.merge_favorites(jsonb, jsonb, jsonb, timestamptz, interval)
  from public, anon, authenticated;
revoke all on function public.push_favorites_delta(jsonb, jsonb, uuid) from public, anon;
grant execute on function public.push_favorites_delta(jsonb, jsonb, uuid) to authenticated;
