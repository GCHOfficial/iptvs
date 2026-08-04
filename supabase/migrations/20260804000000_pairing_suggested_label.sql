-- ---------------------------------------------------------------------------
-- Device name at pairing time.
--
-- A freshly paired device had no name: `devices.label` defaulted to '' and the
-- panel rendered "Device" until the owner used Rename. This migration lets a
-- name exist from the moment of pairing, from either end:
--
--   * the DEVICE sends a platform-derived SUGGESTION ("Android TV",
--     "Windows PC") when it asks for a pairing code — zero typing, which
--     matters because the primary device is a TV with a D-pad remote;
--   * the PANEL operator may type a name into the Pair form, which wins.
--
-- WHY A DEVICE-SUPPLIED *SUGGESTION* AND NOT A DEVICE-WRITTEN LABEL.
-- A device is an ANONYMOUS auth user, and `devices_update` is
-- `owner = auth.uid() and is_real_user()` — a device simply cannot write its
-- own `devices` row, by design. Granting it one would mean a new
-- `set_device_label` SECURITY DEFINER RPC, which is permanent API surface a
-- device could call at ANY time, letting it overwrite an owner-chosen name
-- forever rather than only at pairing. Routing the suggestion through the
-- pairing row it already creates keeps the write window bounded to the pairing
-- itself and adds no new callable surface.
--
-- POSTGREST OVERLOAD RESOLUTION — THE CONSTRAINT THAT SHAPES THIS FILE.
-- PostgREST chooses the candidate whose PARAMETER-NAME SET matches the request
-- body's keys; if two candidates match it fails with PGRST203 ("could not
-- choose the best candidate function"). Therefore the overloads here are
-- ARITY-DISTINCT WITH NO DEFAULT ON ANY PARAMETER. Adding
-- `claim_pairing(p_code text, p_label text DEFAULT null)` beside the existing
-- `claim_pairing(p_code text)` would make a `{p_code}` body ambiguous and break
-- EVERY pairing — a total outage, not a degraded field. The precedent is
-- already in this repo and live in production: `20260726000000_e2ee.sql` ships
-- `push_metadata` as (jsonb), (jsonb,uuid) and (jsonb,uuid,jsonb), none with a
-- DEFAULT. A DEFAULT is only correct here if the narrower form is dropped in
-- the same migration — which this file deliberately does NOT do:
--
--   * `request_pairing()` (0-arg) is called by INSTALLED APP VERSIONS, which
--     can be arbitrarily old and cannot be forced to update. It must keep
--     working forever.
--   * `claim_pairing(p_code)` (1-arg) is called by the panel, a static SPA a
--     user can leave OPEN ACROSS A DEPLOY. Dropping it would break the Pair
--     button in any tab loaded before the deploy.
--
-- Both narrow forms are therefore KEPT, rewritten as thin delegates into the
-- wide forms so there is exactly one copy of each body. The delegates carry no
-- rate check and no identity check of their own — both live in the wide body
-- they call, so every path is metered exactly once and an anonymous caller
-- still gets the identical error it gets today.
--
-- `suggested_label` IS ATTACKER-CONTROLLED TEXT. It arrives from an anonymous
-- session and is rendered in ANOTHER ACCOUNT'S panel device list. Hence: a
-- length bound, a control-character rejection (`\n`/`\r`/`\t` would break the
-- panel's row layout), and the panel's existing `esc()` on render — the label
-- is written into a text node, never an HTML attribute. The string carries zero
-- authority: nothing branches on it, it is display only.
--
-- BOUND COUPLING. The `pairings_validate` ceiling MUST be <= the
-- `devices_validate` ceiling (256, set by 20260727000000_tenant_isolation.sql).
-- If a suggestion could pass at pairing INSERT but fail `devices_validate`
-- inside `claim_pairing`, a device could store a value that makes the owner's
-- claim fail outright — a denial of pairing. Equal ceilings close that.
--
-- WHY `suggested_label` JOINS THE UPDATE FREEZE. There is no UPDATE policy on
-- `pairings` today, so nothing client-reachable can mutate it — but the freeze
-- in `pairings_validate` exists precisely as belt-and-braces against a policy
-- being re-added later (that is the same reasoning tenant_isolation.sql applied
-- when it dropped `pairings_insert`). If the suggestion were mutable and a
-- self-scoped `device_uid = auth.uid()` UPDATE policy ever reappeared, a device
-- could change its suggestion AFTER the user has read the code off its screen
-- and WHILE they are typing it into the panel — a TOCTOU relabel with no
-- legitimate use. `claim_pairing` only ever sets `claimed_by`, so the added
-- freeze is inert on the live path.
--
-- LABEL PRECEDENCE (the whole feature in one line):
--
--   panel-supplied (trimmed, non-blank)
--     > existing devices.label (SAME owner only)
--       > device suggestion
--         > ''
--
-- This is the scalar analogue of `merge_preserving_nonempty`: an absent value
-- never blanks a stored one, and only an explicit panel action changes a stored
-- non-empty name. Concretely — a re-pair with the panel field left blank must
-- NOT clobber a hand-chosen "Living room TV" with "Android TV"; that would be a
-- device-side value overwriting a panel-set one, exactly the class the
-- field-preserve rule forbids.
--
-- The "SAME owner only" qualifier is a deliberate BEHAVIOUR CHANGE. Today a
-- device re-paired from account A to account B carries A's chosen name
-- ("Grandma's bedroom TV") into B's device list — a small pre-existing
-- cross-account information flow. A new owner now always starts from the
-- device's own suggestion instead. Pinned by 13_pairing_label.test.sql.
--
-- ORDERING NOTE (not cosmetic): `claim_pairing` bounds the panel's label
-- BEFORE it looks the code up, so the error cannot depend on whether the code
-- exists. Validating after the lookup would turn an oversized label into an
-- oracle for code validity, which is the exact surface tenant_isolation.sql's
-- F6 rate limit was added to shrink.
--
-- ACCEPTED RESIDUALS:
--   * The suggestion is unauthenticated by nature — any holder of the public
--     anon key can open an anonymous session and claim to be "Living room TV".
--     It is a display string with zero authority and cannot influence any
--     decision path, so there is nothing to authenticate it against.
--   * Bidi / zero-width Unicode (U+202E and friends) is NOT caught by
--     `[[:cntrl:]]` and could visually reorder a device row's text. Accepted
--     for a display-only, `esc()`-rendered string.
--
-- IDEMPOTENT / RE-ENTRANT throughout: `add column if not exists`,
-- `create or replace` for every function, `drop trigger if exists` before
-- create, and NO `drop function` anywhere (dropping would discard grants and
-- break the open-tab / old-app cases above).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. The column.
--
--    NOT NULL DEFAULT '' with a non-volatile default: no table rewrite on
--    PG11+, and every pre-existing row reads as "no suggestion", which is
--    exactly today's behaviour.
-- ---------------------------------------------------------------------------

alter table public.pairings
  add column if not exists suggested_label text not null default '';

-- ---------------------------------------------------------------------------
-- 2. request_pairing(p_label) — the device's suggestion.
--
--    Body is VERBATIM from 20260716000000_harden_cloud.sql's request_pairing(),
--    with exactly two changes: the `sugg` local, and `suggested_label` on the
--    INSERT. The 5/min rate limit, the previous-code delete, and the collision
--    retry loop are untouched.
--
--    `left(btrim(...), 256)` TRUNCATES rather than rejects: the trigger's bound
--    is belt-and-braces against a future direct writer, not an error path the
--    real caller should ever reach. Control characters are deliberately NOT
--    stripped here — the trigger rejects them, and a device that sends one only
--    fails its own pairing.
-- ---------------------------------------------------------------------------

create or replace function public.request_pairing(p_label text)
returns table (code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  dev uuid := auth.uid();
  new_code text;
  recent int;
  sugg text := left(btrim(coalesce(p_label, '')), 256);
begin
  if dev is null then
    raise exception 'not authenticated';
  end if;

  -- Rate limit: at most 5 requests per device per minute.
  select count(*) into recent
    from public.pairings
    where device_uid = dev and created_at > now() - interval '1 minute';
  if recent >= 5 then
    raise exception 'too many pairing requests, slow down';
  end if;

  -- Drop this device's previous unclaimed/expired codes.
  delete from public.pairings as p
    where p.device_uid = dev and (p.claimed_by is null or p.expires_at < now());

  -- Generate a unique code (retry on the rare collision).
  loop
    new_code := public.gen_pairing_code();
    begin
      insert into public.pairings (code, device_uid, expires_at, suggested_label)
        values (new_code, dev, now() + interval '10 minutes', sugg);
      exit;
    exception when unique_violation then
      -- try again
    end;
  end loop;

  return query
    select p.code, p.expires_at from public.pairings p where p.code = new_code;
end;
$$;

-- Legacy 0-arg form, kept forever for old installed app versions. The explicit
-- ''::text cast is REQUIRED — an untyped literal is `unknown` and would not
-- resolve against the 1-arg signature. No rate check here: it lives in the
-- 1-arg body, and duplicating it would halve the effective limit for legacy
-- callers.
create or replace function public.request_pairing()
returns table (code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query select * from public.request_pairing(''::text);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. pairings_validate — bound the new column, and freeze it on UPDATE.
--
--    Body VERBATIM from 20260727000000_tenant_isolation.sql section 5 plus the
--    `suggested_label` checks. The trigger stays purely REJECTING and never
--    rewrites NEW — a rewrite would make the UPDATE freeze compare against a
--    rewritten value rather than what the writer actually sent.
-- ---------------------------------------------------------------------------

create or replace function public.pairings_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  max_code_len constant int      := 64;                    -- gen_pairing_code emits 8
  max_ttl      constant interval := interval '15 minutes'; -- request_pairing uses 10
  max_label    constant int      := 256;                   -- realistic suggestion <= 32
                                                           -- ("Android TV"); MUST stay
                                                           -- <= devices_validate's 256
begin
  if tg_op = 'INSERT' then
    if new.code is null or length(new.code) > max_code_len then
      raise exception 'iptvs: pairing code invalid (max % chars)', max_code_len
        using errcode = 'check_violation';
    end if;
    if new.device_uid is null then
      raise exception 'iptvs: pairing row has null fields'
        using errcode = 'check_violation';
    end if;
    if new.expires_at is null or new.expires_at > now() + max_ttl then
      raise exception 'iptvs: pairing code lifetime too long'
        using errcode = 'check_violation';
    end if;
    -- Attacker-controlled text bound for another account's device list.
    if new.suggested_label is null or length(new.suggested_label) > max_label then
      raise exception 'iptvs: pairing label invalid (max % chars)', max_label
        using errcode = 'check_violation';
    end if;
    -- [[:cntrl:]] covers C0 + DEL; U+0000 cannot be stored in a text column at
    -- all. The practical targets are \n / \r / \t breaking the panel's layout.
    if new.suggested_label ~ '[[:cntrl:]]' then
      raise exception 'iptvs: pairing label invalid'
        using errcode = 'check_violation';
    end if;
    -- Only claim_pairing may set claimed_by, and only via UPDATE.
    if new.claimed_by is not null then
      raise exception 'iptvs: pairing code cannot be pre-claimed'
        using errcode = 'check_violation';
    end if;
  else
    -- claim_pairing updates claimed_by and nothing else; freeze the rest so a
    -- claimed code can never be re-pointed, have its TTL extended, or have its
    -- suggestion swapped out from under the user mid-pairing.
    if new.code is distinct from old.code
       or new.device_uid is distinct from old.device_uid
       or new.expires_at is distinct from old.expires_at
       or new.suggested_label is distinct from old.suggested_label then
      raise exception 'iptvs: pairing row is immutable'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists pairings_validate on public.pairings;
create trigger pairings_validate before insert or update on public.pairings
  for each row execute function public.pairings_validate();

-- ---------------------------------------------------------------------------
-- 4. claim_pairing(p_code, p_label) — resolve the name and link the device.
--
--    Body from 20260727000000_tenant_isolation.sql section 7, plus the label
--    resolution. The identity check, the F6 rate limit, the FOR UPDATE +
--    claimed_by-null single-use guard, and the `invalid or expired code` error
--    are all unchanged.
--
--    The final label is computed into a local BEFORE the upsert rather than
--    inside an ON CONFLICT ... DO UPDATE CASE. Same semantics, but the
--    precedence rule is legible in one place instead of split across an
--    excluded./existing-row expression.
-- ---------------------------------------------------------------------------

create or replace function public.claim_pairing(p_code text, p_label text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  claimer     uuid := auth.uid();
  dev         uuid;
  sugg_label  text;
  panel_label text;
  prev_owner  uuid;
  prev_label  text;
  final_label text;
begin
  if claimer is null or not public.is_real_user() then
    raise exception 'only a signed-in account can claim a device';
  end if;

  -- Bound online code guessing (F6). Keyed on the calling account.
  perform public.check_push_rate('claim', 10, interval '1 minute');

  -- Bound the panel's label BEFORE the code lookup, deliberately: this error
  -- must not depend on whether the code exists, or an oversized label becomes
  -- an oracle for code validity.
  panel_label := btrim(coalesce(p_label, ''));
  if length(panel_label) > 256 then
    raise exception 'iptvs: device label invalid (max % chars)', 256
      using errcode = 'check_violation';
  end if;

  select device_uid, suggested_label into dev, sugg_label
    from public.pairings
    where code = upper(p_code)
      and claimed_by is null
      and expires_at > now()
    for update;

  if dev is null then
    raise exception 'invalid or expired code';
  end if;
  sugg_label := btrim(coalesce(sugg_label, ''));

  select owner, label into prev_owner, prev_label
    from public.devices where device_uid = dev;

  -- Precedence: panel > existing name (same owner only) > suggestion > ''.
  final_label := case
    -- An explicit panel edit always wins.
    when panel_label <> '' then panel_label
    -- Fresh pairing: nothing to preserve.
    when prev_owner is null then sugg_label
    -- Re-pair to a DIFFERENT account: the new owner must never inherit the
    -- previous owner's chosen name.
    when prev_owner is distinct from claimer then sugg_label
    -- Same owner re-pairing: preserve the name they already chose. A blank
    -- panel field must not blank or overwrite a stored non-empty value.
    when coalesce(prev_label, '') <> '' then prev_label
    else sugg_label
  end;

  insert into public.devices (device_uid, owner, label)
    values (dev, claimer, final_label)
    on conflict (device_uid) do update
      set owner = excluded.owner,
          label = excluded.label;

  update public.pairings set claimed_by = claimer where code = upper(p_code);
end;
$$;

-- Legacy 1-arg form, kept forever for panel tabs loaded before this deploy.
-- No rate check and no identity check of its own — both live in the 2-arg body
-- it delegates into, so an anonymous caller still gets the identical
-- 'only a signed-in account can claim a device' error it gets today, and a
-- claim is metered exactly once.
create or replace function public.claim_pairing(p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.claim_pairing(p_code, null::text);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants.
--
--    NOT decorative: a newly created signature inherits PostgreSQL's default
--    PUBLIC EXECUTE (and, in the pgTAP bootstrap, an `alter default privileges
--    ... grant all on functions to anon, authenticated, service_role`), so the
--    new wide forms must be revoked and re-granted explicitly. The narrow forms
--    keep their grants across `create or replace`; they are re-stated here to
--    document intent and to survive a hand-edited database.
--
--    01_baseline_invariants.test.sql enforces `search_path = ''` on every
--    DEFINER function automatically, but it does NOT check grants — these have
--    to be right by hand.
-- ---------------------------------------------------------------------------

revoke all on function public.request_pairing(text)     from public, anon;
revoke all on function public.claim_pairing(text, text) from public, anon;
grant execute on function public.request_pairing(text)     to authenticated;
grant execute on function public.claim_pairing(text, text) to authenticated;

revoke all on function public.request_pairing()   from public, anon;
revoke all on function public.claim_pairing(text) from public, anon;
grant execute on function public.request_pairing()   to authenticated;
grant execute on function public.claim_pairing(text) to authenticated;
