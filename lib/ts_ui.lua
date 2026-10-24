-- Encoders and keys (spec 5.4). E1 scrolls the sequences (one empty page past the last), E2 picks
-- a line of the info column, E3 changes it. K3 starts and stops, K2 twice deletes.
-- Dependencies are passed in; no norns globals; Lua 5.3 compatible.
--   set()  -> the live { selected, sequences } (the empty page is selected = #sequences + 1)
--   seq    -> ts_seq: toggle, changed, state, stop_now, playhead
--   router -> ts_router: set_level, set_send, release_seq
--   model  -> ts_model;  now() -> seconds
local Ui = {}

local DELETE_WINDOW = 3.0 -- seconds
local DELETE_TEXT = "K2 again to delete"
local LEVEL_STEP = 0.05

local VOICE_SHORT = {
  ["sine"] = "sine", ["midi synth"] = "midi s", ["midi kit"] = "midi k", ["crow 1+2"] = "crow12",
  ["crow 3+4"] = "crow34", ["jf"] = "jf", ["wsyn"] = "wsyn", ["drum rack"] = "drums",
}
local SCALE_SHORT = {
  chromatic = "chrom", major = "major", minor = "minor", dorian = "dorian", phrygian = "phryg",
  lydian = "lydian", mixolydian = "mixo", harmonicMinor = "harm", majorPentatonic = "maj p",
  minorPentatonic = "min p",
}
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local SENDS = { { "rev", "reverb" }, { "dly", "delay" }, { "grn", "grains" } }
local LABELS = { "voice", "bars", "low", "high", "level", "quant", "grid", "pitch", "root", "scale" }

local PITCH_LINES = { pitch = true, root = true, scale = true }

local function clip(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function note_name(n) return NOTE_NAMES[n % 12 + 1] .. (n // 12 - 1) end

local function on_off(v) return v and "on" or "off" end

local function level_step(v, d) return clip(math.floor((v + d * LEVEL_STEP) * 20 + 0.5) / 20, 0, 1) end

-- the position of v in list (compared by list[i][key] when key is given), 1 when absent
local function index_of(list, v, key)
  for i, x in ipairs(list) do
    if (key and x[key] or x) == v then return i end
  end
  return 1
end

local function is_midi(seq) return seq.voice == "midi synth" or seq.voice == "midi kit" end

function Ui.new(opts)
  local set, seq, router, model, now = opts.set, opts.seq, opts.router, opts.model, opts.now
  local line_i = 1
  local pending = nil -- { seq, at }: the first K2 of a delete
  local self = {}

  local function selected_seq()
    local cur = set()
    return cur.selected and cur.sequences[cur.selected] or nil
  end

  local function push_sends(s)
    for _, send in ipairs(SENDS) do router.set_send(s, send[2], s[send[2] .. "_send"]) end
  end

  -- every setting E3 can change, by label: its text, and what a turn of d does (false: no change)
  local SETTINGS = {
    voice = {
      show = function(s) return VOICE_SHORT[s.voice] end,
      turn = function(s, d)
        local voices = model.VOICES
        local v = voices[clip(index_of(voices, s.voice) + d, 1, #voices)]
        if v == s.voice then return false end
        -- the old voice's notes end first, on whichever target held them
        router.release_seq(s)
        local was_midi = is_midi(s)
        model.set_voice(s, v)
        if is_midi(s) and not was_midi then s.midi_channel = model.free_channel(set().sequences, s) end
        router.set_level(s, s.level)
        push_sends(s)
      end,
    },
    bars = {
      show = function(s) return tostring(s.bars) end,
      turn = function(s, d) s.bars = clip(s.bars + d, 1, 64) end,
    },
    low = {
      show = function(s) return note_name(s.low) end,
      turn = function(s, d) model.set_range(s, s.low + d, s.high) end,
    },
    high = {
      show = function(s) return note_name(s.high) end,
      turn = function(s, d) model.set_range(s, s.low, s.high + d) end,
    },
    level = {
      show = function(s) return string.format("%.2f", s.level) end,
      turn = function(s, d)
        s.level = level_step(s.level, d)
        router.set_level(s, s.level)
      end,
    },
    quant = {
      show = function(s) return on_off(s.time_quant) end,
      turn = function(s, d) s.time_quant = d > 0 end,
    },
    grid = {
      show = function(s) return model.STEP_LABELS[index_of(model.STEP_CHOICES, s.steps_per_beat)] end,
      turn = function(s, d)
        local choices = model.STEP_CHOICES
        s.steps_per_beat = choices[clip(index_of(choices, s.steps_per_beat) + d, 1, #choices)]
      end,
    },
    pitch = {
      show = function(s) return on_off(s.pitch_quant) end,
      turn = function(s, d) s.pitch_quant = d > 0 end,
    },
    root = {
      show = function(s) return NOTE_NAMES[s.root + 1] end,
      turn = function(s, d) s.root = clip(s.root + d, 0, 11) end,
    },
    scale = {
      show = function(s) return SCALE_SHORT[s.scale] end,
      turn = function(s, d)
        s.scale = model.SCALES[clip(index_of(model.SCALES, s.scale, "name") + d, 1, #model.SCALES)].name
      end,
    },
    chan = {
      show = function(s) return tostring(s.midi_channel) end,
      turn = function(s, d) s.midi_channel = clip(s.midi_channel + d, 1, 16) end,
    },
    bend = {
      show = function(s) return tostring(s.bend_range) end,
      turn = function(s, d) s.bend_range = clip(s.bend_range + d, 1, 48) end,
    },
  }
  for _, send in ipairs(SENDS) do
    local field = send[2] .. "_send"
    SETTINGS[send[1]] = {
      show = function(s) return string.format("%.2f", s[field]) end,
      turn = function(s, d)
        s[field] = level_step(s[field], d)
        router.set_send(s, send[2], s[field])
      end,
    }
  end

  -- {{label, value}, ...} for the sequence's voice: no pitch lines for the kit and drum rack, the MIDI
  -- lines for MIDI voices, the sends for the sine and drum rack
  function self.info_lines(s)
    local ids = {}
    for _, id in ipairs(LABELS) do
      -- hits are rows, not pitches: pitch quantize, root and scale do not apply (spec 5.3)
      if not (PITCH_LINES[id] and model.plays_hits(s.voice)) then ids[#ids + 1] = id end
    end
    if is_midi(s) then ids[#ids + 1] = "chan"; ids[#ids + 1] = "bend" end
    if model.uses_engine(s.voice) then
      for _, send in ipairs(SENDS) do ids[#ids + 1] = send[1] end
    end
    local out = {}
    for i, id in ipairs(ids) do out[i] = { id, SETTINGS[id].show(s) } end
    return out
  end

  -- the selected line, kept within the selected sequence's lines
  function self.line()
    local s = selected_seq()
    if not s then return line_i end
    return clip(line_i, 1, #self.info_lines(s))
  end

  -- Pushes every sequence's level and sends to the engine. Deleting shifts indices, and the engine
  -- keeps them per index.
  function self.sync_engine()
    for _, s in ipairs(set().sequences) do
      router.set_level(s, s.level)
      push_sends(s)
    end
  end

  function self.enc(n, d)
    local cur = set()
    if n == 1 then
      local count = #cur.sequences
      local limit = math.max(math.min(count + 1, model.MAX_SEQUENCES), 1)
      cur.selected = clip((cur.selected or count + 1) + d, 1, limit)
    elseif n == 2 then
      local s = selected_seq()
      if s then line_i = clip(self.line() + d, 1, #self.info_lines(s)) end
    elseif n == 3 then
      local s = selected_seq()
      if not s then return end
      local id = self.info_lines(s)[self.line()][1]
      if SETTINGS[id].turn(s, d) ~= false then seq.changed(s) end
    end
  end

  -- Stops the sequence and the running ones after it (their indices shift, and the voices hold
  -- notes by index), removes it, and moves the selection to a neighbour.
  local function delete(s)
    local list = set().sequences
    local k = index_of(list, s)
    seq.stop_now(s)
    for j = k + 1, #list do
      if seq.state(list[j]) ~= "stopped" then seq.stop_now(list[j]) end
    end
    table.remove(list, k)
    set().selected = #list > 0 and math.min(k, #list) or nil
    self.sync_engine()
  end

  function self.key(n, z)
    if z ~= 1 then return end
    local s = selected_seq()
    if not s then return end
    if n == 3 then
      seq.toggle(s)
    elseif n == 2 then
      if pending and pending.seq == s and now() - pending.at <= DELETE_WINDOW then
        pending = nil
        delete(s)
      else
        pending = { seq = s, at = now() }
      end
    end
  end

  -- "K2 again to delete" while a delete waits for its second press, otherwise nil
  function self.message()
    if pending and pending.seq == selected_seq() and now() - pending.at <= DELETE_WINDOW then
      return DELETE_TEXT
    end
  end

  -- What Screen.draw takes. ctx: bpb, hover, tip, blink.
  function self.view(ctx)
    local cur = set()
    local s = selected_seq()
    local states = {}
    for i, q in ipairs(cur.sequences) do states[i] = seq.state(q) end
    return {
      seq = s,
      bpb = ctx.bpb,
      state = s and seq.state(s) or "stopped",
      playhead = s and seq.playhead(s) or nil,
      hover = ctx.hover, tip = ctx.tip, blink = ctx.blink,
      lines = s and self.info_lines(s) or {},
      line = self.line(),
      dots = { selected = cur.selected or #cur.sequences + 1, states = states },
      message = self.message(),
    }
  end

  return self
end

return Ui
