-- The sequence data model: pure data, no norns globals. Ported from the Mac tabletseq's model.scd.
local M = {}

M.VOICES = { "sine", "midi synth", "midi kit", "crow 1+2", "crow 3+4", "jf", "wsyn", "drum rack" }

-- default {low, high} note per voice
M.RANGES = {
  ["sine"] = { 55, 84 },
  ["midi synth"] = { 48, 84 },
  ["midi kit"] = { 36, 51 },
  ["crow 1+2"] = { 55, 84 },
  ["crow 3+4"] = { 55, 84 },
  ["jf"] = { 55, 84 },
  ["wsyn"] = { 55, 84 },
  ["drum rack"] = { 36, 51 },
}

M.STEP_CHOICES = { 1, 2, 3, 4, 6, 8 }
M.STEP_LABELS = { "1/4", "1/8", "1/8T", "1/16", "1/16T", "1/32" }

-- the Mac's ten, in its order; degrees are semitones above the root
M.SCALES = {
  { name = "chromatic", degrees = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 } },
  { name = "major", degrees = { 0, 2, 4, 5, 7, 9, 11 } },
  { name = "minor", degrees = { 0, 2, 3, 5, 7, 8, 10 } },
  { name = "dorian", degrees = { 0, 2, 3, 5, 7, 9, 10 } },
  { name = "phrygian", degrees = { 0, 1, 3, 5, 7, 8, 10 } },
  { name = "lydian", degrees = { 0, 2, 4, 6, 7, 9, 11 } },
  { name = "mixolydian", degrees = { 0, 2, 4, 5, 7, 9, 10 } },
  { name = "harmonicMinor", degrees = { 0, 2, 3, 5, 7, 8, 11 } },
  { name = "majorPentatonic", degrees = { 0, 2, 4, 7, 9 } },
  { name = "minorPentatonic", degrees = { 0, 3, 5, 7, 10 } },
}

M.MAX_SEQUENCES = 16

local function contains(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

local function scale_known(name)
  for _, s in ipairs(M.SCALES) do if s.name == name then return true end end
  return false
end

local function valid_num(v)
  return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function clip(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- round half up, as an integer
local function round_int(v) return math.floor(v + 0.5) end

local function int_in(v, default, lo, hi)
  if valid_num(v) then return clip(round_int(v), lo, hi) end
  return default
end

local function bool_or(v, default)
  if type(v) == "boolean" then return v end
  return default
end

-- A new sequence on the sine with the spec's defaults. `seqs` is the sequences already there.
function M.new_sequence(seqs)
  local r = M.RANGES["sine"]
  return {
    voice = "sine",
    bars = 4,
    low = r[1],
    high = r[2],
    time_quant = true,
    steps_per_beat = 4,
    pitch_quant = true,
    root = 0,
    scale = "minorPentatonic",
    level = 0.8,
    midi_channel = 1,
    bend_range = 24,
    reverb_send = 0,
    delay_send = 0,
    grains_send = 0,
    strokes = {},
  }
end

function M.loop_beats(seq, bpb)
  return seq.bars * bpb
end

-- The voice's default range is applied only while the sequence has no strokes.
function M.set_voice(seq, voice)
  local r = M.RANGES[voice]
  if r then
    seq.voice = voice
    if #seq.strokes == 0 then
      seq.low, seq.high = r[1], r[2]
    end
  end
  return seq
end

-- At least an octave, within 0-127.
function M.set_range(seq, low, high)
  low = clip(low, 0, 127)
  high = clip(high, 0, 127)
  if high - low < 12 then
    high = low + 12
    if high > 127 then high = 127; low = 115 end
  end
  seq.low, seq.high = low, high
  return seq
end

-- A point is {beat, note, pressure}: three finite numbers with beat >= 0.
function M.sanitize_point(p)
  if type(p) ~= "table" or #p ~= 3 then return nil end
  for i = 1, 3 do
    if not valid_num(p[i]) then return nil end
  end
  if p[1] < 0 then return nil end
  return { p[1], clip(p[2], 0, 127), clip(p[3], 0, 1) }
end

-- Lines keep strictly ascending beats, so an envelope never gets a negative time.
function M.sanitize_stroke(raw)
  if type(raw) ~= "table" or type(raw.points) ~= "table" then return nil end
  local points = {}
  for _, p in ipairs(raw.points) do
    local q = M.sanitize_point(p)
    if q then points[#points + 1] = q end
  end
  if raw.kind == "dot" and #points > 0 then
    return { kind = "dot", points = { points[1] } }
  elseif raw.kind == "line" then
    local kept = {}
    for _, p in ipairs(points) do
      if #kept == 0 or p[1] > kept[#kept][1] then kept[#kept + 1] = p end
    end
    if #kept >= 2 then return { kind = "line", points = kept } end
  end
  return nil
end

function M.sanitize_sequence(raw)
  if type(raw) ~= "table" then return nil end
  local voice = contains(M.VOICES, raw.voice) and raw.voice or "sine"
  local def = M.RANGES[voice]
  local seq = { voice = voice }
  M.set_range(seq, int_in(raw.low, def[1], 0, 127), int_in(raw.high, def[2], 0, 127))
  seq.bars = int_in(raw.bars, 4, 1, 64)
  seq.time_quant = bool_or(raw.time_quant, true)
  seq.steps_per_beat = 4
  if valid_num(raw.steps_per_beat) and contains(M.STEP_CHOICES, raw.steps_per_beat) then
    seq.steps_per_beat = math.tointeger(raw.steps_per_beat)
  end
  seq.pitch_quant = bool_or(raw.pitch_quant, true)
  seq.root = int_in(raw.root, 0, 0, 11)
  seq.scale = scale_known(raw.scale) and raw.scale or "minorPentatonic"
  seq.level = valid_num(raw.level) and clip(raw.level, 0, 1) or 0.8
  seq.midi_channel = int_in(raw.midi_channel, 1, 1, 16)
  seq.bend_range = int_in(raw.bend_range, 24, 1, 48)
  for _, k in ipairs({ "reverb_send", "delay_send", "grains_send" }) do
    seq[k] = valid_num(raw[k]) and clip(raw[k], 0, 1) or 0
  end
  seq.strokes = {}
  if type(raw.strokes) == "table" then
    for _, s in ipairs(raw.strokes) do
      local stroke = M.sanitize_stroke(s)
      if stroke then seq.strokes[#seq.strokes + 1] = stroke end
    end
  end
  return seq
end

-- {selected, sequences} with selected 1-based, or nil when there are no sequences or none was stored.
-- Invalid sequences are dropped; at most MAX_SEQUENCES are kept.
function M.sanitize_set(raw)
  if type(raw) ~= "table" or type(raw.sequences) ~= "table" then return nil end
  local seqs = {}
  for _, s in ipairs(raw.sequences) do
    local seq = M.sanitize_sequence(s)
    if seq then
      seqs[#seqs + 1] = seq
      if #seqs == M.MAX_SEQUENCES then break end
    end
  end
  local n = #seqs
  local selected
  if n > 0 and raw.selected ~= nil then
    if valid_num(raw.selected) then
      selected = clip(round_int(raw.selected), 1, n)
    else
      selected = 1
    end
  end
  return { selected = selected, sequences = seqs }
end

-- Capture (spec 5.1). A cap is a runtime table holding one stroke in progress.
-- x is the fraction of canvas width; y is divided by 1.6 so distances are fractions of the width.
M.MAX_ENV_POINTS = 32
M.DOT_RADIUS = 0.01
M.MIN_POINT_DIST = 0.001

-- MIDI kits and the drum rack play hits: no dot expansion, and a zero-length line stays one hit.
function M.plays_hits(voice)
  return voice == "midi kit" or voice == "drum rack"
end

function M.begin_stroke(seq, bpb, x, y, p)
  local loop_beats = M.loop_beats(seq, bpb)
  local low, high = seq.low, seq.high
  local cx = clip(x, 0, 1 - 1e-6)
  local cy = clip(y, 0, 1)
  local cp = clip(p, 0, 1)
  local point = { cx * loop_beats, high - cy * (high - low), cp }
  return {
    seq = seq, loop_beats = loop_beats, low = low, high = high,
    points = { point }, down = point, down_x = cx, down_y = cy, last_x = cx, last_y = cy,
    max_pressure = cp, max_dist = 0,
  }
end

function M.extend_stroke(cap, x, y, p)
  local cx = clip(x, 0, 1 - 1e-6)
  local cy = clip(y, 0, 1)
  local cp = clip(p, 0, 1)
  local from_down = math.sqrt((cx - cap.down_x) ^ 2 + ((cy - cap.down_y) / 1.6) ^ 2)
  local from_last = math.sqrt((cx - cap.last_x) ^ 2 + ((cy - cap.last_y) / 1.6) ^ 2)
  cap.max_pressure = math.max(cap.max_pressure, cp)
  cap.max_dist = math.max(cap.max_dist, from_down)
  if from_last >= M.MIN_POINT_DIST then
    cap.points[#cap.points + 1] = { cx * cap.loop_beats, cap.high - cy * (cap.high - cap.low), cp }
    cap.last_x, cap.last_y = cx, cy
  end
  return cap
end

-- A dot, or a line with strictly ascending beats; the capture itself is left unchanged.
function M.finish_stroke(cap)
  local points = cap.points
  local dot = { kind = "dot", points = { { cap.down[1], cap.down[2], cap.max_pressure } } }
  if cap.max_dist <= M.DOT_RADIUS then return dot end
  if points[#points][1] < points[1][1] then
    local rev = {}
    for i = #points, 1, -1 do rev[#rev + 1] = points[i] end
    points = rev
  end
  local kept = {}
  for _, p in ipairs(points) do
    if #kept == 0 or p[1] > kept[#kept][1] then kept[#kept + 1] = { p[1], p[2], p[3] } end
  end
  local span = #kept >= 2 and (kept[#kept][1] - kept[1][1]) / cap.loop_beats or 0
  if span < 0.01 then return dot end
  return { kind = "line", points = kept }
end

local function copy_points(points)
  local out = {}
  for i, p in ipairs(points) do out[i] = { p[1], p[2], p[3] } end
  return out
end

-- Linear interpolation of {note, pressure} at a beat; clamped to the first and last point.
function M.interp_at(points, beat)
  local first, last = points[1], points[#points]
  if beat <= first[1] then return { first[2], first[3] } end
  if beat >= last[1] then return { last[2], last[3] } end
  for i = 2, #points do
    local b = points[i]
    if b[1] > beat then
      local a = points[i - 1]
      local span = b[1] - a[1]
      local t = span > 1e-12 and (beat - a[1]) / span or 1
      return { a[2] + t * (b[2] - a[2]), a[3] + t * (b[3] - a[3]) }
    end
  end
end

-- Spec 5.1 time quantize. Works on integer steps; the result is always a new list of new points.
function M.time_quantize(stroke, seq, bpb)
  local points = stroke.points
  if not seq.time_quant then return copy_points(points) end
  local sp = seq.steps_per_beat
  local loop_steps = M.loop_beats(seq, bpb) * sp
  local b0 = points[1][1]
  local span = points[#points][1] - b0
  local q_start = round_int(b0 * sp)
  local q_end = round_int(points[#points][1] * sp)
  if #points == 1 then q_end = q_start end
  if q_end <= q_start then
    -- a hit line that rounds to zero steps stays zero: it becomes a single hit later
    q_end = (#points > 1 and not M.plays_hits(seq.voice)) and q_start + 1 or q_start
  end
  local wrap = q_start >= loop_steps and loop_steps or 0
  local out = {}
  for i, p in ipairs(points) do
    local frac = span > 1e-12 and (p[1] - b0) / span or 0
    out[i] = { (q_start + frac * (q_end - q_start) - wrap) / sp, p[2], p[3] }
  end
  return out
end

-- Returns {} only if the first point is already past the loop end.
function M.cut_at_loop_end(points, loop_beats)
  if points[#points][1] <= loop_beats + 1e-9 then return copy_points(points) end
  local kept = {}
  for _, p in ipairs(points) do
    if p[1] < loop_beats - 1e-9 then kept[#kept + 1] = { p[1], p[2], p[3] } end
  end
  if #kept == 0 then return {} end
  local at = M.interp_at(points, loop_beats)
  kept[#kept + 1] = { loop_beats, at[1], at[2] }
  return kept
end

-- At most max_n points, evenly spaced in time, first and last kept exactly.
function M.resample(points, max_n)
  local first, last = points[1], points[#points]
  if #points <= max_n then return copy_points(points) end
  local span = last[1] - first[1]
  if span < 1e-12 then
    return { { first[1], first[2], first[3] }, { last[1], last[2], last[3] } }
  end
  local out = {}
  for k = 0, max_n - 1 do
    if k == 0 then
      out[#out + 1] = { first[1], first[2], first[3] }
    elseif k == max_n - 1 then
      out[#out + 1] = { last[1], last[2], last[3] }
    else
      local beat = first[1] + span * k / (max_n - 1)
      local at = M.interp_at(points, beat)
      out[#out + 1] = { beat, at[1], at[2] }
    end
  end
  return out
end

-- The per-stroke pipeline: time quantize, cut at the loop end, resample. nil for a hidden stroke
-- or one with nothing left. A pitched dot becomes two points one grid step apart.
function M.stroke_points(stroke, seq, bpb)
  local loop_beats = M.loop_beats(seq, bpb)
  local grid = 1 / seq.steps_per_beat
  if stroke.points[1][1] >= loop_beats then return nil end
  local points = M.cut_at_loop_end(M.time_quantize(stroke, seq, bpb), loop_beats)
  if #points == 0 then return nil end
  if not M.plays_hits(seq.voice) and #points == 1 then
    points = { points[1], { points[1][1] + grid, points[1][2], points[1][3] } }
  end
  return M.resample(points, M.MAX_ENV_POINTS)
end

return M
