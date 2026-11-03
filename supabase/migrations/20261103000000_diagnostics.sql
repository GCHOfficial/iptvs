-- iptvs — "Send diagnostics": a user hands the developer one log, by code.
--
-- Why this exists
-- ---------------
-- The exportable diagnostics log is the only evidence a playback or ingestion
-- bug ever leaves behind, and the device it lives on is usually a television:
-- no keyboard, no mail client, no file manager. "Copy and paste it to me" is
-- not a thing a TV remote can do. This adds one button that uploads the log and
-- shows a six-character code the user can read out, plus the developer-only
-- read path for it.
--
-- The owner's bounds, which this migration implements and MUST NOT be widened:
-- insert-only, size-capped, rate-limited, 30-day expiry, readable only by the
-- app developer. The machine deletes below (lazy expiry, ceiling eviction) are
-- how a <=30-day expiry is *implemented*, not a widening of it. A
-- developer-initiated delete is deliberately NOT in scope; it would be a
-- separate RPC, and the DELETE guard here is written so that adding one later
-- means adding a third sweep mode rather than loosening anything.
--
-- The one real departure from everything before it
-- ------------------------------------------------
-- `submit_diagnostics` is the **first write RPC in this schema callable by the
-- `anon` role** — i.e. by an install with no session at all, holding nothing but
-- the public anon key. Every other device->cloud write path requires a paired
-- anonymous session and resolves an owner through `current_device_owner()`.
--
-- That is deliberate, and the alternative is worse. Requiring a session here
-- would mean calling `signInAnonymously()` from the diagnostics screen, and an
-- anonymous sign-in mints a permanent `auth.users` row that counts toward the
-- project's monthly active users forever. This repo has already paid that bill
-- once: the profile picker used to call `ensureAnonSession()` on the boot path
-- and produced ~1,900 anonymous users against 62 devices that ever paired (see
-- docs/cloud-sync.md). Worse, it would buy nothing: a per-session meter is not a
-- bound when sessions are free to mint, so a bad actor would simply mint one per
-- submission.
--
-- The consequence is that **every bound here is absolute (global), never per
-- subject** — there is no trustworthy subject to meter. A global budget is a
-- denial-of-service lever (one actor can exhaust the hour's submissions for
-- everyone), and that is accepted: the failure mode is "the support button says
-- try later", which is exactly where users were before this feature existed.
-- The thing a global budget *does* bound is the only thing that matters here —
-- unbounded storage growth on a free-tier project.
--
-- House rules this file follows (CLAUDE.md "Cloud sync + profiles"):
--   * every SECURITY DEFINER function pins `search_path = ''` and
--     schema-qualifies everything;
--   * NO `force row level security` anywhere — the RPC-only tables rely on RLS
--     with zero policies plus table-level REVOKEs, and FORCE would make the
--     DEFINER RPCs (owned by `postgres`, which owns the tables) silently read
--     and write nothing;
--   * rejections are `iptvs: `-prefixed `check_violation`s carrying the LIMIT
--     only, never the offending value;
--   * server `now()` — the client sends no timestamps;
--   * no `DEFAULT` parameters anywhere (see the note on `submit_diagnostics`).
--
-- Idempotent throughout (create or replace / if not exists / drop trigger if
-- exists), like every migration before it.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Who may read submitted diagnostics. One row per developer account, seeded
-- **by hand from the Supabase dashboard** after that account has signed in once
-- (supabase/README.md documents the insert).
--
-- Empty means nobody can read anything — fail closed. There is deliberately no
-- RPC that adds a reader: a self-service "make me a reader" path would be the
-- whole security boundary of this feature, and the boundary is better off being
-- a row only someone with dashboard access can write.
create table if not exists public.support_readers (
  uid        uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- One submitted log.
--
-- `code` is the primary key AND the thing the user reads out loud. It is an
-- **identifier, not a bearer token**: there is no read path for a non-developer
-- caller, so guessing one gains nothing. (If a read-by-code path is ever added
-- for the submitting device, this becomes a secret and needs a secret's
-- entropy — 6 characters of a 31-symbol alphabet is ~29.7 bits, which is a fine
-- identifier and a poor token.)
--
-- Every metadata column is **self-asserted by an unauthenticated client** and
-- must be treated as attacker-controlled wherever it is displayed. They are
-- bounded and control-character-free (see `assert_diagnostics_valid`) precisely
-- because they are rendered in the developer's own signed-in panel; the panel
-- escapes them as well.
--
-- `install_hint` is free text the app sends to help correlate two reports from
-- the same install. It is NOT an identity and nothing may be inferred from it.
--
-- No column CHECK constraints, on purpose. A CHECK violation's DETAIL is
-- "Failing row contains (...)" — which here would echo the entire log body back
-- over the wire. Everything is validated in a BEFORE trigger instead, the same
-- reason `sources_validate` exists rather than constraints on `sources`.
create table if not exists public.diagnostics (
  code         text primary key,
  body         text not null,
  body_bytes   int  not null default 0,
  app_version  text not null default '',
  platform     text not null default '',
  channel      text not null default '',
  is_tv        boolean not null default false,
  install_hint text not null default '',
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '30 days'
);

-- The sweep orders by expires_at; the ceiling eviction and the developer list
-- order by created_at. Both are tiny tables by construction (<=2000 rows), but
-- the sweep runs on every single submission, so it gets its index.
create index if not exists diagnostics_expires_idx on public.diagnostics(expires_at);
create index if not exists diagnostics_created_idx on public.diagnostics(created_at);

-- The global submission meter. ONE row, keyed on a constant bucket — there is
-- no subject to key on (see the header). Same `ON CONFLICT DO UPDATE` sliding
-- window as `check_push_rate`, which is what makes the read-modify-write atomic
-- under concurrency without an explicit lock.
create table if not exists public.diag_rate (
  bucket       text primary key,
  window_start timestamptz not null default now(),
  count        int not null default 0
);

-- ---------------------------------------------------------------------------
-- RLS: enabled with DELIBERATELY ZERO policies on all three, plus table-level
-- REVOKEs. Deny-by-default: no client role reaches these tables at all, in
-- either direction. Reads go through the two developer RPCs, writes through
-- `submit_diagnostics`. This is the `source_secrets` pattern, and for a
-- stronger reason: a diagnostics body contains a user's provider address,
-- source and profile names, and what they watched.
--
-- The REVOKE also strips TRUNCATE, which RLS does not filter and which would
-- otherwise be a latent full-wipe primitive.
-- ---------------------------------------------------------------------------

alter table public.support_readers enable row level security;
alter table public.diagnostics      enable row level security;
alter table public.diag_rate        enable row level security;

revoke all on table public.support_readers from anon, authenticated;
revoke all on table public.diagnostics      from anon, authenticated;
revoke all on table public.diag_rate        from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Validation (pure: inspects only its arguments, touches no table, holds no
-- secret). Called from the BEFORE INSERT trigger AND from the top of the submit
-- RPC — the RPC's call is the cheap early-out that stops a 300 MB body being
-- carried through the sweep and the ceiling arithmetic before being rejected,
-- and the trigger's call is the one that is actually authoritative.
--
-- Messages carry the LIMIT and nothing else. "diagnostics too large (max 262144
-- bytes)" tells the client what to trim to; echoing the body would defeat the
-- entire point of the table.
-- ---------------------------------------------------------------------------

create or replace function public.assert_diagnostics_valid(
  p_body         text,
  p_app_version  text,
  p_platform     text,
  p_channel      text,
  p_install_hint text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  -- 256 KiB. The client trims oldest-first to fit (`DiagnosticsLog
  -- .asTextBounded`), so a submit should never fail on size — this is the
  -- backstop for a client that doesn't, not the user-facing limit.
  max_body_bytes constant int := 262144;
  -- Realistic: "0.1.73", "android", "googlePlay". 64 is already ~4x.
  max_meta_chars constant int := 64;
  meta text;
begin
  if p_body is null then
    raise exception 'iptvs: diagnostics body is required'
      using errcode = 'check_violation';
  end if;
  if octet_length(p_body) > max_body_bytes then
    raise exception 'iptvs: diagnostics too large (max % bytes)', max_body_bytes
      using errcode = 'check_violation';
  end if;

  foreach meta in array array[
    coalesce(p_app_version, ''),
    coalesce(p_platform, ''),
    coalesce(p_channel, ''),
    coalesce(p_install_hint, '')
  ]
  loop
    if length(meta) > max_meta_chars then
      raise exception 'iptvs: diagnostics metadata too long (max % characters)',
        max_meta_chars
        using errcode = 'check_violation';
    end if;
    -- These four strings are rendered in the developer's panel. A control
    -- character in one of them is either an ANSI escape dressing a fake line up
    -- as a real one, or a bidi override reversing what it reads as. The panel
    -- scrubs for display as well; this stops them being stored at all.
    if meta ~ '[[:cntrl:]]' then
      raise exception 'iptvs: diagnostics metadata contains control characters'
        using errcode = 'check_violation';
    end if;
  end loop;
end;
$$;

revoke all on function public.assert_diagnostics_valid(text, text, text, text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- BEFORE INSERT: normalise, then validate, then compute `body_bytes` from the
-- body itself.
--
-- `body_bytes` is the input to the storage ceiling, so it is **never** taken
-- from the caller — a client that under-reports it would be handing itself an
-- unbounded quota. It is recomputed here, where it cannot be argued with.
--
-- Every nullable-looking field is coalesced before the column's NOT NULL can
-- fire, for the same reason this table has no CHECKs: a NOT NULL violation's
-- DETAIL echoes the whole row, body included.
create or replace function public.diagnostics_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.body is null then
    raise exception 'iptvs: diagnostics body is required'
      using errcode = 'check_violation';
  end if;
  new.app_version  := coalesce(new.app_version, '');
  new.platform     := coalesce(new.platform, '');
  new.channel      := coalesce(new.channel, '');
  new.install_hint := coalesce(new.install_hint, '');
  new.is_tv        := coalesce(new.is_tv, false);
  new.created_at   := coalesce(new.created_at, now());
  new.expires_at   := coalesce(new.expires_at, now() + interval '30 days');

  perform public.assert_diagnostics_valid(
    new.body, new.app_version, new.platform, new.channel, new.install_hint);

  new.body_bytes := octet_length(new.body);
  return new;
end;
$$;

drop trigger if exists diagnostics_validate on public.diagnostics;
create trigger diagnostics_validate before insert on public.diagnostics
  for each row execute function public.diagnostics_validate();

-- BEFORE UPDATE OR DELETE: the insert-only guarantee, enforced structurally.
--
-- UPDATE is refused unconditionally. A submitted log is a piece of evidence;
-- nothing in this design ever needs to edit one, and "nothing edits it" is a
-- far easier property to keep true than "only the right things edit it".
--
-- DELETE is refused unless the row is *itself* eligible, under a
-- transaction-local mode flag the submit RPC sets — the same
-- `set_config(..., true)` idiom as `iptvs.force_profile_revision`. Two modes:
--
--   'expire' — the row is past `expires_at`. This is the 30-day expiry being
--              implemented, not an exception to it.
--   'evict'  — the row is older than the 72 h floor and the table is at its
--              absolute ceiling.
--
-- The guard re-checks the row's own eligibility rather than trusting the flag,
-- which is the whole point: a bug in the sweep's WHERE clause cannot delete a
-- fresh submission, because the trigger would refuse it. Adding a
-- developer-initiated delete later means adding a third mode here — a visible,
-- reviewable change — rather than relaxing anything.
--
-- This fires for every role including `postgres` and `service_role`, so it
-- binds the dashboard too.
create or replace function public.diagnostics_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  mode text := coalesce(current_setting('iptvs.diagnostics_sweep', true), '');
begin
  if tg_op = 'UPDATE' then
    raise exception 'iptvs: diagnostics rows cannot be modified'
      using errcode = 'check_violation';
  end if;

  if mode = 'expire' and old.expires_at <= now() then
    return old;
  end if;
  if mode = 'evict' and old.created_at <= now() - interval '72 hours' then
    return old;
  end if;

  raise exception 'iptvs: diagnostics rows cannot be deleted'
    using errcode = 'check_violation';
end;
$$;

drop trigger if exists diagnostics_immutable on public.diagnostics;
create trigger diagnostics_immutable before update or delete on public.diagnostics
  for each row execute function public.diagnostics_immutable();

revoke all on function public.diagnostics_validate()  from public, anon, authenticated;
revoke all on function public.diagnostics_immutable() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The global meter.
--
-- Structurally `check_push_rate`, minus the subject. `check_push_rate` returns
-- early when `auth.uid()` is null because its callers reject a session-less
-- caller anyway; here a session-less caller is the *normal* case, so the bucket
-- is a constant and the window is shared by everyone.
-- ---------------------------------------------------------------------------

create or replace function public.check_diagnostics_rate(p_limit int, p_window interval)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cur int;
begin
  insert into public.diag_rate as dr (bucket, window_start, count)
    values ('submit', now(), 1)
  on conflict (bucket) do update
    set window_start = case when dr.window_start < now() - p_window
                            then now() else dr.window_start end,
        count        = case when dr.window_start < now() - p_window
                            then 1 else dr.count + 1 end
  returning dr.count into cur;

  if cur > p_limit then
    raise exception 'iptvs: too many diagnostics submissions, try again later'
      using errcode = 'check_violation';
  end if;
end;
$$;

revoke all on function public.check_diagnostics_rate(int, interval)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The code.
--
-- `D-` + 6 characters of the same unambiguous alphabet `gen_pairing_code` uses
-- (no I/L/O/0/1 — these are read off a television across a room and spoken down
-- a phone line). The `D-` prefix keeps it structurally distinct from an 8-char
-- pairing code, so a user who pastes the wrong one into the wrong box gets a
-- clean rejection rather than a confusing lookup.
--
-- Same modulo bias as `gen_pairing_code` (256 % 31 = 8, so the first eight
-- symbols are ~3% likelier). Left as-is deliberately: this is an identifier, the
-- generator retries on collision, and divergence from the pairing generator
-- would be a worse thing to explain than the bias.
--
-- SECURITY INVOKER, like `gen_pairing_code`, and revoked from every client
-- role. Only the DEFINER submit RPC calls it, and a function's owner always
-- retains EXECUTE on its own functions regardless of the REVOKEs.
-- ---------------------------------------------------------------------------

create or replace function public.gen_diagnostics_code()
returns text
language plpgsql
set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  out text := 'D-';
  i int;
begin
  for i in 1..6 loop
    out := out || substr(alphabet,
      1 + (get_byte(extensions.gen_random_bytes(1), 0) % length(alphabet)), 1);
  end loop;
  return out;
end;
$$;

revoke all on function public.gen_diagnostics_code() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- submit_diagnostics — the anon-callable write path.
--
-- NO DEFAULT PARAMETERS, and that is a rule rather than a preference. PostgREST
-- resolves an overload by the *set of parameter names* in the request body, and
-- a DEFAULT sitting beside a narrower overload makes two candidates match the
-- same call — answered as `PGRST203`, which in this schema's history broke 100%
-- of pairings. There is no narrower overload today; this shape makes it
-- impossible for one to be added carelessly later. A future field is a NEW
-- arity with every parameter explicit, and this one stays forever as a delegate
-- (installs are arbitrarily old).
--
-- Order of operations, each step chosen:
--   1. validate      — cheap, pure, and rejects a hostile payload before it can
--                      cost anything.
--   2. meter         — *after* validation, so garbage can't burn the global
--                      hourly budget that real users share.
--   3. expire        — bounded lazy sweep; see below.
--   4. ceiling       — evict above the 72 h floor, else refuse.
--   5. insert        — server-generated code, retried on collision.
-- ---------------------------------------------------------------------------

create or replace function public.submit_diagnostics(
  p_body         text,
  p_app_version  text,
  p_platform     text,
  p_channel      text,
  p_is_tv        boolean,
  p_install_hint text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- Absolute bounds. Sized for a free-tier project: 2000 logs of up to 256 KiB
  -- would be 500 MB, so the byte ceiling is the one that usually binds.
  max_rows    constant int      := 2000;
  max_bytes   constant bigint   := 67108864;          -- 64 MiB
  rate_limit  constant int      := 120;
  rate_window constant interval := interval '1 hour';
  -- The sweep is bounded so one unlucky submission can't pay for a month of
  -- accumulated expiry in a single request. Anything it doesn't reach is
  -- already invisible to the developer RPCs (both filter `expires_at > now()`),
  -- so the only cost of being behind is disk, and the next submission catches
  -- up.
  sweep_limit constant int      := 200;
  -- Nothing is evicted before this age, however full the table is. Without it,
  -- a burst of submissions would evict the reports that burst is about.
  evict_floor constant interval := interval '72 hours';

  body         text := coalesce(p_body, '');
  new_bytes    int;
  n_rows       bigint;
  n_bytes      bigint;
  victim       text;
  victim_bytes int;
  evicted      int := 0;
  -- `attempt` is deliberately NOT declared: the integer FOR loop below defines
  -- its own loop variable and ignores any outer one of the same name, so a
  -- declaration here would be dead weight that merely looks like state.
  new_code     text;
begin
  perform public.assert_diagnostics_valid(
    body, p_app_version, p_platform, p_channel, p_install_hint);
  new_bytes := octet_length(body);

  perform public.check_diagnostics_rate(rate_limit, rate_window);

  -- 3. Lazy expiry. There is no cron on this project, so expiry is work the
  --    next writer does.
  --    `FOR UPDATE SKIP LOCKED` rather than a plain subquery: two submits
  --    landing together would otherwise pick the same expired rows and delete
  --    them in whatever order the planner chose, which is a deadlock waiting
  --    for a quiet night. Skipping a row another transaction is already
  --    deleting is exactly the right answer — it is going away either way.
  perform set_config('iptvs.diagnostics_sweep', 'expire', true);
  delete from public.diagnostics
   where code in (
     select d.code
       from public.diagnostics d
      where d.expires_at <= now()
      order by d.expires_at
      limit sweep_limit
      for update skip locked);
  perform set_config('iptvs.diagnostics_sweep', '', true);

  -- 4. Absolute ceiling.
  select count(*), coalesce(sum(d.body_bytes), 0)
    into n_rows, n_bytes
    from public.diagnostics d;

  while n_rows >= max_rows or n_bytes + new_bytes > max_bytes loop
    -- Belt and braces: the loop makes progress by construction (each pass
    -- deletes exactly one row), but an unbounded WHILE inside a DEFINER
    -- function reachable by `anon` is not a thing to leave to construction.
    evicted := evicted + 1;
    if evicted > max_rows then
      raise exception 'iptvs: diagnostics are temporarily unavailable'
        using errcode = 'check_violation';
    end if;

    -- Same reason as the sweep, plus one of its own: without SKIP LOCKED two
    -- concurrent submits can choose the SAME victim, and the loser's DELETE
    -- removes nothing while its bookkeeping still decrements `n_rows` — so it
    -- would believe it had made room it had not, and push the table past the
    -- ceiling this loop exists to hold.
    select d.code, d.body_bytes
      into victim, victim_bytes
      from public.diagnostics d
     where d.created_at <= now() - evict_floor
     order by d.created_at
     limit 1
     for update skip locked;

    if victim is null then
      -- Everything in the table is inside the 72 h floor. Refuse rather than
      -- evict a fresh report, and say nothing about why beyond "later".
      raise exception 'iptvs: diagnostics are temporarily unavailable'
        using errcode = 'check_violation';
    end if;

    perform set_config('iptvs.diagnostics_sweep', 'evict', true);
    delete from public.diagnostics where code = victim;
    perform set_config('iptvs.diagnostics_sweep', '', true);

    n_rows  := n_rows - 1;
    n_bytes := n_bytes - victim_bytes;
    victim  := null;
  end loop;

  -- 5. Insert under a server-generated code. The retry is for a PK collision,
  --    which at 2000 rows against 31^6 is vanishingly rare — but `unique_violation`
  --    is the one error here that is not a bug, so it is handled rather than
  --    surfaced.
  for attempt in 1..12 loop
    new_code := public.gen_diagnostics_code();
    begin
      insert into public.diagnostics (
        code, body, app_version, platform, channel, is_tv, install_hint)
      values (
        new_code,
        body,
        coalesce(p_app_version, ''),
        coalesce(p_platform, ''),
        coalesce(p_channel, ''),
        coalesce(p_is_tv, false),
        coalesce(p_install_hint, ''));
      return new_code;
    exception when unique_violation then
      -- try again
    end;
  end loop;

  raise exception 'iptvs: diagnostics are temporarily unavailable'
    using errcode = 'check_violation';
end;
$$;

-- THE anon grant. This is the only `grant execute ... to anon` on a write path
-- in this schema; see the header for why. Pinned by 01_baseline_invariants so
-- it can neither disappear nor spread silently.
revoke all on function
  public.submit_diagnostics(text, text, text, text, boolean, text) from public;
grant execute on function
  public.submit_diagnostics(text, text, text, text, boolean, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Developer reads.
-- ---------------------------------------------------------------------------

-- Is the caller the app developer?
--
-- SECURITY DEFINER because `support_readers` has zero policies and zero grants,
-- so an INVOKER call would die on "permission denied for table" before it could
-- answer. Not granted to any client role: nothing needs to ask this directly —
-- the panel decides whether to show its Support tab by whether
-- `support_list_diagnostics` succeeds, which is the same question asked where
-- the answer is actually enforced.
--
-- `is_real_user()` is a conjunct rather than an afterthought: a reader row is
-- seeded by hand against a real signed-in account, and an anonymous session
-- should never satisfy this even if one somehow acquired a seeded uid.
create or replace function public.is_support_reader()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_real_user()
     and exists (
       select 1 from public.support_readers r where r.uid = auth.uid()
     )
$$;

revoke all on function public.is_support_reader() from public, anon, authenticated;

-- The inbox. Metadata only — the body costs a second call, so listing 100
-- submissions doesn't drag 25 MB of log text through the browser.
--
-- Expired rows are filtered here as well as swept lazily, so the 30-day promise
-- holds the instant it falls due rather than whenever the next submission
-- happens to run the sweep.
create or replace function public.support_list_diagnostics(p_limit int)
returns table (
  code         text,
  created_at   timestamptz,
  expires_at   timestamptz,
  body_bytes   int,
  app_version  text,
  platform     text,
  channel      text,
  is_tv        boolean,
  install_hint text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  lim int := least(greatest(coalesce(p_limit, 50), 1), 500);
begin
  if not public.is_support_reader() then
    raise exception 'iptvs: not authorised' using errcode = 'check_violation';
  end if;

  return query
    select d.code, d.created_at, d.expires_at, d.body_bytes,
           d.app_version, d.platform, d.channel, d.is_tv, d.install_hint
      from public.diagnostics d
     where d.expires_at > now()
     order by d.created_at desc
     limit lim;
end;
$$;

-- One body. Returns null for an unknown or expired code — the caller is already
-- the developer, so there is nothing to conceal by distinguishing them, and
-- "null" is the one answer the panel can render without a special case.
create or replace function public.support_get_diagnostics(p_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  b text;
begin
  if not public.is_support_reader() then
    raise exception 'iptvs: not authorised' using errcode = 'check_violation';
  end if;

  select d.body into b
    from public.diagnostics d
   where d.code = upper(btrim(coalesce(p_code, '')))
     and d.expires_at > now();
  return b;
end;
$$;

revoke all on function public.support_list_diagnostics(int)  from public, anon;
revoke all on function public.support_get_diagnostics(text)  from public, anon;
grant execute on function public.support_list_diagnostics(int)  to authenticated;
grant execute on function public.support_get_diagnostics(text)  to authenticated;
