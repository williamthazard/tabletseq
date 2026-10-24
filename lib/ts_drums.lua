-- The drum rack: one shared kit, loaded from a folder into engine slots 1-16. Slot n plays rows of
-- note 35 + n, so note 36 is the first sample. Dependencies are passed in; no norns globals; Lua 5.3.
--   engine_voice: load(slot, path), clear(slot), play(seq_index, note, at)
--   scandir(dir) -> file names or nil; file_info(path) -> truthy when the file exists.
local Drums = {}

local MAX = 16
local AUDIO = { wav = true, aif = true, aiff = true, flac = true }

function Drums.new(opts)
  local ev, scandir, file_info = opts.engine_voice, opts.scandir, opts.file_info
  local d = {}
  local files = {} -- slot -> file name

  -- Loads the audio files beside `path` (the file picked), sorted by name, up to 16. Returns the count.
  function d.load_folder(path)
    local dir = type(path) == "string" and path:match("^(.*/)")
    local listed = dir and scandir(dir)
    local found = {}
    for _, name in ipairs(listed or {}) do
      local ext = name:match("^[^.].*%.(%w+)$")
      if ext and AUDIO[ext:lower()] and file_info(dir .. name) then found[#found + 1] = name end
    end
    table.sort(found)
    for slot = 1, MAX do
      local name = found[slot]
      files[slot] = name
      if name then ev.load(slot, dir .. name) else ev.clear(slot) end
    end
    return d.count()
  end

  function d.count()
    local n = 0
    for slot = 1, MAX do
      if files[slot] then n = n + 1 end
    end
    return n
  end

  function d.names()
    local out = {}
    for slot = 1, MAX do
      if files[slot] then out[#out + 1] = files[slot] end
    end
    return out
  end

  -- A hit on a row with no sample sends nothing.
  function d.play(seq_index, note, at)
    if note.kind == "hit" and files[note.note - 35] then ev.play(seq_index, note, at) end
  end

  return d
end

return Drums
