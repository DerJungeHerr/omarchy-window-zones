-- lua test/window-zones.test.lua : checks the pure geometry without Hyprland.
local M = dofile((arg[0]:match("^(.*)/test/[^/]+$") or ".") .. "/hypr/window-zones.lua")

local function eq(a, b, what)
  assert(M.json(a) == M.json(b), what .. ": " .. M.json(a) .. " ~= " .. M.json(b))
end

local mon = { x = 0, y = 0, width = 3440, height = 1440, scale = 1, transform = 0,
              reserved = { top = 26, left = 0, right = 0, bottom = 0 } }

local a = M.area(mon)
eq(a, { x = 0, y = 26, w = 3440, h = 1414 }, "area minus bar")
eq(M.area(mon, { edge = "bottom", size = 64 }), { x = 0, y = 26, w = 3440, h = 1350 }, "area minus dock")

local hidpi = { x = 3440, y = 744, width = 2880, height = 1800, scale = 2, transform = 0, reserved = { top = 26 } }
eq(M.area(hidpi), { x = 3440, y = 770, w = 1440, h = 874 }, "scaled monitor")

-- Halves leave gaps_out at the screen edges and 2 x gaps_in between them.
local left = M.cell(a, { 0, 0, 1/2, 1 }, 10, 5)
local right = M.cell(a, { 1/2, 0, 1, 1 }, 10, 5)
eq(left, { x = 10, y = 36, w = 1705, h = 1394 }, "left half")
eq(right, { x = 1725, y = 36, w = 1705, h = 1394 }, "right half")
assert(right.x - (left.x + left.w) == 10, "gap between halves")

assert(M.edge_hit(0, 3440, 2).cell == 1, "left edge")
assert(M.edge_hit(0, 3440, 3437).cell == 2, "right edge")
assert(M.edge_hit(0, 3440, 1700) == nil, "middle is no edge")

assert(M.in_hotspot(a, 0, 0, 3440, 1720, 5), "top centre")
assert(not M.in_hotspot(a, 0, 0, 3440, 200, 5), "top left corner is not the hotspot")
assert(not M.in_hotspot(a, 0, 0, 3440, 1720, 400), "below the bar is not the hotspot")
assert(M.in_hotspot({ x = 0, y = 0, w = 3440, h = 1440 }, 0, 0, 3440, 1720, 2), "hotspot without a bar")

local p = M.panel(a, 0, 3440)
assert(p.y > a.y and math.abs(p.x + p.w / 2 - 1720) <= 1, "panel centred under the bar")
local c = p.tiles[1].cells[2]
eq(M.panel_hit(p, c.x + 1, c.y + 1), { cell = 2, layout = 1 }, "hit right half tile")
local s = p.tiles[#p.tiles].cells[1]
eq(M.panel_hit(p, s.x + 1, s.y + 1), { cell = 1, layout = #M.LAYOUTS }, "hit scratchpad")
assert(M.panel_hit(p, p.x + 1, p.y + 1) == nil, "panel padding hits nothing")

-- Three windows in the left half: each a titlebar lower and 24 px further right,
-- the front one ending exactly at the zone's corner.
local fan = { M.fan(left, 3, 0, 30), M.fan(left, 3, 1, 30), M.fan(left, 3, 2, 30) }
eq(fan[1], { x = 10, y = 36, w = 1657, h = 1334 }, "fan back")
eq(fan[3], { x = 58, y = 96, w = 1657, h = 1334 }, "fan front")
assert(fan[3].x + fan[3].w == left.x + left.w and fan[3].y + fan[3].h == left.y + left.h, "fan fills the zone")
eq(M.fan(left, 1, 0, 30), left, "one window fills the zone")
assert(M.fan_slot(left, fan[2], 30) == 1, "slot of the middle window")
assert(M.fan_slot(left, { x = 300, y = 300, w = 400, h = 300 }, 30) == nil, "a loose window is no member")
assert(M.fan_slot(left, { x = 10, y = 36, w = 3000, h = 300 }, 30) == nil, "a window wider than the zone is no member")
eq(M.fan(left, 7, 5, 30), M.fan(left, 5, 0, 30), "the sixth window starts again at the back")

assert(M.json({ a = { 1, 2 }, b = "x", c = true }) == '{"a":[1,2],"b":"x","c":true}', "json")
assert(M.json({ x = 1.6 }) == '{"x":2}', "json rounds numbers")
assert(M.json("a\"b\\c") == '"a\\u0022b\\u005cc"', "json escapes")

local narrow = M.panel(M.area({ x = 0, y = 0, width = 720, height = 1280, scale = 1, transform = 0, reserved = { top = 26 } }), 0, 720)
assert(narrow.x >= 0 and narrow.x + narrow.w <= 720, "panel fits a narrow screen")

print("ok")
