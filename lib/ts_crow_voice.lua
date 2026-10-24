-- The crow pairs: pitch on the odd output, envelope on the even one (1+2 or 3+4), played from the MIDI plan.
-- `crow` is norns's crow table (crow.output[i].volts); `connected` says whether a crow is plugged in;
-- `clock` is norns's clock (run, sleep, cancel, get_beats, get_beat_sec). All are passed in.
-- One voice per pair, shared by every sequence: a pair is mono, so the latest-started note owns it
-- (a chord, started on one beat, plays its highest note). While crow is absent nothing is sent.
-- play(seq_index, note, at[, seq]): `at` is an absolute beat; `seq` may carry bend_range (default 24)
-- and level (default 1). No norns globals; Lua 5.3 compatible.
local Common = include 'lib/ts_voice_common'
local CrowVoice = {}

local THRESHOLD = 0.001 -- volts; smaller changes are not sent
local EPS = Common.EPS

function CrowVoice.new(opts)
  local crow, connected, clock = opts.crow, opts.connected, opts.clock
  local pitch_out, env_out = 2 * opts.pair - 1, 2 * opts.pair
  local v = {}
  local owner = nil   -- the entry of the note that owns the pair
  local sched = Common.scheduler(clock)
  local want = {}     -- output -> the volts it should hold
  local sent = {}     -- output -> the volts last sent

  local function send(out, volts)
    want[out] = volts
    if not connected() then return end
    if sent[out] and math.abs(volts - sent[out]) <= THRESHOLD then return end
    sent[out] = volts
    crow.output[out].volts = volts
  end

  local sleep_until = sched.sleep_until

  local function end_entry(e)
    if not e.alive then return end
    e.alive = false
    if owner == e then
      owner = nil
      send(env_out, 0)
    end
  end

  local function run_note(i, note, at, seq)
    sleep_until(at)
    if note.vel <= 0 then return end
    local range = seq and seq.bend_range or 24
    local level = seq and seq.level or 1
    local function pitch_of(bend) return (note.note + (bend - 8192) / 8192 * range - 60) / 12 end
    local entry = { seq = i, alive = true, start = at, top = note.note }
    local steps, first_bend = Common.steps_of(note, true)
    -- a note started on the same beat as a higher one leaves the pair to it
    local yields = owner and owner.alive and math.abs(owner.start - at) <= EPS and owner.top > note.note
    if not yields then
      owner = entry
      send(pitch_out, pitch_of(first_bend or 8192))
      send(env_out, 5 * note.vel / 127)
    end
    for _, s in ipairs(steps) do
      sleep_until(at + s[1])
      if not entry.alive then return end
      if owner == entry then
        if s[2] == 1 then send(pitch_out, pitch_of(s[3])) else send(env_out, 5 * level * s[3] / 127) end
      end
    end
    sleep_until(at + note.dur)
    end_entry(entry)
  end

  function v.play(seq_index, note, at, seq)
    if note.kind ~= "midi" then return end
    sched.spawn(seq_index, function() run_note(seq_index, note, at, seq) end)
  end

  -- Cancels the sequence's unplayed notes; the envelope drops only if one of its notes owns the pair.
  function v.release_seq(i)
    sched.cancel(i)
    if owner and owner.seq == i then end_entry(owner) end
  end

  function v.release_all()
    sched.cancel_all()
    if owner then end_entry(owner) end
  end

  -- A crow that came back has lost its volts: send again what each output should hold.
  function v.reconnected()
    sent = {}
    for _, out in ipairs({ pitch_out, env_out }) do
      if want[out] then send(out, want[out]) end
    end
  end

  return v
end

return CrowVoice
