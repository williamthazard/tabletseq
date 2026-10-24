-- The voice router: picks each sequence's target by its voice and passes the sequence's index (its
-- place in seq_list()). Voices are passed in; no norns globals; Lua 5.3 compatible.
--   voices = { engine, midi, crow1, crow2, jf, wsyn [, drums] }
-- `drums`, when given, takes the drum rack's hits in place of `engine` (it filters empty slots).
local Router = {}

local TARGET = {
  ["sine"] = "engine", ["drum rack"] = "engine",
  ["midi synth"] = "midi", ["midi kit"] = "midi",
  ["crow 1+2"] = "crow1", ["crow 3+4"] = "crow2",
  ["jf"] = "jf", ["wsyn"] = "wsyn",
}

local ORDER = { "engine", "midi", "crow1", "crow2", "jf", "wsyn" }

function Router.new(opts)
  local voices, seq_list = opts.voices, opts.seq_list
  local r = {}
  local started = {} -- voices whose first_use has run this session

  local function index_of(seq)
    for i, s in ipairs(seq_list()) do
      if s == seq then return i end
    end
  end

  function r.play(seq, note, at)
    local i = index_of(seq)
    local target = TARGET[seq.voice]
    if not i or not target then return end
    local v = voices[target]
    if not started[target] then
      started[target] = true
      if v.first_use then v.first_use() end
    end
    if seq.voice == "drum rack" and voices.drums then v = voices.drums end
    -- the MIDI voices take the channel; crow, JF and w/syn take the sequence (for its level)
    local extra = seq
    if target == "midi" then extra = seq.midi_channel end
    v.play(i, note, at, extra)
  end

  -- The sequence's voice may have just changed, so its notes are released on every target.
  function r.release_seq(seq)
    local i = index_of(seq)
    if not i then return end
    for _, name in ipairs(ORDER) do voices[name].release_seq(i) end
  end

  function r.release_all()
    for _, name in ipairs(ORDER) do voices[name].release_all() end
  end

  -- Only the engine mixes by level; the other targets read seq.level as they play.
  function r.set_level(seq, level)
    local i = index_of(seq)
    if i and TARGET[seq.voice] == "engine" then voices.engine.set_level(i, level) end
  end

  return r
end

return Router
