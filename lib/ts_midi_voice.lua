-- The MIDI voices: the synth and the drum kit, played from the MIDI plan (a port of the Mac's lib/midi.scd).
-- `dev` returns the norns midi device (colon methods: note_on, note_off, pitchbend, channel_pressure, cc)
-- or nil; it is called on every send, so a device change is picked up. `clock` is norns's clock
-- (run, sleep, cancel, get_beats, get_beat_sec). Both are passed in. No norns globals; Lua 5.3 compatible.
-- Channels are 1-16. A kit hit is a plan note with its fixed hit length as `dur` and no bends.
local MidiVoice = {}

local CENTRE = 8192

function MidiVoice.new(opts)
  local dev, clock = opts.dev, opts.clock
  local v = {}
  local sounding = {} -- sequence index -> list of { chan, note, alive }
  local waiting = {}  -- sequence index -> { [job] = true } of notes not yet finished
  local used = {}     -- channels that have sent anything
  local bend_of = {}  -- channel -> the last bend sent

  local function send(name, ...)
    local d = dev()
    if d then d[name](d, ...) end
  end

  local function send_bend(chan, value)
    if bend_of[chan] == value then return end
    bend_of[chan] = value
    send("pitchbend", value, chan)
  end

  local function busy(chan)
    for _, list in pairs(sounding) do
      for _, e in ipairs(list) do
        if e.alive and e.chan == chan then return true end
      end
    end
    return false
  end

  local function end_entry(e)
    if e.alive then
      e.alive = false
      send("note_off", e.note, 0, e.chan)
    end
  end

  local function sleep_until(beat)
    local rest = beat - clock.get_beats()
    if rest > 1e-9 then clock.sleep(rest * clock.get_beat_sec()) end
  end

  -- note-on at beat `at`, then the plan's bends and pressures at their beats, then the note-off.
  -- A note still sounding at this pitch ends first (its own note-off is then dropped). A note
  -- without bends starts from a centred bend if a finished glide left the channel bent, unless it
  -- joins notes still sounding there; notes with the same bends send each step once (chords).
  local function run_note(i, note, at, chan)
    sleep_until(at)
    if note.vel <= 0 then return end
    for _, list in pairs(sounding) do
      for _, e in ipairs(list) do
        if e.chan == chan and e.note == note.note then end_entry(e) end
      end
    end
    local list = sounding[i]
    if not list then list = {}; sounding[i] = list end
    for k = #list, 1, -1 do
      if not list[k].alive then table.remove(list, k) end
    end
    local entry = { chan = chan, note = note.note, alive = true }
    list[#list + 1] = entry
    used[chan] = true
    -- steps due with the note come first, bend then pressure
    local steps = {}
    for _, b in ipairs(note.bends) do steps[#steps + 1] = { b[1], 1, b[2] } end
    for _, p in ipairs(note.pressures) do steps[#steps + 1] = { p[1], 2, p[2] } end
    table.sort(steps, function(a, b)
      if a[1] ~= b[1] then return a[1] < b[1] end
      return a[2] < b[2]
    end)
    local n = 1
    local function play_steps_due(upto)
      while steps[n] and steps[n][1] <= upto + 1e-9 do
        local s = steps[n]
        n = n + 1
        if s[2] == 1 then send_bend(chan, s[3]) else send("channel_pressure", s[3], chan) end
      end
    end
    if #note.bends == 0 and bend_of[chan] ~= nil and bend_of[chan] ~= CENTRE then
      local others = false
      for _, list2 in pairs(sounding) do
        for _, e in ipairs(list2) do
          if e ~= entry and e.alive and e.chan == chan then others = true end
        end
      end
      if not others then send_bend(chan, CENTRE) end
    end
    play_steps_due(0)
    send("note_on", note.note, note.vel, chan)
    while steps[n] do
      sleep_until(at + steps[n][1])
      if not entry.alive then return end
      play_steps_due(steps[n][1])
    end
    sleep_until(at + note.dur)
    end_entry(entry)
  end

  function v.play(seq_index, note, at, channel)
    if note.kind ~= "midi" then return end
    local job = {}
    waiting[seq_index] = waiting[seq_index] or {}
    local jobs = waiting[seq_index]
    job.id = clock.run(function()
      run_note(seq_index, note, at, channel)
      job.done = true
      jobs[job] = nil
    end)
    if not job.done then jobs[job] = true end
  end

  local function cancel(i)
    for job in pairs(waiting[i] or {}) do clock.cancel(job.id) end
    waiting[i] = nil
  end

  function v.release_seq(i)
    cancel(i)
    local mine = sounding[i] or {}
    sounding[i] = nil
    local chans = {}
    for _, e in ipairs(mine) do
      if e.alive then chans[e.chan] = true end
      end_entry(e)
    end
    -- a glide this sequence left bent is centred once nothing else sounds on its channel
    for chan in pairs(chans) do
      if not busy(chan) and bend_of[chan] ~= nil and bend_of[chan] ~= CENTRE then send_bend(chan, CENTRE) end
    end
  end

  function v.release_all()
    for i in pairs(waiting) do cancel(i) end
    local order = {}
    for i in pairs(sounding) do order[#order + 1] = i end
    table.sort(order)
    for _, i in ipairs(order) do
      for _, e in ipairs(sounding[i]) do end_entry(e) end
    end
    sounding = {}
    local chans = {}
    for chan in pairs(used) do chans[#chans + 1] = chan end
    table.sort(chans)
    for _, chan in ipairs(chans) do
      send("cc", 123, 0, chan)
      bend_of[chan] = CENTRE
      send("pitchbend", CENTRE, chan)
    end
  end

  return v
end

return MidiVoice
