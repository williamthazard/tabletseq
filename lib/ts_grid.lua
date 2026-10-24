-- The grid (spec 5.5): row 1 starts and stops sequence x, row 2 selects it. `g` is norns's grid
-- (or a stub with cols, led, all, refresh), called with a colon. No norns globals; Lua 5.3.
local Grid = {}

local STOPPED, PLAYING, DIM, SELECTED = 3, 15, 2, 10

function Grid.new(opts)
  local g, set, seq = opts.g, opts.set, opts.seq
  local self = {}

  -- the sequence a key's column stands for, or nil past the sequences or the grid's width
  local function sequence_at(x)
    if x < 1 or x > (g.cols or 16) then return nil end
    return set().sequences[x]
  end

  function self.key(x, y, z)
    if z ~= 1 then return end
    local s = sequence_at(x)
    if not s then return end
    if y == 1 then
      seq.toggle(s)
    elseif y == 2 then
      set().selected = x
    end
  end

  -- phase runs 0 to 1 over one blink: bright at 0, dim at 0.5
  function self.redraw(phase)
    local cur = set()
    g:all(0)
    for x = 1, math.min(g.cols or 16, #cur.sequences) do
      local state = seq.state(cur.sequences[x])
      local level = STOPPED
      if state == "playing" then
        level = PLAYING
      elseif state == "starting" or state == "stopping" then
        level = STOPPED + math.floor(12 * math.abs(1 - 2 * (phase % 1)) + 0.5)
      end
      g:led(x, 1, level)
      g:led(x, 2, x == cur.selected and SELECTED or DIM)
    end
    g:refresh()
  end

  return self
end

return Grid
