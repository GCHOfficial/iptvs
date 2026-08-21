-- push_favorites_delta / merge_favorites: the per-row delta that makes
-- automatic favorite pushing safe.
--
-- The property that matters is the third one: two devices pushing *different*
-- rows must both survive. That is the whole reason this exists — the legacy
-- whole-set push_favorites cannot express it, because a missing element is
-- indistinguishable from a deletion.
--
-- Note what is deliberately absent: tombstones. A removal drops the element
-- outright, so `profiles.favorites` keeps exactly the shape every shipped
-- client already reads (source_id/kind/item_id and nothing else).

begin;

select plan(10);

-- ── merge_favorites: pure semantics ────────────────────────────────────────
--
-- Run **before** dropping to `authenticated`, as the owning superuser.
-- `merge_favorites` is revoked from public/anon/authenticated on purpose: it is
-- an internal helper, reachable only through `push_favorites_delta`, which is
-- SECURITY DEFINER and therefore runs as its owner. Calling it as
-- `authenticated` here would fail with "permission denied for function" — and
-- the right response to that is this ordering, not a grant that would widen the
-- surface for the sake of a test.

select is(
  public.merge_favorites(
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
    '[]'::jsonb
  ),
  jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
  'an added favorite lands in the merged array, carrying no extra keys'
);

select is(
  public.merge_favorites(
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1'))
  ),
  '[]'::jsonb,
  'a removal drops the element outright — no tombstone is left behind'
);

-- The core property: device A adds ch2 while device B removes ch1. Neither
-- delta mentions the other's row, so both changes must survive.
select is(
  public.merge_favorites(
    public.merge_favorites(
      jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
      jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch2')),
      '[]'::jsonb
    ),
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1'))
  ),
  jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch2')),
  'concurrent deltas on different rows both survive (ch2 added, ch1 removed)'
);

select is(
  public.merge_favorites(
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1'))
  ),
  '[]'::jsonb,
  'a key in both halves resolves to removed, deterministically'
);

select is(
  public.merge_favorites(
    '[]'::jsonb,
    jsonb_build_array(
      jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1'),
      jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')
    ),
    '[]'::jsonb
  ),
  jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
  'a repeated add does not duplicate the favorite'
);

-- Re-adding something the stored set already holds must not duplicate it
-- either: the merge drops the stored copy before re-adding.
select is(
  public.merge_favorites(
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
    '[]'::jsonb
  ),
  jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
  'adding an already-stored favorite is idempotent'
);

-- Kinds and sources are part of the key, not just the item id.
select is(
  public.merge_favorites(
    jsonb_build_array(
      jsonb_build_object('source_id', 'a', 'kind', 'live', 'item_id', 'x'),
      jsonb_build_object('source_id', 'b', 'kind', 'live', 'item_id', 'x'),
      jsonb_build_object('source_id', 'a', 'kind', 'movie', 'item_id', 'x')
    ),
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('source_id', 'a', 'kind', 'live', 'item_id', 'x'))
  ),
  jsonb_build_array(
    jsonb_build_object('source_id', 'a', 'kind', 'movie', 'item_id', 'x'),
    jsonb_build_object('source_id', 'b', 'kind', 'live', 'item_id', 'x')
  ),
  'removal keys on (source_id, kind, item_id), not the item id alone'
);

-- A stored array written by an older client is left exactly as it was found.
select is(
  public.merge_favorites(
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'legacy')),
    '[]'::jsonb,
    '[]'::jsonb
  ),
  jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'legacy')),
  'an empty delta leaves a legacy-written set untouched'
);

-- ── everything below runs as a client ──────────────────────────────────────

set local role authenticated;

select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');

select gen_random_uuid() as source_a_id \gset

select throws_ok(
  format('select public.push_favorites_delta(%L::jsonb, %L::jsonb, %L::uuid)',
         '[]'::jsonb, '[]'::jsonb, :'profile_a_id'::uuid),
  null, null,
  'an unpaired caller cannot push a favorites delta'
);

select test.login_device() as device_a \gset
select code from public.request_pairing() \gset pairing_
select test.jwt(:'owner_a'::uuid, false);
select public.claim_pairing(:'pairing_code');
select test.jwt(:'device_a'::uuid, true);
select public.set_device_profile(:'profile_a_id'::uuid);

select lives_ok(
  format(
    'select public.push_favorites_delta(%L::jsonb, %L::jsonb, %L::uuid)',
    jsonb_build_array(jsonb_build_object(
      'source_id', :'source_a_id'::uuid, 'kind', 'live', 'item_id', 'ch1')),
    '[]'::jsonb,
    :'profile_a_id'::uuid
  ),
  'a paired device can push a favorites delta for its own profile'
);

select * from finish();
rollback;
