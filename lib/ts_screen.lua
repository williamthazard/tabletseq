-- The screen (spec 5.4): the canvas at the left, the info column at the right, the sequence ticks
-- at the bottom of the info column. `s` is norns's screen (or a recorder), called with a dot. No norns
-- globals; Lua 5.3 compatible.
--
-- view = {
--   seq    = the selected sequence, or the draft on the blank page,
--   new    = true on the blank page, which is marked "new",
--   bpb    = beats per bar (default 4),
--   state  = "stopped" | "starting" | "playing" | "stopping",
--   playhead = beat within the loop, or nil,
--   span   = {bottom, top, pad}: the pitches at the canvas's edges (Model.canvas_span), default seq.low..high,
--   stroke = the points {beat, note, pressure} of the stroke being drawn on seq, or nil,
--   hover  = {x, y} and tip = {x, y}, fractions of the canvas, or nil,
--   guides = {rows, root, scale}: pitches of faint dotted lines (ts_ui), or nil,
--   readout = what is under the pen, instead of the lines: {lines = {...}} or {big = "E4"}, or nil,
--   lines  = {{label, value}, ...}, line = the index E2 has selected,
--   dots   = { selected = index, states = {state, ...} },
--   blink  = true on the bright half of the waiting blink,
--   message = text for the bottom strip, or nil,
--   readings = the tablet's readings (ts_tablet), drawn instead of everything else, or nil }
local Screen = {}

local W, H = 82, 64        -- the canvas
local COL = 85             -- the info column starts here
local ROW0, ROW = 8, 9     -- the first line's baseline and the line height
local VISIBLE = 6          -- lines shown at once; the list scrolls to keep the selected line in view
local TICK_Y, TICK_SPAN = 60, 128 - COL   -- the tick indicator's top (it is 3 px tall) and width

local function round(v) return math.floor(v + 0.5) end

local function px(v) return round(v) + 0.5 end

local function waiting(state) return state == "starting" or state == "stopping" end

-- A pitch's y on the canvas. space: {bottom, top, pad}, the pitches at the canvas's edges (see
-- Model.canvas_span). Padded spans (row voices) use the full height, so a row's centre is its centre.
local function pitch_y(space, note)
  return (space.top - note) / (space.top - space.bottom) * (space.pad and H or H - 1)
end

-- Dotted lines (every other pixel) at the given pitches, one level, queued and filled once.
local function dotted(s, span, pitches, level)
  s.level(level)
  for _, p in ipairs(pitches) do
    local y = math.max(0, math.min(H - 1, round(pitch_y(span, p))))
    for x = 0, W - 1, 2 do s.pixel(x, y) end
  end
  s.fill()
end

-- Row boundaries; the root notes; and, when neighbours are at least 3 px apart, the scale notes (dimmer).
local function guide_lines(s, g, span)
  -- (rows crowded closer than 3 px would only wash the canvas, so they are dropped too)
  if g.rows and #g.rows > 0 and (#g.rows < 2 or pitch_y(span, g.rows[1]) - pitch_y(span, g.rows[2]) >= 3) then
    dotted(s, span, g.rows, 2)
  end
  if g.scale and #g.scale > 1 then
    local roomy = true
    for i = 2, #g.scale do
      if pitch_y(span, g.scale[i - 1]) - pitch_y(span, g.scale[i]) < 3 then roomy = false; break end
    end
    if roomy then dotted(s, span, g.scale, 1) end
  end
  if g.root and #g.root > 0 then dotted(s, span, g.root, 2) end
end

-- Strokes are drawn thinned and in four brightness bands, because every call on norns is a C call
-- into cairo on the main thread: thousands of them per frame would starve the clocks. A point is
-- skipped when it lands less than 1 px (straight-line distance) from the last one drawn; a finished
-- stroke always keeps its last point. A segment's level is the mean pressure of its ends, snapped to
-- the nearest of the BANDS, so the pressure shading still reads. All the segments of a band are
-- one path (move, line, line, ...) stroked once; the dots of a band are filled once.
local BANDS = { 3, 7, 11, 15 }

local function band_of(pressure)
  return math.floor(3 * math.max(0, math.min(1, pressure)) + 0.5) + 1
end

-- art = { segs = {[band] = {x0, y0, x1, y1, ...}}, dots = {[band] = {x, y, ...}} }
local function new_art()
  local art = { segs = {}, dots = {} }
  for b = 1, #BANDS do art.segs[b], art.dots[b] = {}, {} end
  return art
end

local function add_dot(art, x, y, pressure)
  local d = art.dots[band_of(pressure)]
  local k = #d
  d[k + 1], d[k + 2] = x, y
end

-- Adds the stroke's points (pos maps one to canvas x, y) to art; true if any segment was added.
-- keep_last: the last point is always drawn, however close it is to the one before.
local function add_line(art, pts, pos, keep_last)
  local x0, y0 = pos(pts[1])
  local p0 = pts[1][3]
  local n, drawn = #pts, false
  for i = 2, n do
    local x1, y1 = pos(pts[i])
    if (keep_last and i == n) or (x1 - x0) ^ 2 + (y1 - y0) ^ 2 >= 1 then
      local g = art.segs[band_of((p0 + pts[i][3]) / 2)]
      local k = #g
      g[k + 1], g[k + 2], g[k + 3], g[k + 4] = x0, y0, x1, y1
      x0, y0, p0 = x1, y1, pts[i][3]
      drawn = true
    end
  end
  return drawn
end

-- Draws art: per band, the segments stroked once, then the dots filled once. Segments that start
-- where the last one ended continue the path.
local function draw_art(s, art)
  s.line_width(1)
  s.line_join("round")
  for b = 1, #BANDS do
    local g, d = art.segs[b], art.dots[b]
    if #g > 0 or #d > 0 then s.level(BANDS[b]) end
    if #g > 0 then
      local lx, ly
      for i = 1, #g, 4 do
        if g[i] ~= lx or g[i + 1] ~= ly then s.move(g[i], g[i + 1]) end
        s.line(g[i + 2], g[i + 3])
        lx, ly = g[i + 2], g[i + 3]
      end
      s.stroke()
    end
    if #d > 0 then
      for i = 1, #d, 2 do
        s.move(d[i] + 1.5, d[i + 1])
        s.circle(d[i], d[i + 1], 1.5)
      end
      s.fill()
    end
  end
end

local function build_strokes(seq, loop_beats, span)
  local art = new_art()
  local function pos(p)
    return p[1] / loop_beats * W, pitch_y(span, p[2])
  end
  for _, stroke in ipairs(seq.strokes) do
    local pts = stroke.points
    if pts[1][1] < loop_beats then
      if stroke.kind == "dot" then
        local x, y = pos(pts[1])
        add_dot(art, x, y, pts[1][3])
      else
        add_line(art, pts, pos, true)
      end
    end
  end
  return art
end

-- The finished strokes' art is kept per sequence while nothing that moves a point on the canvas has
-- changed: the loop length, the span, the voice and range, and each stroke (the table, its points
-- table, their count and the first and last point). The stroke in progress is never cached.
local cache = setmetatable({}, { __mode = "k" })

local function stamp(seq, loop_beats, span)
  local st = { loop_beats = loop_beats, bottom = span.bottom, top = span.top, pad = span.pad or false,
    voice = seq.voice, low = seq.low, high = seq.high, n = #seq.strokes, strokes = {} }
  for i, stroke in ipairs(seq.strokes) do
    local pts = stroke.points
    local a, z = pts[1], pts[#pts]
    st.strokes[i] = { stroke, pts, #pts, stroke.kind, a[1], a[2], a[3], z[1], z[2], z[3] }
  end
  return st
end

local function same(a, b)
  for _, k in ipairs({ "loop_beats", "bottom", "top", "pad", "voice", "low", "high", "n" }) do
    if a[k] ~= b[k] then return false end
  end
  for i = 1, a.n do
    local x, y = a.strokes[i], b.strokes[i]
    for j = 1, 10 do
      if x[j] ~= y[j] then return false end
    end
  end
  return true
end

local function strokes(s, seq, loop_beats, span)
  local now = stamp(seq, loop_beats, span)
  local hit = cache[seq]
  if not (hit and same(hit.stamp, now)) then
    hit = { stamp = now, art = build_strokes(seq, loop_beats, span) }
    cache[seq] = hit
  end
  draw_art(s, hit.art)
end

-- The stroke being drawn, as a finished one is (unquantized: the pen's own path), but not cached and
-- without forcing its last point (the tip is drawn on its own).
-- space: the loop length and canvas span the points were captured in (they may differ from the
-- sequence's now)
local function live_stroke(s, space, pts)
  local loop_beats = space.loop_beats
  local function pos(p)
    return p[1] / loop_beats * W, pitch_y(space, p[2])
  end
  local art = new_art()
  if #pts == 1 then
    local x, y = pos(pts[1])
    add_dot(art, x, y, pts[1][3])
  else
    local drawn = add_line(art, pts, pos, false)
    -- a jittery tap or hold never leaves its first pixel: it stays a dot
    if not drawn then
      local x, y = pos(pts[1])
      add_dot(art, x, y, pts[1][3])
    end
  end
  draw_art(s, art)
end

local function canvas(s, view)
  local seq = view.seq
  local loop_beats = seq.bars * (view.bpb or 4)
  -- a faint bar grid
  s.level(2)
  s.line_width(1)
  for b = 1, seq.bars - 1 do
    local x = px(b / seq.bars * W)
    s.move(x, 0)
    s.line(x, H)
    s.stroke()
  end
  local span = view.span or { bottom = seq.low, top = seq.high }
  if view.guides then guide_lines(s, view.guides, span) end
  strokes(s, seq, loop_beats, span)
  if view.stroke then
    live_stroke(s, view.stroke_space or { loop_beats = loop_beats, bottom = span.bottom, top = span.top, pad = span.pad },
      view.stroke)
  end
  if view.playhead then
    local x = px(view.playhead / loop_beats * W)
    s.level(15)
    s.move(x, 0)
    s.line(x, H)
    s.stroke()
  end
  if view.hover then
    s.level(8)
    s.circle(view.hover.x * W, view.hover.y * H, 3)
    s.stroke()
  end
  if view.tip then
    s.level(15)
    s.circle(view.tip.x * W, view.tip.y * H, 1.5)
    s.fill()
  end
  -- a sequence waiting for the bar blinks the canvas corners
  if waiting(view.state) and view.blink then
    s.level(15)
    for _, c in ipairs({ { 0, 0, 1, 1 }, { W, 0, -1, 1 }, { 0, H, 1, -1 }, { W, H, -1, -1 } }) do
      s.move(c[1], c[2] + c[4] * 0.5)
      s.line(c[1] + c[3] * 4, c[2] + c[4] * 0.5)
      s.move(c[1] + c[3] * 0.5, c[2])
      s.line(c[1] + c[3] * 0.5, c[2] + c[4] * 4)
    end
    s.stroke()
  end
end

-- What is under the pen, in place of the settings.
local function readout(s, r)
  if r.big then
    s.font_face(1)
    s.font_size(16)
    s.level(15)
    s.move((COL + 127) / 2, 36)
    s.text_center(r.big)
    return
  end
  s.font_face(1)
  s.font_size(8)
  for i, text in ipairs(r.lines) do
    s.level(i == 1 and 15 or 6)
    s.move(COL, ROW0 + (i - 1) * ROW)
    s.text(text)
  end
end

local function info(s, view)
  if view.readout then return readout(s, view.readout) end
  local lines = view.lines
  local first = 1
  if view.line > VISIBLE then first = view.line - VISIBLE + 1 end
  s.font_face(1)
  s.font_size(8)
  for row = 1, VISIBLE do
    local i = first + row - 1
    local line = lines[i]
    if line then
      local y = ROW0 + (row - 1) * ROW
      s.level(i == view.line and 15 or 4)
      s.move(COL, y)
      s.text(line[1])
      s.move(127, y)
      s.text_right(line[2])
    end
  end
end

-- The sequence indicator: one tick per sequence along the bottom of the info column, in order. The
-- ticks are 3 px wide with 1 px gaps while they fit, else narrower (never under 1 px); the selected
-- one is taller. Rects at integer coordinates, filled once per level.
local function ticks(s, view)
  local d = view.dots
  if not d or #d.states < 2 then return end
  local n = #d.states
  local w = 3
  while w > 1 and n * w + (n - 1) > TICK_SPAN do w = w - 1 end
  local x0 = COL + (TICK_SPAN - (n * w + (n - 1))) // 2
  local levels = {}
  for i, state in ipairs(d.states) do
    local level = state == "playing" and 9 or 3
    if i == d.selected then level = 15 end
    if waiting(state) and not view.blink then level = 1 end
    levels[level] = levels[level] or {}
    levels[level][#levels[level] + 1] = i
  end
  for _, level in ipairs({ 1, 3, 9, 15 }) do
    local group = levels[level]
    if group then
      s.level(level)
      for _, i in ipairs(group) do
        local h = i == d.selected and 3 or 1
        s.rect(x0 + (i - 1) * (w + 1), TICK_Y + 3 - h, w, h)
      end
      s.fill()
    end
  end
end

-- The tablet readings page (PARAMS > tablet readings), in place of the normal page.
local function readings(s, r)
  local rows = {
    "max x " .. r.max_x,
    "max y " .. r.max_y,
    "max p " .. r.max_p,
    "button " .. (r.button and (r.button .. " (" .. r.button_code .. ")") or "none"),
    "x " .. r.x .. "  y " .. r.y .. "  p " .. r.p,
    "PARAMS > tablet readings: off",
  }
  s.font_face(1)
  s.font_size(8)
  for i, text in ipairs(rows) do
    s.level(i == #rows and 4 or 15)
    s.move(2, 8 + (i - 1) * 10)
    s.text(text)
  end
end

function Screen.draw(s, view)
  s.clear()
  s.aa(0)
  if view.readings then
    readings(s, view.readings)
    s.update()
    return
  end
  if view.seq then
    canvas(s, view)
    info(s, view)
    if view.new then
      s.font_face(1)
      s.font_size(8)
      s.level(5)
      s.move(2, 8)
      s.text("new")
    end
  end
  ticks(s, view)
  if view.message then
    s.level(0)
    s.rect(0, 55, 128, 9)
    s.fill()
    s.font_size(8)
    s.level(15)
    s.move(2, 62)
    s.text(view.message)
  end
  s.update()
end

return Screen
