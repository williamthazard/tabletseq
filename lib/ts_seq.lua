-- The sequencer: one routine per sequence on the norns clock. A sequence starts and stops on the
-- bar line. The routine wakes every STEP beats and hands the router each note of the pass LOOKAHEAD
-- beats before it starts, with its absolute beat, so only the notes about to sound hold a clock
-- coroutine (norns has 100 slots for them, shared by the whole script): a pass is never handed out
-- whole. A change to a playing sequence is planned from its next pass. The clock's beat is re-read at
-- every wake, so a beat counter that restarts or jumps starts the pass afresh on the next bar line;
-- the voices wait for each note's beat in short sleeps, so a tempo change moves nothing off its beat.
-- A wake that is merely late (the main thread was busy) is no jump: the beats it advanced match the
-- wall time that passed. Notes that fell due during the stall and are over, a STALE past their
-- start, are skipped; one that would still be sounding plays late.
-- A routine is never clock.cancel'ed (a wake matron has already queued for it would then resume a
-- coroutine that is gone): stopping flags it, and it returns at its next wake, at most a bar away
-- while it waits to start and STEP beats away while it plays.
local Seq = {}

local EPS = 1e-9

-- how far ahead of a note's start it goes to the router, and how often the routine wakes to hand
-- notes out (the notes about to sound are then 0.125 to 0.25 beats early, never late)
local LOOKAHEAD = 0.25
local STEP = 0.125
-- a wake further than this many beats from the last one, or before it, is a jump of the beat counter
local JUMP = 1
-- with the wall clock: a wake is a jump when the beats went back by more than BACK, or ran ahead of
-- the elapsed time by more than JUMP
local BACK = 0.01
-- a note this far past its start when a late wake finds it is skipped
local STALE = 0.25

-- clock: run(fn), sync(beats), get_beats(); model: ts_model; router: play(seq, note, at),
-- release_seq(seq); bpb: fn() -> beats per bar; now_beats: fn() -> the clock's beat (default clock.get_beats);
-- now_secs: fn() -> wall-clock seconds, optional (without it a wake more than JUMP beats on is a jump);
-- beat_sec: fn() -> seconds per beat (default clock.get_beat_sec)
function Seq.new(opts)
  local clock, model, router = opts.clock, opts.model, opts.router
  local bpb = opts.bpb
  local now_beats = opts.now_beats or clock.get_beats
  local now_secs = opts.now_secs
  local beat_sec = opts.beat_sec or clock.get_beat_sec
  local skipped = 0
  local entries = {} -- seq -> { state, pass_start, pass_beats, plan }
  local self = {}

  -- one pass of the loop; the plan is kept until the sequence changes
  local function pass_notes(seq, e)
    if not e.plan then e.plan = model.notes_for(seq, bpb()) end
    return e.plan
  end

  -- the bar line nearest the clock's beat: only used after a sync(bpb), because the beat counter can
  -- restart or jump (a clock reset, a MIDI Start, a Link session merge) and a counted bar would be stale
  local function bar_now()
    local n = bpb()
    return math.floor(now_beats() / n + 0.5) * n
  end

  -- did the beat counter jump between two wakes? `at` and `secs` are now, `prev` and `prev_secs` the last wake
  local function jumped(at, secs, prev, prev_secs)
    if not now_secs then return at < prev - EPS or at - prev > JUMP end
    local explained = math.max(secs - prev_secs, 0) / beat_sec()
    return at < prev - BACK or at - prev - explained > JUMP
  end

  -- stops the routine without a clock.cancel: it sees the flag when it next wakes
  local function cancel(seq, e)
    e.cancelled = true
    entries[seq] = nil
  end

  local function finish(seq)
    entries[seq] = nil
    router.release_seq(seq)
  end

  local function play_routine(seq, e)
    return function()
      local on_bar = false -- a jump landed on a bar line: it is the start of the pass already
      while true do
        if not on_bar then clock.sync(bpb()) end
        if e.cancelled then return end
        on_bar = false
        if e.state == "stopping" then finish(seq); return end
        local bar = bar_now() -- the start of the pass
        e.state = "playing"
        local line = bar      -- the last bar line reached
        -- the beat of the last wake: read with its seconds, so a late first wake is no jump
        local prev = now_secs and math.max(bar, now_beats()) or bar
        local prev_secs = now_secs and now_secs()
        local plan, i
        local function new_pass()
          e.pass_start = bar
          e.pass_beats = model.loop_beats(seq, bpb())
          plan, i = pass_notes(seq, e), 1
        end
        new_pass()
        -- hand out what starts by `limit`; a note STALE past its start and wholly over (a late wake)
        -- is skipped, one that would still be sounding plays late
        local function hand_out(limit)
          while plan[i] and bar + plan[i].start <= limit + EPS do
            if now_secs and bar + plan[i].start < prev - STALE
                and bar + plan[i].start + (plan[i].dur or 0) < prev then
              skipped = skipped + 1
            else
              router.play(seq, plan[i], bar + plan[i].start)
            end
            i = i + 1
          end
        end
        while true do
          hand_out(prev + LOOKAHEAD) -- what starts within LOOKAHEAD of this wake
          clock.sync(STEP)
          if e.cancelled then return end
          local at, secs = now_beats(), now_secs and now_secs()
          if jumped(at, secs, prev, prev_secs) then
            -- the beat counter jumped: what is still waiting is on the old timeline, so it goes
            -- and the pass is handed out again from the next bar line (a wake on a bar line is it:
            -- sync would wait for the one after)
            router.release_seq(seq)
            local n = bpb()
            on_bar = math.abs(at / n - math.floor(at / n + 0.5)) * n < EPS
            break
          end
          prev, prev_secs = at, secs
          -- a late wake can pass several bar lines
          while at >= line + bpb() - EPS do
            if e.state == "stopping" then finish(seq); return end
            line = line + bpb()
            if line - bar >= e.pass_beats - EPS then
              if now_secs then hand_out(prev + LOOKAHEAD) end -- the rest of the pass that ends
              bar = line
              new_pass()
            end
          end
        end
      end
    end
  end

  function self.state(seq)
    local e = entries[seq]
    return e and e.state or "stopped"
  end

  function self.toggle(seq)
    local e = entries[seq]
    if not e then
      e = { state = "starting" }
      entries[seq] = e
      clock.run(play_routine(seq, e))
    elseif e.state == "starting" then
      cancel(seq, e)
    elseif e.state == "playing" then
      e.state = "stopping"
    else -- stopping: keep playing
      e.state = "playing"
    end
  end

  -- the beat within the loop, or nil unless it plays (or waits to stop)
  function self.playhead(seq)
    local e = entries[seq]
    if not e or not e.pass_start then return nil end
    return (now_beats() - e.pass_start) % e.pass_beats
  end

  function self.stop_now(seq)
    local e = entries[seq]
    if e then cancel(seq, e) end
    router.release_seq(seq)
  end

  function self.stop_all()
    local all = {}
    for seq in pairs(entries) do all[#all + 1] = seq end
    for _, seq in ipairs(all) do self.stop_now(seq) end
  end

  -- Does the sequencer allow a new beats-per-bar? The caller stores it. Refused while anything
  -- plays or waits.
  function self.set_bpb(n)
    if next(entries) ~= nil then return false end
    return math.type(n) == "integer" and n >= 1 and n <= 16
  end

  -- how many notes have been skipped as stale after a late wake
  function self.skipped() return skipped end

  function self.changed(seq)
    local e = entries[seq]
    if e then e.plan = nil end
  end

  return self
end

return Seq
