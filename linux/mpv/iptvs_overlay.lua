-- IPTVS native Linux mpv overlay.
--
-- Renders the same control surface as lib/player/player_overlay.dart's
-- `_LinuxPlayerControls` (the embedded media_kit fallback for this platform)
-- directly into mpv's OSD via a single ASS-events overlay, so the app never
-- has to place a second compositor window above HDR video. State arrives
-- from Dart over `script-message-to iptvs_overlay iptvs-state`; user actions
-- either mutate local mpv properties directly (seek/volume/menus, which the
-- Dart side does not track) or are `emit()`-ted back over IPC user-data for
-- state the Dart side owns (favorites, aspect cycling, playback lifecycle).
local mp = require 'mp'
local assdraw = require 'mp.assdraw'
local utils = require 'mp.utils'

-- ===== Palette =====
-- ASS colors are &HBBGGRR& (byte-swapped RGB). Every value below is derived
-- from lib/theme.dart's AppColors — do not hand-tune these; if the app theme
-- changes, recompute the BGR swap from the new RGB and update the comment.
local COLOR = {
    accent  = 'F66C7B', -- #7B6CF6 AppColors.accent  (seek/progress fill, favorite-on, spinner)
    live    = '6D4DFF', -- #FF4D6D AppColors.live    (LIVE badge, synced)
    textHi  = 'F8F4F2', -- #F2F4F8 AppColors.textHi  (kept for parity; _LinuxPlayerControls text is literal white/textLo, see below)
    textLo  = 'B2A39A', -- #9AA3B2 AppColors.textLo  (secondary text: EPG line, info labels)
    panel   = '1F1816', -- #16181F AppColors.panel   (info panel bg)
    panelHi = '362B27', -- #272B36 AppColors.panelHi (popup menu bg)
    line    = '493B35', -- #353B49 AppColors.line    (seek/progress track)
    ink     = '130F0E', -- #0E0F13 AppColors.ink     (unused here: no app-bg surface behind video)
    white   = 'FFFFFF',
}

-- ASS alpha is inverted opacity: 00 = opaque, FF = fully transparent.
local ALPHA = {
    opaque   = '00',
    panel    = '0A', -- 0.96 opacity — info panel background
    barPeak  = '1A', -- 0.90 opacity — top/bottom bar gradient's most-opaque edge
    badge    = '75', -- 0.54 opacity — badge pill background (Colors.black54)
    border24 = 'C2', -- ~0.24 opacity — badge/live-pill border (Colors.white24)
    white70  = '4D', -- 0.70 opacity — VOD time label (Colors.white70)
    chip     = '14', -- 0.92 opacity — reconnect chip bg (PlayerReconnectChip)
}

-- ===== Material Icons glyphs =====
-- Codepoints verified against the vendored linux/mpv/fonts/MaterialIcons-Regular.otf
-- cmap with fontTools (each resolves to the correctly-named glyph, e.g. 0xE092
-- -> "arrow_back_baseline"). These match Flutter's Icons.* codePoint constants
-- (packages/flutter/lib/src/material/icons.dart), not the placeholder values
-- from the original design draft, which did not correspond to real glyphs in
-- this font.
local function utf8_char(codepoint)
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(
            0xC0 + math.floor(codepoint / 0x40),
            0x80 + (codepoint % 0x40)
        )
    end
    return string.char(
        0xE0 + math.floor(codepoint / 0x1000),
        0x80 + (math.floor(codepoint / 0x40) % 0x40),
        0x80 + (codepoint % 0x40)
    )
end

local ICON = {
    arrow_back          = utf8_char(0xE092),
    play_arrow           = utf8_char(0xE4CB),
    pause                = utf8_char(0xE47C),
    replay_10            = utf8_char(0xE524),
    forward_10           = utf8_char(0xE2C5),
    volume_up            = utf8_char(0xE6C5),
    volume_off           = utf8_char(0xE6C4),
    subtitles            = utf8_char(0xE619),
    audiotrack           = utf8_char(0xE0B6),
    speed                = utf8_char(0xE5E0),
    aspect_ratio         = utf8_char(0xE0A3),
    info_outline         = utf8_char(0xE33D),
    fullscreen           = utf8_char(0xE2CB),
    skip_next            = utf8_char(0xE5BD),
    fiber_manual_record  = utf8_char(0xE265),
    star                 = utf8_char(0xE5F9),
    star_border          = utf8_char(0xE5FA),
}

local overlay = mp.create_osd_overlay('ass-events')
local state = {
    title = 'IPTVS Player',
    canFavorite = false,
    favorite = false,
    isLive = false,
    liveSynced = true,
    aspectLabel = 'Fit',
    reconnecting = false,
}
local visible = true
local info_open = false
local open_menu = nil
local hide_timer = nil
local hitboxes = {}
-- Seek/volume track bounds computed once per render() and reused by click(),
-- so the hit-test geometry can never drift from what render() actually drew.
local geo = {}
-- HiDPI scale factor derived from the OSD's real output height; every
-- geometry/font-size helper below routes through px()/fs() so a 4K output
-- (scale=2) renders at the same physical size as 1080p instead of shrinking.
local scale = 1

local function px(n) return n * scale end
local function fs(n) return n * scale end

local function esc(value)
    return tostring(value or ''):gsub('\\', '\\e'):gsub('{', '\\{'):gsub('}', '\\}')
end

local function emit(command)
    -- JSON IPC clients cannot receive Lua script-message broadcasts directly.
    -- Publish through observed user-data so Dart receives a property-change.
    mp.set_property('user-data/iptvs-control', command .. '|' .. tostring(mp.get_time()))
end

local function add_hitbox(x1, y1, x2, y2, command)
    table.insert(hitboxes, {x1 = x1, y1 = y1, x2 = x2, y2 = y2, command = command})
end

-- Counts UTF-8 codepoints (not bytes) so measure()/truncate() aren't thrown
-- off by the multi-byte punctuation these strings actually contain (·, –, •, ×).
local function utf8_len(text)
    local _, count = text:gsub('[^\128-\191]', '')
    return count
end

-- Removes exactly one trailing UTF-8 codepoint without splitting a multi-byte
-- sequence (walks back over continuation bytes 0x80-0xBF).
local function utf8_trim_last(text)
    if #text == 0 then return text end
    local i = #text
    while i > 1 and text:byte(i) >= 0x80 and text:byte(i) <= 0xBF do
        i = i - 1
    end
    return text:sub(1, i - 1)
end

-- libass exposes no text-extents API to Lua scripts, so width is a heuristic
-- (average glyph advance ~0.58 * font size) — good enough for badge sizing
-- and ellipsis decisions, not pixel-exact.
local function measure(text, font_px)
    return utf8_len(tostring(text or '')) * font_px * 0.58
end

local function truncate(text, font_px, max_w)
    text = tostring(text or '')
    if measure(text, font_px) <= max_w then return text end
    local out = text
    while utf8_len(out) > 0 and measure(out .. '…', font_px) > max_w do
        out = utf8_trim_last(out)
    end
    return out .. '…'
end

local function property(name, fallback)
    local value = mp.get_property_native(name)
    if value == nil then return fallback end
    return value
end

local function duration_label(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    local hh = math.floor(seconds / 3600)
    local mm = math.floor(seconds / 60) % 60
    local ss = math.floor(seconds) % 60
    if hh > 0 then return string.format('%d:%02d:%02d', hh, mm, ss) end
    return string.format('%d:%02d', mm, ss)
end

local function hm_now()
    return os.date('%H:%M')
end

local function hm_ms(ms)
    if not ms then return '' end
    local d = os.date('*t', math.floor(ms / 1000))
    return string.format('%02d:%02d', d.hour, d.min)
end

-- Mirrors PlayerVideoSurfaceState._programmeLine: "HH:MM – HH:MM · title" and,
-- when a next programme is known, "  •  Next HH:MM – HH:MM · title" appended.
local function programme_line()
    if not state.epgNowTitle then return nil end
    local current = string.format('%s – %s · %s',
        hm_ms(state.epgNowStartMs), hm_ms(state.epgNowStopMs), state.epgNowTitle)
    if not state.epgNextTitle then return current end
    return string.format('%s  •  Next %s – %s · %s',
        current, hm_ms(state.epgNextStartMs), hm_ms(state.epgNextStopMs), state.epgNextTitle)
end

-- Mirrors Dart's `dynamicRangeLabelFrom` (player_screen.dart). `target` is
-- video-target-params -- the actual output colorimetry *after* mpv's render
-- pipeline (tone-mapping included), so a tone-mapped-to-SDR stream reports
-- SDR here even though its source was PQ/HLG -- the honest signal for
-- whether HDR actually reached the display. `source` is video-params
-- (source-side); the Dolby Vision check still consults it because DV
-- metadata doesn't reliably carry through the target-params render path.
-- The HDR10+ upgrade comes from `state.hdr10Plus` (pushed by Dart's
-- ST2094-40 scene-metadata probe over iptvs-state) -- Lua can't judge the
-- scene properties' semantics itself, so Dart stays the single authority.
local function dynamic_range(target, source)
    source = source or {}
    local gamma = string.lower(tostring(target.gamma or ''))
    local primaries = string.lower(tostring(target.primaries or ''))
    local source_gamma = string.lower(tostring(source.gamma or ''))
    local source_matrix = string.lower(tostring(source.colormatrix or ''))
    if source_matrix:find('dolby', 1, true) or source_gamma:find('dolby', 1, true) then
        return 'Dolby Vision'
    end
    if gamma:find('pq', 1, true) then
        if state.hdr10Plus then return 'HDR10+ · PQ' end
        return 'HDR10 · PQ'
    end
    if gamma:find('hlg', 1, true) then return 'HLG' end
    if primaries:find('2020', 1, true) then return 'HDR · BT.2020' end
    if gamma == '' and primaries == '' then return '' end
    return 'SDR'
end

local function codec_label(codec)
    if not codec or codec == '' then return 'Unknown' end
    return string.upper(codec)
end

local function channels_label(audio)
    if not audio then return '' end
    local channels = audio['demux-channels']
    if channels and channels ~= '' then return channels end
    local count = audio['demux-channel-count']
    if count and count > 0 then
        if count == 1 then return 'Mono' end
        if count == 2 then return 'Stereo' end
        return count .. ' ch'
    end
    return ''
end

-- Mirrors PlayerVideoSurfaceState._speedLabel.
local function speed_display(rate)
    if rate == 1 then return 'Normal (1.0×)' end
    if rate == math.floor(rate) then return string.format('%.1f×', rate) end
    return tostring(rate) .. '×'
end

-- Draws a filled (optionally rounded) rectangle. round_rect_cw degrades to a
-- plain rectangle when radius is 0, so this is the one drawing primitive
-- bars/tracks/pills/panels all share.
local function rrect(ass, x1, y1, x2, y2, color, alpha, radius)
    ass:new_event()
    ass:append(string.format('{\\pos(0,0)\\an7\\bord0\\shad0\\1c&H%s&\\alpha&H%s&}',
        color, alpha or ALPHA.opaque))
    ass:draw_start()
    ass:round_rect_cw(x1, y1, x2, y2, radius or 0, radius or 0)
    ass:draw_stop()
end

-- Approximates Flutter's Color(0xE6000000) -> transparent vertical gradient
-- with stepped bands (ASS has no native gradient fill). opaque_at_top=true
-- puts the most-opaque band at y1 (top bar); false puts it at y2 (bottom bar).
local function gradient_bar(ass, x1, y1, x2, y2, opaque_at_top)
    -- 36 bands ≈ 3px per step on a 1080p-height bar: below the visible
    -- banding threshold even over a bright scene (8 bands showed as hard
    -- gray strips). Still one ass event per band; 2 bars × 36 per render
    -- is well within libass budget.
    local bands = 36
    local band_h = (y2 - y1) / bands
    for i = 0, bands - 1 do
        local t = (i + 0.5) / bands
        if not opaque_at_top then t = 1 - t end
        local alpha = math.floor(0x1A + t * (0xFF - 0x1A) + 0.5)
        rrect(ass, x1, y1 + i * band_h, x2, y1 + (i + 1) * band_h,
            '000000', string.format('%02X', alpha), 0)
    end
end

-- An icon glyph with no chip behind it (the Flutter reference floats icons
-- directly on the gradient) and a nominal 44*s touch hitbox regardless of the
-- glyph's own visual size. `x` is the button's left edge; returns the width
-- consumed so callers can chain placement left-to-right.
local function icon_button(ass, x, cy, glyph, command, active)
    local half = px(22)
    local cx = x + half
    local color = active and COLOR.accent or COLOR.white
    ass:new_event()
    ass:append(string.format(
        '{\\pos(%.2f,%.2f)\\an5\\fnMaterial Icons\\fs%.2f\\bord0\\shad0\\1c&H%s&}%s',
        cx, cy, fs(22), color, glyph))
    -- Full 44*s square touch box centred on the glyph — not just its left
    -- half (x + half would stop at the glyph's centre line).
    add_hitbox(x, cy - half, x + half * 2, cy + half, command)
    return px(44)
end

local function text_button_width(text, font_px, has_icon)
    local pad_h = px(10)
    local icon_w = has_icon and (fs(18) + px(4)) or 0
    return pad_h * 2 + icon_w + measure(text, font_px)
end

-- A text button (aspect/speed labels, "Go to live"). Text color mirrors the
-- app's textButtonTheme.foregroundColor (AppColors.textHi) since these route
-- through TextButton/PopupMenuItem in the Flutter reference, which have no
-- explicit color override — unlike the plain icon buttons above, which are
-- literal Colors.white.
local function text_button(ass, x, cy, text, command, icon_glyph)
    local font_px = fs(14)
    local pad_h = px(10)
    local icon_w = icon_glyph and (fs(18) + px(4)) or 0
    local w = text_button_width(text, font_px, icon_glyph ~= nil)
    local h = px(34)
    if icon_glyph then
        ass:new_event()
        ass:append(string.format(
            '{\\pos(%.2f,%.2f)\\an4\\fnMaterial Icons\\fs%.2f\\bord0\\1c&H%s&}%s',
            x + pad_h, cy, fs(18), COLOR.textHi, icon_glyph))
    end
    ass:new_event()
    ass:append(string.format(
        '{\\pos(%.2f,%.2f)\\an4\\fnInter\\b1\\fs%.2f\\bord0\\1c&H%s&}%s',
        x + pad_h + icon_w, cy, font_px, COLOR.textHi, esc(text)))
    add_hitbox(x, cy - h / 2, x + w, cy + h / 2, command)
    return w
end

-- A right-anchored pill: black54 bg + white24 border + 11px w600 white text,
-- matching _LinuxPlayerControlsState._badge. `right_x` is the pill's right
-- edge; returns the total width consumed (including the gap to the next one).
local function badge(ass, right_x, cy, text)
    local font_px = fs(11)
    local pad_h = px(7)
    local w = measure(text, font_px) + pad_h * 2
    local h = font_px + px(9)
    local x1, x2 = right_x - w, right_x
    local y1, y2 = cy - h / 2, cy + h / 2
    rrect(ass, x1, y1, x2, y2, COLOR.white, ALPHA.border24, px(4))
    local inset = px(1.3)
    rrect(ass, x1 + inset, y1 + inset, x2 - inset, y2 - inset, '000000', ALPHA.badge, px(3))
    ass:new_event()
    ass:append(string.format(
        '{\\pos(%.2f,%.2f)\\an5\\fnInter\\b1\\fs%.2f\\bord0\\1c&H%s&}%s',
        (x1 + x2) / 2, cy, font_px, COLOR.white, esc(text)))
    return w + px(6)
end

-- The bottom-row LIVE pill (_LiveBadge): dot + "LIVE", filled `live` when
-- synced, greyed (white24) when behind. `x` is the pill's left edge; returns
-- its width.
local function live_pill(ass, x, cy, synced)
    local font_px = fs(11)
    local dot_r = px(4)
    local pad_h = px(8)
    local gap = px(5)
    local text = 'LIVE'
    local text_w = measure(text, font_px)
    local w = pad_h * 2 + dot_r * 2 + gap + text_w
    local h = font_px + px(6)
    local x1, x2 = x, x + w
    local y1, y2 = cy - h / 2, cy + h / 2
    if synced then
        rrect(ass, x1, y1, x2, y2, COLOR.live, ALPHA.opaque, px(4))
    else
        rrect(ass, x1, y1, x2, y2, COLOR.white, ALPHA.border24, px(4))
    end
    local dcx = x1 + pad_h + dot_r
    rrect(ass, dcx - dot_r, cy - dot_r, dcx + dot_r, cy + dot_r, COLOR.white, ALPHA.opaque, dot_r)
    ass:new_event()
    ass:append(string.format(
        '{\\pos(%.2f,%.2f)\\an4\\fnInter\\b1\\fs%.2f\\bord0\\1c&H%s&}%s',
        dcx + dot_r + gap, cy, font_px, COLOR.white, text))
    return w
end

-- The live-reconnect chip, mirroring PlayerReconnectChip in
-- player_overlay.dart: panel bg @0.92 + radius-8, an accent indicator dot (a
-- static dot stands in for the Flutter spinner — deliberately not animated)
-- and "Reconnecting…" in textHi 14. Drawn above the controls and independent
-- of their visibility, top-centred like the embedded Positioned(top: 24,
-- Center) placement, so an active reconnect stays visible even after the bars
-- auto-hide.
local function draw_reconnect_chip(ass, w)
    local text = 'Reconnecting…'
    local font_px = fs(14)
    local pad_h = px(16)
    local pad_v = px(10)
    local dot_r = px(8)
    local gap = px(10)
    local content_w = dot_r * 2 + gap + measure(text, font_px)
    local content_h = math.max(dot_r * 2, font_px)
    local chip_w = content_w + pad_h * 2
    local chip_h = content_h + pad_v * 2
    local x1 = (w - chip_w) / 2
    local y1 = px(24)
    rrect(ass, x1, y1, x1 + chip_w, y1 + chip_h, COLOR.panel, ALPHA.chip, px(8))
    local cy = y1 + chip_h / 2
    local dcx = x1 + pad_h + dot_r
    rrect(ass, dcx - dot_r, cy - dot_r, dcx + dot_r, cy + dot_r,
        COLOR.accent, ALPHA.opaque, dot_r)
    ass:new_event()
    ass:append(string.format(
        '{\\pos(%.2f,%.2f)\\an4\\fnInter\\fs%.2f\\bord0\\1c&H%s&}%s',
        dcx + dot_r + gap, cy, font_px, COLOR.textHi, esc(text)))
end

-- Forward declaration — defined after render() (it keys the position ticker
-- on/off to `visible`, and every visibility change flows through a render()).
local sync_tick_timer

local function render()
    local w, h = mp.get_osd_size()
    if not w or w <= 0 or not h or h <= 0 then return end
    if sync_tick_timer then sync_tick_timer() end
    scale = h / 1080
    local ass = assdraw.ass_new()
    hitboxes = {}
    geo = {}

    if visible then
    local top_h = px(96)
    local bottom_h = px(112)
    gradient_bar(ass, 0, 0, w, top_h, true)
    gradient_bar(ass, 0, h - bottom_h, w, h, false)

    -- ===== top bar =====
    local pad = px(16)
    local icon_cy = px(34)
    icon_button(ass, pad, icon_cy, ICON.arrow_back, 'back')

    local params = property('video-params', {})
    local target_params = property('video-target-params', {})
    local video_track = property('current-tracks/video', {})
    local dr = dynamic_range(target_params, params)
    local fps = video_track['demux-fps'] or property('container-fps', nil)
        or property('estimated-vf-fps', nil)

    local badge_items = {}
    local vw, vh = params.w or video_track['demux-w'], params.h or video_track['demux-h']
    if vw and vh and vw > 0 then table.insert(badge_items, vw .. '×' .. vh) end
    if dr ~= '' then table.insert(badge_items, dr) end
    if fps and fps > 0 then table.insert(badge_items, string.format('%.2f FPS', fps)) end
    if state.sourceName and state.sourceName ~= '' then
        table.insert(badge_items, state.sourceName)
    end
    table.insert(badge_items, hm_now())

    local favorite_w = state.canFavorite and (px(44) + px(8)) or 0
    local bx = w - pad - favorite_w
    for i = #badge_items, 1, -1 do
        bx = bx - badge(ass, bx, icon_cy, badge_items[i])
    end
    local badges_left_x = bx

    if state.canFavorite then
        local glyph = state.favorite and ICON.star or ICON.star_border
        icon_button(ass, w - pad - px(44), icon_cy, glyph, 'favorite', state.favorite)
    end

    local title_x1 = pad + px(44) + px(14)
    local title_max_w = math.max(px(40), badges_left_x - px(12) - title_x1)
    ass:new_event()
    ass:append(string.format(
        '{\\pos(%.2f,%.2f)\\an7\\fnInter\\b1\\fs%.2f\\bord0\\1c&H%s&}%s',
        title_x1, px(10), fs(20), COLOR.white, esc(truncate(state.title, fs(20), title_max_w))))
    local prog_line = programme_line()
    if prog_line then
        ass:new_event()
        ass:append(string.format(
            '{\\pos(%.2f,%.2f)\\an7\\fnInter\\fs%.2f\\bord0\\1c&H%s&}%s',
            title_x1, px(42), fs(13), COLOR.textLo,
            esc(truncate(prog_line, fs(13), title_max_w))))
    end

    -- ===== bottom bar =====
    local by = h - bottom_h
    local bpad = px(20)
    local row1_y = by + px(20)
    local row2_cy = h - px(30)
    local track_h = px(5)
    local duration = tonumber(property('duration', 0)) or 0
    local position = tonumber(property('time-pos', 0)) or 0

    if state.isLive then
        local now_title = state.epgNowTitle
        local pill_w = live_pill(ass, bpad, row1_y, state.liveSynced)
        local title_reserve = now_title
            and math.min(px(260), math.max(px(60), (w - 2 * bpad) * 0.32)) or 0
        local track_x1 = bpad + pill_w + px(12)
        local track_x2 = w - bpad - (now_title and (title_reserve + px(12)) or 0)
        rrect(ass, track_x1, row1_y - track_h / 2, track_x2, row1_y + track_h / 2,
            COLOR.line, ALPHA.opaque, track_h / 2)
        local progress = 0
        local now_start, now_stop = state.epgNowStartMs, state.epgNowStopMs
        if now_start and now_stop and now_stop > now_start then
            progress = math.min(1, math.max(0, (os.time() * 1000 - now_start) / (now_stop - now_start)))
        end
        local fill_x2 = track_x1 + (track_x2 - track_x1) * progress
        if fill_x2 > track_x1 then
            rrect(ass, track_x1, row1_y - track_h / 2, fill_x2, row1_y + track_h / 2,
                COLOR.accent, ALPHA.opaque, track_h / 2)
        end
        if now_title then
            ass:new_event()
            ass:append(string.format(
                '{\\pos(%.2f,%.2f)\\an4\\fnInter\\fs%.2f\\bord0\\1c&H%s&}%s',
                track_x2 + px(12), row1_y, fs(14), COLOR.white,
                esc(truncate(now_title, fs(14), title_reserve))))
        end
    else
        local track_x1, track_x2 = bpad, w - bpad
        local progress = duration > 0 and math.min(1, math.max(0, position / duration)) or 0
        rrect(ass, track_x1, row1_y - track_h / 2, track_x2, row1_y + track_h / 2,
            COLOR.line, ALPHA.opaque, track_h / 2)
        local fill_x2 = track_x1 + (track_x2 - track_x1) * progress
        if fill_x2 > track_x1 then
            rrect(ass, track_x1, row1_y - track_h / 2, fill_x2, row1_y + track_h / 2,
                COLOR.accent, ALPHA.opaque, track_h / 2)
        end
        local thumb_r = px(6)
        rrect(ass, fill_x2 - thumb_r, row1_y - thumb_r, fill_x2 + thumb_r, row1_y + thumb_r,
            COLOR.accent, ALPHA.opaque, thumb_r)
        geo.seek = {x1 = track_x1, x2 = track_x2}
        add_hitbox(track_x1, row1_y - px(14), track_x2, row1_y + px(14), 'seekbar')
    end

    local playing = not property('pause', false)
    local muted = property('mute', false)
    local volume = tonumber(property('volume', 100)) or 100

    local x = bpad
    x = x + icon_button(ass, x, row2_cy, playing and ICON.pause or ICON.play_arrow, 'playPause')
    if not state.isLive then
        x = x + icon_button(ass, x, row2_cy, ICON.replay_10, 'seekBack')
        x = x + icon_button(ass, x, row2_cy, ICON.forward_10, 'seekForward')
    end
    x = x + icon_button(ass, x, row2_cy, muted and ICON.volume_off or ICON.volume_up, 'mute')
        + px(4)

    local vol_x1, vol_x2 = x, x + px(96)
    rrect(ass, vol_x1, row2_cy - track_h / 2, vol_x2, row2_cy + track_h / 2,
        COLOR.line, ALPHA.opaque, track_h / 2)
    local vol_fill = vol_x1 + (vol_x2 - vol_x1) * math.min(1, math.max(0, volume / 100))
    if vol_fill > vol_x1 then
        rrect(ass, vol_x1, row2_cy - track_h / 2, vol_fill, row2_cy + track_h / 2,
            COLOR.accent, ALPHA.opaque, track_h / 2)
    end
    local vol_thumb_r = px(6)
    rrect(ass, vol_fill - vol_thumb_r, row2_cy - vol_thumb_r, vol_fill + vol_thumb_r,
        row2_cy + vol_thumb_r, COLOR.accent, ALPHA.opaque, vol_thumb_r)
    geo.volume = {x1 = vol_x1, x2 = vol_x2}
    add_hitbox(vol_x1, row2_cy - px(14), vol_x2, row2_cy + px(14), 'volume')
    x = vol_x2 + px(14)

    if not state.isLive then
        local label = duration_label(position) .. ' / ' .. duration_label(duration)
        ass:new_event()
        ass:append(string.format(
            '{\\pos(%.2f,%.2f)\\an4\\fnInter\\fs%.2f\\bord0\\1c&H%s&\\alpha&H%s&}%s',
            x, row2_cy, fs(13), COLOR.white, ALPHA.white70, esc(label)))
    end

    local tracks = property('track-list', {})
    local audio_count = 0
    for _, item in ipairs(tracks) do
        if item.type == 'audio' then audio_count = audio_count + 1 end
    end

    local right = w - bpad
    right = right - px(44)
    icon_button(ass, right, row2_cy, ICON.fullscreen, 'fullscreen')

    right = right - px(8) - px(44)
    icon_button(ass, right, row2_cy, ICON.info_outline, 'info')

    right = right - px(8)
    local aspect_label = state.aspectLabel or 'Fit'
    local aspect_w = text_button_width(aspect_label, fs(14), false)
    right = right - aspect_w
    text_button(ass, right, row2_cy, aspect_label, 'aspect')

    if not state.isLive then
        right = right - px(8)
        local speed = tonumber(property('speed', 1)) or 1
        local speed_label = speed_display(speed)
        local speed_w = text_button_width(speed_label, fs(14), false)
        right = right - speed_w
        text_button(ass, right, row2_cy, speed_label, 'speed')
    end

    right = right - px(8) - px(44)
    icon_button(ass, right, row2_cy, ICON.subtitles, 'subtitle')

    if audio_count > 1 then
        right = right - px(8) - px(44)
        icon_button(ass, right, row2_cy, ICON.audiotrack, 'audio')
    end

    if state.isLive and not state.liveSynced then
        right = right - px(8)
        local label = 'Go to live'
        local go_w = text_button_width(label, fs(14), true)
        right = right - go_w
        text_button(ass, right, row2_cy, label, 'goLive', ICON.skip_next)
    end

    -- ===== info panel =====
    if info_open then
        local audio = property('current-tracks/audio', {})
        local resolution = (vw and vh and vw > 0) and (vw .. '×' .. vh) or 'Unknown'
        local audio_bits = {}
        local ac = codec_label(audio.codec)
        if ac ~= 'Unknown' then table.insert(audio_bits, ac) end
        local ch = channels_label(audio)
        if ch ~= '' then table.insert(audio_bits, ch) end
        local rows = {
            {'Resolution', resolution},
            {'Dynamic range', dr ~= '' and dr or 'Unknown'},
            {'Video', codec_label(video_track.codec)},
            {'Audio', #audio_bits > 0 and table.concat(audio_bits, ' · ') or 'Unknown'},
        }
        if fps and fps > 0 then
            table.insert(rows, {'Frame rate', string.format('%.3f FPS', fps)})
        end

        local panel_w = px(320)
        local panel_x2 = w - px(20)
        local panel_x1 = panel_x2 - panel_w
        local panel_y1 = px(76)
        local pad_i = px(18)
        local title_fs = fs(17)
        local row_fs = fs(13)
        local row_h = px(24)
        local label_w = px(115)
        local panel_h = pad_i * 2 + title_fs + px(12) + #rows * row_h
        rrect(ass, panel_x1, panel_y1, panel_x2, panel_y1 + panel_h,
            COLOR.panel, ALPHA.panel, px(8))
        ass:new_event()
        ass:append(string.format(
            '{\\pos(%.2f,%.2f)\\an7\\fnInter\\b1\\fs%.2f\\bord0\\1c&H%s&}Stream information',
            panel_x1 + pad_i, panel_y1 + pad_i, title_fs, COLOR.white))
        local ry = panel_y1 + pad_i + title_fs + px(12)
        for _, row in ipairs(rows) do
            ass:new_event()
            ass:append(string.format(
                '{\\pos(%.2f,%.2f)\\an7\\fnInter\\fs%.2f\\bord0\\1c&H%s&}%s',
                panel_x1 + pad_i, ry, row_fs, COLOR.textLo, row[1]))
            ass:new_event()
            ass:append(string.format(
                '{\\pos(%.2f,%.2f)\\an7\\fnInter\\fs%.2f\\bord0\\1c&H%s&}%s',
                panel_x1 + pad_i + label_w, ry, row_fs, COLOR.white, esc(row[2])))
            ry = ry + row_h
        end
    end

    -- ===== audio/subtitle/speed menu =====
    if open_menu then
        local options = {}
        if open_menu == 'speed' then
            for _, rate in ipairs({0.5, 0.75, 1, 1.25, 1.5, 2}) do
                table.insert(options, {speed_display(rate), tostring(rate)})
            end
        else
            if open_menu == 'subtitle' then table.insert(options, {'Off', 'no'}) end
            for _, item in ipairs(tracks) do
                local wanted = (open_menu == 'audio' and item.type == 'audio')
                    or (open_menu == 'subtitle' and item.type == 'sub')
                if wanted then
                    local label
                    if open_menu == 'subtitle' and item.id == 'auto' then
                        label = 'Auto'
                    elseif item.title and item.title ~= '' then
                        label = item.title
                    elseif item.lang and item.lang ~= '' then
                        label = string.upper(item.lang)
                    else
                        label = (open_menu == 'audio' and 'Audio ' or 'Subtitle ') .. tostring(item.id)
                    end
                    table.insert(options, {label, tostring(item.id)})
                end
            end
        end
        local menu_w = px(250)
        local row_h = fs(15) + px(20)
        local menu_x2 = w - px(22)
        local menu_x1 = menu_x2 - menu_w
        local menu_y2 = by - px(8)
        local menu_y1 = menu_y2 - (#options * row_h)
        rrect(ass, menu_x1, menu_y1, menu_x2, menu_y2, COLOR.panelHi, ALPHA.opaque, px(8))
        for index, option in ipairs(options) do
            local y1 = menu_y1 + (index - 1) * row_h
            ass:new_event()
            ass:append(string.format(
                '{\\pos(%.2f,%.2f)\\an4\\fnInter\\fs%.2f\\bord0\\1c&H%s&}%s',
                menu_x1 + px(14), y1 + row_h / 2, fs(15), COLOR.textHi, esc(option[1])))
            add_hitbox(menu_x1, y1, menu_x2, y1 + row_h, 'select:' .. open_menu .. ':' .. option[2])
        end
    end

    end

    -- Above the controls and independent of their visibility, so an active
    -- reconnect stays on screen even after the bars auto-hide.
    if state.reconnecting then
        draw_reconnect_chip(ass, w)
    end

    overlay.res_x = w
    overlay.res_y = h
    overlay.data = ass.text
    overlay:update()
    if visible then
        mp.set_mouse_area(0, 0, w, h, 'iptvs-overlay')
    else
        mp.set_mouse_area(0, 0, 0, 0, 'iptvs-overlay')
    end
end

local function schedule_hide()
    if hide_timer then hide_timer:kill() end
    hide_timer = mp.add_timeout(4, function()
        if not property('pause', false) and not info_open and not open_menu
            and not state.reconnecting then
            visible = false
            render()
        end
    end)
end

local function show()
    visible = true
    render()
    schedule_hide()
end

local function click()
    if not visible then show(); return end
    local pos = property('mouse-pos', {})
    local x, y = pos.x or -1, pos.y or -1
    for _, box in ipairs(hitboxes) do
        if x >= box.x1 and x <= box.x2 and y >= box.y1 and y <= box.y2 then
            if box.command == 'seekbar' then
                local g = geo.seek
                if g then
                    local ratio = (x - g.x1) / math.max(1, g.x2 - g.x1)
                    mp.commandv('seek', math.min(100, math.max(0, ratio * 100)), 'absolute-percent')
                end
                schedule_hide()
            elseif box.command == 'volume' then
                local g = geo.volume
                if g then
                    local pct = math.min(100, math.max(0, ((x - g.x1) / math.max(1, g.x2 - g.x1)) * 100))
                    mp.set_property_number('volume', pct)
                end
                schedule_hide()
            elseif box.command == 'info' then
                info_open = not info_open
                open_menu = nil
                render()
                if info_open and hide_timer then hide_timer:kill() end
                if not info_open then schedule_hide() end
            elseif box.command == 'speed' or box.command == 'audio' or box.command == 'subtitle' then
                local opening = open_menu ~= box.command
                open_menu = opening and box.command or nil
                info_open = false
                render()
                if opening and hide_timer then hide_timer:kill() end
                if not opening then schedule_hide() end
            elseif box.command:match('^select:') then
                local kind, id = box.command:match('^select:([^:]+):(.+)$')
                if kind == 'speed' then mp.set_property('speed', id)
                elseif kind == 'audio' then mp.set_property('aid', id)
                elseif kind == 'subtitle' then mp.set_property('sid', id) end
                open_menu = nil
                render()
                schedule_hide()
            else
                emit(box.command)
                schedule_hide()
            end
            return
        end
    end
end

mp.register_script_message('iptvs-state', function(json)
    local decoded = utils.parse_json(json)
    if decoded then state = decoded end
    render()
end)

-- Discrete state changes re-render immediately so interaction stays snappy.
-- `time-pos`/`duration` are deliberately NOT observed: mpv fires time-pos
-- near frame rate, and each observation callback would rebuild the entire
-- ASS scene (gradient bands, buttons, badges) for a value only the VOD seek
-- bar and time label read — the live layout renders progress from os.time().
-- The position ticker below covers those at 4 Hz while the chrome is shown.
for _, name in ipairs({
    'pause', 'mute', 'volume', 'video-params',
    'video-target-params', 'current-tracks/video', 'current-tracks/audio',
    'speed', 'track-list',
}) do
    mp.observe_property(name, 'native', function() render() end)
end

-- Position/clock ticker: only runs while the chrome is visible (a hidden
-- overlay does no periodic work — state-message and property changes still
-- render immediately). 4 Hz keeps the VOD seek bar visually smooth and is
-- ample for the live wall-clock progress and top-bar clock.
local tick_timer = nil
sync_tick_timer = function()
    if visible and tick_timer == nil then
        tick_timer = mp.add_periodic_timer(0.25, render)
    elseif not visible and tick_timer ~= nil then
        tick_timer:kill()
        tick_timer = nil
    end
end
sync_tick_timer() -- chrome starts visible; the ticker starts with it

-- Single-press peel, matching the app's Back-ladder contract (see CLAUDE.md /
-- docs/tv-navigation.md): close the open list-menu, else close the info
-- panel, else hide the overlay chrome, else — nothing local left to
-- peel — hand off to Dart, which exits the player. The on-screen back arrow
-- *button* (routed through click()'s default `emit(box.command)` branch)
-- deliberately skips this and always exits directly, matching the embedded
-- overlay's back-arrow behavior.
local function handle_back()
    if open_menu then
        open_menu = nil
        render()
    elseif info_open then
        info_open = false
        render()
    elseif visible then
        if hide_timer then hide_timer:kill() end
        visible = false
        render()
    else
        emit('back')
    end
end

mp.add_forced_key_binding('MOUSE_MOVE', 'iptvs-show', show)
mp.add_forced_key_binding('MBTN_LEFT', 'iptvs-click', click)
mp.add_forced_key_binding('ESC', 'iptvs-back', handle_back)
mp.add_forced_key_binding('MBTN_BACK', 'iptvs-back-btn', handle_back)
mp.add_forced_key_binding('SPACE', 'iptvs-play', function() emit('playPause') end)
mp.add_forced_key_binding('LEFT', 'iptvs-left', function() emit('seekBack') end, {repeatable = true})
mp.add_forced_key_binding('RIGHT', 'iptvs-right', function() emit('seekForward') end, {repeatable = true})
mp.add_forced_key_binding('f', 'iptvs-fullscreen', function() emit('fullscreen') end)
mp.add_forced_key_binding('m', 'iptvs-mute', function() emit('mute') end)
mp.add_forced_key_binding('UP', 'iptvs-vol-up', function()
    mp.commandv('add', 'volume', 5)
    show()
end, {repeatable = true})
mp.add_forced_key_binding('DOWN', 'iptvs-vol-down', function()
    mp.commandv('add', 'volume', -5)
    show()
end, {repeatable = true})
mp.add_forced_key_binding('i', 'iptvs-info', function()
    info_open = not info_open
    open_menu = nil
    show(); if info_open and hide_timer then hide_timer:kill() end
end)
mp.add_forced_key_binding('s', 'iptvs-favorite', function() emit('favorite') end)

-- Orphaned-process safety net. If the Flutter app is killed outright (e.g.
-- SIGKILL from an OOM-killer or a force-quit) this mpv child would otherwise
-- survive as a fullscreen zombie window forever — the app has no dispose
-- path to run and the IPC socket just goes quiet. This lives in Lua rather
-- than Dart because dart:io has no way to observe SIGKILL (there is nothing
-- to catch) or to arrange PR_SET_PDEATHSIG before the child forks; mpv's own
-- Lua environment, running inside the child process itself, can poll its own
-- parent unconditionally. Once reparented to init (ppid == 1) the original
-- parent is gone, so ask mpv to quit itself. All io errors are swallowed —
-- a failed read just means we try again on the next tick. This script only
-- ever runs on Linux (LinuxNativeSession, the only thing that launches it,
-- is itself Platform.isLinux-gated), so no runtime platform check is needed
-- here.
local function check_parent_alive()
    local ok, line = pcall(function()
        local f = io.open('/proc/self/stat', 'r')
        if not f then return nil end
        local contents = f:read('*l')
        f:close()
        return contents
    end)
    if not ok or not line then return end
    -- Fields: pid (comm) state ppid ... — comm itself may contain spaces or
    -- even parens, so capture everything after the LAST ')' (the capture
    -- excludes no further ')', which is only satisfiable at the true last
    -- one) rather than assuming fixed whitespace-delimited positions from
    -- the start of the line.
    local rest = line:match('%)([^%)]*)$')
    if not rest then return end
    local fields = {}
    for field in rest:gmatch('%S+') do
        fields[#fields + 1] = field
    end
    -- rest starts at field 3 (state); field 4 (ppid) is fields[2] here.
    local ppid = tonumber(fields[2])
    if ppid == 1 then
        mp.command('quit')
    end
end

mp.add_periodic_timer(5, check_parent_alive)

show()
