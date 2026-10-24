-- The sequencer: one routine per sequence on the norns clock. A sequence starts and stops on the
-- bar line; each pass hands its notes to the router with their absolute beats. A change to a
-- playing sequence is planned from its next pass. The bar line is re-read from the clock at every
-- sync, so a beat counter that restarts or jumps starts the pass afresh on the new bar line; the
-- voices wait for each note's beat in short sleeps, so a tempo change moves nothing off its beat.
local Seq = {}

local EPS = 1e-9

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

  -- the bar line nearest the clock's beat: re-read after every sync, because the beat counter can
  -- restart or jump (a clock reset, a MIDI Start, a Link session merge) and a counted bar would be stale
  local function bar_now()
    local n = bpb()
    return math.floor(now_beats() / n + 0.5) * n
  end

  local function play_routine(seq, e)
    return function()
      clock.sync(bpb())
      local bar = bar_now()
      e.state = "playing"
      while true do
        e.pass_start = bar
        e.pass_beats = model.loop_beats(seq, bpb())
        for _, note in ipairs(pass_notes(seq, e)) do
          router.play(seq, note, bar + note.start)
        end
        local elapsed = 0 -- beats of this pass gone by, counted in whole bars
        repeat
          clock.sync(bpb())
          local at = bar_now()
          if e.state == "stopping" then
            entries[seq] = nil
            router.release_seq(seq)
            return
          end
          if math.abs(at - (bar + bpb())) > EPS then
            -- the beat counter jumped: what is still waiting is on the old timeline, so it goes
            -- and the pass is handed out again from the new bar line
            router.release_seq(seq)
            bar = at
            break
          end
          bar = at
          elapsed = elapsed + bpb()
        until elapsed >= e.pass_beats - EPS
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
