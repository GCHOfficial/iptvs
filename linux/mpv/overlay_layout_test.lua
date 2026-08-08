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

print('')
if failures > 0 then
  print(failures .. ' check(s) failed')
  os.exit(1)
end
print('all checks passed')
