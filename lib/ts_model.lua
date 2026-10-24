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

-- Pitch quantize (spec 6.3), notes and the MIDI plan. Ports of the Mac's snapToScale ... midiNotesFor.
M.P_HARD = 1.0
-- How far past the midpoint between two scale notes a line must go before the note changes.
M.SNAP_HYSTERESIS = 0.2

local function scale_degrees(name)
  for _, s in ipairs(M.SCALES) do
    if s.name == name then return s.degrees end
  end
  return M.SCALES[#M.SCALES].degrees
end

-- sort by start; equal starts keep their order (table.sort is not stable)
local function sort_by_start(notes)
  local keyed = {}
  for i, n in ipairs(notes) do keyed[i] = { n = n, i = i } end
  table.sort(keyed, function(a, b)
    if a.n.start ~= b.n.start then return a.n.start < b.n.start end
    return a.i < b.i
  end)
  local out = {}
  for i, k in ipairs(keyed) do out[i] = k.n end
  return out
end

-- Nearest scale note to `note`; ties go to the lower note. root is a pitch class 0-11.
function M.snap_to_scale(note, root, scale)
  local degrees = scale_degrees(scale)
  local octave = math.floor((note - root) / 12)
  local best, best_dist = nil, math.huge
  -- lowest candidates first, so a tie keeps the lower note
  for o = -1, 1 do
    for _, d in ipairs(degrees) do
      local cand = root + d + (octave + o) * 12
      local dist = math.abs(cand - note)
      if dist < best_dist - 1e-9 then best, best_dist = cand, dist end
    end
  end
  return best + 0.0
end

function M.pressure_to_amp(pressure)
  local f = clip(pressure / M.P_HARD, 0, 1)
  return 10 ^ ((-40 + 40 * f) / 20)
end

-- The next scale note above (dir 1) or below (dir -1) the scale note `note`.
function M.scale_step(note, dir, root, scale)
  local degrees = scale_degrees(scale)
  local cand = round_int(note) + dir
  local tries = 0
  -- every scale repeats each 12 semitones, so 12 tries always find the next note
  while not contains(degrees, (cand - root) % 12) and tries < 12 do
    cand = cand + dir
    tries = tries + 1
  end
  return cand + 0.0
end

-- Thins a stepped line to at most max_n points, keeping both ends. Points that only carry pressure
-- (same note as the point before) go first, the most crowded first; then the shortest notes.
function M.cap_points(pts, max_n)
  local out = {}
  for i, p in ipairs(pts) do out[i] = p end
  while #out > max_n do
    local best_i, best_cost
    for i = 2, #out - 1 do
      local gap = out[i + 1][1] - out[i][1]
      local cost = (out[i][2] == out[i - 1][2]) and gap or gap + 1e6
      if best_cost == nil or cost < best_cost then best_i, best_cost = i, cost end
    end
    table.remove(out, best_i)
  end
  return out
end

-- Autotune: at every moment the pitch is the scale note nearest the drawn line, so a slide plays
-- each scale note it passes and the hold curve keeps each note until the next point. A note changes
-- only once the line is SNAP_HYSTERESIS semitones past the midpoint to the next scale note.
-- Every input point is kept (its pressure feeds the amp envelope); a point is added at each change.
-- points: ascending {beat, note, pressure}. Returns {points = ..., curve = "hold"}.
function M.quantize_pitch(points, root, scale)
  local h = M.SNAP_HYSTERESIS
  local cur = M.snap_to_scale(points[1][2], root, scale)
  local out = { { points[1][1], cur, points[1][3] } }
  -- a point on the same beat as the last one replaces it, so beats stay strictly ascending
  local function put(p)
    if p[1] - out[#out][1] < 1e-9 then out[#out] = p else out[#out + 1] = p end
  end
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local y = a[2]
    local moving = true
    while moving do
      local up = M.scale_step(cur, 1, root, scale)
      local down = M.scale_step(cur, -1, root, scale)
      local up_at = (cur + up) / 2 + h
      local down_at = (cur + down) / 2 - h
      local cross
      if b[2] >= up_at and y < up_at then
        cur = up
        cross = up_at
      elseif b[2] <= down_at and y > down_at then
        cur = down
        cross = down_at
      end
      if cross == nil then
        moving = false
      else
        -- how far along a -> b the line reaches the threshold
        local f = (cross - a[2]) / (b[2] - a[2])
        y = cross
        put({ a[1] + f * (b[1] - a[1]), cur, a[3] + f * (b[3] - a[3]) })
      end
    end
    put({ b[1], cur, b[3] })
  end
  return { points = M.cap_points(out, M.MAX_ENV_POINTS), curve = "hold" }
end

-- The note for one pitched stroke. points: ascending {beat, note, pressure}, at least 2, at most 32.
-- Each env is {levels, times}; the pitch env also carries its curve ("lin" or "hold").
function M.voice_note(points, seq)
  local grid = 1 / seq.steps_per_beat
  local q
  if seq.pitch_quant then
    q = M.quantize_pitch(points, seq.root, seq.scale)
  else
    q = { points = points, curve = "lin" }
  end
  local pts = q.points
  local pitch, amp, times = {}, {}, {}
  for i, p in ipairs(pts) do
    pitch[i] = p[2]
    amp[i] = M.pressure_to_amp(p[3])
    if i > 1 then times[i - 1] = p[1] - pts[i - 1][1] end
  end
  local start, last = pts[1][1], pts[#pts][1]
  return {
    kind = "voice",
    start = start,
    dur = math.max(last - start, grid),
    pitch_env = { levels = pitch, times = times, curve = q.curve },
    amp_env = { levels = amp, times = times },
  }
end

-- Strokes whose first beat is at or past the loop end are kept but neither drawn nor played.
function M.hidden_count(seq, bpb)
  local loop_beats = M.loop_beats(seq, bpb)
  local n = 0
  for _, s in ipairs(seq.strokes) do
    if s.points[1][1] >= loop_beats then n = n + 1 end
  end
  return n
end

-- The highest pressure from beat lo to beat hi, the ends interpolated.
function M.peak_pressure(points, lo, hi)
  local top = math.max(M.interp_at(points, lo)[2], M.interp_at(points, hi)[2])
  for _, p in ipairs(points) do
    if p[1] >= lo and p[1] <= hi and p[3] > top then top = p[3] end
  end
  return top
end

-- Hits (spec 6.3 step 4): the kit and drum rack path. points: the stroke after quantizing, cutting
-- and resampling. Returns {{kind = "hit", start, note, amp, pressure}, ...}.
function M.drum_notes(stroke, points, seq, bpb)
  local sp = seq.steps_per_beat
  local grid = 1 / sp
  local loop_beats = M.loop_beats(seq, bpb)
  local first, last = points[1][1], points[#points][1]
  local stored = stroke.points
  local top = 0
  for _, p in ipairs(stored) do top = math.max(top, p[3]) end
  local function snap(note)
    if seq.pitch_quant then return M.snap_to_scale(note, seq.root, seq.scale) end
    return note
  end
  -- the highest pressure within half a grid step of the hit, clipped to the stroke
  local function accent(beat)
    return M.peak_pressure(points, math.max(beat - grid / 2, first), math.min(beat + grid / 2, last))
  end
  local short = #points == 1
  if not short then
    short = (stored[#stored][1] - stored[1][1]) < grid
    if seq.time_quant then
      short = short or round_int(first * sp) == round_int(last * sp)
    end
  end
  if short then
    return { { kind = "hit", start = first, note = snap(points[1][2]), amp = M.pressure_to_amp(top), pressure = top } }
  end
  local beats = {}
  if seq.time_quant then
    local first_step = round_int(first * sp)
    local steps = round_int(last * sp) - first_step + 1
    for i = 0, steps - 1 do beats[#beats + 1] = (first_step + i) / sp end
  else
    local steps = math.floor((last - first) * sp + 1e-9) + 1
    for i = 0, steps - 1 do beats[#beats + 1] = first + i * grid end
  end
  local out = {}
  for _, b in ipairs(beats) do
    if b < loop_beats - 1e-9 then
      local pressure = accent(b)
      out[#out + 1] = {
        kind = "hit", start = b, note = snap(M.interp_at(points, b)[1]),
        amp = M.pressure_to_amp(pressure), pressure = pressure,
      }
    end
  end
  return out
end

-- What the voice plays through (spec 12.4): "engine" (the sine), "hits" (the kit and drum rack)
-- or "midi" (the MIDI synth, crow, JF and w/syn).
function M.note_plan_kind(voice)
  if voice == "sine" then return "engine" end
  if M.plays_hits(voice) then return "hits" end
  return "midi"
end

-- Does the voice sound in the SuperCollider engine?
function M.uses_engine(voice)
  return voice == "sine" or voice == "drum rack"
end

-- All notes of a sequence for one pass of its loop, sorted by start. The sine gets voice notes, the
-- kit and drum rack get hits, the rest get the MIDI plan.
function M.notes_for(seq, bpb)
  local kind = M.note_plan_kind(seq.voice)
  if kind == "midi" then return M.midi_notes_for(seq, bpb) end
  local notes = {}
  for _, stroke in ipairs(seq.strokes) do
    local points = M.stroke_points(stroke, seq, bpb)
    if points then
      if kind == "hits" then
        for _, h in ipairs(M.drum_notes(stroke, points, seq, bpb)) do notes[#notes + 1] = h end
      else
        notes[#notes + 1] = M.voice_note(points, seq)
      end
    end
  end
  return sort_by_start(notes)
end

-- 1-127 from pressure, scaled by the sequence's level; 0 means the note is not sent
-- (MIDI velocity 0 is a note-off).
function M.midi_velocity(pressure, level)
  local f = clip(pressure / M.P_HARD, 0, 1)
  return round_int((1 + f * 126) * level)
end

-- The lowest channel no other MIDI sequence uses; 16 when all are taken.
function M.free_channel(seqs, except)
  local taken = {}
  for _, s in ipairs(seqs) do
    if s ~= except and (s.voice == "midi synth" or s.voice == "midi kit") then taken[s.midi_channel] = true end
  end
  for ch = 1, 16 do
    if not taken[ch] then return ch end
  end
  return 16
end

-- MIDI notes for a sequence (spec 6.2-6.3, 12.4), sorted by start:
-- {kind = "midi", start, dur, note, vel, bends = {{beat from start, 0-16383}, ...},
--  pressures = {{beat from start, 0-127}, ...}}. Notes whose velocity is 0 are dropped.
function M.midi_notes_for(seq, bpb)
  local grid = 1 / seq.steps_per_beat
  local level = seq.level
  local notes = {}
  -- A pen lands at almost no pressure, so a note's velocity is the peak in its first half grid
  -- step (the window kit hits use), never past the note's end.
  local function velocity_at(points, start, stop)
    return M.midi_velocity(M.peak_pressure(points, start, math.min(start + grid / 2, stop)), level)
  end
  -- channel pressure, sent only when its 0-127 value changes
  local function pressures_of(pts, t0)
    local out = {}
    for _, p in ipairs(pts) do
      local v = round_int(clip(p[3] / M.P_HARD, 0, 1) * 127)
      if #out == 0 or out[#out][2] ~= v then out[#out + 1] = { p[1] - t0, v } end
    end
    return out
  end
  for _, stroke in ipairs(seq.strokes) do
    local points = M.stroke_points(stroke, seq, bpb)
    if points then
      if seq.voice == "midi kit" then
        -- every integer note is a pad, so the scale never applies
        local plain = {}
        for k, v in pairs(seq) do plain[k] = v end
        plain.pitch_quant = false
        for _, hit in ipairs(M.drum_notes(stroke, points, plain, bpb)) do
          notes[#notes + 1] = {
            kind = "midi", start = hit.start, dur = grid, note = round_int(hit.note),
            vel = M.midi_velocity(hit.pressure, level), bends = {}, pressures = {},
          }
        end
      elseif seq.pitch_quant then
        -- autotune: a new note wherever the stepped pitch changes; no pitch bend
        local q = M.quantize_pitch(points, seq.root, seq.scale).points
        local stop = points[#points][1]
        local segs = {}
        for _, p in ipairs(q) do
          local seg = segs[#segs]
          if seg and seg[#seg][2] == p[2] then seg[#seg + 1] = p else segs[#segs + 1] = { p } end
        end
        for i, seg in ipairs(segs) do
          local s0 = seg[1][1]
          local s1 = segs[i + 1] and segs[i + 1][1][1] or stop
          -- a change on the very last point has no length of its own
          if s1 - s0 > 1e-9 then
            notes[#notes + 1] = {
              kind = "midi", start = s0, dur = s1 - s0, note = round_int(seg[1][2]),
              vel = velocity_at(points, s0, s1), bends = {}, pressures = pressures_of(seg, s0),
            }
          end
        end
      else
        -- glide: one note from the rounded first pitch; pitch bend follows the line
        local t0 = points[1][1]
        local note = round_int(points[1][2])
        local range = seq.bend_range
        local bends = {}
        for i, p in ipairs(points) do
          bends[i] = { p[1] - t0, clip(round_int(8192 + (p[2] - note) / range * 8192), 0, 16383) }
        end
        notes[#notes + 1] = {
          kind = "midi", start = t0, dur = math.max(points[#points][1] - t0, grid), note = note,
          vel = velocity_at(points, t0, points[#points][1]), bends = bends, pressures = pressures_of(points, t0),
        }
      end
    end
  end
  local kept = {}
  for _, n in ipairs(notes) do
    if n.vel > 0 then kept[#kept + 1] = n end
  end
  return sort_by_start(kept)
end

return M
