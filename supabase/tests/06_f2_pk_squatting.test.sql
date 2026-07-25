-- F2: PK/child-row squatting. RLS alone never stopped this — `owner =
-- auth.uid()` passes for account B inserting ITS OWN owner column, no matter
-- whose profile_id it points at. The composite FKs from tenant_isolation.sql
-- section 2 are the actual fix; this file proves both the negative (a
-- foreign profile_id is rejected) and the positive (a same-account insert,
-- which looks identical from RLS's point of view, is not collateral damage).

begin;

select plan(4);

set local role authenticated;

select test.login_user() as owner_a \gset
select gen_random_uuid() as profile_a_id \gset
insert into public.profiles (id, owner, name)
  values (:'profile_a_id'::uuid, :'owner_a'::uuid, 'Default');

select test.login_user() as owner_b \gset

-- Negative: account B tries to plant a `sources` row in account A's profile.
-- RLS's `owner = auth.uid()` is satisfied (owner = B); only the composite FK
-- catches the mismatched profile.
select throws_ok(
  format(
    'insert into public.sources (id, owner, profile_id, kind, label) values (%L, %L, %L, %L, %L)',
    gen_random_uuid(), :'owner_b'::uuid, :'profile_a_id'::uuid, 'm3u', 'squatted'
  ),
  '23503',
  'inserting a sources row under a foreign profile_id violates the composite FK'
);

-- Negative: same attack against metadata_configs, whose profile_id is the
-- PRIMARY KEY — the original finding (a squatted row here permanently blocks
-- the victim's own push_metadata, which upserts on conflict (profile_id)).
select throws_ok(
  format(
    'insert into public.metadata_configs (owner, profile_id) values (%L, %L)',
    :'owner_b'::uuid, :'profile_a_id'::uuid
  ),
  '23503',
  'inserting a metadata_configs row under a foreign profile_id violates the composite FK'
);

-- Positive: the identical shape of write, same-account, must not be
-- collateral damage from the new constraint.
select test.jwt(:'owner_a'::uuid, false);
select lives_ok(
  format(
    'insert into public.sources (id, owner, profile_id, kind, label) values (%L, %L, %L, %L, %L)',
    gen_random_uuid(), :'owner_a'::uuid, :'profile_a_id'::uuid, 'm3u', 'legit'
  ),
  'inserting a sources row under the account''s own profile still succeeds'
);
select lives_ok(
  format(
    'insert into public.metadata_configs (owner, profile_id) values (%L, %L)',
    :'owner_a'::uuid, :'profile_a_id'::uuid
  ),
  'inserting a metadata_configs row under the account''s own profile still succeeds'
);

select * from finish();

rollback;
