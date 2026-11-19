#!/bin/bash
# Writes what expect.lua needs from the running plugin into <dir>:
#   env          "dock_edge dock_size bar gaps_out gaps_in"
#   env.layouts  the panel's layouts, custom ones included, as a Lua table
dir=${1:?dir}
[[ $dir =~ ^[A-Za-z0-9/._-]+$ ]] || { echo "unexpected path $dir" >&2; exit 1; }
hyprctl eval 'local d = window_zones_dock
  local f = io.open("'"$dir"'/env", "w")
  local function opt(k, d) local ok, v = pcall(hl.get_config, k) if type(v) == "table" then v = v.top end return ok and v or d end
  f:write(d and d.edge or "none", " ", d and d.size or 0, " ", opt("plugin:hyprbars:bar_height", 0), " ", opt("general:gaps_out", 10), " ", opt("general:gaps_in", 5), "\n")
  f:close()
  local out = {}
  for _, l in ipairs(window_zones.LAYOUTS) do
    local cells = {}
    for _, c in ipairs(l.cells) do cells[#cells + 1] = string.format("{%q,%q,%q,%q}", c[1], c[2], c[3], c[4]) end
    out[#out + 1] = string.format("{name=%q,scratchpad=%s,cells={%s}}", l.name, tostring(l.scratchpad == true), table.concat(cells, ","))
  end
  f = io.open("'"$dir"'/env.layouts", "w")
  f:write("return {", table.concat(out, ","), "}\n")
  f:close()' >/dev/null
sleep 0.2
[[ -s $dir/env && -s $dir/env.layouts ]]
