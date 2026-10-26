-- The sequencer: one routine per sequence on the norns clock. A sequence starts and stops on the
-- bar line. The routine wakes every STEP beats and hands the router each note of the pass LOOKAHEAD
-- beats before it starts, with its absolute beat, so only the notes about to sound hold a clock
-- coroutine (norns has 100 slots for them, shared by the whole script): a pass is never handed out
-- whole. A change to a playing sequence is planned from its next pass. The clock's beat is re-read at
-- every wake, so a beat counter that restarts or jumps starts the pass afresh on the next bar line;
-- the voices wait for each note's beat in short sleeps, so a tempo change moves nothing off its beat.
local Seq = {}

local EPS = 1e-9

-- how far ahead of a note's start it goes to the router, and how often the routine wakes to hand
-- notes out (the notes about to sound are then 0.125 to 0.25 beats early, never late)
local LOOKAHEAD = 0.25
local STEP = 0.125
-- a wake further than this many beats from the last one, or before it, is a jump of the beat counter
local JUMP = 1

-- clock: run(fn), sync(beats), cancel(id), get_beats(); model: ts_model; router: play(seq, note, at),
-- release_seq(seq); bpb: fn() -> beats per bar; now_beats: fn() -> the clock's beat (default clock.get_beats)
function Seq.new(opts)
  local clock, model, router = opts.clock, opts.model, opts.router
  local bpb = opts.bpb
  local now_beats = opts.now_beats or clock.get_beats
  local entries = {} -- seq -> { state, id, pass_start, pass_beats, plan }
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

  local function finish(seq)
    entries[seq] = nil
    router.release_seq(seq)
  end

  local function play_routine(seq, e)
    return function()
      local on_bar = false -- a jump landed on a bar line: it is the start of the pass already
      while true do
        if not on_bar then clock.sync(bpb()) end
        on_bar = false
        if e.state == "stopping" then finish(seq); return end
        local bar = bar_now() -- the start of the pass
        e.state = "playing"
        local line = bar      -- the last bar line reached
        local prev = bar      -- the beat of the last wake
        local plan, i
        local function new_pass()
          e.pass_start = bar
          e.pass_beats = model.loop_beats(seq, bpb())
          plan, i = pass_notes(seq, e), 1
        end
        new_pass()
        while true do
          -- hand out what starts within LOOKAHEAD of this wake
          while plan[i] and bar + plan[i].start <= prev + LOOKAHEAD + EPS do
            router.play(seq, plan[i], bar + plan[i].start)
            i = i + 1
          end
          clock.sync(STEP)
          local at = now_beats()
          if at < prev - EPS or at - prev > JUMP then
            -- the beat counter jumped: what is still waiting is on the old timeline, so it goes
            -- and the pass is handed out again from the next bar line (a wake on a bar line is it:
            -- sync would wait for the one after)
            router.release_seq(seq)
            local n = bpb()
            on_bar = math.abs(at / n - math.floor(at / n + 0.5)) * n < EPS
            break
          end
          prev = at
          if at >= line + bpb() - EPS then
            if e.state == "stopping" then finish(seq); return end
            line = line + bpb()
            if line - bar >= e.pass_beats - EPS then
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
      e.id = clock.run(play_routine(seq, e))
    elseif e.state == "starting" then
      clock.cancel(e.id)
      entries[seq] = nil
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
    if e then
      clock.cancel(e.id)
      entries[seq] = nil
    end
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

  function self.changed(seq)
    local e = entries[seq]
    if e then e.plan = nil end
  end

  return self
end

return Seq
