-- The screen (spec 5.4): the canvas at the left, the info column at the right, the sequence dots
-- along the bottom. `s` is norns's screen (or a recorder), called with a dot. No norns globals;
-- Lua 5.3 compatible.
--
-- view = {
--   seq    = the selected sequence, or the draft on the blank page,
--   new    = true on the blank page, which is marked "new",
--   bpb    = beats per bar (default 4),
--   state  = "stopped" | "starting" | "playing" | "stopping",
--   playhead = beat within the loop, or nil,
--   hover  = {x, y} and tip = {x, y}, fractions of the canvas, or nil,
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
local DOT_Y, DOT_STEP = 60, 5

local function round(v) return math.floor(v + 0.5) end

local function px(v) return round(v) + 0.5 end

local function waiting(state) return state == "starting" or state == "stopping" end

local function strokes(s, seq, loop_beats)
  local low, high = seq.low, seq.high
  local function pos(p)
    return p[1] / loop_beats * W, (high - p[2]) / (high - low) * (H - 1)
  end
  s.line_width(1)
  for _, stroke in ipairs(seq.strokes) do
    local pts = stroke.points
    if pts[1][1] < loop_beats then
      if stroke.kind == "dot" then
        local x, y = pos(pts[1])
        s.level(3 + round(12 * pts[1][3]))
        s.circle(x, y, 1.5)
        s.fill()
      else
        for i = 2, #pts do
          local x0, y0 = pos(pts[i - 1])
          local x1, y1 = pos(pts[i])
          s.level(3 + round(12 * (pts[i - 1][3] + pts[i][3]) / 2))
          s.move(x0, y0)
          s.line(x1, y1)
          s.stroke()
        end
      end
    end
  end
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
  strokes(s, seq, loop_beats)
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

local function info(s, view)
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

local function dots(s, view)
  local d = view.dots
  if not d or #d.states < 2 then return end
  local x0 = (W - (#d.states - 1) * DOT_STEP) / 2
  for i, state in ipairs(d.states) do
    local level = state == "playing" and 9 or 3
    if i == d.selected then level = 15 end
    if waiting(state) and not view.blink then level = 1 end
    s.level(level)
    s.circle(x0 + (i - 1) * DOT_STEP, DOT_Y, 1.5)
    s.fill()
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
  dots(s, view)
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
