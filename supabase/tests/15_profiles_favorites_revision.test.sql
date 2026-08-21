-- profiles.updated_at: favorites are exempt, everything else still advances it.
--
-- This is the revision the manual push compares to decide whether to warn
-- "this profile changed on the panel — pushing will replace those newer
-- changes". Getting the exemption too wide is a data-loss risk, not a nuisance:
-- a revision that stops advancing means that dialog stops appearing and a
-- device push silently overwrites real panel edits. So the "still advances"
-- cases matter more here than the "stays put" one.

begin;

select plan(7);

set local role authenticated;

select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');

-- ── the exemption ──────────────────────────────────────────────────────────

select updated_at as rev_before from public.profiles where id = :'profile_a_id'::uuid \gset

update public.profiles
   set favorites = jsonb_build_array(
     jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch1'))
 where id = :'profile_a_id'::uuid;

select is(
  (select updated_at from public.profiles where id = :'profile_a_id'::uuid),
  :'rev_before'::timestamptz,
  'a favorites-only update leaves the snapshot revision untouched'
);

select is(
  (select jsonb_array_length(favorites) from public.profiles where id = :'profile_a_id'::uuid),
  1,
  'and the favorites themselves are still written'
);

-- Even when the statement explicitly sets updated_at, as the push RPCs do.
select updated_at as rev_explicit from public.profiles where id = :'profile_a_id'::uuid \gset
update public.profiles
   set favorites = '[]'::jsonb, updated_at = now()
 where id = :'profile_a_id'::uuid;
select is(
  (select updated_at from public.profiles where id = :'profile_a_id'::uuid),
  :'rev_explicit'::timestamptz,
  'an explicit updated_at = now() alongside favorites is still exempt'
);

-- ── everything else must still advance it ──────────────────────────────────

select updated_at as rev_name from public.profiles where id = :'profile_a_id'::uuid \gset
update public.profiles set name = 'Renamed' where id = :'profile_a_id'::uuid;
select ok(
  (select updated_at from public.profiles where id = :'profile_a_id'::uuid)
    > :'rev_name'::timestamptz,
  'a panel edit (name) still advances the revision'
);

-- A name change *and* a favorites change together is a real change.
select updated_at as rev_both from public.profiles where id = :'profile_a_id'::uuid \gset
update public.profiles
   set name = 'Renamed twice',
       favorites = jsonb_build_array(
         jsonb_build_object('source_id', 'src', 'kind', 'live', 'item_id', 'ch2'))
 where id = :'profile_a_id'::uuid;
select ok(
  (select updated_at from public.profiles where id = :'profile_a_id'::uuid)
    > :'rev_both'::timestamptz,
  'favorites alongside a real column change does not confer the exemption'
);

-- The child-revision path: a source insert must still bump the profile, even
-- though it reaches the row as an updated_at-only write.
select updated_at as rev_source from public.profiles where id = :'profile_a_id'::uuid \gset
select gen_random_uuid() as source_a_id \gset
insert into public.sources (id, owner, profile_id, kind, label, fields, settings, position)
  values (:'source_a_id'::uuid, :'owner_a'::uuid, :'profile_a_id'::uuid,
          'm3u', 'Fixture', '{}'::jsonb, '{}'::jsonb, 0);
select ok(
  (select updated_at from public.profiles where id = :'profile_a_id'::uuid)
    > :'rev_source'::timestamptz,
  'a source insert still advances the profile revision (child-revision path)'
);

select updated_at as rev_source_del from public.profiles where id = :'profile_a_id'::uuid \gset
delete from public.sources where id = :'source_a_id'::uuid;
select ok(
  (select updated_at from public.profiles where id = :'profile_a_id'::uuid)
    > :'rev_source_del'::timestamptz,
  'a source delete still advances the profile revision'
);

select * from finish();
rollback;
