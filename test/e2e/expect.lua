-- Where Window Zones should put things, from the plugin's own geometry.
--   lua expect.lua <monitor.json> <env> cell <layout> <cell> [n k]   -> client "x y w h"
--   lua expect.lua <monitor.json> <env> panel <layout> <cell>        -> panel cell centre "x y"
-- <monitor.json> is one monitor from `hyprctl monitors -j`; <env> holds
-- "dock_edge dock_size bar gaps_out gaps_in" as read from the running plugin.
local root = arg[0]:match("^(.*)/test/e2e/[^/]+$") or "."
local M = dofile(root .. "/hypr/window-zones.lua")

local function read(path) local f = assert(io.open(path)); local s = f:read("a"); f:close(); return s end
local function num(json, key) return tonumber(json:match('"' .. key .. '":%s*(%-?[%d.]+)')) end

local json = read(arg[1])
local r = { json:match('"reserved":%s*%[%s*(%-?%d+),%s*(%-?%d+),%s*(%-?%d+),%s*(%-?%d+)') }
local mon = { x = num(json, "x"), y = num(json, "y"), width = num(json, "width"), height = num(json, "height"),
              scale = num(json, "scale"), transform = num(json, "transform"),
              reserved = { left = tonumber(r[1]), top = tonumber(r[2]), right = tonumber(r[3]), bottom = tonumber(r[4]) } }
local dock_edge, dock_size, bar, out, inn = read(arg[2]):match("(%S+) (%S+) (%S+) (%S+) (%S+)")
local dock = dock_edge ~= "none" and { edge = dock_edge, size = tonumber(dock_size) } or nil
bar, out, inn = tonumber(bar), tonumber(out), tonumber(inn)

local layout
for i, l in ipairs(M.LAYOUTS) do if l.name == arg[4] then layout = i end end
assert(layout, "unknown layout " .. tostring(arg[4]))
local cell = tonumber(arg[5])
local area = M.area(mon, dock)

if arg[3] == "panel" then
  local w = mon.width / mon.scale
  local c = M.panel(area, mon.x, w).tiles[layout].cells[cell]
  print(math.floor(c.x + c.w / 2), math.floor(c.y + c.h / 2))
else
  local box = M.cell(area, M.LAYOUTS[layout].cells[cell], out, inn)
  local n, k = tonumber(arg[6] or 1), tonumber(arg[7] or 0)
  box = M.fan(box, n, k, bar)
  print(box.x, box.y + bar, box.w, box.h - bar)
end
