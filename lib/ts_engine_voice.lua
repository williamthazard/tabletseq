-- The engine voice: the sine and the drum rack's one-shots, played by Engine_TabletSeq.
-- `engine` is norns's engine table (plain functions, called with a dot); `clock` is norns's clock
-- (run, sleep, cancel, get_beats, get_beat_sec). Both are passed in. No norns globals; Lua 5.3 compatible.
local Common = include 'lib/ts_voice_common'
local EngineVoice = {}

local STEP = 0.001 -- beats a hold curve takes to jump to its next level

local function join(list)
  local out = {}
  for i, v in ipairs(list) do out[i] = string.format("%.6f", v):gsub("0+$", ""):gsub("%.$", "") end
  return table.concat(out, ",")
end

-- The pitch env's "hold" curve keeps each level until the next point; the string has no curve, so a
-- hold is sent as steps: each level held to just before the next point, then a quick jump onto it.
local function steps(levels, times)
  local lv, tm = { levels[1] }, {}
  for i = 1, #times do
    local jump = math.min(STEP, times[i] / 2)
    lv[#lv + 1] = levels[i]; tm[#tm + 1] = times[i] - jump
    lv[#lv + 1] = levels[i + 1]; tm[#tm + 1] = jump
  end
  return lv, tm
end

-- "<n>;<pitch levels>;<pitch times>;<amp levels>;<amp times>", comma-separated within each part.
-- n is the pitch env's point count after any hold steps. Times are in beats.
function EngineVoice.encode_env(pitch_env, amp_env)
  local plv, ptm = pitch_env.levels, pitch_env.times
  if pitch_env.curve == "hold" then plv, ptm = steps(plv, ptm) end
  return table.concat({ #plv, join(plv), join(ptm), join(amp_env.levels), join(amp_env.times) }, ";")
end

function EngineVoice.new(engine, clock)
  local v = {}
  local pending = {} -- sequence index -> { [routine id] = true } of notes waiting for their beat

  local function cancel(i)
    for id in pairs(pending[i] or {}) do clock.cancel(id) end
    pending[i] = nil
  end

  -- Runs fn at the absolute clock beat `at`, or at once when that has come.
  local function at_beat(i, at, fn)
    if at <= clock.get_beats() + 1e-9 then fn(); return end
    pending[i] = pending[i] or {}
    local waiting = pending[i]
    local id
    id = clock.run(function()
      Common.sleep_until(clock, at)
      waiting[id] = nil
      fn()
    end)
    waiting[id] = true
  end

  function v.play(seq_index, note, at)
    if note.kind == "voice" then
      at_beat(seq_index, at, function()
        local ts = clock.get_beat_sec()
        engine.sine_note(seq_index, note.dur * ts, ts, EngineVoice.encode_env(note.pitch_env, note.amp_env))
      end)
    elseif note.kind == "hit" then
      at_beat(seq_index, at, function() engine.oneshot_hit(seq_index, note.note - 35, note.amp) end)
    end
  end

  function v.release_seq(i)
    cancel(i)
    engine.seq_release(i)
  end

  function v.release_all()
    for i in pairs(pending) do cancel(i) end
    engine.release_all()
  end

  function v.set_level(i, level) engine.seq_level(i, level) end
  function v.set_send(i, which, value) engine.seq_send(i, which, value) end
  function v.load(slot, path) engine.oneshot_load(slot, path) end
  function v.clear(slot) engine.oneshot_clear(slot) end

  return v
end

return EngineVoice
