---
name: db-migration-checklist
description: "Walk through a schema change to AppDatabase (lib/data/app_database.dart) safely — bump schemaVersion, write an idempotent/re-entrant onUpgrade branch, avoid the _createMediaTables fresh-install trap, and extend the released-schema fixture tests. Use whenever adding/altering a table, column, or index in the local SQLite cache."
---

# AppDatabase migration checklist

`AppDatabase` (`lib/data/app_database.dart`) is a hand-rolled, versioned SQLite schema with no
`onDowngrade` handler. Every migration is permanent and every `onUpgrade` branch must remain
correct forever, including against odd version-skipping paths. Follow this checklist in order;
each step exists because skipping it broke a real release (see the v7 trap below).

## 1. Confirm the change actually needs a schema bump

Adding a column, table, or index does. Changing only Dart-side logic over an existing shape does
not — don't bump `schemaVersion` for that.

## 2. Bump `schemaVersion` and add one new `onUpgrade` branch

- Increment `schemaVersion` by exactly 1.
- Add a new `if (oldV < N)` branch (or the pattern already used) in `onUpgrade` — never edit an
  existing branch for a past version.
- Use `CREATE TABLE IF NOT EXISTS` for new tables and the existing `_isDuplicateColumn` guard
  pattern for `ALTER TABLE ... ADD COLUMN`. New indexes: `CREATE INDEX IF NOT EXISTS`.

## 3. Re-entrancy — the branch must be safe to run twice

There is no `onDowngrade`. An older build opened against a newer DB file silently re-stamps the
version *down* without undoing anything; when a newer build opens it again, every branch from the
now-lower recorded version re-runs — including yours — over a schema that may already have your
change applied. Every statement in your branch must tolerate "already applied" (hence the
`IF NOT EXISTS` / duplicate-column-guard requirements above — don't write a bare `ALTER TABLE`
or `CREATE TABLE` without them).

## 4. The `_createMediaTables` fresh-install trap — check this explicitly

`_createMediaTables` builds the *current* media schema for any fresh install or any upgrade
originating before v3. That means **later `oldV >= 3` branches are skipped for those installs** —
they already have the current shape from `_createMediaTables`, or so the assumption goes.

If your new table or column is NOT added inside `_createMediaTables`, and your `onUpgrade` branch
is gated `oldV >= (something > 3)`, a **fresh install misses it entirely** — nothing ever creates
it. This is exactly the v7 bug: `external_metadata` was created only in an `oldV >= 3 && oldV < 7`
branch; fresh installs crashed on every metadata query until v8 added it to both paths.

So: for any new table/column that isn't part of `_createMediaTables`'s current-schema build,
verify it is *also* reachable on a fresh install — either by being included in
`_createMediaTables` itself, or by an unconditional (or `oldV < N`, not `oldV >= N`-only) creation
path that a fresh install still executes.

## 5. Connection tuning — leave `onConfigure` alone unless you mean it

`onConfigure` sets WAL, `synchronous = NORMAL`, an 8 MB `cache_size`, and deliberately leaves
`temp_store` at the default (an unbounded `MEMORY` sorter would blow up on `readChannels`'s
unindexed `ORDER BY number, name` on a 250k-channel source). Don't touch these for a table-shape
change.

## 6. Query plan pins — don't let the planner drift

If your change affects a query on `programmes` or another indexed table, check whether an
existing index pin still applies. `idx_prog_lookup` is pinned via an explicit `INDEXED BY` in the
"next" half of the now/next query because the planner otherwise sorts every future programme
through a temp B-tree (952ms vs 98ms measured) — `ANALYZE`, which production never runs, is what
makes the planner pick correctly on its own. If you add a new index that could shadow an existing
plan, check `explainNowQueryPlan`/`explainNextQueryPlan` in `persistence_test.dart` still pass.

## 7. Test coverage — extend, don't just add

- Add or extend a fixture-based case in `test/released_schema_fixtures_test.dart`: fixture DB at
  the prior released version → migrate → assert pragma-based schema parity with a fresh install →
  seeded-data survives → DB can be closed and reopened cleanly a second time. This is the suite
  that would have caught the v7 bug — every publicly shipped upgrade path must stay covered.
- If the change affects the v1→current chain generally, `persistence_test.dart` is the other
  place migration regression tests live.
- Use `AppDatabase.openAt(path)` (the `@visibleForTesting` seam) to open a specific fixture file
  rather than the app's default path.

## 8. Update CLAUDE.md's "Database migrations" section

That section names the current `schemaVersion` and summarizes what each version added. If your
migration lands, update the version number and add a one-line description of what v(N) does,
in the same commit.

## Quick self-check before calling a migration done

- [ ] `schemaVersion` bumped by exactly 1
- [ ] New `onUpgrade` branch added, not an existing one edited
- [ ] Every statement in the branch is idempotent (`IF NOT EXISTS` / duplicate-column guard)
- [ ] Verified reachable from a **fresh install**, not just from upgraders past some `oldV`
      threshold — check `_createMediaTables` if this is a media-related table
- [ ] No unrelated change to `onConfigure` / `temp_store`
- [ ] Existing `INDEXED BY` pins re-verified if the change touches `programmes`
- [ ] `released_schema_fixtures_test.dart` extended with a fixture case for this upgrade
- [ ] `flutter test test/persistence_test.dart test/released_schema_fixtures_test.dart` green
- [ ] CLAUDE.md "Database migrations" section updated in the same commit
