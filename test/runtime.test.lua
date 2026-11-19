-- lua test/runtime.test.lua : the compositor-side lifecycle against a fake `hl`.
-- Checks what matters for stability: timers don't pile up across loads, an error
-- stops the plugin once instead of on every tick, a vanished monitor or a sleep
-- gap ends a drag without warping the cursor.
local file = (arg[0]:match("^(.*)/test/[^/]+$") or ".") .. "/hypr/window-zones.lua"

local timers, dispatched, spawned, now = {}, {}, {}, 1000
local monitor = { name = "M", x = 0, y = 0, width = 1920, height = 1080, scale = 1, transform = 0,
                  reserved = { top = 26 }, active_workspace = { id = 1 } }
local win = { address = "0xa", mapped = true, floating = true, pinned = false, fullscreen = 0,
              workspace = { id = 1, special = false }, tags = { "omarchy-floating-workspace" },
              at = { x = 500, y = 400 }, size = { x = 800, y = 600 }, focus_history_id = 0 }
local cursor = { x = 700, y = 385 }

local function timer(fn, opts)
  local t = { fn = fn, opts = opts, enabled = true }
  function t:set_enabled(v) self.enabled = v end
  function t:is_enabled() return self.enabled end
  timers[#timers + 1] = t
  return t
end

hl = {
  timer = timer,
  on = function() return { remove = function() end } end,
  get_config = function() return nil end,
  get_windows = function() return { win } end,
  get_active_window = function() return win end,
  get_active_workspace = function() return monitor.active_workspace end,
  get_cursor_pos = function() return { x = cursor.x, y = cursor.y } end,
  get_monitor_at = function() return monitor end,
  dispatch = function(d) dispatched[#dispatched + 1] = d end,
  exec_cmd = function(c) spawned[#spawned + 1] = c end,
  window_rule = function() end,
  config = function() end,
  dsp = setmetatable({}, { __index = function(_, group)
    return setmetatable({}, { __index = function(_, name)
      return function(args) return { group = group, name = name, args = args } end
    end })
  end }),
}
os.time = function() return now end
local getenv = os.getenv
os.getenv = function(k) if k == "XDG_RUNTIME_DIR" then return "/tmp" end return getenv(k) end

local function tick(name)
  for _, t in ipairs(timers) do
    if t.enabled and t.opts.type == "repeat" and t.opts.timeout == (name == "idle" and 50 or 16) then t.fn() end
  end
end
local function count(group, name)
  local n = 0
  for _, d in ipairs(dispatched) do if d.group == group and d.name == name then n = n + 1 end end
  return n
end

-- Loading again and again (each settings change does) keeps two timers.
for _ = 1, 5 do window_zones_gen = 1 dofile(file) end
local repeating = 0
for _, t in ipairs(timers) do if t.opts.type == "repeat" then repeating = repeating + 1 end end
assert(repeating == 2, "five loads keep two timers, got " .. repeating)

-- Start a drag: window and cursor move together.
tick("idle")
win.at.x, cursor.x = win.at.x - 50, cursor.x - 50
tick("idle")
assert(window_zones_timers.drag.enabled, "a drag starts")

-- The machine sleeps mid-drag: on wake the drag is dropped, no warp, no placement.
now = now + 30
tick("drag")
assert(not window_zones_timers.drag.enabled and window_zones_timers.idle.enabled, "a sleep gap ends the drag")
assert(count("cursor", "move") == 0 and count("window", "resize") == 0, "nothing warped or placed after sleep")

-- A drag whose monitor disappears (lid closed) ends quietly.
tick("idle")
win.at.x, cursor.x = win.at.x - 50, cursor.x - 50
tick("idle")
assert(window_zones_timers.drag.enabled, "a second drag starts")
hl.get_monitor_at = function() return nil end
tick("drag") tick("drag")
hl.get_monitor_at = function() return monitor end
assert(#spawned == 0 or not spawned[#spawned]:match("stopped"), "a missing monitor is no error")

-- Restore sizes survive a config reload, which starts a fresh Lua state.
local state_file = "/tmp/window-zones-snapped.lua"
os.remove(state_file)
tick("idle")
win.at.x, cursor.x = win.at.x - 50, cursor.x - 50
tick("idle")
cursor.x, win.at.x = 2, win.at.x - (cursor.x - 2)
tick("drag")                      -- at the left edge: target is the left half
cursor.y = cursor.y + 20
tick("drag")                      -- the cursor moved on without the window: dropped
assert(count("window", "resize") > 0, "the window is placed")
local function reload()
  window_zones = nil
  window_zones_gen = 2
  dofile(file)
end
local windows = hl.get_windows
hl.get_windows = function() return {} end
reload()
assert(next(window_zones.snapped) == nil, "entries of windows that are gone are dropped")
hl.get_windows = windows
reload()
local s = window_zones.snapped["0xa"]
assert(s and s.w == 800 and s.h == 600 and s.box and s.zone, "the restore size is back after a reload")

-- Custom layouts from the settings join the panel before the scratchpad.
window_zones_settings = { layouts = { { cols = { 60, 40 }, split = { false, true } } } }
reload()
local L = window_zones.LAYOUTS
assert(L[#L - 1].name == "Custom 1" and #L[#L - 1].cells == 3 and L[#L].scratchpad, "a custom layout from the settings")
window_zones_settings = nil
reload()
assert(not window_zones.LAYOUTS[#window_zones.LAYOUTS - 1].name:match("^Custom"), "gone again without the setting")

-- A state file that tries to run code is ignored.
local f = assert(io.open(state_file, "w"))
f:write('return { ["0xa"] = { w = os.exit(1), h = 1 } }')
f:close()
reload()
assert(next(window_zones.snapped) == nil, "a hostile state file is ignored")
os.remove(state_file)

-- Resizing a placed window moves the edge of the placed window next to it.
-- Halves on 1920 x 1080 with a 26 px bar, gaps 10 / 5, no titlebar.
local function placed(w, x)
  w.at, w.size = { x = x, y = 36 }, { x = 945, y = 1034 }
  window_zones.snapped[w.address] = { w = 800, h = 600, box = { x = x, y = 36, w = 945, h = 1034 },
                                      zone = { x = x, y = 36, w = 945, h = 1034, ws = 1, bar = 0 } }
end
local win2 = { address = "0xb", mapped = true, floating = true, pinned = false, fullscreen = 0,
               workspace = { id = 1, special = false }, tags = { "omarchy-floating-workspace" }, focus_history_id = 1 }
hl.get_windows = function() return { win, win2 } end
placed(win, 10) placed(win2, 965)
cursor.x, cursor.y = 950, 500
local function last_dispatch(addr, name)
  for i = #dispatched, 1, -1 do
    local d = dispatched[i]
    if d.group == "window" and d.name == name and d.args.window == "address:" .. addr then return d.args end
  end
end
dispatched = {}
tick("idle")
win.size.x = 1045                 -- its right edge dragged 100 px to the right
tick("idle")
assert(not last_dispatch("0xb", "resize"), "nothing moves while the edge is still moving")
tick("idle")                      -- the edge stands still
local r, m = last_dispatch("0xb", "resize"), last_dispatch("0xb", "move")
assert(r and r.x == 845 and r.y == 1034, "the neighbour gives up 100 px")
assert(m and m.x == 1065 and m.y == 36, "the neighbour's left edge follows, the gap stays")
assert(window_zones.snapped["0xa"].box.w == 1045 and window_zones.snapped["0xb"].box.x == 1065, "both remember their new boxes")
assert(window_zones.snapped["0xa"].w == 800, "the size to restore on drag out stays")

-- Placing a window resizes it too, and a tick can fall between its new size and
-- its new position: that is no resize by the user, nothing follows.
placed(win, 10) placed(win2, 965)
win.at, win.size = { x = 500, y = 400 }, { x = 800, y = 600 }   -- where it was before the drop
dispatched = {}
tick("idle")
win.size = { x = 945, y = 1034 }   -- the resize has landed, the move not yet
tick("idle") tick("idle")
assert(not last_dispatch("0xb", "resize") and not last_dispatch("0xb", "move"), "a placement moves no neighbour")
assert(window_zones.snapped["0xa"].box.x == 10, "a placement keeps the box it asked for")

-- Moving a placed window without resizing it couples nothing.
placed(win, 10) placed(win2, 965)
dispatched = {}
tick("idle")
win.at.y = 60
tick("idle") tick("idle")
assert(not last_dispatch("0xb", "resize") and not last_dispatch("0xb", "move"), "a move is no resize")

-- A window in a fan is left alone: its neighbour would not know which one to follow.
local win3 = { address = "0xc", mapped = true, floating = true, pinned = false, fullscreen = 0,
               workspace = { id = 1, special = false }, tags = { "omarchy-floating-workspace" }, focus_history_id = 2 }
placed(win, 10) placed(win2, 965) placed(win3, 965)
win3.at, win3.size = { x = 989, y = 36 }, { x = 921, y = 1034 }   -- second card of a fan in the right half
hl.get_windows = function() return { win, win2, win3 } end
dispatched = {}
tick("idle")
win.size.x = 1045
tick("idle") tick("idle")
assert(not last_dispatch("0xb", "resize") and not last_dispatch("0xc", "resize"), "a fan does not follow")
hl.get_windows = windows
os.remove(state_file)

-- An error inside a tick stops the plugin once, instead of on every tick.
hl.get_cursor_pos = function() error("boom") end
for _ = 1, 10 do tick("idle") tick("drag") end
local notes = 0
for _, c in ipairs(spawned) do if c:match("Window Zones stopped") then notes = notes + 1 end end
assert(notes == 1, "one notification for an error, got " .. notes)
assert(not window_zones_timers.idle.enabled and not window_zones_timers.drag.enabled, "timers are off after an error")

os.remove("/tmp/window-zones-error.log")
print("ok")
