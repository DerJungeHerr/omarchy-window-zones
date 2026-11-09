-- Window Zones: Windows-style window snapping for Omarchy floating workspaces.
--
-- Service.qml loads this file into Hyprland with `hyprctl eval` when the shell
-- starts and after every config reload (a reload starts a fresh Lua state):
--   window_zones_gen = 1731100000000  window_zones_dock = { edge = "bottom", size = 51 }  dofile(".../window-zones.lua")
-- window_zones_gen identifies the loading service; the overlay ignores other generations.
--
-- Hyprland has no drag events and Omarchy's titlebar plugin swallows titlebar
-- clicks, so a drag is recognised by watching: the active window moving by the
-- same amount as the cursor. A release with the cursor standing still is found
-- by nudging the cursor one pixel: a held window follows it, a dropped one does not.
--
-- Runs inside the compositor: never call hyprctl from here.

local M = {}

local IDLE_MS, DRAG_MS = 50, 16
local TOL = 2          -- px: how closely the window has to follow the cursor
local STILL_MS = 120   -- stillness before the release probe
local EDGE = 6         -- px: width of the left/right snap strips
local HOT_HALF = 0.15  -- half-width of the top-centre hotspot, as part of the monitor width
local FAN_X = 24       -- px: each window in a shared zone sits this far right of the one behind
local FAN_MAX = 5      -- windows fanned out per zone; more start again at the back

M.LAYOUTS = {
  { name = "Halves", cells = { { 0, 0, 1/2, 1 }, { 1/2, 0, 1, 1 } } },
  { name = "Thirds", cells = { { 0, 0, 1/3, 1 }, { 1/3, 0, 2/3, 1 }, { 2/3, 0, 1, 1 } } },
  { name = "Wide left", cells = { { 0, 0, 2/3, 1 }, { 2/3, 0, 1, 1 } } },
  { name = "Wide right", cells = { { 0, 0, 1/3, 1 }, { 1/3, 0, 1, 1 } } },
  { name = "Quarters", cells = { { 0, 0, 1/2, 1/2 }, { 1/2, 0, 1, 1/2 }, { 0, 1/2, 1/2, 1 }, { 1/2, 1/2, 1, 1 } } },
  { name = "Full", cells = { { 0, 0, 1, 1 } } },
  { name = "Scratchpad", scratchpad = true, cells = { { 0, 0, 1, 1 } } },
}

-- Usable box of a monitor in global logical coordinates: minus the bar and
-- other reserved edges, and minus the dock, which reserves nothing itself.
function M.area(mon, dock)
  local w, h = mon.width / mon.scale, mon.height / mon.scale
  if mon.transform % 2 == 1 then w, h = h, w end
  local r = mon.reserved or {}
  local a = { x = mon.x + (r.left or 0), y = mon.y + (r.top or 0) }
  a.w = w - (r.left or 0) - (r.right or 0)
  a.h = h - (r.top or 0) - (r.bottom or 0)
  if dock and dock.size and dock.size > 0 then
    if dock.edge == "bottom" then a.h = a.h - dock.size
    elseif dock.edge == "top" then a.y, a.h = a.y + dock.size, a.h - dock.size
    elseif dock.edge == "left" then a.x, a.w = a.x + dock.size, a.w - dock.size
    elseif dock.edge == "right" then a.w = a.w - dock.size end
  end
  return a
end

-- The outer box (titlebar included) for a cell given as fractions of the area.
-- Screen edges get gaps_out, inner edges gaps_in, like tiled windows.
function M.cell(a, c, out, inn)
  local x0 = a.x + c[1] * a.w + (c[1] == 0 and out or inn)
  local y0 = a.y + c[2] * a.h + (c[2] == 0 and out or inn)
  local x1 = a.x + c[3] * a.w - (c[3] == 1 and out or inn)
  local y1 = a.y + c[4] * a.h - (c[4] == 1 and out or inn)
  return { x = math.floor(x0 + 0.5), y = math.floor(y0 + 0.5),
           w = math.floor(x1 - x0 + 0.5), h = math.floor(y1 - y0 + 0.5) }
end

-- The dropdown: one small screen per layout, centred under the bar. Rects are
-- global; every tile carries its cells as hit boxes.
function M.panel(a, mon_x, mon_w)
  local pad, gap = 14, 12
  local n = #M.LAYOUTS
  -- Narrow screens get smaller tiles so the whole panel stays on screen.
  local tw = math.min(120, math.floor((mon_w - 32 - (n - 1) * gap - 2 * pad) / n))
  local th = math.floor(tw * a.h / a.w + 0.5)
  local p = { w = n * tw + (n - 1) * gap + 2 * pad, h = th + 2 * pad, tiles = {} }
  p.x = math.floor(mon_x + (mon_w - p.w) / 2 + 0.5)
  p.y = a.y + 8
  for i, layout in ipairs(M.LAYOUTS) do
    local t = { x = p.x + pad + (i - 1) * (tw + gap), y = p.y + pad, w = tw, h = th, cells = {} }
    for j, c in ipairs(layout.cells) do
      t.cells[j] = M.cell(t, c, 3, 2)
    end
    p.tiles[i] = t
  end
  return p
end

local function inside(r, x, y, margin)
  margin = margin or 0
  return x >= r.x - margin and x < r.x + r.w + margin and y >= r.y - margin and y < r.y + r.h + margin
end

-- What a drop at (x, y) would do: { layout = i, cell = j } or nil.
function M.panel_hit(p, x, y)
  for i, t in ipairs(p.tiles) do
    for j, c in ipairs(t.cells) do
      if inside(c, x, y) then return { layout = i, cell = j } end
    end
  end
end

-- Window k (0 = back) of n sharing a zone: each a titlebar lower and FAN_X
-- further right than the one behind, all shrunk so the fan fills the zone.
function M.fan(zone, n, k, bar)
  n = math.min(n, FAN_MAX)
  k = k % FAN_MAX
  return { x = zone.x + k * FAN_X, y = zone.y + k * bar,
           w = zone.w - (n - 1) * FAN_X, h = zone.h - (n - 1) * bar }
end

-- The fan slot an outer box sits in within a zone, or nil.
function M.fan_slot(zone, r, bar)
  if r.x + r.w > zone.x + zone.w + TOL or r.y + r.h > zone.y + zone.h + TOL then return end
  for k = 0, FAN_MAX - 1 do
    if math.abs(r.x - (zone.x + k * FAN_X)) <= TOL and math.abs(r.y - (zone.y + k * bar)) <= TOL then return k end
  end
end

function M.edge_hit(mon_x, mon_w, x)
  if x < mon_x + EDGE then return { layout = 1, cell = 1 } end
  if x >= mon_x + mon_w - EDGE then return { layout = 1, cell = 2 } end
end

-- The bar's strip above the usable area, or a thin strip when nothing is reserved on top.
function M.in_hotspot(a, mon_x, mon_y, mon_w, x, y)
  return y < math.max(a.y, mon_y + EDGE) and math.abs(x - (mon_x + mon_w / 2)) <= mon_w * HOT_HALF
end

-- Minimal JSON for the overlay: numbers, strings without quotes, arrays, objects.
function M.json(v)
  local t = type(v)
  if t == "table" then
    if v[1] ~= nil or next(v) == nil then
      local out = {}
      for i, x in ipairs(v) do out[i] = M.json(x) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local out, keys = {}, {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = '"' .. k .. '":' .. M.json(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  elseif t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(ch) return string.format("\\u%04x", ch:byte()) end) .. '"'
  elseif t == "boolean" then
    return tostring(v)
  end
  return tostring(math.floor(v + 0.5))
end

if not hl then return M end

-- Runtime -----------------------------------------------------------------

if window_zones and window_zones.stop then window_zones.stop() end
window_zones = M

local gen = math.floor(tonumber(window_zones_gen) or 0)
local dock = window_zones_dock
M.gen = gen

local function xy(t) return t.x or t[1], t.y or t[2] end

local function opt(key, fallback)
  local ok, v = pcall(hl.get_config, key)
  if not ok or v == nil then return fallback end
  if type(v) == "table" then return v.top or v[1] or fallback end
  return v
end

local function eligible(w)
  if not (w and w.mapped and w.floating and not w.pinned and w.fullscreen == 0 and not w.group) then return false end
  if not w.workspace or w.workspace.special then return false end
  for _, tag in pairs(w.tags or {}) do
    if tag == "omarchy-floating-workspace" then return true end
  end
  return false
end

local function window(addr)
  for _, w in ipairs(hl.get_windows()) do
    if w.address == addr then return w end
  end
end

local function monitor_box(m)
  local w, h = m.width / m.scale, m.height / m.scale
  if m.transform % 2 == 1 then w, h = h, w end
  return m.x, m.y, w, h
end

local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- Spawned calls may arrive out of order: seq lets the overlay keep the newest.
local seq = 0
local function overlay(state)
  seq = seq + 1
  local json = state and M.json(state) or "{}"
  hl.exec_cmd("omarchy-shell -q window-zones show " .. gen .. " " .. seq .. " " .. shell_quote(json))
end

local function dispatch(d) pcall(hl.dispatch, d) end

-- Windows Window Zones placed: their size before, the box they got, and their zone.
local snapped = {}

local function place(addr, box, zone)
  local w = window(addr)
  if not w then return end
  local ww, wh = xy(w.size)
  if not snapped[addr] then snapped[addr] = { w = ww, h = wh } end
  local target = { x = box.x, y = box.y + zone.bar, w = box.w, h = box.h - zone.bar }
  snapped[addr].box, snapped[addr].zone = target, zone
  local win = "address:" .. addr
  dispatch(hl.dsp.window.resize({ window = win, x = target.w, y = target.h, relative = false }))
  dispatch(hl.dsp.window.move({ window = win, x = target.x, y = target.y }))
end

-- The windows already fanned out in a zone, back to front. Read from where the
-- windows are, so it holds after a reload too.
local function members(zone, skip)
  local list = {}
  for _, w in ipairs(hl.get_windows()) do
    if w.address ~= skip and eligible(w) and w.workspace.id == zone.ws then
      local x, y = xy(w.at)
      local ww, wh = xy(w.size)
      local k = M.fan_slot(zone, { x = x, y = y - zone.bar, w = ww, h = wh + zone.bar }, zone.bar)
      if k then list[#list + 1] = { addr = w.address, k = k, recent = w.focus_history_id } end
    end
  end
  table.sort(list, function(a, b)
    if a.k ~= b.k then return a.k < b.k end
    return a.recent > b.recent
  end)
  return list
end

-- Lay a zone's windows out as a fan. raise also restacks them back to front,
-- which a drop wants and a window leaving the zone does not.
local function arrange(zone, list, raise)
  for i, m in ipairs(list) do
    place(m.addr, M.fan(zone, #list, i - 1, zone.bar), zone)
    if raise then dispatch(hl.dsp.window.alter_zorder({ window = "address:" .. m.addr, mode = "top" })) end
  end
end

local function zone_of(d)
  local out, inn = opt("general:gaps_out", 10), opt("general:gaps_in", 5)
  local zone = M.cell(d.area, M.LAYOUTS[d.target.layout].cells[d.target.cell], out, inn)
  zone.ws, zone.bar = d.ws, d.bar
  return zone
end

local drag, last

local function finish(drop)
  local d = drag
  drag = nil
  M.drag_timer:set_enabled(false)
  M.idle_timer:set_enabled(true)
  overlay(nil)
  if not (drop and d and d.target) then return end
  local layout = M.LAYOUTS[d.target.layout]
  if layout.scratchpad then
    snapped[d.addr] = nil
    dispatch(hl.dsp.window.move({ window = "address:" .. d.addr, workspace = "special:scratchpad", follow = false }))
  else
    local zone = zone_of(d)
    local list = members(zone, d.addr)
    list[#list + 1] = { addr = d.addr }
    arrange(zone, list, true)
  end
end

-- Pulled out of its zone: back to the size it had before Window Zones placed it,
-- under the cursor at the same relative spot of the titlebar.
local function unsnap(w, cx)
  local s = snapped[w.address]
  if not s then return end
  snapped[w.address] = nil
  if s.zone then arrange(s.zone, members(s.zone, w.address), false) end
  local wx, wy = xy(w.at)
  local ww, wh = xy(w.size)
  if not s.box or math.abs(ww - s.box.w) > TOL or math.abs(wh - s.box.h) > TOL then return end
  local win = "address:" .. w.address
  local nx = math.floor(cx - (cx - wx) / ww * s.w + 0.5)
  dispatch(hl.dsp.window.resize({ window = win, x = s.w, y = s.h, relative = false }))
  dispatch(hl.dsp.window.move({ window = win, x = nx, y = wy }))
end

local function start(w, cx)
  unsnap(w, cx)
  drag = { addr = w.address, ws = w.workspace.id, still = 0, bar = opt("plugin:hyprbars:bar_height", 0) }
  M.idle_timer:set_enabled(false)
  M.drag_timer:set_enabled(true)
end

local function idle_tick()
  local w = hl.get_active_window()
  local c = hl.get_cursor_pos()
  if not (w and c and eligible(w)) then last = nil return end
  local wx, wy = xy(w.at)
  local ww, wh = xy(w.size)
  local now = { addr = w.address, x = wx, y = wy, w = ww, h = wh, cx = c.x, cy = c.y }
  local p = last
  last = now
  if not p or p.addr ~= now.addr or p.w ~= now.w or p.h ~= now.h then return end
  local dx, dy, dcx, dcy = now.x - p.x, now.y - p.y, now.cx - p.cx, now.cy - p.cy
  if (dx ~= 0 or dy ~= 0) and math.abs(dx - dcx) <= TOL and math.abs(dy - dcy) <= TOL then
    start(w, c.x)
  end
end

local function target_at(d, x, y)
  local m = hl.get_monitor_at(x, y)
  if not m then return end
  local mx, my, mw = monitor_box(m)
  d.monitor, d.mx, d.my = m.name, mx, my
  d.area = M.area(m, dock)
  if d.panel and d.panel_monitor == m.name and inside(d.panel, x, y, 40) then
    return M.panel_hit(d.panel, x, y)
  end
  d.panel = nil
  if M.in_hotspot(d.area, mx, my, mw, x, y) then
    d.panel, d.panel_monitor = M.panel(d.area, mx, mw), m.name
    return nil
  end
  return M.edge_hit(mx, mw, x)
end

-- The overlay works in monitor-local coordinates.
local function local_rect(d, r)
  return { x = r.x - d.mx, y = r.y - d.my, w = r.w, h = r.h }
end

local function show(d)
  local state = { monitor = d.monitor }
  if d.panel then
    local tiles = {}
    for i, t in ipairs(d.panel.tiles) do
      local cells = {}
      for j, c in ipairs(t.cells) do cells[j] = local_rect(d, c) end
      tiles[i] = { rect = local_rect(d, t), cells = cells, scratchpad = M.LAYOUTS[i].scratchpad or false }
    end
    state.panel = { rect = local_rect(d, d.panel), tiles = tiles }
  end
  if d.target then
    state.hot = { layout = d.target.layout, cell = d.target.cell }
    if not M.LAYOUTS[d.target.layout].scratchpad then
      -- Where the window would land: in front of whatever the zone holds.
      local zone = zone_of(d)
      local n = #members(zone, d.addr) + 1
      state.preview = local_rect(d, M.fan(zone, n, n - 1, d.bar))
    end
  end
  overlay(state)
end

local function key(d)
  return (d.monitor or "") .. ":" .. (d.panel and "p" or "") .. ":" .. (d.target and (d.target.layout .. "." .. d.target.cell) or "")
end

local function drag_tick()
  local d = drag
  local w = window(d.addr)
  local c = hl.get_cursor_pos()
  if not (w and c and eligible(w)) then return finish(false) end
  local wx, wy = xy(w.at)

  if d.probe then
    local p = d.probe
    d.probe = nil
    if c.x ~= p.cx or c.y ~= p.cy then
      -- The user moved during the probe: judge the next tick normally.
    elseif wx - p.wx == p.dx then
      dispatch(hl.dsp.cursor.move({ x = p.cx - p.dx, y = p.cy }))
      d.still, d.wx, d.wy, d.cx, d.cy = 0, wx - p.dx, wy, c.x - p.dx, c.y
      return
    else
      dispatch(hl.dsp.cursor.move({ x = p.cx - p.dx, y = p.cy }))
      return finish(true)
    end
  end

  if d.wx then
    local dx, dy, dcx, dcy = wx - d.wx, wy - d.wy, c.x - d.cx, c.y - d.cy
    if (dcx ~= 0 or dcy ~= 0) and (math.abs(dx - dcx) > TOL or math.abs(dy - dcy) > TOL) then
      -- The cursor moved on without the window: it was let go before.
      return finish(true)
    end
    if dx == 0 and dy == 0 and dcx == 0 and dcy == 0 then
      d.still = d.still + DRAG_MS
      -- Without a target a drop changes nothing, so only then is the release worth a probe.
      if d.still >= STILL_MS and d.target then
        local m = hl.get_monitor_at(c.x, c.y)
        local mx, _, mw = monitor_box(m)
        local step = (c.x >= mx + mw - 2) and -1 or 1
        d.probe = { cx = c.x + step, cy = c.y, wx = wx, dx = step }
        dispatch(hl.dsp.cursor.move({ x = c.x + step, y = c.y }))
        return
      end
    else
      d.still = 0
    end
  end
  d.wx, d.wy, d.cx, d.cy = wx, wy, c.x, c.y

  local before = key(d)
  d.target = target_at(d, c.x, c.y)
  if key(d) ~= before then show(d) end
end

M.idle_timer = hl.timer(idle_tick, { timeout = IDLE_MS, type = "repeat" })
M.drag_timer = hl.timer(drag_tick, { timeout = DRAG_MS, type = "repeat" })
M.drag_timer:set_enabled(false)

-- A closed window leaves its zone: the rest close up.
M.closed = hl.on("window.close", function(w)
  local s = w and snapped[w.address]
  if not s then return end
  snapped[w.address] = nil
  if s.zone then arrange(s.zone, members(s.zone, w.address), false) end
end)

function M.stop()
  M.closed:remove()
  M.idle_timer:set_enabled(false)
  M.drag_timer:set_enabled(false)
  if drag then overlay(nil) end
  drag = nil
end

return M
