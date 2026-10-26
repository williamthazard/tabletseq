-- The Just Friends and w/syn voices, over crow's ii bus, played from the MIDI plan.
-- `ii` is a function returning crow.ii.jf / crow.ii.wsyn; it is called on every send, never cached
-- (a cached crowSub breaks). `connected` says whether a crow is plugged in; `clock` is norns's clock
-- (run, sleep, get_beats, get_beat_sec); `settings` is the live settings table the params edit
-- (JF: mode; w/syn: voices, lpg_time, lpg_symmetry, fm_env, hold). All are passed in.
-- One voice per module, shared by every sequence: JF's six channels and w/syn's voices rotate globally,
-- and a stolen one is released first. Module settings are sent by apply_settings only; first_use also
-- sends the neutral timbre, before a session's first note and after crow reconnects. A release that
-- falls due while crow is away is owed: first_use sends it once crow is back.
-- play(seq_index, note, at[, seq]): `at` is an absolute beat; `seq` may carry bend_range (default 24)
-- and level (default 1). While crow is absent nothing is sent. No norns globals; Lua 5.3 compatible.
local Common = include 'lib/ts_voice_common'
local IiVoice = {}

local THRESHOLD = 0.001 -- volts; smaller changes are not sent
local EPS = 1e-9
local NEUTRAL_RATIO = 0.7

local function pitch_volts(note) return (note - 60) / 12 end
local function level_volts(p) return 1 + 4 * p end

-- Piecewise-linear lookup like IEnvGen on Env(levels, times); clamps outside the range.
local function env_at(levels, times, x)
  local t0 = 0
  if x <= t0 then return levels[1] end
  for i = 1, #times do
    local t1 = t0 + times[i]
    if x <= t1 then return levels[i] + (levels[i + 1] - levels[i]) * (x - t0) / times[i] end
    t0 = t1
  end
  return levels[#levels]
end

-- just draw's wave shape for x, with noise 2: the neutral timbre is its x = 0.5.
local function curve_at(x) return env_at({ 1, 0.5, 0, -0.5, -0.85 }, { 0.2, 0.2, 0.3, 0.3 }, x) end
local function ramp_at(x) return env_at({ 0.5, 0.5, 0.15, 0.04, 0.01 }, { 0.1, 0.3, 0.3, 0.3 }, x) end
local function depth_at(x, noise) return env_at({ 0, 0, 1.5, noise }, { 0.45, 0.3, 0.25 }, x) end

local scheduler, steps_of = Common.scheduler, Common.steps_of

-- Returns send(key, volts, fn): calls fn(volts) unless `key` last sent the same volts.
local function changes()
  local sent = {}
  return function(key, volts, fn)
    if sent[key] and math.abs(volts - sent[key]) <= THRESHOLD then return end
    sent[key] = volts
    fn(volts)
  end
end

-- Just Friends: each note plays the next of six channels; the end plays it again at level 0.
function IiVoice.Jf(opts)
  local ii, connected, settings = opts.ii, opts.connected, opts.settings
  local sched = scheduler(opts.clock)
  local v = {}
  local ch = 0
  local owed = {} -- channel -> the pitch of a release skipped while crow was away
  local pool = Common.pool(function(e) return e.chan end, function(e)
    if connected() then ii().play_voice(e.chan, e.pitch, 0) else owed[e.chan] = e.pitch end
  end)
  local release = pool.release

  local function run_note(i, note, at, seq, wait)
    if not wait(at) then return end
    if note.vel <= 0 or not connected() then return end
    local range = seq and seq.bend_range or 24
    local function pitch_of(bend) return pitch_volts(note.note + (bend - 8192) / 8192 * range) end
    local steps, first_bend = steps_of(note, false)
    ch = ch % 6 + 1
    local e = { seq = i, chan = ch, alive = true, pitch = pitch_of(first_bend or 8192) }
    pool.claim(e)
    owed[e.chan] = nil -- the new note replaces what was owed on its channel
    local send = changes()
    send("pitch", e.pitch, function() end) -- play_voice carries the pitch
    ii().play_voice(e.chan, e.pitch, level_volts(note.vel / 127))
    for _, s in ipairs(steps) do
      if not wait(at + s[1]) or not e.alive then return end
      e.pitch = pitch_of(s[3])
      if connected() then send("pitch", e.pitch, function(volts) ii().pitch(e.chan, volts) end) end
    end
    if not wait(at + note.dur) then return end
    release(e)
  end

  function v.play(i, note, at, seq)
    if note.kind ~= "midi" then return end
    sched.spawn(i, function(wait) run_note(i, note, at, seq, wait) end)
  end

  function v.release_seq(i) pool.release_seq(i, sched) end

  function v.release_all() pool.release_all(sched) end

  function v.apply_settings()
    if not connected() then return end
    ii().mode(settings.mode)
  end

  function v.first_use()
    if not connected() then return end
    v.apply_settings()
    ii().run_mode(1)
    ii().run(5 * math.log(NEUTRAL_RATIO, 2))
    for chan = 1, 6 do
      if owed[chan] then ii().play_voice(chan, owed[chan], 0) end
    end
    owed = {}
  end

  return v
end

-- w/syn: each note plays the next voice (within `voices`); while held, velocity follows pressure.
function IiVoice.Wsyn(opts)
  local ii, connected, settings = opts.ii, opts.connected, opts.settings
  local sched = scheduler(opts.clock)
  local v = {}
  local voice = 0
  local owed = {} -- voice -> true: a release skipped while crow was away
  local pool = Common.pool(function(e) return e.voice end, function(e)
    if not settings.hold then return end
    if connected() then ii().velocity(e.voice, 0) else owed[e.voice] = true end
  end)
  local release = pool.release

  local function run_note(i, note, at, seq, wait)
    if not wait(at) then return end
    if note.vel <= 0 or not connected() then return end
    local range = seq and seq.bend_range or 24
    local level = seq and seq.level or 1
    local function pitch_of(bend) return pitch_volts(note.note + (bend - 8192) / 8192 * range) end
    local steps, first_bend = steps_of(note, settings.hold)
    local n = settings.voices
    voice = (n and n > 0) and (voice % n + 1) or 1
    local e = { seq = i, voice = voice, alive = true }
    pool.claim(e)
    owed[e.voice] = nil
    local send = changes()
    local volts = pitch_of(first_bend or 8192)
    send("pitch", volts, function() end) -- play_voice carries the pitch and the velocity
    ii().play_voice(e.voice, volts, level_volts(note.vel / 127))
    for _, s in ipairs(steps) do
      if not wait(at + s[1]) or not e.alive then return end
      if connected() then
        if s[2] == 1 then
          send("pitch", pitch_of(s[3]), function(p) ii().pitch(e.voice, p) end)
        else
          send("velocity", level_volts(level * s[3] / 127), function(p) ii().velocity(e.voice, p) end)
        end
      end
    end
    if not wait(at + note.dur) then return end
    release(e)
  end

  function v.play(i, note, at, seq)
    if note.kind ~= "midi" then return end
    sched.spawn(i, function(wait) run_note(i, note, at, seq, wait) end)
  end

  function v.release_seq(i) pool.release_seq(i, sched) end

  function v.release_all() pool.release_all(sched) end

  function v.apply_settings()
    if not connected() then return end
    ii().voices(settings.voices)
    ii().lpg_time(settings.lpg_time)
    ii().lpg_symmetry(settings.lpg_symmetry)
    ii().fm_env(settings.fm_env)
    ii().ar_mode(settings.hold and 0 or 1)
  end

  -- The settings, then the neutral timbre: just draw's curve, ramp and FM index at x = 0.5, noise 2.
  function v.first_use()
    if not connected() then return end
    v.apply_settings()
    ii().curve(5 * curve_at(0.5))
    ii().ramp(10 * (0.5 - ramp_at(0.5)))
    ii().fm_index(math.min(depth_at(0.5, 2), 5))
    ii().fm_ratio(NEUTRAL_RATIO, 1)
    local voices = {}
    for n in pairs(owed) do voices[#voices + 1] = n end
    table.sort(voices)
    for _, n in ipairs(voices) do ii().velocity(n, 0) end
    owed = {}
  end

  return v
end

return { Jf = { new = IiVoice.Jf }, Wsyn = { new = IiVoice.Wsyn } }
