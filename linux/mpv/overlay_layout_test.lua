-- Headless layout test for iptvs_overlay.lua.
--
-- The Linux native OSD is the one control surface in the app with no test at
-- all: it renders ASS inside mpv, only on the Wayland+HDR path, so nothing in
-- CI (and nothing on a Windows dev box) ever executes it — a nil index or a bad
-- format string would ship undetected, and the layout could drift from the
-- other four overlays unnoticed. That is exactly what happened: this file was
-- written when the strip/badges were brought to parity with the Android, iOS
-- and Windows overlays.
--
-- It stubs the three mpv modules the script requires, renders one frame per
-- scenario, and asserts on the emitted ASS events + hitboxes. No mpv, no
-- Wayland, no HDR stream needed:
--
--     lua linux/mpv/overlay_layout_test.lua       (Lua 5.1 / LuaJIT — mpv's own)
--
-- It does NOT replace looking at the thing on a real session: it can prove the
-- rows are ordered and clear of each other, not that the result looks right.

local W, H = 1920, 1080

-- ===== mpv module stubs ======================================================

local ass_events = {}

local function new_ass()
  local ass = {text = ''}
  function ass:new_event()
    if self.text ~= '' then self.text = self.text .. '\n' end
    table.insert(ass_events, {header = nil, body = ''})
    self.current = ass_events[#ass_events]
  end
  function ass:append(text)
    self.text = self.text .. text
    if self.current then self.current.body = self.current.body .. text end
  end
  function ass:draw_start() self:append('{\\p1}') end
  function ass:draw_stop() self:append('{\\p0}') end
  function ass:round_rect_cw(x1, y1, x2, y2)
    if self.current then
      self.current.rect = {x1 = x1, y1 = y1, x2 = x2, y2 = y2}
    end
  end
  return ass
end

local properties = {}
local timers = {}
local script_messages = {}

local mp = {
  create_osd_overlay = function()
    return {data = '', update = function() end, remove = function() end}
  end,
  get_osd_size = function() return W, H, 1 end,
  get_property_native = function(name) return properties[name] end,
  get_property = function(name) return properties[name] end,
  set_property = function(name, value) properties[name] = value end,
  set_property_number = function(name, value) properties[name] = value end,
  get_time = function() return 0 end,
  command = function() end,
  commandv = function() end,
  set_mouse_area = function() end,
  observe_property = function() end,
  register_script_message = function(name, fn) script_messages[name] = fn end,
  add_forced_key_binding = function() end,
  remove_key_binding = function() end,
  add_timeout = function() return {kill = function() end} end,
  add_periodic_timer = function()
    local timer = {kill = function() end}
    table.insert(timers, timer)
    return timer
  end,
}
mp.assdraw = {ass_new = new_ass}
-- The harness sends state as a table, not JSON: parse_json just hands back
-- whatever `deliver_state` stashed, so the test needs no JSON encoder.
local pending_state
mp.utils = {parse_json = function() return pending_state end}

package.loaded['mp'] = mp
package.loaded['mp.assdraw'] = mp.assdraw
package.loaded['mp.utils'] = mp.utils

-- ===== harness ===============================================================

local script_dir = arg[0]:match('^(.*)[/\\][^/\\]*$') or '.'
dofile(script_dir .. '/iptvs_overlay.lua')

local failures = 0
local function check(ok, message)
  if not ok then
    failures = failures + 1
    print('FAIL  ' .. message)
  else
    print('ok    ' .. message)
  end
end

-- Renders one frame for `state` and returns the events it emitted.
local function render_with(state, props)
  properties = {
    ['video-params'] = {w = 1920, h = 1080, gamma = 'pq', primaries = 'bt.2020'},
    ['video-target-params'] = {gamma = 'pq', primaries = 'bt.2020'},
    ['current-tracks/video'] = {['demux-fps'] = 50},
    ['current-tracks/audio'] = {},
    ['pause'] = false,
    ['mute'] = false,
    ['volume'] = 100,
    ['duration'] = 0,
    ['time-pos'] = 0,
    ['track-list'] = {},
  }
  for key, value in pairs(props or {}) do properties[key] = value end
  ass_events = {}
  pending_state = state
  script_messages['iptvs-state']('{}')
  return ass_events
end

-- The zap banner only ever draws with the chrome *hidden* (it is the bottom
-- bar's mutually-exclusive counterpart), and the script owns `visible`
-- itself, so the harness reaches it through the test seam the overlay
-- exports rather than by faking a key press.
local seam = _G.iptvs_overlay_test
local function render_hidden(state, props)
  seam.set_chrome_visible(false)
  local events = render_with(state, props)
  seam.set_chrome_visible(true)
  return events
end

-- Each push must carry a *new* `atMs` to restart the banner's countdown; a
-- repeated stamp is how an unrelated state push leaves the banner alone.
local next_at_ms = 0
local function fresh_at_ms()
  next_at_ms = next_at_ms + 1000
  return next_at_ms
end

-- Every text event carries `\pos(x,y)` and its payload after the closing brace.
local function texts(events)
  local out = {}
  for _, event in ipairs(events) do
    local x, y = event.body:match('\\pos%(([%-%d%.]+),([%-%d%.]+)%)')
    local body = event.body:match('}([^{]*)$')
    if x and body and body ~= '' then
      table.insert(out, {x = tonumber(x), y = tonumber(y), text = body})
    end
  end
  return out
end

local function find_text(events, needle)
  for _, item in ipairs(texts(events)) do
    if item.text:find(needle, 1, true) then return item end
  end
  return nil
end

-- The raw event behind a text payload, for the assertions that are about the
-- *colour* a string was drawn in (a dimmed past programme) rather than where
-- it landed. `}` anchors the match to the payload, which every text event
-- appends immediately after its closing brace.
local function find_event(events, needle)
  for _, event in ipairs(events) do
    if event.body:find('}' .. needle, 1, true) then return event end
  end
  return nil
end

local function drawn_in(event, color)
  return event ~= nil and event.body:find('1c&H' .. color .. '&', 1, true) ~= nil
end

-- A drawn rect of `color` whose vertical span contains `y` — how the quick
-- list's selection highlight is found without restating its geometry here.
local function find_rect_at(events, color, y)
  for _, event in ipairs(events) do
    local rect = event.rect
    if rect and event.body:find('1c&H' .. color .. '&', 1, true)
      and y >= rect.y1 and y <= rect.y2 then
      return rect
    end
  end
  return nil
end

local COLOR_TEXT_HI = 'F8F4F2'
local COLOR_TEXT_LO = 'B2A39A'
local COLOR_LINE = '493B35'

local NOW_MS = os.time() * 1000
local live_state = {
  title = 'CALLE 13 HD',
  sourceName = 'CandyCloud',
  isLive = true,
  liveSynced = true,
  canFavorite = true,
  favorite = false,
  aspectLabel = 'Fill',
  epgNowTitle = 'Chicago P.D.',
  epgNowStartMs = NOW_MS - 20 * 60 * 1000,
  epgNowStopMs = NOW_MS + 25 * 60 * 1000,
  epgNextTitle = 'Harry Wild',
  epgNextStartMs = NOW_MS + 25 * 60 * 1000,
  epgNextStopMs = NOW_MS + 85 * 60 * 1000,
}

-- ===== 0. the aspect chip grows with its label ===============================
--
-- The chip is the one control whose width is driven by its text
-- (`text_button_width`), and the label set now includes "Stretch" — nearly
-- twice the width of "Fit". A chip that did not measure would clip it, so this
-- renders the longest and shortest labels and checks the chip actually moves.
--
-- It matters here specifically because the Windows GDI overlay *cannot* measure
-- (its layout runs without a device context) and carries a hand-set width
-- instead; this is the surface that proves the measuring path works.

local narrow_events = render_with({
  title = 'CALLE 13 HD',
  isLive = true,
  liveSynced = true,
  aspectLabel = 'Fit',
})
local wide_events = render_with({
  title = 'CALLE 13 HD',
  isLive = true,
  liveSynced = true,
  aspectLabel = 'Stretch',
})

local narrow_chip = find_text(narrow_events, 'Fit')
local wide_chip = find_text(wide_events, 'Stretch')
check(narrow_chip ~= nil, 'the aspect chip renders a short label')
check(wide_chip ~= nil, 'the aspect chip renders the longest label')
if narrow_chip and wide_chip then
  check(math.abs(narrow_chip.y - wide_chip.y) < 1,
    'the aspect chip keeps its row whatever the label')
  -- The control row is laid out right-to-left, so a wider chip starts further
  -- left. Equal x would mean a fixed width, i.e. a clipped "Stretch".
  check(wide_chip.x < narrow_chip.x,
    'a longer aspect label makes the chip wider rather than clipping')
end

-- ===== 1. live with a guide: the three-row EPG strip ==========================

local events = render_with(live_state)

local now_title = find_text(events, 'Chicago P.D.')
local now_range = find_text(events, ' – ')
local next_line = find_text(events, 'Next · ')
check(now_title ~= nil, 'live strip renders the current programme title')
check(now_range ~= nil, 'live strip renders the HH:MM – HH:MM range')
check(next_line ~= nil, 'live strip renders "Next · range · title"')

if now_title and now_range and next_line then
  check(now_range.x > now_title.x,
    'the range is right-aligned opposite the title')
  check(math.abs(now_range.y - now_title.y) < 1,
    'title and range share the first row')
  check(next_line.y > now_title.y,
    '"Next" sits below the title row')
  -- The progress bar is the only drawn rect between the two text rows spanning
  -- most of the width.
  local track = nil
  for _, event in ipairs(events) do
    local rect = event.rect
    if rect and rect.y1 > now_title.y and rect.y2 < next_line.y
      and (rect.x2 - rect.x1) > W * 0.8 then
      track = rect
    end
  end
  check(track ~= nil, 'the programme progress bar sits between the two rows')
end

-- Nothing in the strip may collide with the transport row below it. The
-- transport is the lowest row of Material Icons glyphs (play, mute); the strip
-- grew from one row to three, and `bottom_h` grew with it, so this is the
-- assertion that the two didn't end up on top of each other.
local function lowest_icon_y(events)
  local lowest = nil
  for _, event in ipairs(events) do
    if event.body:find('fnMaterial Icons', 1, true) then
      local y = tonumber(event.body:match('\\pos%([%-%d%.]+,([%-%d%.]+)%)'))
      if y and (not lowest or y > lowest) then lowest = y end
    end
  end
  return lowest
end

local transport_y = lowest_icon_y(events)
if transport_y and next_line then
  -- A 44px control centred on `transport_y`, so its top edge is -22.
  local gap = (transport_y - 22) - next_line.y
  check(gap > 12,
    string.format('the strip clears the transport row (gap %.0fpx)', gap))
end

-- ===== 2. badge order: source, LIVE, resolution, HDR, fps, clock =============

local function badge_x(events, needle)
  local item = find_text(events, needle)
  return item and item.x or nil
end

local source_x = badge_x(events, 'CandyCloud')
local live_x = badge_x(events, 'LIVE')
local res_x = badge_x(events, '1080p')
local hdr_x = badge_x(events, 'HDR10')
local fps_x = badge_x(events, '50fps')
check(source_x and live_x and res_x and hdr_x and fps_x,
  'compact badges render (source, LIVE, 1080p, HDR10, 50fps)')
if source_x and live_x and res_x and hdr_x and fps_x then
  check(source_x < live_x, 'source is left of LIVE')
  check(live_x < res_x, 'LIVE is left of the resolution')
  check(res_x < hdr_x, 'resolution is left of HDR')
  check(hdr_x < fps_x, 'HDR is left of fps')
end
check(find_text(events, '1920×1080') == nil,
  'no raw WxH badge (every overlay says "1080p")')
check(find_text(events, 'FPS') == nil,
  'no "50.00 FPS" badge (every overlay says "50fps")')

-- The programme must NOT appear under the title any more.
local title_item = find_text(events, 'CALLE 13 HD')
if title_item and now_title then
  check(title_item.y < now_title.y - 100,
    'the title is in the top bar and the programme in the bottom bar')
end

-- ===== 2b. the favorite star lives in the control row ========================
--
-- It used to be drawn in the *top* bar beside the badges, which put this OSD
-- (Linux's HDR-on-Wayland surface) somewhere different from the embedded
-- Flutter overlay Linux uses for every other stream -- and from Android and
-- iOS, which have always had it in the bottom cluster. Lua 5.1 has no
-- hex string escape, so the Material glyphs are spelled in decimal:
-- U+E5FA star_border, U+E5F9 star.
local STAR_BORDER = '\238\151\186'
local STAR_FILLED = '\238\151\185'

local star = find_text(events, STAR_BORDER)
local aspect_chip = find_text(events, 'Fill')
check(star ~= nil, 'the favorite star renders when the channel can be favorited')
if star and aspect_chip then
  check(math.abs(star.y - aspect_chip.y) < 1,
    'the favorite star shares the control row with the aspect chip')
end
if star and title_item then
  check(star.y > title_item.y + 100,
    'the favorite star is not in the top bar')
end
check(find_text(events, STAR_FILLED) == nil,
  'an unfavorited channel draws the outline star')

local favorited_state = {}
for k, v in pairs(live_state) do favorited_state[k] = v end
favorited_state.favorite = true
check(find_text(render_with(favorited_state), STAR_FILLED) ~= nil,
  'a favorited channel draws the filled star')

-- ===== 2c. the quick-list button sits immediately left of "Go to live" =======
--
-- The slot rule is identical on all four surfaces (docs/player.md, "The quick
-- list (Phase 6 ...)"): right cluster, immediately LEFT of the "Go to live"
-- chip, which itself sits left of the favorite star. It exists because the
-- list used to be keyboard/remote-only -- a pointer had no way to open it.
-- U+E2B8 format_list_bulleted, spelled in decimal (Lua 5.1 has no \x escape).
local LIST_GLYPH = '\238\138\184'

local zapping_state = {}
for k, v in pairs(live_state) do zapping_state[k] = v end
zapping_state.liveSynced = false
-- Dart pushes a `quickList` block on every state push of a zapping session,
-- `open = false` while it is closed. Its presence is what says "this route
-- zaps"; a VOD or no-zap route carries none.
zapping_state.quickList = {open = false, mode = 'channels', rows = {},
  selectedIndex = 0, windowStart = 0, total = 0}

local zap_events = render_with(zapping_state)
local list_button = find_text(zap_events, LIST_GLYPH)
local go_live_chip = find_text(zap_events, 'Go to live')
local zap_star = find_text(zap_events, STAR_BORDER)
check(list_button ~= nil, 'a zapping live route draws the quick-list button')
if list_button and go_live_chip then
  check(math.abs(list_button.y - go_live_chip.y) < 1,
    'the quick-list button shares the control row with "Go to live"')
  check(list_button.x < go_live_chip.x,
    'the quick-list button sits immediately left of "Go to live"')
end
if go_live_chip and zap_star then
  check(go_live_chip.x < zap_star.x,
    '... and "Go to live" stays left of the favorite star')
end

check(find_text(render_with(live_state), LIST_GLYPH) == nil,
  'a live route with no zap session draws no quick-list button')
check(find_text(render_with({
  title = 'Some Film',
  isLive = false,
  aspectLabel = 'Fit',
  quickList = {open = false, rows = {}},
}), LIST_GLYPH) == nil, 'VOD draws no quick-list button, even if pushed one')

-- ===== 3. SDR shows no dynamic-range badge ===================================

local sdr = render_with(live_state, {
  ['video-params'] = {w = 1280, h = 720},
  ['video-target-params'] = {},
})
check(find_text(sdr, 'SDR') == nil, 'SDR renders no dynamic-range badge')
check(find_text(sdr, '720p') ~= nil, 'a 1280x720 stream badges as 720p')

-- ===== 4. live with no guide: no strip, LIVE pill stays ======================

local bare = render_with({
  title = 'CALLE 13 HD',
  sourceName = 'CandyCloud',
  isLive = true,
  liveSynced = false,
  aspectLabel = 'Fit',
})
check(find_text(bare, 'Next · ') == nil, 'no guide → no "Next" row')
check(find_text(bare, 'LIVE') ~= nil, 'no guide → the LIVE pill still shows')
check(find_text(bare, 'Go to live') ~= nil,
  'behind the live edge → the "Go to live" chip, labelled with the action')

-- ===== 5. VOD keeps its scrubber and time label ==============================

local vod = render_with({
  title = 'Some Film',
  sourceName = 'CandyCloud',
  isLive = false,
  aspectLabel = 'Fit',
}, {['duration'] = 5400, ['time-pos'] = 1200})
check(find_text(vod, ' / ') ~= nil, 'VOD renders the position / duration label')
check(find_text(vod, 'LIVE') == nil, 'VOD renders no LIVE pill')
check(find_text(vod, 'Next · ') == nil, 'VOD renders no EPG strip')

-- ===== 6. the zap banner =====================================================
--
-- Phase 5 of in-player live zapping (docs/player.md "Live zapping"). The
-- banner is the only acknowledgement a keypress gets while the chrome is
-- hidden, which is exactly when zapping is used — so "does it draw at all"
-- is the assertion that matters most, and nothing else in the suite can make
-- it.

local function zap_state(overrides)
  local zap = {
    channelNumber = 12,
    channelName = 'BBC One HD',
    sourceName = 'CandyCloud',
    digits = '',
    settling = false,
    position = 3,
    total = 40,
    atMs = fresh_at_ms(),
    epgNowTitle = 'Pointless',
    epgNowStartMs = NOW_MS - 10 * 60 * 1000,
    epgNowStopMs = NOW_MS + 35 * 60 * 1000,
    epgNextTitle = 'The Repair Shop',
    epgNextStartMs = NOW_MS + 35 * 60 * 1000,
    epgNextStopMs = NOW_MS + 95 * 60 * 1000,
  }
  for k, v in pairs(overrides or {}) do zap[k] = v end
  local out = {}
  for k, v in pairs(live_state) do out[k] = v end
  out.zap = zap
  return out
end

local banner = render_hidden(zap_state())
check(find_text(banner, '12 · BBC One HD') ~= nil,
  'a zap push draws the identity run while the chrome is hidden')
check(find_text(banner, '3/40') ~= nil,
  'the banner shows the cursor place in the launch range')
check(find_text(banner, 'Pointless') ~= nil,
  'the banner reuses the live EPG strip for the cursor channel')
check(find_text(banner, 'The Repair Shop') ~= nil,
  'the banner strip carries the "Next" row too')
-- The cursor's guide, not the playing channel's: the two key runs are
-- deliberately separate, and reading the wrong one is how a held key would
-- print the programme of the channel being left.
check(find_text(banner, 'Chicago P.D.') == nil,
  'the banner prints the cursor guide, not the playing channel\'s')

-- With no zap block at all (a session that never zapped) nothing is drawn,
-- so a non-zapping Linux session looks exactly as it did before Phase 5.
check(find_text(render_hidden(live_state), 'BBC One HD') == nil,
  'no zap push → no banner')

-- ===== 6b. VOD never banners ================================================

local vod_zap = zap_state()
vod_zap.isLive = false
check(find_text(render_hidden(vod_zap), 'BBC One HD') == nil,
  'VOD draws no zap banner even with a zap block pushed')

-- ===== 6c. the digit readout ================================================
--
-- Mid-entry the number being built is the thing the user is looking at, so it
-- leads the row in the accent at a larger size (Kotlin `ChannelIdentityRow`).
-- It also keeps the banner up past the 3 s timer — hiding it would take the
-- feedback away while the user is still typing — which is why this push
-- carries no fresh `atMs` at all.

seam.set_banner_visible(false)
check(find_text(render_hidden(zap_state({atMs = 0})), 'BBC One HD') == nil,
  'once the 3 s timer has fired the banner is gone')

seam.set_banner_visible(false)
local digits_events = render_hidden(zap_state({digits = '123', atMs = 0}))
local digit_item = find_text(digits_events, '123')
local identity_item = find_text(digits_events, '12 · BBC One HD')
check(digit_item ~= nil, 'a half-typed number keeps the banner up on its own')
if digit_item and identity_item then
  check(digit_item.x < identity_item.x, 'the digits lead the identity run')
  check(math.abs(digit_item.y - identity_item.y) < 1,
    'the digits share the identity row')
end
if digit_item then
  local accent_digits = nil
  for _, event in ipairs(digits_events) do
    if event.body:find('}123', 1, true) and event.body:find('F66C7B', 1, true) then
      accent_digits = tonumber(event.body:match('\\fs([%d%.]+)'))
    end
  end
  check(accent_digits ~= nil, 'the digit readout is drawn in the accent')
  if accent_digits then
    check(accent_digits > 16, 'the digit readout is larger than the identity')
  end
end

-- ===== 6d. a transient note replaces the position readout ===================

seam.set_banner_visible(false)
local message_events = render_hidden(zap_state({message = 'No channel 999',
  atMs = 0}))
check(find_text(message_events, 'No channel 999') ~= nil,
  'a transient note renders in the banner')
check(find_text(message_events, '3/40') == nil,
  'the note takes the position readout\'s slot rather than stacking with it')

-- ===== 6e. the bar's identity run is conditional ============================
--
-- With the controls up the identity run is drawn only when it says something
-- the top bar's title does not — a number, a half-typed number, a note. A
-- session that never zaps therefore renders byte-identically to before.

local bar_with_identity = render_with(zap_state())
check(find_text(bar_with_identity, '12 · BBC One HD') ~= nil,
  'the bottom bar shows the identity run when the cursor has a number')

-- Built by hand rather than through `zap_state`: a nil in an overrides table
-- is invisible to `pairs`, so "no channel number" cannot be expressed as one.
local no_identity_state = {}
for k, v in pairs(live_state) do no_identity_state[k] = v end
no_identity_state.zap = {
  channelName = 'BBC One HD',
  digits = '',
  position = 3,
  total = 40,
  atMs = fresh_at_ms(),
}
local bar_without_identity = render_with(no_identity_state)
check(find_text(bar_without_identity, 'BBC One HD') == nil,
  'no number, no digits, no note → the bar draws no identity run')

-- The strip grew a row above it; the transport row must still clear it.
local identity_transport_y = lowest_icon_y(bar_with_identity)
local identity_next = find_text(bar_with_identity, 'Next · ')
if identity_transport_y and identity_next then
  local gap = (identity_transport_y - 22) - identity_next.y
  check(gap > 12,
    string.format('the strip clears the transport row with an identity row '
      .. 'above it (gap %.0fpx)', gap))
end
local identity_item_bar = find_text(bar_with_identity, '12 · BBC One HD')
if identity_item_bar and identity_next then
  check(identity_item_bar.y < identity_next.y,
    'the identity run sits above the EPG strip in the bar')
end

-- ===== 7. the quick list ====================================================
--
-- Phase 6d (docs/player.md "The quick list"). The list is the one thing on
-- this surface that is a *browsable* readout rather than a one-line one, and
-- every string in it arrives already formatted — so what these scenarios
-- prove is placement, ordering, state-to-colour and the second windowing
-- step, which is all this renderer actually decides.

-- `rows` is built from plain tables so a scenario can express exactly the
-- flags it is about; nothing here tries to be a faithful `ZapQuickListRow`
-- beyond the keys the renderer reads.
local function quick_list(overrides)
  local list = {
    open = true,
    mode = 'channels',
    heading = 'Sports HD',
    rows = {},
    selectedIndex = 0,
    windowStart = 0,
    total = 0,
    loading = false,
    revision = 1,
  }
  for k, v in pairs(overrides or {}) do list[k] = v end
  if list.total == 0 and type(list.rows) == 'table' and #list.rows > 0 then
    list.total = #list.rows
  end
  return list
end

local function with_quick_list(list, zap_overrides)
  local out = zap_state(zap_overrides or {})
  out.quickList = list
  return out
end

local channel_rows = {
  {index = 0, id = 'a', kind = 'channel', label = 'Eurosport 1',
    secondary = 'Cycling: Giro stage 9'},
  {index = 1, id = 'b', kind = 'channel', label = 'Eurosport 2',
    secondary = 'Snooker', badge = 'ON NOW', selected = true},
  {index = 2, id = 'c', kind = 'channel', label = 'Sky Sports Main',
    secondary = 'Premier League', playing = true},
  {index = 3, id = 'd', kind = 'channel', label = 'DAZN 1',
    secondary = 'Boxing'},
}

local list_events = render_hidden(with_quick_list(quick_list({
  rows = channel_rows, selectedIndex = 1,
})))

check(find_text(list_events, 'Sports HD') ~= nil,
  'the quick list draws its heading')
check(find_text(list_events, '2/4') ~= nil,
  'the heading carries the cursor place in the full list')

local row_a = find_text(list_events, 'Eurosport 1')
local row_b = find_text(list_events, 'Eurosport 2')
local row_c = find_text(list_events, 'Sky Sports Main')
local row_d = find_text(list_events, 'DAZN 1')
check(row_a and row_b and row_c and row_d, 'every row of the window renders')
if row_a and row_b and row_c and row_d then
  check(row_a.y < row_b.y and row_b.y < row_c.y and row_c.y < row_d.y,
    'the rows render in the order they arrived')
  check(math.abs(row_a.x - row_b.x) < 1,
    'the rows share a left edge')
end
check(find_text(list_events, 'Snooker') ~= nil,
  'a row draws its secondary line')
check(find_text(list_events, 'ON NOW') ~= nil,
  'a row draws its badge text verbatim')

-- The highlight is a filled row, so it is found as a drawn rect crossing the
-- selected row's own text — geometry the test never has to restate.
if row_b and row_a then
  local highlight = find_rect_at(list_events, COLOR_LINE, row_b.y)
  check(highlight ~= nil, 'the selected row is highlighted')
  check(find_rect_at(list_events, COLOR_LINE, row_a.y) == nil,
    'an unselected row is not')
  if highlight then
    check(highlight.x2 - highlight.x1 > 200,
      'the highlight spans the row, not just its text')
  end
end
check(drawn_in(find_event(list_events, 'Eurosport 1'), COLOR_TEXT_HI),
  'an unselected live row draws in the ordinary text colour')

-- The playing channel is marked even when the cursor is elsewhere — the two
-- flags are deliberately separate.
local PLAY_ARROW = '\238\147\139' -- U+E4CB play_arrow, Lua 5.1 has no \x
check(find_text(list_events, PLAY_ARROW) ~= nil,
  'the channel actually playing carries the play marker')

-- ===== 7b. the banner yields to the list ====================================

check(find_text(list_events, '12 · BBC One HD') == nil,
  'the zap banner does not draw behind an open quick list')
check(find_text(render_hidden(with_quick_list(quick_list({
    rows = channel_rows, selectedIndex = 1, open = false,
  }))), 'Eurosport 1') == nil,
  'open=false is a tear-down: the list draws nothing')
check(find_text(render_hidden(with_quick_list(quick_list({
    rows = channel_rows, open = false,
  }))), '12 · BBC One HD') ~= nil,
  'and the banner comes back when it does')

-- A push with no `rows`, `total` or `emptyLabel` at all must still render:
-- every optional key is tolerated missing.
check(pcall(render_hidden, with_quick_list({open = true})) == true,
  'a quick list with nothing but `open` renders rather than throwing')

-- The guide key opens the list with the chrome up, and the list is drawn over
-- the bars — so opening it stands them down rather than burying the transport
-- row under a panel that has just taken its arrows away.
-- A closed push first: the stand-down fires on the closed→open *edge*.
render_with(with_quick_list(quick_list({rows = channel_rows, open = false})))
local chrome_then_list = render_with(with_quick_list(quick_list({
  rows = channel_rows,
})))
check(find_text(chrome_then_list, 'Eurosport 1') ~= nil,
  'the list draws with the chrome nominally up')
check(find_text(chrome_then_list, 'CALLE 13 HD') == nil,
  'opening the list stands the chrome down')
seam.set_chrome_visible(true) -- the push above hid it; later scenarios expect chrome

-- ===== 7c. schedule mode: past rows, archive rows ===========================

local schedule_rows = {
  {index = 0, id = '1', kind = 'programme', label = 'Breakfast',
    secondary = '06:00 – 09:00', badge = 'CATCH-UP', past = true,
    archive = true},
  {index = 1, id = '2', kind = 'programme', label = 'Pointless',
    secondary = '17:15 – 18:00', badge = 'ON NOW', live = true,
    selected = true},
  {index = 2, id = '3', kind = 'programme', label = 'The Repair Shop',
    secondary = '18:00 – 19:00'},
}
local schedule_events = render_hidden(with_quick_list(quick_list({
  mode = 'schedule', heading = 'BBC One HD', rows = schedule_rows,
  selectedIndex = 1,
})))
check(find_text(schedule_events, 'CATCH-UP') ~= nil,
  'a past archive row badges CATCH-UP')
check(drawn_in(find_event(schedule_events, 'Breakfast'), COLOR_TEXT_LO),
  'a past programme is dimmed')
check(drawn_in(find_event(schedule_events, 'The Repair Shop'), COLOR_TEXT_HI),
  'a future programme is not')
local HISTORY = '\238\140\148' -- U+E314 history, the archive mark
check(find_text(schedule_events, HISTORY) ~= nil,
  'an archive row carries the catch-up mark beside its badge')
check(find_text(schedule_events, '06:00 – 09:00') ~= nil,
  'the row prints the range it was given, unformatted by this surface')

-- ===== 7d. empty and loading ================================================

check(find_text(render_hidden(with_quick_list(quick_list({
    mode = 'schedule', heading = 'BBC One HD',
    emptyLabel = 'No guide for today',
  }))), 'No guide for today') ~= nil,
  'an empty list prints its emptyLabel')
check(find_text(render_hidden(with_quick_list(quick_list({
    loading = true,
  }))), 'Loading…') ~= nil,
  'a fetch in flight with nothing to show yet says so')
check(find_text(render_hidden(with_quick_list(quick_list({
    loading = true, emptyLabel = 'No guide for today',
  }))), 'No guide for today') == nil,
  'loading wins over a stale emptyLabel')

-- ===== 7e. the second windowing step ========================================
--
-- Dart ships a 40-row window around the cursor; this surface then draws the
-- slice of it that fits the output. The two use the same centre-and-clamp
-- arithmetic, and a slice that misses the cursor would draw a list with no
-- visible selection — indistinguishable, on a remote, from a frozen picture.

local long_rows = {}
for i = 0, 39 do
  long_rows[i + 1] = {index = 100 + i, id = tostring(i), kind = 'channel',
    label = string.format('Channel %02d', i), secondary = 'Something on'}
end
local scrolled = render_hidden(with_quick_list(quick_list({
  rows = long_rows, windowStart = 100, selectedIndex = 130, total = 250000,
})))
local cursor_row = find_text(scrolled, 'Channel 30')
check(cursor_row ~= nil, 'the cursor row is inside the drawn slice')
check(find_text(scrolled, 'Channel 00') == nil,
  'the slice scrolled away from the top of the window')
check(find_text(scrolled, 'Channel 39') ~= nil,
  'and clamped at its bottom rather than running past it')
if cursor_row then
  check(find_rect_at(scrolled, COLOR_LINE, cursor_row.y) ~= nil,
    'the highlight follows selectedIndex - windowStart into the slice')
end
check(find_text(scrolled, '131/250000') ~= nil,
  'the place readout is the absolute one, not the window\'s')

-- ===== 8. the zap key policy ================================================
--
-- The Lua mirror of Kotlin's `ZapKeyPolicy` (pinned there by
-- `ZapKeyPolicyTest`). Nothing else executes these branches: mpv's key
-- bindings are unreachable from a headless render.

local function key(name, is_repeat, opts)
  opts = opts or {}
  if opts.isLive == false then
    render_with({title = 'Some Film', isLive = false, aspectLabel = 'Fit'})
  else
    local pushed = zap_state({digits = opts.digits or ''})
    pushed.quickList = opts.list
    render_with(pushed)
  end
  seam.set_chrome_visible(opts.chromeVisible == true)
  local command, swallow = seam.zap_key_command(name, is_repeat == true)
  seam.set_chrome_visible(true)
  return command, swallow
end

check(key('UP') == 'zap:up', 'chrome hidden: UP is the next higher channel')
check(key('DOWN') == 'zap:down', 'chrome hidden: DOWN is the next lower one')
check(key('RIGHT') == 'zap:prev', 'chrome hidden: RIGHT is previous-channel')
check(key('LEFT') == 'zap:list', 'chrome hidden: LEFT opens the quick list')
check(key('LEFT', false, {chromeVisible = true}) == nil,
  'chrome visible: LEFT stays seek')
local _, left_swallow = key('LEFT', true)
check(left_swallow == true,
  'a held LEFT is swallowed rather than re-opening the list')
check(key('UP', false, {chromeVisible = true}) == nil,
  'chrome visible: UP stays volume')
check(key('RIGHT', false, {chromeVisible = true}) == nil,
  'chrome visible: RIGHT stays seek')
check(key('PGUP', false, {chromeVisible = true}) == 'zap:up',
  'PGUP zaps whether the chrome is up or not')
check(key('PGDWN', false, {chromeVisible = true}) == 'zap:down',
  'PGDWN zaps whether the chrome is up or not')
check(key('UP', true) == 'zap:up', 'a held UP keeps zapping (that is scanning)')
local _, right_swallow = key('RIGHT', true)
check(right_swallow == true, 'a held RIGHT is swallowed, not toggled repeatedly')

check(key('7', false, {chromeVisible = true}) == 'zap:digit:7',
  'a digit is unambiguous — it zaps with the chrome up too')
check(key('KP7') == 'zap:digit:7', 'the numpad digits zap as well')
local digit_command, digit_swallow = key('7', true)
check(digit_command == nil and digit_swallow == true,
  'a held digit is swallowed rather than stacked four times')

check(key('ENTER') == nil, 'OK is not ours with no half-typed number')
check(key('ESC') == nil, 'ESC falls through to the Back ladder with no number')
check(key('ENTER', false, {digits = '12'}) == 'zap:activate',
  'OK commits a half-typed number early')
check(key('KP_ENTER', false, {digits = '12'}) == 'zap:activate',
  'the numpad OK commits it too')
check(key('ESC', false, {digits = '12'}) == 'zap:back',
  'Back clears a half-typed number before the Back ladder sees it')
check(key('BS', false, {digits = '12'}) == 'zap:back',
  'Backspace clears it as well')

check(key('UP', false, {isLive = false}) == nil, 'VOD: UP is not a zap key')
check(key('7', false, {isLive = false}) == nil, 'VOD: digits are not zap keys')

check(key('g') == 'zap:list', 'the guide key opens the list')
check(key('g', false, {chromeVisible = true}) == 'zap:list',
  'the guide key is unambiguous: it works with the chrome up too')
local _, guide_swallow = key('g', true)
check(guide_swallow == true, 'a held guide key is swallowed')
check(key('g', false, {isLive = false}) == nil,
  'VOD: the guide key is not ours (it is not even bound there)')

-- ===== 8b. the key policy with the list open ================================
--
-- Every arrow is claimed here regardless of the chrome: the list is the
-- on-screen cursor, and handing Up back to the volume control mid-walk would
-- be two cursors for one press. The rungs that peel or commit swallow their
-- repeats; Up/Down repeat freely, which is how a list is scanned.

local OPEN = quick_list({rows = channel_rows, selectedIndex = 1})
local function open_key(name, is_repeat, chrome_visible)
  return key(name, is_repeat, {list = OPEN, chromeVisible = chrome_visible})
end

check(open_key('UP') == 'zap:move:-1', 'open: UP moves the highlight up')
check(open_key('DOWN') == 'zap:move:1', 'open: DOWN moves it down')
check(open_key('UP', true) == 'zap:move:-1',
  'open: a held UP keeps moving (repeat is how a list is scanned)')
check(open_key('UP', false, true) == 'zap:move:-1',
  'open: the list owns the arrows whether the chrome is up or not')
check(open_key('LEFT') == 'zap:back', 'open: LEFT is one rung up the stack')
check(open_key('RIGHT') == 'zap:descend', 'open: RIGHT descends')
local _, open_left_swallow = open_key('LEFT', true)
check(open_left_swallow == true,
  'open: a held LEFT is swallowed rather than tearing through the stack')
local _, open_right_swallow = open_key('RIGHT', true)
check(open_right_swallow == true,
  'open: a held RIGHT is swallowed rather than firing a fetch per repeat')
check(open_key('ENTER') == 'zap:activate',
  'open: OK activates the selected row with no digits pending')
check(open_key('KP_ENTER') == 'zap:activate', 'open: the numpad OK too')
check(open_key('ESC') == 'zap:back',
  'open: Escape peels a list rung ahead of the Back ladder')
check(open_key('BS') == 'zap:back', 'open: Backspace does the same')
check(open_key('PGUP') == 'zap:up',
  'open: the dedicated channel keys still mean "next channel"')
check(open_key('PGDWN') == 'zap:down', 'open: and the other way')
check(open_key('4') == 'zap:digit:4', 'open: a digit still enters a number')
check(open_key('KP4') == 'zap:digit:4', 'open: from the numpad as well')
check(open_key('g') == 'zap:close', 'open: the guide key closes the list')
check(open_key('f') == nil, 'open: an unrelated key is left alone')

-- A closed push is not an open one: the arrows must revert with nothing
-- unbound (the policy is consulted per press, so the next push is enough).
local CLOSED = quick_list({rows = channel_rows, open = false})
check(key('UP', false, {list = CLOSED}) == 'zap:up',
  'a closed list hands the arrows straight back to channel up/down')
check(key('LEFT', false, {list = CLOSED}) == 'zap:list',
  'and LEFT goes back to opening it')

print('')
if failures > 0 then
  print(failures .. ' check(s) failed')
  os.exit(1)
end
print('all checks passed')
