-- 20260728000000_secret_profile_sync.sql: a source that moves between profiles
-- must not leave its secret attached to the profile it left.
--
-- Why this matters beyond tidiness: `source_secrets.profile_id` is
-- `references public.profiles(id) on delete cascade`, so a stale value means
-- deleting the OLD profile silently destroys the credential of a source that is
-- alive and in use in a DIFFERENT profile. No error is raised anywhere; the
-- user finds out when the source stops playing.
--
-- Exercised through a direct `sources` UPDATE (the panel's own move path),
-- deliberately — the trigger exists precisely because patching push_sources
-- alone would have left that path broken.

begin;

select plan(6);

set local role authenticated;

select test.login_user() as owner_a \gset

select gen_random_uuid() as profile_1 \gset
select gen_random_uuid() as profile_2 \gset
insert into public.profiles (id, owner, name) values (:'profile_1'::uuid, :'owner_a'::uuid, 'One');
insert into public.profiles (id, owner, name) values (:'profile_2'::uuid, :'owner_a'::uuid, 'Two');

select gen_random_uuid() as src_plain \gset
select gen_random_uuid() as src_enc \gset
insert into public.sources (id, owner, profile_id, kind, label)
  values (:'src_plain'::uuid, :'owner_a'::uuid, :'profile_1'::uuid, 'm3u', 'plaintext');
insert into public.sources (id, owner, profile_id, kind, label)
  values (:'src_enc'::uuid, :'owner_a'::uuid, :'profile_1'::uuid, 'm3u', 'encrypted');

-- Seeded as the bootstrapping role: source_secrets is RPC-only (zero policies,
-- and since tenant_isolation no client grants), so `authenticated` cannot write
-- it directly. set_source_secret would refuse format 1 while the profile has
-- E2EE off, and standing up a whole crypto profile would test the wrong thing.
reset role;
insert into public.source_secrets (source_id, owner, profile_id, format, payload)
  values (:'src_plain'::uuid, :'owner_a'::uuid, :'profile_1'::uuid, 0,
          '{"playlistUrl":"https://example.invalid/list"}'::jsonb);
insert into public.source_secrets (source_id, owner, profile_id, format, payload)
  values (:'src_enc'::uuid, :'owner_a'::uuid, :'profile_1'::uuid, 1,
          '{"ckv":1,"ct":"x"}'::jsonb);

set local role authenticated;
select test.jwt(:'owner_a'::uuid, false);

-- ---------------------------------------------------------------------------
-- Move both sources to the second profile.
-- ---------------------------------------------------------------------------

select lives_ok(
  format('update public.sources set profile_id = %L where id in (%L, %L)',
         :'profile_2'::uuid, :'src_plain'::uuid, :'src_enc'::uuid),
  'moving a source between the account''s own profiles succeeds'
);

reset role;

select is(
  (select profile_id from public.source_secrets where source_id = :'src_plain'::uuid),
  :'profile_2'::uuid,
  'a moved source''s plaintext secret follows it to the new profile'
);

-- format 1's AAD binds the OLD profile id, so the envelope is undecryptable
-- under the new one regardless — deleting matches push_sources' M2 semantics.
select is(
  (select count(*)::int from public.source_secrets where source_id = :'src_enc'::uuid),
  0,
  'a moved source''s format-1 envelope is dropped rather than silently re-pointed'
);

-- ---------------------------------------------------------------------------
-- The payoff: deleting the vacated profile must no longer take the credential
-- with it. This is the assertion that would have failed before the trigger.
-- ---------------------------------------------------------------------------

select lives_ok(
  format('delete from public.profiles where id = %L', :'profile_1'::uuid),
  'the vacated profile can be deleted'
);

select is(
  (select count(*)::int from public.source_secrets where source_id = :'src_plain'::uuid),
  1,
  'deleting the vacated profile does NOT cascade away the moved source''s secret'
);

select is(
  (select payload ->> 'playlistUrl' from public.source_secrets where source_id = :'src_plain'::uuid),
  'https://example.invalid/list',
  'the surviving secret still holds its original payload'
);

select * from finish();

rollback;
