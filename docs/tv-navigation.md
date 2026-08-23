# TV / remote navigation — full detail

The app targets Android TV (the universal APK) and must be fully D-pad-navigable, not just
touch/mouse. This doc records the full design, its invariants, and the failure history that
produced them. The compact rules live in CLAUDE.md; read this before changing any focus or
navigation code.

## Core widgets

- **Lists/grids** use `FocusableCard` (`lib/widgets/focusable_card.dart`): a
  `FocusableActionDetector` tile that shows an accent focus ring, activates on OK/Enter/Select
  (`ActivateIntent`), and scrolls itself into view on focus. First item gets `autofocus`.
  **The ring paints from `hasFocus`, not `onShowFocusHighlight`** — the latter is gated on
  `FocusManager.highlightMode == traditional`, which starts as `touch` on Android, so a cold start
  into the Movies tab drew *no* ring on the autofocused tile until some key was pressed, and any
  TV box whose remote emits pointer events never got one at all. (The live tab was always immune
  because its cursor is drawn from `hasFocus`; this brings the card in line.) Tapping never
  focuses a card — the inner `InkWell` sets `canRequestFocus: false` — so touch interaction
  produces no rings. An explicit `autofocus: true` **does** now ring on a phone (the first media
  tile, the first Legal link): deliberate, and the same resting-cursor behaviour the live list
  has always had on touch.
  **The ring is a `foregroundDecoration`, and the box's own border is a fixed-width transparent
  spacer (`kFocusableCardBorderWidth`).** A `BoxDecoration`'s border is what insets a
  `Container`'s child, so the old `Border.all(width: _focused ? 2 : 1)` on `decoration` meant
  focusing a card narrowed its whole subtree by 2 logical px — through ~7 interpolated fractional
  widths, since the `AnimatedContainer` lerps it over 120 ms. Harmless for text; expensive for
  artwork. A poster sized from its own constraints feeds that width to `imageCacheSize`, and
  `memCacheWidth` is part of the `ResizeImage` cache key: every frame of the animation minted a
  fresh key, i.e. a cache miss, an asynchronous re-resolve and a re-decode with the `placeholder`
  on screen. Walking the media grid therefore made each poster visibly reload on the way in *and*
  on the way out, for artwork that had been decoded seconds earlier — reported as "posters
  refresh when hovered over", and not TV-specific (keyboard traversal on desktop does the same
  thing). Painting the ring over the child instead leaves the layout identical in both states.
  Grids that reserve the border in their own arithmetic (`MediaGridMetrics.tileBorder`) take the
  constant from the widget rather than restating it — the two drifting apart is what previously
  overflowed a focused tile by ~1.6 px. Keep any future focus affordance out of the layout:
  scale, paint and colour are free; anything that changes constraints is not.
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
  `sources_screen` credential/config field. It also takes an optional **`errorText`**, rendered
  below the field in `AppColors.danger` and tinting the cell's own border to match — the focused
  /editing accent ring still wins, so validation never fights the focus indicator. That exists so
  add/edit-source validation reports *at* the field instead of in a `SnackBar` at the far edge of
  the screen, which on a TV is nowhere near where the user is looking. Callers own when to set and
  clear it; it does not gate submission. Implementation notes: its prefix/suffix icons live
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
- **A control that removes itself must hand focus on first.** `TvTextField`'s clear (×) above does
  it (`onClear` parks focus on the cell before the button disappears); so does the player overlay's
  "Go to live", which vanishes the moment the reload reaches the live edge and used to take the
  D-pad with it — no focused node was left in the overlay, so no arrow key did anything until Back
  tore the player down (docs/player.md, "hands focus to play/pause before it disappears"). Any new
  *contextual* control — one whose visibility depends on state the control itself changes — owes the
  same treatment.
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
`kCategoryRowExtent` 48 in `live_tab_view.dart` — raised from 44 so the row clears the 48 px touch
minimum, with the 2 px visual gap drawn *inside* the extent so the selection model still scrolls by
one uniform value. `LiveLayoutMetrics` reduces them within guarded
minimums on short wide viewports, and the coordinator receives those exact computed values so its
index→offset calculation cannot drift from the rendered list.

Because `_reveal` scrolls a row against `position.viewportDimension`, the **viewport itself** has to
exclude the system-bar insets, or a revealed row lands underneath the bar. That is why the channel
list screen's body is wrapped in `SafeArea(top: false)` rather than the list carrying bottom
padding: `SafeArea` shrinks the body's constraints, so every existing index→offset calculation stays
correct with no arithmetic change. Padding the list would have left `viewportDimension` including
the covered strip. Android TV reports zero insets, so this is a no-op there; it matters on phones
under edge-to-edge (targetSdk 35+), where in **landscape** the bar is a *side* inset, not a bottom
one. The same reasoning puts the EPG grid's `SafeArea` outside its `LayoutBuilder`, since the
timeline width is derived from those constraints too.

**`MediaQuery`'s window width is the sole wide/narrow authority for the live tab — never the
SafeArea-shrunk body constraints.** `ChannelListScreen._isWide()` (`MediaQuery.sizeOf(context).width
>= kWideLayoutMinWidth`) is what the coordinator takes as its `isWide` callback (deciding where Up
escapes to and whether Left/Back reach the sidebar) and what the Back ladder's `wideLive` reads
(`_handleRootBack`); `live_tab_view.dart`'s own wide/narrow branch and `LiveLayoutMetrics.forSize`
read the same window size. This used to be a `LayoutBuilder` reading `constraints.maxWidth` — the
body's *own* width, which `SafeArea` shrinks by the left/right system-bar and cutout insets in
Android landscape — instead. **A real shipping bug on tablets with a landscape nav bar**: a window
just over `kWideLayoutMinWidth` rendered the phone layout from `constraints.maxWidth` while every
other branch, reading the unshrunk window width, still believed it was wide. That band was a dead
zone — no preview panel and no long-press sheet, so the preview was unreachable, a tap started an
audible preview with nothing on screen to show it, and, worst, **the Back ladder stalled forever at
rung 2**: `focusCategories()` requested focus on a sidebar node the mismatched layout had never
built, and Flutter's `FocusNode.requestFocus` silently no-ops on a node that isn't attached to the
tree — no exception, no fallback, just a Back press that does nothing. Keep every future
wide/narrow branch in the live tab reading `MediaQuery`'s window size, never a `LayoutBuilder`'s
post-`SafeArea` constraints.

The selection model replaced a per-row-focus
design that kept producing bugs: an off-screen row in a lazy `ListView` has no context, so
`requestFocus` silently no-ops, which forced a *jump-scroll → post-frame requestFocus → re-assert
retry* pipeline that key auto-repeat outran, that geometry traversal leaked out of, and that stale
re-asserts fought. Selecting row N is now a synchronous integer assignment that cannot fail or
race.

The coordinator also retains the selected channel's stable id. After an async
refresh inserts, removes, or reorders rows, it reconciles the numeric cursor to
that id before repainting; if the channel disappeared it clamps to the nearest
valid index. Explicit search and category changes intentionally reset to the
first result.

Wide-layout geometry is platform-, height- and **text-scale**-aware. Android TV images can expose
either a 960×540 or 1920×1080 logical viewport on a 4K panel, so logical height alone cannot
identify the required density. Android wide layouts use a compact 0.625 geometry scale, with 56/88
px live rows and a 120 px preview. Other platforms scale from 0.75–1.0 when their viewport is
short — and **"short" is not a wide-layout privilege**: an 800×360 landscape phone is short for
the same reason a 1280×600 desktop window is, and at full density it fitted two channel rows, so
narrow layouts below `kShortViewportMaxHeight` scale too. Phone *portrait* (tall and narrow)
retains the normal scale. Category rows retain a 40 px D-pad target.

`MediaQuery` text scaling **feeds the extents** (clamped at `kMaxLiveTextScale`) rather than being
ignored. It has to: the tall EPG row had ~1.10× headroom and the compact 88 px row ~3% at default
scale, while Android's first font step is already 1.15 and iOS reaches 1.35. The scaler must be
read at
**both** `LiveLayoutMetrics.forSize` call sites (`live_tab_view.dart` and
`ChannelListScreen._liveChannelRowExtent`/`_liveCategoryRowExtent`), because the selection model
scrolls by `index * extent` — if the view lays out one extent while the coordinator scrolls by
another, every D-pad move drifts. **Predicting text height is a hint, never the guarantee.** `_epgRowContentHeight` only decides
*when the "Next" line is dropped*; the row's text `Column` sits in `ClipRect` → `OverflowBox`, so
an unbounded main axis makes a `RenderFlex` overflow structurally impossible whatever the estimate
says. That split exists because the estimate was wrong three times running: the bundled Inter lays
out at **~1.41**, not the ~1.21 an earlier comment claimed, *and* the engine rounds each line's
ascent and descent to whole logical pixels on top of that — ~4.3 px per four-line row, which no
amount of chrome tuning was going to close. `test/layout_overflow_test.dart` pins it with the real
font loaded, because `flutter_test`'s default font makes every line exactly `1.0 × fontSize` and
hides the whole class of bug. The channel logo is sized from the row it sits in
(`LiveLayoutMetrics.logoSize`) for the same reason — bounded so it can never be what overflows.

`LiveTabView.build` asserts the two agree; the assert is what
caught `live_tab_layout_test.dart` hard-coding the base constants while the view scaled them.
Relatedly, the "drop the *Next* line" test is a **content-height** comparison, not
`extent < kChannelRowExtentWithEpg` — the latter fired on any scaling at all, so a 700 px-tall
desktop window dropped the line with ~19 px to spare.

Movie/series grids are **not** part of the platform fork any more. One continuous ladder divides
the viewport width by `kMediaPosterTargetWidth`, clamped 3–16 columns, so a poster stays in a
~176–230 px band from a 600 px window to a 4K panel. It reproduces the Android-TV counts the fork
existed to produce (960 → 5, 1920 → 10) and desktop's 1280 → 6 exactly, so the fork bought nothing
but divergence — an Android tablet used to show 7 columns where an iPad of the same width showed
6. Only the tighter gutters survive, keyed off viewport size rather than the platform. The
grid/list switch is two-dimensional (`kMediaGridMinWidth` × `kMediaGridMinHeight`) so a tablet in
portrait no longer flips to a list while its own landscape shows a grid. Metric regressions pin
both Android TV viewport forms, the ladder's reproduction of the old column counts, and the
tile-width band.

- **The cross-source Favorites view adds no navigation surface.** "Favorites · All sources" is an
  ordinary entry in the category list, so it costs the Back ladder nothing — no new rung, no new
  focus node, and the channel list stays the same selection model under the same `itemExtent`
  rules (its rows carry a guide of their own, so they take the EPG extent when one is loaded —
  decided by `showsEpg`, the single value the extent and the row layout both read). That
  was the reason for preferring it over a dedicated screen, which would have duplicated the list,
  preview pane, EPG strip and D-pad model. It also behaves like one: OK previews and a second OK
  goes fullscreen, exactly as anywhere else — the preview simply resolves through the row's own
  source (CLAUDE.md, cross-source favorites). What makes that safe is that the preview is
  identified by `(sourceId, channelId)`, never the id alone; on a remote the symptom of getting
  that wrong would be a second OK opening a different channel than the one on screen.
  Its rows carry a **source chip inline with the channel
  name** rather than on a line of their own: index→offset math is `index * itemExtent`, so a row
  that grows by a line breaks scrolling for the whole list. The chip's font stays below the title's
  so the line height — and therefore the extent — is still set by the title alone, and
  `layout_overflow_test.dart` sweeps it with real font metrics at text scales up to 2.0.

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
  focus remains in the sidebar rather than moving to a channel pane with no activation target —
  `focusChannels()` falls back to `focusCategories()` when the visible list is empty, because
  every caller has already consumed the key press and returning silently left the D-pad dead
  (Down from the search cell went nowhere). The sidebar is guaranteed to still be there: on a wide
  layout the empty-state message replaces only the **channel list**, never the whole tab. That
  matters more than it sounds — `ChannelListScreen` nulls the toolbar's category dropdown whenever
  live && wide, so an empty state that unmounted the sidebar removed *every* caller of
  `_selectCategory` at once, and picking a zero-channel category (common on portals) was
  unrecoverable short of restarting the app.
  Pointer taps and the phone dropdown apply the same filter without forcing D-pad focus.
- **Drawing the cursor.** Each list draws its cursor row accented **only while it owns the D-pad**
  (`listFocused`), and subdued (a panel-lift, no accent) when it doesn't — so the accent always
  telegraphs *which pane you are in*, while the resting mark still shows where you'll land on
  return. Since the cursor is drawn from `hasFocus` and a focus change rebuilds nothing on its
  own, the coordinator **notifies on focus change** (it listens to its own nodes); without that
  the accent stayed stuck in the channel list after Left/Back moved the D-pad to the categories.
- **Notification granularity.** That focus-change notify, plus one per cursor move, used to run
  through a single aggregate listener wrapping the *entire* live body — so one Down press
  rebuilt the sidebar, the whole preview panel (gradient, nested `LayoutBuilder`, video/image
  `Stack`, EPG text) and the channel list, when two rows had changed. Under key auto-repeat that
  was the dominant per-frame cost on weak Android TV silicon. The coordinator is still the single
  owner of the selection state, but it publishes **narrow slices** — `channelSelection`,
  `categorySelection`, `previewRegion`, `digitEntry` — and each pane subscribes to the one it
  draws. Each pane's *focus node* is folded into its own slice, so a handover still repaints both
  sides (the losing pane's node fires too). Every mutation also pulses the aggregate
  `notifyListeners()`, so whole-coordinator listeners are unaffected. `ChannelListScreen`
  therefore keeps `_focus` **out** of `_bodyListenable`, and the preview channel is resolved
  through a callback inside the preview pane's own rebuild rather than passed down as a value.
  Pinned by the `notification granularity` group in `test/live_focus_coordinator_test.dart` —
  if those collapse back to "everything notifies everything", the split has silently regressed.
- A fixed row height means the tallest row (name + `Now ·` + progress + `Next ·`) must *fit*
  `kChannelRowExtentWithEpg`, or it overflows. Every source in the tests except `_EpgSource`
  returns an empty EPG, so that one test is the only thing guarding it — keep it.

## When the body has no rows

A selection model's rows are not focus targets, which is the whole point — but it means a body
that renders *instead* of the rows has no focus targets either, and Flutter has nothing to give
focus to. That is fine for an empty-category message, which is text. It is not fine for the
**load-error body**, which carries the only control that can recover the screen.

The symptom on a television: "Try again" drawn, plainly the only action available, and
unpressable. The first OK went nowhere and there was nothing to arrow towards, because
`handleChannelsKey` correctly returns `ignored` when there are no visible channels — so no key
was being *stolen*; there was simply no focusable widget in the subtree. A source that fails to
load is exactly the moment the user cannot route around the problem.

Both tabs' error bodies are now `SourceErrorView` (`lib/widgets/source_error_view.dart`) and its
retry **autofocuses**, the same rule the delete-confirmation dialog follows. Autofocus is safe
here specifically because this body only mounts on a failed load, which replaces the list
wholesale: whatever focus the body held is already gone, so there is nothing to steal it from.

Pinned by `test/source_error_view_test.dart`, which asserts the button holds focus on arrival and
that a single `select` press with no navigation first runs the retry.

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
  That border is a **`foregroundDecoration`, not a `decoration`** — `Container` reserves
  `decoration.border` as padding but never the foreground one, so drawing the ring the obvious way
  gave the cursor row 4 px less content space than every other row and overflowed it *only when
  focused*. Both wrap the same rect, so the ring looks identical and now costs no layout.
  The selected row's `panelHi` fill stays either way, so the row remains visible. The star cell
  fits inside the row extents, which are no longer fixed: they scale with density *and* with the platform text scale, and the star target scales with the text scale alongside them.
- **Touch**: tapping the star toggles directly (selecting the row first, so cursor and pointer
  never disagree). Tapping the row body **plays only on a phone** — on a wide layout the first tap
  starts/switches the preview and a second tap (or tap while already previewing that channel) goes
  fullscreen, the same `onPlayChannel` → `_play` path OK runs (`channel_list_screen.dart`), because
  that's the only touch affordance that can reach the preview panel on a wide touch layout (no
  remote, so there's no OK to fall back to). The hint text under the panel is deliberately
  **input-neutral** ("OK or tap/click to preview") rather than naming an input the device might not
  have, and the compact chip variant is length-bounded to ellipsize past roughly 22 characters on
  its ~170 px thumbnail. On a **phone**, long-press opens the audible preview sheet
  (`PhonePreviewSheet` — Play / favorite / catch-up); on wide layouts long-press does nothing (the
  preview panel is always on screen).
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

Browsing bottom sheets capture the focus node that opened them and restore it
after ordinary dismissal when it is still attached. If a lazy rebuild removed
that node, the live list, media first tile, or current tab is used as a
route-safe fallback. Playback launched from a sheet uses the dedicated
post-player restoration path.

Media keeps its own rungs (deep grid → top of grid → tabs). The **chrome** — the AppBar actions
and the toolbar's buttons, which are plain `IconButton`s with **no route key** (`''`), while every
*content* focusable carries one — sits *above* the ladder: Back from it goes straight to the exit
prompt rather than diving back down into the sections to be climbed out of again. The one
exception is a bare `FocusScopeNode` / nothing actually focused (a transient state, e.g. just
after a dialog is dismissed) — that isn't somewhere the user can *be*, so it recovers to the tabs
instead of offering to exit. Pinned end-to-end by `test/channel_list_focus_test.dart` (whose
`_ManySource` gives both lists enough rows to actually scroll).

**iOS has no hardware Back**, so *both* iOS player surfaces render the same peel/exit shape
through touch. This paragraph describes the presented `IptvsPlayerViewController`
(docs/ios.md, docs/player.md "iOS"); the **embedded Flutter overlay on the mpv-routed path**
(`EmbeddedPlayerControls` with `touch: true` — docs/player.md "iOS") deliberately mirrors it,
tap-peeling the info panel, then hiding the chrome, then revealing it, with an **X** that exits
outright. They must not diverge: a Stalker source always routes to mpv (`create_link` returns
extension-less locators, so `selectIosEngine` rule 4 applies), so for those users the embedded
overlay is the *only* player surface they ever see — a different interaction model there would
be a different app, not a fallback. The presented controller:
tapping outside the chrome (on the scrim, or the exposed-video area with the chrome already
open) closes an open menu, then the info panel — the same menu → info ladder rungs Android's
`ControlsOverlay` and the Windows/Linux overlays use — while tapping the exposed video with
chrome hidden just toggles the chrome visible, matching every other platform's tap-to-show.
The overlay's **X** is a dedicated Exit control that skips the ladder entirely and dismisses
outright, mirroring the other platforms' explicit back-arrow-always-exits behavior (docs/player.md
Windows: "the on-screen back-*arrow* button still exits directly"). `isModalInPresentation = true`
(docs/ios.md "Native player") disables the system interactive-swipe dismiss gesture for the same
reason the ladder is enforced everywhere else: a stray edge swipe must not exit the player outside
an explicit control, since nothing else on iOS plays the role a hardware/remote Back press does on
the other platforms.

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

**The horizontal reveal must measure the cell the row actually painted.** Rows are horizontally
virtualized — a cell outside `[offset - 240, offset + timelineWidth + 240]` is never built — so a
reveal that pans away from the cursor doesn't merely hide it, it stops building it, and the grid
shows a selected row with no highlight anywhere on it. That is exactly the "browse right along one
channel until the guide jumps somewhere with no apparent focus" report, and it needs one bad guide
entry on one channel to reproduce. Two things caused it, both now fixed in `_revealProgrammeAt`
(pinned in `test/epg_grid_test.dart`):

- `_cellWidth` truncates an entry that overruns the next one's start (bad guide runtimes), but the
  reveal called it **without `nextStart`** and so measured a span the row never drew. An entry
  claiming 30 hours is painted 30 minutes wide and revealed as thousands of pixels, panning to the
  far-right clamp of the 25-hour window with the real cell left far behind. The reveal now takes
  the row's list and an index, so it computes exactly the geometry `_layouts()` does.
- A cell **wider than the viewport** can't be framed by its trailing edge at all: the title is
  drawn at the cell's left edge, so an end-aligned pan scrolls it away and leaves a blank stretch
  of fill as the only sign of the cursor. `width >= timelineWidth` therefore takes the same
  leading-edge branch as "it's off the left edge".

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
times.

**Pan-frame budget.** The whole grid pans by moving one shared `_hOffset`
`ValueNotifier`, so every visible row's `ValueListenableBuilder` re-runs at 60 fps for the
duration of a pan. Nothing that is *invariant across a pan* may be computed inside that builder:
each programme's `(left, width)` and its semantics label are precomputed once per row build into
`_CellLayout` (index-parallel to the row's programme list, built in `_ChannelRow.build`), and the
airing state (`isCurrent`/`isPast`) comes from **one** `DateTime.now()` per row per frame, passed
down to the cells rather than read per cell. The hour ruler depends only on the `late final`
window bounds, so it is built once (`_hourHeaderWidget`) and returned by identity — the element
tree then skips the ~50 tick widgets on every `setState`. Keep the builder's output shape
unchanged when touching this: `test/epg_grid_test.dart` pins the exact `Positioned.width` values
(240 for the clamped overlong cell), the selected cell being appended **last** to the row `Stack`,
and the label format `'$title, $channel, $hm to $hm, $n of $total'`.

The selected cell **and** its channel row are accent-highlighted (a solid accent-tinted
cell fill + bold title, plus a full-row lift and an accent bar beside the channel name) so the
cursor reads clearly from across the room — the fix for the "looks like nothing's selected /
screen isn't working" report; the bottom detail bar gives the synopsis its own **multi-line** row
(title / channel·time / up-to-3-line description) rather than truncating it. Cells are
deliberately lightweight (no per-cell `FocusableCard`) and horizontally virtualized to the visible
window (safe precisely because they aren't focus targets); pinned by `test/epg_grid_test.dart`
(incl. an overlapping-programme row).
