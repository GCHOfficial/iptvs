-- push_favorites_delta / merge_favorites: the per-row merge that makes
-- automatic favorite pushing safe.
--
-- The property that matters is the last one: two devices pushing *different*
-- rows must both survive. That is the whole reason this exists — the legacy
-- whole-set push_favorites cannot express it, because a missing element is
-- indistinguishable from a deletion.

begin;

select plan(13);

-- The merge stores timestamps as `timestamptz::text`, which renders in the
-- session's TimeZone — so the exact-string assertions below are only stable
-- with it pinned. Not a property of the code under test, just of this file.
set local timezone = 'UTC';

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
    '[]'::jsonb,
    '2026-01-01 00:00:00+00'::timestamptz
  ) -> 0 ->> 'item_id',
  'ch1',
  'an added favorite lands in the merged array'
);

select ok(
  (public.merge_favorites(
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
    '[]'::jsonb,
    '2026-01-01 00:00:00+00'::timestamptz
  ) -> 0 ? 'deleted_at') is false,
  'a plain add carries no tombstone'
);

select is(
  public.merge_favorites(
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
    '2026-01-01 00:00:00+00'::timestamptz
  ) -> 0 ->> 'deleted_at',
  '2026-01-01 00:00:00+00',
  'a removal leaves a tombstone stamped with the server time'
);

-- The core property: device A adds ch2 while device B removes ch1. Neither
-- delta mentions the other's row, so both changes must survive.
select is(
  (
    select jsonb_agg(e ->> 'item_id' order by e ->> 'item_id')
      from jsonb_array_elements(
        public.merge_favorites(
          public.merge_favorites(
            jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
            jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch2')),
            '[]'::jsonb,
            '2026-01-01 00:00:00+00'::timestamptz
          ),
          '[]'::jsonb,
          jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
          '2026-01-01 00:00:01+00'::timestamptz
        )
      ) e
     where (e ->> 'deleted_at') is null
  ),
  '["ch2"]'::jsonb,
  'concurrent deltas on different rows both survive (ch2 added, ch1 deleted)'
);

select ok(
  (public.merge_favorites(
    jsonb_build_array(jsonb_build_object(
      'source_id', 'src', 'kind', 'live', 'item_id', 'ch1',
      'deleted_at', '2026-01-01 00:00:00+00')),
    jsonb_build_array(jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1')),
    '[]'::jsonb,
    '2026-01-02 00:00:00+00'::timestamptz
  ) -> 0 ? 'deleted_at') is false,
  're-adding a tombstoned favorite clears the tombstone'
);

-- Client-supplied timestamps are discarded: the merge reads only the identity
-- triple from the delta payloads.
select is(
  public.merge_favorites(
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object(
      'source_id', 'src', 'kind', 'live', 'item_id', 'ch1',
      'updated_at', '1999-01-01 00:00:00+00',
      'deleted_at', '1999-01-01 00:00:00+00')),
    '[]'::jsonb,
    '2026-01-01 00:00:00+00'::timestamptz
  ),
  jsonb_build_array(jsonb_build_object(
    'source_id', 'src', 'kind', 'live', 'item_id', 'ch1',
    'updated_at', '2026-01-01 00:00:00+00')),
  'a client-supplied deleted_at/updated_at is ignored, not merged'
);

select is(
  public.merge_favorites(
    jsonb_build_array(jsonb_build_object(
      'source_id', 'src', 'kind', 'live', 'item_id', 'old',
      'deleted_at', '2020-01-01 00:00:00+00')),
    '[]'::jsonb,
    '[]'::jsonb,
    '2026-01-01 00:00:00+00'::timestamptz
  ),
  '[]'::jsonb,
  'a tombstone past the retention window is pruned'
);

-- A malformed deleted_at can only arrive via the legacy whole-set push (or a
-- row stored before this migration). It must not raise — an unguarded cast
-- here would wedge every later delta push on that profile.
select lives_ok(
  $$select public.merge_favorites(
      jsonb_build_array(jsonb_build_object(
        'source_id', 'src', 'kind', 'live', 'item_id', 'junk',
        'deleted_at', 'not-a-timestamp')),
      '[]'::jsonb, '[]'::jsonb, '2026-01-01 00:00:00+00'::timestamptz)$$,
  'a malformed deleted_at does not raise in the merge'
);

select is(
  public.merge_favorites(
    jsonb_build_array(jsonb_build_object(
      'source_id', 'src', 'kind', 'live', 'item_id', 'junk',
      'deleted_at', 'not-a-timestamp')),
    '[]'::jsonb, '[]'::jsonb, '2026-01-01 00:00:00+00'::timestamptz
  ),
  '[]'::jsonb,
  'a malformed tombstone is treated as expired and dropped'
);

-- ── everything below runs as a client ──────────────────────────────────────
-- `assert_favorites_valid` is granted to authenticated (the validation triggers
-- call it as the writing user), and the RPC guards need a real session.

set local role authenticated;

select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');

select gen_random_uuid() as source_a_id \gset

-- ── assert_favorites_valid: the new keys ───────────────────────────────────

select throws_ok(
  $$select public.assert_favorites_valid(
      jsonb_build_array(jsonb_build_object(
        'source_id', 'src', 'kind', 'live', 'item_id', 'ch1',
        'deleted_at', 'not-a-timestamp')))$$,
  '23514',
  null,
  'a malformed deleted_at is rejected at the write boundary'
);

select lives_ok(
  $$select public.assert_favorites_valid(
      jsonb_build_array(jsonb_build_object(
        'source_id', 'src', 'kind', 'live', 'item_id', 'ch1')))$$,
  'a favorite with no timestamp keys stays valid (every pre-migration row)'
);

-- ── push_favorites_delta: guards ───────────────────────────────────────────

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
