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

return M
