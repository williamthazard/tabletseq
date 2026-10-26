-- What the crow, Just Friends and w/syn voices share: the clock scheduler with per-sequence job
-- tracking, the building of a note's later steps, and the occupant bookkeeping of a rotating pool.
-- Everything is passed in; no norns globals; Lua 5.3 compatible.
local Common = {}

Common.EPS = 1e-9

-- The longest stretch of beats one clock.sleep covers (see sleep_until).
Common.CHUNK = 0.25

-- Waits until the clock reaches the absolute `beat`. norns's clock.sleep takes SECONDS, so a single
-- long sleep would keep its wall-clock time through a tempo change (an edit, a Link peer, an external
-- clock) and wake at the wrong beat. The wait is therefore taken in short stretches, each worked out
-- from the clock's beat and tempo as they are then. Returns false, at the first wake that sees it,
-- when `job` has been cancelled (see scheduler): the caller then returns at once.
function Common.sleep_until(clock, beat, job)
  while true do
    if job and job.cancelled then return false end
    local rest = beat - clock.get_beats()
    if rest <= Common.EPS then return true end
    clock.sleep(math.min(rest, Common.CHUNK) * clock.get_beat_sec())
  end
end

-- Scheduling on `clock` (run, sleep, get_beats, get_beat_sec); jobs are tracked per sequence. A job is
-- never clock.cancel'ed: norns's clock.cancel forgets the coroutine, but a wake matron has already
-- queued for it still arrives, and clock.resume then fails on the missing thread. Cancelling sets a
-- flag instead; the job sees it at its next wake (within CHUNK beats) and returns, holding its clock
-- slot until then. spawn(i, fn) calls fn(wait), where wait(beat) sleeps until the beat and returns
-- false when the job was cancelled: `if not wait(at) then return end`.
function Common.scheduler(clock)
  local s = { waiting = {} }

  function s.spawn(i, fn)
    local job = {}
    s.waiting[i] = s.waiting[i] or {}
    local jobs = s.waiting[i]
    local function wait(beat) return Common.sleep_until(clock, beat, job) end
    clock.run(function()
      fn(wait)
      job.done = true
      jobs[job] = nil
    end)
    if not job.done then jobs[job] = true end
  end

  function s.cancel(i)
    for job in pairs(s.waiting[i] or {}) do job.cancelled = true end
    s.waiting[i] = nil
  end

  function s.cancel_all()
    for i in pairs(s.waiting) do s.cancel(i) end
  end

  return s
end

-- A note's later steps: { beat from start, 1 = pitch | 2 = pressure, value }, sorted. Steps at the
-- note's own start are left out: the note starts with its first bend (returned) and its velocity.
function Common.steps_of(note, want_pressure)
  local steps, first_bend = {}, nil
  for _, b in ipairs(note.bends) do
    if b[1] <= Common.EPS then first_bend = b[2] else steps[#steps + 1] = { b[1], 1, b[2] } end
  end
  if want_pressure then
    for _, p in ipairs(note.pressures) do
      if p[1] > Common.EPS then steps[#steps + 1] = { p[1], 2, p[2] } end
    end
  end
  table.sort(steps, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  return steps, first_bend
end

-- The entries sounding on a pool's slots. `slot_of(e)` names an entry's slot; `sound_off(e)` stops its
-- sound (called once, only for a live entry). Returns release(e), claim(e) (releases a slot's previous
-- occupant, then takes it), release_seq(i, sched) and release_all(sched), the last two also cancelling
-- the scheduler's unplayed notes.
function Common.pool(slot_of, sound_off)
  local p, occupant = {}, {}

  function p.release(e)
    if not e.alive then return end
    e.alive = false
    if occupant[slot_of(e)] == e then occupant[slot_of(e)] = nil end
    sound_off(e)
  end

  function p.claim(e)
    local slot = slot_of(e)
    if occupant[slot] then p.release(occupant[slot]) end
    occupant[slot] = e
  end

  function p.release_seq(i, sched)
    sched.cancel(i)
    for _, e in pairs(occupant) do
      if e.seq == i then p.release(e) end
    end
  end

  function p.release_all(sched)
    sched.cancel_all()
    for _, e in pairs(occupant) do p.release(e) end
  end

  return p
end

return Common
