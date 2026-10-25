-- The settings that are not per sequence, as norns params so PSETs save and load them: beats per
-- bar, the MIDI device, the JF and w/syn module settings, the drum folder, the tablet and flip, and the
-- effects (just draw's reverb, delay and Carter's delay; the sends are per sequence).
-- `p` is the paramset (norns's `params`). init() ends with params:bang(), so the defaults reach everything.
-- deps = {
--   seq            ts_seq (set_bpb),
--   jf, wsyn       the ii voices (apply_settings),
--   jf_settings, wsyn_settings   the live tables those voices read,
--   used(name)     has a sequence used the "jf" / "wsyn" voice this session,
--   midi_connect   fn(port) -> device (default midi.connect),  set_midi(device),  ports() -> names,
--   drums          ts_drums (load_folder),  tablet  ts_tablet (select, set_flip),
--   notify(text)   shows a message,
--   beat_sec()     seconds per beat (default clock.get_beat_sec) }
-- Returns { after_read = fn, resync_delay = fn }. Uses the norns globals `controlspec`, `_path`, `engine`
-- and (by default) `midi` and `clock`.
-- Lua 5.3 compatible.
local Params = {}

-- Delay sync: option 1 is free; the rest are beat counts (schicksalslied 2's list).
local SYNC_OPTIONS = { "free", "1/16", "1/12", "1/8", "1/6", "3/16", "1/4", "1/3", "3/8", "1/2",
  "2/3", "3/4", "1", "4/3", "3/2", "2", "8/3", "3", "4", "5", "6", "7", "8" }
local SYNC_BEATS = { 1/16, 1/12, 1/8, 1/6, 3/16, 1/4, 1/3, 3/8, 1/2, 2/3, 3/4, 1, 4/3, 3/2, 2,
  8/3, 3, 4, 5, 6, 7, 8 }
local MAX_DELAY = 8

-- The delay time in seconds: the delay_time param while free, else the beats at beat_sec,
-- capped at the engine's longest delay.
function Params.delay_time_now(p, beat_sec)
  local i = p:get("delay_sync")
  if i == 1 then return p:get("delay_time") end
  return math.min(SYNC_BEATS[i - 1] * beat_sec, MAX_DELAY)
end

function Params.add(p, deps)
  local connect = deps.midi_connect or function(port) return midi.connect(port) end
  local api = {}
  local beat_sec = deps.beat_sec or function() return clock.get_beat_sec() end

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

  -- The engine's output level, ahead of its -1 dBFS limiter. Saved in PSETs.
  p:add_control("engine_level", "engine level", controlspec.new(-60, 6, "lin", 0, -10, "dB"))
  p:set_action("engine_level", function(db) engine.set_out_level(10 ^ (db / 20)) end)

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

  -- Reverb and delay live in the engine, after the sequences' groups; each sequence's sends feed them. Each action sends its value to the
  -- engine command of the same name; params:bang() then brings the engine in line.
  p:add_group("effects", "effects", 9)
  local function fx(id, name, min, max, warp, default, units, command)
    p:add_control(id, name, controlspec.new(min, max, warp, 0, default, units))
    p:set_action(id, function(v) engine[command](v) end)
  end
  -- delay_sync (default "1", one beat) follows the norns clock; delay_time is the free setting,
  -- shown only while free. api.resync_delay re-sends the synced time when the tempo changes.
  p:add_option("delay_sync", "delay sync", SYNC_OPTIONS, 13)
  p:add_control("delay_time", "delay time", controlspec.new(0.01, 8, "lin", 0, 0.3, "s"))
  p:set_action("delay_time", function(v)
    if p:get("delay_sync") == 1 then engine.set_delay_time(v) end
  end)
  p:set_action("delay_sync", function(i)
    if i == 1 then p:show("delay_time") else p:hide("delay_time") end
    if _menu then _menu.rebuild_params() end
    engine.set_delay_time(Params.delay_time_now(p, beat_sec()))
  end)
  fx("delay_decay", "delay decay", 0.01, 60, "exp", 0.5, "s", "set_delay_decay")
  fx("delay_level", "delay level", 0, 2, "lin", 1, "", "set_delay_level")
  fx("delay_to_reverb", "delay to reverb", 0, 1, "lin", 1, "", "set_delay_to_reverb")
  fx("delay_to_dry", "delay to dry", 0, 1, "lin", 0, "", "set_delay_to_dry")
  fx("reverb_room", "reverb room", 0, 1, "lin", 0.5, "", "set_reverb_room")
  fx("reverb_damp", "reverb damp", 0, 1, "lin", 0.5, "", "set_reverb_damp")
  fx("reverb_level", "reverb level", 0, 2, "lin", 1, "", "set_reverb_level")

  -- Carter's delay: schicksalslied 2's granular chain, ported. It stays unallocated until grains_on
  -- is switched on. Each action sends its value to the engine, which stores it until the chain
  -- is allocated; params:bang() then brings the engine in line.
  p:add_group("carters_delay", "carter's delay", 36)
  p:add_binary("grains_on", "carter's delay", "toggle", 0)
  p:set_action("grains_on", function(v) engine.grains_on(v) end)
  local function grain(id, name, min, max, warp, step, default, units, command)
    p:add_control(id, name, controlspec.new(min, max, warp, step, default, units))
    p:set_action(id, function(v) engine[command](v) end)
  end
  local function grain_option(id, name, options, command)
    p:add_option(id, name, options, 1)
    p:set_action(id, function(i) engine[command](i - 1) end)
  end
  local OFF_ON = { "off", "on" }
  grain("grains_level", "delay level", 0, 1, "lin", 0.01, 0.3, "", "set_grains_level")

  p:add_separator("ts_grain_engine", "granular engine")
  grain_option("granular_freeze", "granular freeze", OFF_ON, "set_grains_freeze")
  -- The delay buffer is not saved, so recalling "on" would bring the chain up frozen on silence.
  p:set_save("granular_freeze", false)
  grain("buffer_preservation", "buffer preservation", 0, 1, "lin", 0.01, 0, "", "set_grains_rec_pre")
  grain_option("grain_window", "grain window", { "hann", "percussive", "swell", "reverse swell" },
    "set_grains_window")
  grain("grain_sync_distribution", "grain sync distribution", 0, 1, "lin", 0.01, 1, "",
    "set_grains_sync")
  grain("granular_cutoff_ceiling", "grain cutoff ceiling", 200, 16000, "exp", 1, 16000, "Hz",
    "set_grains_cutoff_ceiling")
  grain("grain_rate_mult", "grain rate mult", 0.25, 4, "lin", 0.01, 1, "x", "set_grains_rate_mult")
  grain_option("grain_octaves", "grain octaves", OFF_ON, "set_grains_octaves")
  grain_option("grain_fifths", "grain fifths & 4ths", OFF_ON, "set_grains_fifths")
  grain_option("grain_suboctaves", "grain sub-octaves", OFF_ON, "set_grains_suboctaves")
  grain_option("grain_reverse", "grain reverse", OFF_ON, "set_grains_reverse")
  -- Takes effect the next time the chain is allocated (switch carter's delay off and on).
  grain("grain_delay_scale", "grain delay scale", 0.01, 2, "lin", 0.01, 1, "", "set_grains_delay_scale")

  p:add_separator("ts_grain_fb", "feedback patch")
  grain("feedback_amp", "feedback amp", 0, 2, "lin", 0.01, 0, "", "set_grains_fb_amp")
  grain("feedback_balance", "feedback balance", -1, 1, "lin", 0.01, 0, "", "set_grains_fb_balance")
  grain("feedback_hpf", "feedback hpf", 5, 2000, "exp", 1, 12, "Hz", "set_grains_fb_hpf")
  p:add_separator("ts_grain_fb_adv", "(advanced)")
  grain("noise_inject_level", "noise inject level", 0, 1, "lin", 0.01, 0, "", "set_grains_fb_noise")
  grain("sine_inject_level", "sine inject level", 0, 1, "lin", 0.01, 0, "", "set_grains_fb_sine_level")
  grain("sine_inject_freq", "sine inject freq", 20, 2000, "exp", 0.1, 55, "Hz", "set_grains_fb_sine_hz")

  p:add_separator("ts_grain_lfo", "grain LFO rates")
  local LFOS = { { "pan", "pan" }, { "cutoff", "cutoff" }, { "res", "res" } }
  for n = 0, 3 do
    for _, l in ipairs(LFOS) do
      local id = "grain_" .. n .. "_" .. l[1] .. "_rate"
      p:add_control(id, "grain " .. (n + 1) .. " " .. l[2] .. " rate",
        controlspec.new(1, 64, "lin", 0.1, math.random(1, 64), "beats"))
      p:set_action(id, function(v) engine["set_grains_" .. l[1] .. "_rate"](n, v) end)
    end
  end
  p:add_trigger("randomize_grain_lfo_rates", "randomize all grain LFO rates")
  p:set_action("randomize_grain_lfo_rates", function()
    for n = 0, 3 do
      for _, l in ipairs(LFOS) do
        p:set("grain_" .. n .. "_" .. l[1] .. "_rate", math.random(10, 6400) / 100)
      end
    end
  end)

  -- Re-sends the delay time when it follows the clock. tabletseq.lua calls it when the tempo changes.
  function api.resync_delay()
    if p:get("delay_sync") > 1 then
      engine.set_delay_time(Params.delay_time_now(p, beat_sec()))
    end
  end

  return api
end

return Params
