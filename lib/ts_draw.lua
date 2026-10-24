-- Drawing: pen events become strokes on the selected sequence. The upper pen button clears it
-- (a second press within 1 s, on the same sequence, confirms); the lower undoes the last stroke. Both buttons are
-- ignored while the tip is down. No norns globals; the caller passes everything.
local Draw = {}

local CLEAR_WINDOW = 1.0 -- seconds

-- model: ts_model; set: fn() -> { selected = 1-based or nil, sequences = {...} };
-- now: fn() -> seconds; bpb: fn() -> beats per bar (default 4);
-- on_change(seq): the sequence's strokes changed; on_new(seq): a sequence was made for a stroke
-- on the empty page, to be added and selected by the caller (returning false refuses it).
function Draw.new(opts)
  local model, set, now = opts.model, opts.set, opts.now
  local bpb = opts.bpb or function() return 4 end
  local on_change = opts.on_change or function() end
  local on_new = opts.on_new or function() end
  local cap = nil        -- the stroke in progress
  local hover = nil      -- {x, y} while the pen is in range and up
  local clear_at = nil   -- { seq, at }: the first clear press, with the sequence it was made on
  local self = {}

  local function selected_seq()
    local s = set()
    return s.selected and s.sequences[s.selected] or nil
  end

  local function finish()
    if not cap then return end
    local c = cap
    cap = nil
    c.seq.strokes[#c.seq.strokes + 1] = model.finish_stroke(c)
    on_change(c.seq)
  end

  local function pen_down(d)
    finish() -- a stroke left open (the tablet changed under it) is closed first
    local seq = selected_seq()
    if not seq then
      seq = model.new_sequence(set().sequences)
      if on_new(seq) == false then return end
    end
    hover = nil
    cap = model.begin_stroke(seq, bpb(), d.x, d.y, d.p)
  end

  function self.pen(evt, d)
    if evt == "penDown" then pen_down(d)
    elseif evt == "penMove" then
      if cap then model.extend_stroke(cap, d.x, d.y, d.p) end
    elseif evt == "penUp" then
      finish()
    elseif evt == "hover" then
      hover = { x = d.x, y = d.y }
    elseif evt == "hoverOff" then
      hover = nil
    elseif evt == "octaveUp" then
      if cap then return end
      local seq = selected_seq()
      if not seq then return end
      local t = now()
      -- the second press counts only on the sequence the first was made on (E1 may have moved on)
      if clear_at and clear_at.seq == seq and t - clear_at.at <= CLEAR_WINDOW then
        clear_at = nil
        seq.strokes = {}
        on_change(seq)
      else
        clear_at = { seq = seq, at = t }
      end
    elseif evt == "octaveDown" then
      if cap then return end
      local seq = selected_seq()
      if seq and #seq.strokes > 0 then
        seq.strokes[#seq.strokes] = nil
        on_change(seq)
      end
    end
  end

  -- True while a first clear press waits for its second, and its sequence is still the selected one.
  function self.pending_clear()
    return clear_at ~= nil and clear_at.seq == selected_seq() and now() - clear_at.at <= CLEAR_WINDOW
  end

  function self.hover() return hover end
  function self.cap() return cap end

  return self
end

return Draw
