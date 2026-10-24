-- The settings that are not per sequence, as norns params so PSETs save and load them: beats per
-- bar, the MIDI device, the JF and w/syn module settings, the drum folder, the tablet and flip.
-- `p` is the paramset (norns's `params`). init() ends with params:bang(), so the defaults reach everything.
-- deps = {
--   seq            ts_seq (set_bpb),
--   jf, wsyn       the ii voices (apply_settings),
--   jf_settings, wsyn_settings   the live tables those voices read,
--   used(name)     has a sequence used the "jf" / "wsyn" voice this session,
--   midi_connect   fn(port) -> device (default midi.connect),  set_midi(device),  ports() -> names,
--   drums          ts_drums (load_folder),  tablet  ts_tablet (select, set_flip),
--   notify(text)   shows a message }
-- Returns { after_read = fn }. Uses the norns globals `controlspec`, `_path` and (by default) `midi`.
-- Lua 5.3 compatible.
local Params = {}

function Params.add(p, deps)
  local connect = deps.midi_connect or function(port) return midi.connect(port) end
  local api = {}

  p:add_separator("ts_play", "tabletseq")

  -- Beats per bar changes only while nothing plays. A refused value is put back and remembered: a PSET
  -- read sets its params before action_read stops the sequences, and after_read then applies it.
  local bpb, refused = 4, nil
  p:add_number("beats_per_bar", "beats per bar", 1, 16, 4)
  p:set_action("beats_per_bar", function(v)
    if v == bpb then
      refused = nil
    elseif deps.seq.set_bpb(v) then
      bpb, refused = v, nil
    else
      refused = v
      p:set("beats_per_bar", bpb, true)
      deps.notify("stop to change beats per bar")
    end
  end)

  function api.after_read()
    local want = refused
    refused = nil
    if want then p:set("beats_per_bar", want) end
  end

  p:add_separator("ts_midi", "MIDI")
  p:add_number("midi_device", "device", 1, 16, 1, function(param)
    local n = param:get()
    return (deps.ports and deps.ports()[n]) or ("port " .. n)
  end)
  p:set_action("midi_device", function(n) deps.set_midi(connect(n)) end)

  p:add_separator("ts_ii", "crow ii")
  -- A module's setting is stored at once and sent only once a sequence has used that voice; the voice
  -- sends everything itself on its first use.
  local function ii_setting(name, apply)
    return function(v)
      apply(deps[name .. "_settings"], v)
      if deps.used(name) then deps[name].apply_settings() end
    end
  end

  p:add_option("jf_mode", "JF mode", { "normal", "synthesis" }, 2)
  p:set_action("jf_mode", ii_setting("jf", function(s, i) s.mode = i - 1 end))

  p:add_number("wsyn_voices", "w/syn voices", 0, 4, 4)
  p:set_action("wsyn_voices", ii_setting("wsyn", function(s, v) s.voices = v end))
  p:add_control("wsyn_lpg_time", "w/syn LPG time", controlspec.new(-5, 5, "lin", 0, 0, "V"))
  p:set_action("wsyn_lpg_time", ii_setting("wsyn", function(s, v) s.lpg_time = v end))
  p:add_control("wsyn_lpg_symmetry", "w/syn LPG symmetry", controlspec.new(-5, 5, "lin", 0, 0, "V"))
  p:set_action("wsyn_lpg_symmetry", ii_setting("wsyn", function(s, v) s.lpg_symmetry = v end))
  p:add_option("wsyn_hold", "w/syn envelope", { "hold", "pluck" }, 1)
  p:set_action("wsyn_hold", ii_setting("wsyn", function(s, i) s.hold = (i == 1) end))

  p:add_separator("ts_drums", "drum rack")
  -- Picking any file loads the audio files of its folder. "-" is norns's unset file and a trailing
  -- slash a bare folder: neither names a sample.
  p:add_file("drum_folder", "drum folder", _path.audio)
  p:set_action("drum_folder", function(path)
    if type(path) == "string" and path ~= "-" and path ~= "" and path:sub(-1) ~= "/" then
      deps.drums.load_folder(path)
    end
  end)

  p:add_separator("ts_tablet", "tablet")
  p:add_option("tablet", "tablet", { "auto", "port 1", "port 2", "port 3", "port 4" }, 1)
  p:set_action("tablet", function(i) deps.tablet:select(i > 1 and i - 1 or nil) end)
  p:add_binary("flip", "flip 180", "toggle", 0)
  p:set_action("flip", function(v) deps.tablet:set_flip(v == 1) end)

  return api
end

return Params
