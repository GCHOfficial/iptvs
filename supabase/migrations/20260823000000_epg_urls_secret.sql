-- `epgUrls` joins the source secret-key set.
--
-- Why
-- ---
-- A source can now carry more than one XMLTV guide: the provider's own, plus
-- any number of user-added top-up URLs, merged per channel by the client
-- (`lib/sources/epg_guides.dart`). The extra URLs live in a new source field,
-- `epgUrls` — one URL per line, additional guides only, so the existing
-- `epgUrl` keeps meaning exactly what it always did and an already-published
-- app build that pulls this source still reads its first guide correctly
-- instead of choking on a widened value.
--
-- Those URLs are credential-bearing in exactly the way `epgUrl` and
-- `playlistUrl` are — providers routinely embed username/password in a guide's
-- query string — so the key has to be secret, which means `sources_validate()`
-- has to strip it. Without this migration a key Dart has already classified as
-- secret would be unknown to the trigger, and any writer that *didn't* apply
-- the client-side split would land it in the broadly-readable `sources.fields`
-- row. `test/secret_keys_parity_test.dart` fails until both sides agree, which
-- is what brought this file into being.
--
-- Deploy this BEFORE shipping a client that writes `epgUrls`. The clients apply
-- the split themselves (`kSourceSecretKeys` / panel `SOURCE_SECRET_KEYS`), so
-- the trigger is defence in depth rather than the only guard — but it is the
-- half that holds when a writer is old, wrong, or hostile, and it costs nothing
-- to have in place first.
--
-- How
-- ---
-- `create or replace` over the whole function: the body is otherwise verbatim
-- from `20260725000000_secrets_store.sql`, which is immutable (already applied
-- to production). Only the `array[...]` literal changes.

create or replace function public.sources_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Explicit nulls would pass through to the columns' NOT NULL constraints,
  -- whose error DETAIL echoes the full row (credentials included) — reject
  -- them here first with a clean error.
  if new.label is null or new.fields is null or new.settings is null
     or new.position is null then
    raise exception 'iptvs: source row has null fields'
      using errcode = 'check_violation';
  end if;
  -- Phase 2 strip: credential keys live only in source_secrets.
  new.fields := coalesce(new.fields, '{}'::jsonb)
    - array['mac', 'username', 'password', 'playlistUrl', 'epgUrl', 'epgUrls', 'userAgent'];
  perform public.assert_source_valid(new.kind, new.label, new.fields, new.settings);
  return new;
end;
$$;

-- Sweep any row that predates the strip. Expected to match nothing: no shipped
-- client has ever written this key, and the ones that will apply the split
-- before pushing. The `?` predicate keeps that a zero-row UPDATE rather than a
-- full-table rewrite — which also means it fires no snapshot-revision trigger
-- and provokes no device re-pull storm.
update public.sources s
   set fields = s.fields - 'epgUrls'
 where s.fields ? 'epgUrls';
