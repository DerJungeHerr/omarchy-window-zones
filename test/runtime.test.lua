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

-- An error inside a tick stops the plugin once, instead of on every tick.
hl.get_cursor_pos = function() error("boom") end
for _ = 1, 10 do tick("idle") tick("drag") end
local notes = 0
for _, c in ipairs(spawned) do if c:match("Window Zones stopped") then notes = notes + 1 end end
assert(notes == 1, "one notification for an error, got " .. notes)
assert(not window_zones_timers.idle.enabled and not window_zones_timers.drag.enabled, "timers are off after an error")

os.remove("/tmp/window-zones-error.log")
print("ok")
