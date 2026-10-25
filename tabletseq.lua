---tabletseq
---
---draw loops on a
---wacom one and play
---them on any voice.
---
---x is time
---y is pitch
---pressure is loudness
---
---E1: choose sequence
---  (past the last: new)
---E2: choose setting
---E3: change setting
---K2 twice: delete
---K3: start or stop
---
---pen buttons:
---upper twice: clear
---lower: undo
---
---grid row 1: start/stop
---grid row 2: select
---
---more in PARAMS

engine.name = 'TabletSeq'

local Model = include 'lib/ts_model'
local Seq = include 'lib/ts_seq'
local Router = include 'lib/ts_router'
local EngineVoice = include 'lib/ts_engine_voice'
local MidiVoice = include 'lib/ts_midi_voice'
local CrowVoice = include 'lib/ts_crow_voice'
local Ii = include 'lib/ts_ii_voice'
local Drums = include 'lib/ts_drums'
local Tablet = include 'lib/ts_tablet'
local Draw = include 'lib/ts_draw'
local Ui = include 'lib/ts_ui'
local GridUi = include 'lib/ts_grid'
local Screen = include 'lib/ts_screen'
local Store = include 'lib/ts_store'
local Params = include 'lib/ts_params'

local FPS = 30
local TEMPO_POLL = 0.25            -- seconds between tempo checks
local NOTICE = 3                  -- seconds a message stays on screen

local cur                          -- the live set: { selected, sequences }
local seq, router, drums, ui, draw, gridui, tablet, store, g
local jf_voice, wsyn_voice
local used = {}                    -- "jf" / "wsyn": a sequence has played on that module
local midi_dev
local redraw_metro, sched_metro
local active_port                  -- the hid port being read, or nil
local status                       -- shown on screen when something is wrong
local notice                       -- { text, until }
local dirty = true
local prior_crow_add, prior_hid_add, prior_hid_remove
local prior_tempo_handler
local last_tempo
local poll_at = 0
local params_api
local live_shown = false      -- did the last tick keep the screen drawing (something playing, waiting or shown)
local CLEAR_TEXT = "pen button again to clear"

local function now() return util.time() end

local function crow_here() return norns.crow.connected() end

local function bpb() return params:get("beats_per_bar") end

-- Does the device list ABS_PRESSURE (0x18) among its EV_ABS (3) codes? nil when it doesn't say.
local function reports_pressure(device)
  local codes = type(device) == "table" and device.codes
  local abs = type(codes) == "table" and codes[3]
  if type(abs) ~= "table" or next(abs) == nil then return nil end
  if abs[0x18] ~= nil then return true end
  for _, c in pairs(abs) do
    if c == 0x18 then return true end
  end
  return false
end

-- Which hid port to read: the chosen one, or the first that looks like the tablet.
-- `gone` is a device that is being unplugged and no longer counts.
local function connect_tablet(gone)
  local devices = {}
  for i = 1, 4 do
    local vp = hid.vports[i]
    local here = vp.device and vp.device ~= gone
    devices[i] = { name = here and vp.name or "", has_pressure = nil }
    if here then devices[i].has_pressure = reports_pressure(vp.device) end
  end
  local port = tablet.port
  if not port then port = Tablet.pick(devices) end
  local target = (port and devices[port].name ~= "") and port or nil
  -- Leaving the port a stroke may be on: lift it before the old handler is dropped.
  if active_port and target ~= active_port then tablet:removed() end
  if active_port then hid.vports[active_port].event = nil end
  active_port = nil
  if target then
    local vp = hid.connect(port)
    vp.event = function(t, c, v) tablet:event(t, c, v) end
    tablet:set_model(vp.name)
    active_port = port
    status = nil
  else
    status = "plug in the tablet"
  end
  dirty = true
end

-- A module voice that remembers its first use, so its settings are sent only once it has played.
local function tracked(name, voice)
  return setmetatable({ first_use = function()
    used[name] = true
    voice.first_use()
  end }, { __index = voice })
end

local function say(text)
  notice = { text = text, ["until"] = now() + NOTICE }
  dirty = true
end

local function ports()
  local names = {}
  for i = 1, 16 do names[i] = midi.vports[i].name end
  return names
end

function init()
  cur = { selected = 1, sequences = { Model.new_sequence({}) } }
  used = {}
  midi_dev = nil

  local engine_voice = EngineVoice.new(engine, clock)
  drums = Drums.new{ engine_voice = engine_voice, scandir = util.scandir, file_info = util.file_exists }
  local jf_settings = {} -- filled by params:bang()
  local wsyn_settings = { voices = 4, lpg_time = 0, lpg_symmetry = 0, hold = true }
  jf_voice = Ii.Jf.new{ ii = function() return crow.ii.jf end, connected = crow_here, clock = clock,
    settings = jf_settings }
  wsyn_voice = Ii.Wsyn.new{ ii = function() return crow.ii.wsyn end, connected = crow_here, clock = clock,
    settings = wsyn_settings }
  local crow1 = CrowVoice.new{ crow = crow, connected = crow_here, clock = clock, pair = 1 }
  local crow2 = CrowVoice.new{ crow = crow, connected = crow_here, clock = clock, pair = 2 }
  router = Router.new{
    voices = {
      engine = engine_voice,
      midi = MidiVoice.new{ dev = function() return midi_dev end, clock = clock },
      crow1 = crow1, crow2 = crow2,
      jf = tracked("jf", jf_voice), wsyn = tracked("wsyn", wsyn_voice),
      drums = drums,
    },
    seq_list = function() return cur.sequences end,
  }
  seq = Seq.new{ clock = clock, model = Model, router = router, bpb = bpb }
  ui = Ui.new{ set = function() return cur end, seq = seq, router = router, model = Model, now = now }
  draw = Draw.new{
    model = Model, set = function() return cur end, now = now, bpb = bpb,
    on_change = function(s) seq.changed(s); dirty = true end,
    on_new = function(s)
      if #cur.sequences >= Model.MAX_SEQUENCES then return false end
      cur.sequences[#cur.sequences + 1] = s
      cur.selected = #cur.sequences
      ui.sync_engine()
    end,
  }
  store = Store.new{ tab = tab, model = Model, exists = util.file_exists,
    remove = os.remove }

  -- One-shot timer for the tablet's 2 ms report-end wait.
  sched_metro = metro.init()
  sched_metro.time = 0.002
  local pending
  sched_metro.event = function()
    sched_metro:stop()
    local f = pending
    pending = nil
    if f then f() end
  end

  tablet = Tablet.new{
    emit = function(evt, d) draw.pen(evt, d); dirty = true end,
    schedule = function(f, secs)
      pending = f
      sched_metro:start(secs, 1)
    end,
  }
  tablet.on_select = function() connect_tablet() end

  prior_hid_add, prior_hid_remove = hid.add, hid.remove
  hid.add = function() connect_tablet() end
  hid.remove = function(dev)
    if active_port and hid.vports[active_port].device == dev then tablet:removed() end
    connect_tablet(dev)
  end

  g = grid.connect()
  gridui = GridUi.new{ g = g, set = function() return cur end, seq = seq }
  g.key = function(x, y, z) gridui.key(x, y, z); dirty = true end

  crow.ii.pullup(true)
  -- A crow plugged in later starts blank: pull-ups again, then every output that has played sends
  -- again what it needs (the pairs their volts; JF and w/syn their settings and neutral timbre).
  prior_crow_add = norns.crow.add
  norns.crow.add = function(...)
    if prior_crow_add then prior_crow_add(...) end
    crow.ii.pullup(true)
    crow1.reconnected()
    crow2.reconnected()
    if used.jf then jf_voice.first_use() end
    if used.wsyn then wsyn_voice.first_use() end
  end

  params_api = Params.add(params, {
    seq = seq, jf = jf_voice, wsyn = wsyn_voice, jf_settings = jf_settings, wsyn_settings = wsyn_settings,
    used = function(name) return used[name] end,
    set_midi = function(d) midi_dev = d end, ports = ports,
    drums = drums, tablet = tablet, notify = say,
  })

  -- The delay follows the clock: a tempo edit in PARAMETERS calls the handler, and the redraw metro's
  -- poll catches the rest (Link, MIDI and crow clocks change the tempo without calling it).
  local function resync_delay()
    last_tempo = clock.get_tempo()
    params_api.resync_delay()
  end
  prior_tempo_handler = clock.tempo_change_handler
  clock.tempo_change_handler = function(...)
    if prior_tempo_handler then prior_tempo_handler(...) end
    resync_delay()
  end

  -- The sequences live beside the PSET.
  params.action_write = function(filename)
    store.save(store.path_for(filename), cur)
  end
  params.action_read = function(filename)
    seq.stop_all()
    router.release_all()
    local loaded = store.load(store.path_for(filename))
    if loaded then
      cur = loaded
      ui.sync_engine()
    end
    params_api.after_read()
    dirty = true
  end
  params.action_delete = function(filename)
    store.delete(store.path_for(filename))
  end

  redraw_metro = metro.init()
  redraw_metro.time = 1 / FPS
  redraw_metro.event = function()
    if notice and now() >= notice["until"] then notice = nil; dirty = true end
    if now() >= poll_at then
      poll_at = now() + TEMPO_POLL
      if last_tempo and math.abs(clock.get_tempo() - last_tempo) > 0.01 then resync_delay() end
    end
    local busy = false
    for _, s in ipairs(cur.sequences) do
      if seq.state(s) ~= "stopped" then busy = true end
    end
    -- Anything that keeps the screen drawing on its own (a sequence that is not stopped, a confirm
    -- waiting in the bottom strip, the readings page) ends without a call to mark the screen dirty:
    -- the tick after it ends draws once more, so the last frame (the waiting blink, the prompt, the
    -- readings) does not stay on the screen.
    local live = busy or ui.message() ~= nil or draw.pending_clear() or params:get("tablet_readings") == 1
    if live ~= live_shown then dirty = true end
    live_shown = live
    gridui.redraw((now() * 2) % 1)
    if dirty or live then
      dirty = false
      redraw()
    end
  end
  redraw_metro:start()

  params:bang()
  last_tempo = clock.get_tempo()
  ui.sync_engine()
end

function enc(n, d)
  ui.enc(n, d)
  dirty = true
end

function key(n, z)
  ui.key(n, z)
  dirty = true
end

function redraw()
  local cap = draw.cap()
  local view = ui.view{
    bpb = bpb(),
    hover = draw.hover(),
    tip = cap and { x = cap.last_x, y = cap.last_y } or nil,
    blink = math.floor(now() * 4) % 2 == 0,
  }
  -- the strip at the bottom: a delete waiting, a clear waiting, then a notice; "plug in the tablet"
  -- only on the blank page
  if not view.message and draw.pending_clear() then view.message = CLEAR_TEXT end
  if not view.message then
    view.message = notice and notice.text or (not view.seq and status) or nil
  end
  if params:get("tablet_readings") == 1 then view.readings = tablet:readings() end
  Screen.draw(screen, view)
end

function cleanup()
  seq.stop_all()
  router.release_all()
  if redraw_metro then redraw_metro:stop() end
  if sched_metro then sched_metro:stop() end
  if active_port then hid.vports[active_port].event = nil end
  if g then g.key = nil end
  norns.crow.add = prior_crow_add
  clock.tempo_change_handler = prior_tempo_handler
  hid.add, hid.remove = prior_hid_add, prior_hid_remove
end
