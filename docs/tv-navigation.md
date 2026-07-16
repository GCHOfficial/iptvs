# TV / remote navigation — full detail

The app targets Android TV (the universal APK) and must be fully D-pad-navigable, not just
touch/mouse. This doc records the full design, its invariants, and the failure history that
produced them. The compact rules live in CLAUDE.md; read this before changing any focus or
navigation code.

## Core widgets

- **Lists/grids** use `FocusableCard` (`lib/widgets/focusable_card.dart`): a
  `FocusableActionDetector` tile that shows an accent focus ring, activates on OK/Enter/Select
  (`ActivateIntent`), and scrolls itself into view on focus. First item gets `autofocus`.
  **Exception: the two live-tab lists and the EPG grid.** They are *selection models* (one focus
  node + a selected index; rows aren't focusable) — see below. Reach for `FocusableCard` for
  short, fixed sets (media grid, sources, sheets); reach for a selection model when it's a long
  lazy list a D-pad has to walk, because per-row focus in a lazy `ListView` cannot focus an
  unbuilt row.
- **Text inputs** use `TvTextField` (`lib/widgets/tv_text_field.dart`) — never a bare `TextField`
  on a TV-facing screen. A plain `TextField` traps D-pad focus (its editor eats the arrow keys).
  `TvTextField` is an **"OK to edit" cell**: in traversal it's one focusable stop the D-pad passes
  over; OK/Select (or tap) enters edit mode (the inner field — `ExcludeFocus`'d +
  `IgnorePointer`'d until then — takes focus and the keyboard opens); the IME action or **Back**
  (via `PopScope`, *not* `BackButtonListener`, which needs a `Router` this app doesn't have) exits
  edit and returns focus to the cell. Applied to the channel search box and every
  `sources_screen` credential/config field. Implementation notes: its prefix/suffix icons live
  *outside* the `InputDecoration` in a manually centered Row, and the field uses a collapsed
  `InputDecoration` with **every border slot explicitly `InputBorder.none`** — not the
  `InputDecoration.collapsed` constructor, whose null border slots get filled from the theme's
  `OutlineInputBorder`s by `applyDefaults` and painted a second box inside the cell. The geometry
  and the no-inner-border invariant are pinned by platform-parameterized tests
  (`test/tv_text_field_test.dart`, which also guards that it builds under a plain `Navigator` —
  the regression that caught the `BackButtonListener`/`Router` crash).
  A **clear (×) affordance** (`showClear` + `onClear`) renders as its own **always-focusable
  sibling stop** outside the edit barrier — the same pattern as the password show/hide toggle,
  and for the same reason: anything inside the barrier (a `suffixIcon`) can never be a D-pad
  target, because entering edit mode hands focus to the editor which eats the arrows. Right from
  the cell reaches it while text is present; OK runs `onClear` and parks focus back on the cell
  (the button disappears once the text empties); Back from it peels to the search cell (live) /
  the tabs (media) via the Back ladder's `TvTextField.clear` route-key branch.
- **The same "OK to edit" model** governs the player's sliders (see docs/player.md) — focus
  passes them freely; OK enters adjust mode.
- **Content-kind selector** (`channel_list_chrome.dart` `ChannelContentTabs`) is a focusable chip
  strip (not
  `SegmentedButton`), the natural top of the focus order — reached by Up or the Back ladder. The
  chips deliberately **don't** autofocus, so on entry focus lands in the content (the first
  channel / grid tile, so OK plays immediately) rather than being stranded on the strip by the
  load-time autofocus race. AppBar actions and the body are each wrapped in a
  `FocusTraversalGroup` so D-pad arrows stay within the body instead of jumping sideways into the
  app bar (Flutter's directional traversal is geometry-based).

## The live tab selection model

The live tab is a selection model (`live_focus_coordinator.dart`) — the same pattern the TV guide
uses, and for the same reason. The channel list and the category sidebar each have exactly **one**
focus node (`live.channels` / `live.categories`) and a **selected index**; rows are *not* focus
targets (they stay tappable for touch), and the coordinator drives the scroll itself with exact
`index * itemExtent` maths. This is why both lists set an explicit **`itemExtent`**. Their baseline
extents are `kChannelRowExtentWithEpg` 112 / `kChannelRowExtentPlain` 72 /
`kCategoryRowExtent` 44 in `live_tab_view.dart`; `LiveLayoutMetrics` reduces them within guarded
minimums on short wide viewports, and the coordinator receives those exact computed values so its
index→offset calculation cannot drift from the rendered list. It replaced a per-row-focus
design that kept producing bugs: an off-screen row in a lazy `ListView` has no context, so
`requestFocus` silently no-ops, which forced a *jump-scroll → post-frame requestFocus → re-assert
retry* pipeline that key auto-repeat outran, that geometry traversal leaked out of, and that stale
re-asserts fought. Selecting row N is now a synchronous integer assignment that cannot fail or
race.

Wide-layout geometry is also platform- and height-aware. Android TV images can expose either a
960×540 or 1920×1080 logical viewport on a 4K panel, so logical height alone cannot identify the
required density. Android wide layouts use the compact 0.75 scale; other platforms scale from
0.75–1.0 only when their viewport is short. Minimum row and D-pad target sizes are preserved and
`MediaQuery` text scaling is not overridden. Phone portrait layouts retain the normal scale. The
960×540 and 1920×1080 metric regressions pin both Android TV viewport forms.

- **Movement rules (deliberately asymmetric).** **Down wraps** at the end of the channel list and
  of the category list — the *only* infinite motion in the tab. **Up never wraps**: at the first
  row it **escapes upward** — categories → the search box; channels → the preview controls
  (`live.preview.favorite`/`catchup`), or the search box on a phone (no preview panel). The old
  design wrapped Up in the sidebar too, so the only ways out were Right or Back — that is what
  left users **"stuck in the categories"**. **Right** first enters the selected channel row's
  favorite star (the intra-row action cursor, below) before being consumed; **Left** peels the
  star column back to the row body before crossing to the sidebar. Beyond that Left/Right cross
  between the panes, and every arrow is consumed, so Flutter's geometry traversal never runs
  inside the live body. Pinned by `test/live_focus_coordinator_test.dart` (pure index logic) and
  `test/channel_list_focus_test.dart` (real key events).
- **Category activation.** Up/Down moves only the sidebar cursor; **OK applies that category and
  enters the first/resumed channel in the filtered list**. If a provider exposes an empty category,
  focus remains in the sidebar rather than moving to a channel pane with no activation target.
  Pointer taps and the phone dropdown apply the same filter without forcing D-pad focus.
- **Drawing the cursor.** Each list draws its cursor row accented **only while it owns the D-pad**
  (`listFocused`), and subdued (a panel-lift, no accent) when it doesn't — so the accent always
  telegraphs *which pane you are in*, while the resting mark still shows where you'll land on
  return. Since the cursor is drawn from `hasFocus` and a focus change rebuilds nothing on its
  own, the coordinator **notifies on focus change** (it listens to its own nodes); without that
  the accent stayed stuck in the channel list after Left/Back moved the D-pad to the categories.
- A fixed row height means the tallest row (name + `Now ·` + progress + `Next ·`) must *fit*
  `kChannelRowExtentWithEpg`, or it overflows. Every source in the tests except `_EpgSource`
  returns an empty EPG, so that one test is the only thing guarding it — keep it.

## Per-row favorite button + intra-row action cursor

Every channel row carries an **always-visible star cell** (`_ChannelTile` in `live_tab_view.dart`):
filled accent when favorited, low-contrast outline when not. It replaced the old OK-hold context
menu dialog — favoriting the focused channel is now one **Right + OK** away, entirely in place,
with no dialog to route focus through and no hold-timing gesture to discover.

- **The channel cursor has two intra-row columns** (`ChannelRowColumn` in
  `live_focus_coordinator.dart`): `body` (default; OK plays on key-down) and `favorite` (OK
  toggles). **Right** moves body → favorite and is consumed even when already on the star (or the
  list is empty); **Left** peels favorite → body first — only a second Left crosses to the
  category pane. **Up/Down**, and every (re)entry into the channel pane (`selectChannel`,
  `focusChannels`, `focusChannelsFromCategory`, the Up-escape at row 0), reset the column to
  `body`, so the star column is never sticky across rows.
- **Back mirrors Left**: with the cursor on the star, Back peels it back onto the row body before
  the ladder's first-row rung runs (rung 0 in the Back ladder below).
- **Drawing**: the row body carries the accent border only while the `body` column holds the
  cursor; on the `favorite` column the star cell draws its own accent ring + panel lift instead.
  The selected row's `panelHi` fill stays either way, so the row remains visible. The star cell
  fits well inside the fixed `itemExtent`s (72 / 112) — the extents are unchanged.
- **Touch**: tapping the star toggles directly (selecting the row first, so cursor and pointer
  never disagree); tapping the row body plays. On a **phone**, long-press opens the audible
  preview sheet (`PhonePreviewSheet` — Play / favorite / catch-up); on wide layouts long-press
  does nothing (the preview panel is always on screen).
- **Deliberately dropped**: the menu's per-row **Catch-up** entry on TV. Catch-up stays reachable
  from the preview panel's catch-up button (`live.preview.catchup`) and from the EPG grid's past
  programmes.

## The Back ladder

`channel_list_screen` `_handleRootBack`: Back never changes data or filters — it peels exactly
**one rung** per press toward the exit. Because the live lists are a selection model, each live
rung is a plain check on the coordinator's `region` + selected index (no focus-label
archaeology). Live:

0. channel list, cursor on the **favorite star** (`ChannelRowColumn.favorite`) → the **row body**
   (Back mirrors Left; the row cursor and scroll position don't move);
1. channel list, cursor **not** on the first row → **first channel**;
2. first channel → **categories** (wide) / the **search box** (phone, no sidebar);
3. preview controls (`live.preview.*`) → same as (2);
4. categories, cursor **not** on the first row → **first category** ("All channels") — this moves
   the *highlight only*, it does **not** change the active filter (OK does that);
5. first category → the **search box**;
6. search → the **section tabs**; the search field's **clear button**
   (`TvTextField.clear`) peels to the search cell on live / the tabs on media;
7. tabs → **exit**, behind a double-Back inside a 2s window (first press shows a "Press Back
   again to exit" snackbar), stopping the preview engine on the actual exit.

Media keeps its own rungs (deep grid → top of grid → tabs). The **chrome** — the AppBar actions
and the toolbar's buttons, which are plain `IconButton`s with **no route key** (`''`), while every
*content* focusable carries one — sits *above* the ladder: Back from it goes straight to the exit
prompt rather than diving back down into the sections to be climbed out of again. The one
exception is a bare `FocusScopeNode` / nothing actually focused (a transient state, e.g. just
after a dialog is dismissed) — that isn't somewhere the user can *be*, so it recovers to the tabs
instead of offering to exit. Pinned end-to-end by `test/channel_list_focus_test.dart` (whose
`_ManySource` gives both lists enough rows to actually scroll).

## The EPG grid (TV-guide timeline)

`epg_grid_screen.dart` is the TV-guide timeline (one row per channel on a shared time axis) — it
navigates with an explicit **selection-cursor** model (a single `epg.grid` focus node + a
`cursorTime` **and a `_selectedCol` programme index**), *not* Flutter geometry traversal:
**Left/Right step by programme index** (`_selectedCol`, *not* a re-resolution of `cursorTime` — so
overlapping/duplicate/gappy guide data can no longer trap the cursor, the fixed "can't go right /
highlight jumps between programmes" reports), Up/Down change channel while **holding the time
column** (re-deriving `_selectedCol` on the new row via `_selectedIndexIn`, which prefers the
**latest-starting** containing programme so it matches the front-painted cell), and the screen
drives the pan/scroll itself, so navigation never depends on a lazy/async cell being built; the
vertical reveal **centers** the selected row in the viewport (a bottom-aligned row was covered by
the detail bar).

**Focus restoration after playback is route-scoped.** The main screen's
`_restoreListFocusAfterPlayback` (channel_list_screen.dart) bails when its route isn't the
visible top route (`ModalRoute.isCurrent == false`): when playback was launched *from* the pushed
EPG grid, the grid is still on top after the player pops, and Flutter's own route focus
restoration re-focuses `epg.grid`. Without the guard, the covered channel-list node stole
`primaryFocus` cross-route (FocusManager has no notion of routes) and the grid's `onKeyEvent`
never fired again — the "guide is dead after watching a channel" report. The guard pattern is
pinned by the route-scoped test in `test/epg_grid_test.dart`.

Overlong guide entries (a programme whose bad runtime overlaps the next one) are **visually
clamped at the next programme's start** in `_cellWidth`, and the selected cell is appended last to
its row's `Stack` so its highlight always paints on top — the detail bar still shows the real
times. The selected cell **and** its channel row are accent-highlighted (a solid accent-tinted
cell fill + bold title, plus a full-row lift and an accent bar beside the channel name) so the
cursor reads clearly from across the room — the fix for the "looks like nothing's selected /
screen isn't working" report; the bottom detail bar gives the synopsis its own **multi-line** row
(title / channel·time / up-to-3-line description) rather than truncating it. Cells are
deliberately lightweight (no per-cell `FocusableCard`) and horizontally virtualized to the visible
window (safe precisely because they aren't focus targets); pinned by `test/epg_grid_test.dart`
(incl. an overlapping-programme row).
