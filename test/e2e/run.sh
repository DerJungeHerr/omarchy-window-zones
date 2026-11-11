#!/bin/bash
# End-to-end tests on a live Omarchy session: real drags through a virtual
# pointer, expected geometry from the plugin's own functions.
#
#   test/e2e/run.sh [workspace]      default workspace 17; it should be empty and floating
#
# Takes over the mouse for about a minute and opens throwaway terminals.
# Needs: foot, jq, lua, cc, wayland-client headers.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WS=${1:-17}
TMP=${XDG_RUNTIME_DIR:-/tmp}/window-zones-e2e
ID=io.github.derjungeherr.window-zones
mkdir -p "$TMP"
VP=$TMP/vpointer
[[ $VP -nt $HERE/vpointer.c ]] || cc -O2 -o "$VP" "$HERE/vpointer.c" $(pkg-config --cflags --libs wayland-client) || exit 1

pass=0 fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

hypr() { hyprctl dispatch "$1" >/dev/null; }
warp() { hypr "hl.dsp.cursor.move({ x = $1, y = $2 })"; }
geo() { hyprctl clients -j | jq -r --arg c "$1" '.[]|select(.class==$c)|"\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"'; }
addr() { hyprctl clients -j | jq -r --arg c "$1" '.[]|select(.class==$c)|.address'; }
active() { hyprctl activewindow -j | jq -r .class; }

# The virtual pointer reads commands from a fifo, so warps can go in between.
vp_start() { rm -f "$TMP/fifo"; mkfifo "$TMP/fifo"; "$VP" < "$TMP/fifo" & VP_PID=$!; exec 3>"$TMP/fifo"; sleep 0.2; }
vp() { printf '%s\n' "$1" >&3; }
vp_stop() { exec 3>&-; wait "$VP_PID" 2>/dev/null; }

open() { setsid foot --app-id="$1" -T "$1" sh -c 'exec sleep infinity' >/dev/null 2>&1 < /dev/null & sleep 1.3; }
close() { for c in "$@"; do hypr "hl.dsp.window.close({ window = \"class:$c\" })"; done; sleep 0.5; }
reset() {
  hypr "hl.dsp.window.resize({ window = \"class:$1\", x = 900, y = 600, relative = false })"
  hypr "hl.dsp.window.center({ window = \"class:$1\" })"
  hypr "hl.dsp.focus({ window = \"class:$1\" })"
  hypr "hl.dsp.window.alter_zorder({ window = \"class:$1\", mode = \"top\" })"; sleep 0.3
}

# Grab the titlebar of $1 and glide to ($2, $3); hold still (release probe) and let go.
drag_to() {
  local x y w h gx gy i
  read -r x y w h < <(geo "$1")
  gx=$((x + w / 3)); gy=$((y - 15))
  warp $gx $gy; vp "move 1 0"; sleep 0.1; vp down; sleep 0.1
  for i in $(seq 1 20); do warp $((gx + ($2 - gx) * i / 20)) $((gy + ($3 - gy) * i / 20)); sleep 0.02; done
  sleep 0.5; vp up; sleep 0.7
}

monitor() { hyprctl monitors -j | jq -c '.[]|select(.focused)' > "$TMP/monitor.json"; }
expect() { lua "$HERE/expect.lua" "$TMP/monitor.json" "$TMP/env" "$@"; }

# Compare a window with an expected client box, within 2 px.
near() {
  local name=$1 class=$2; shift 2
  local got want; got=$(geo "$class"); want="$*"
  read -r gx gy gw gh <<< "$got"; read -r wx wy ww wh <<< "$want"
  for p in "$gx $wx" "$gy $wy" "$gw $ww" "$gh $wh"; do
    read -r a b <<< "$p"
    if [[ -z $a ]] || (( a - b > 2 || b - a > 2 )); then bad "$name" "got '$got' want '$want'"; return; fi
  done
  ok "$name"
}

# --- setup --------------------------------------------------------------
# Hover focus would focus the back window of a fan before a peek can show; test
# with Omarchy's click focus and put the user's choice back afterwards.
HOVER=$(omarchy bar get $ID hoverFocus 2>/dev/null); [[ $HOVER == true ]] || HOVER=false
omarchy bar set $ID hoverFocus false --json >/dev/null; sleep 2
trap 'omarchy bar set $ID hoverFocus $HOVER --json >/dev/null' EXIT
hypr "hl.dsp.focus({ workspace = \"$WS\" })"; sleep 0.4
[[ $(omarchy hyprland workspace layout current "$WS") == floating ]] || { echo "workspace $WS is not floating"; exit 1; }
monitor
hyprctl eval 'local d = window_zones_dock
  local f = io.open(os.getenv("XDG_RUNTIME_DIR") .. "/window-zones-e2e/env", "w")
  local function opt(k, d) local ok, v = pcall(hl.get_config, k) if type(v) == "table" then v = v.top end return ok and v or d end
  f:write(d and d.edge or "none", " ", d and d.size or 0, " ", opt("plugin:hyprbars:bar_height", 0), " ", opt("general:gaps_out", 10), " ", opt("general:gaps_in", 5), "\n")
  f:close()' >/dev/null
sleep 0.2
read -r MX MY MW MH < <(jq -r '"\(.x) \(.y) \(.width / .scale | floor) \(.height / .scale | floor)"' "$TMP/monitor.json")
echo "monitor $(jq -r .name "$TMP/monitor.json") ${MW}x${MH} at $MX,$MY, env: $(cat "$TMP/env")"

# Heights along a side where it is a real screen edge (free) or where another
# monitor carries on (shared); empty when there is none.
side_y() {
  local x; [[ $1 == left ]] && x=$((MX - 1)) || x=$((MX + MW))
  hyprctl monitors -j | jq -r --argjson x $x --argjson y0 $((MY + 60)) --argjson y1 $((MY + MH - 60)) --arg want "$2" '
    [ .[] | {x, y, w: (.width / .scale), h: (.height / .scale)} ] as $ms
    | first(range($y0; $y1; 10) | . as $y
        | ([ $ms[] | select($x >= .x and $x < .x + .w and $y >= .y and $y < .y + .h) ] | length > 0) as $shared
        | select(($want == "shared") == $shared)) // empty'
}
# The side fans and drag-outs use: a free edge, left if possible.
if FY=$(side_y left free); [[ -n $FY ]]; then FX=$MX FCELL=1; else FY=$(side_y right free); FX=$((MX + MW - 1)) FCELL=2; fi
vp_start

# --- edges and corners --------------------------------------------------
open wz1
for side in left right; do
  y=$(side_y $side free); x=$MX; cell=1; [[ $side == right ]] && x=$((MX + MW - 1)) cell=2
  if [[ -n $y ]]; then reset wz1; drag_to wz1 $x $y; near "$side edge" wz1 $(expect cell Halves $cell); fi
  y=$(side_y $side shared)
  if [[ -n $y ]]; then
    reset wz1; drag_to wz1 $x $y; read -r gx gy gw gh < <(geo wz1)
    [[ "$gw $gh" == "900 600" ]] && ok "$side edge shared with a monitor: no snap" || bad "$side edge shared with a monitor: no snap" "got $gw x $gh"
    hypr "hl.dsp.window.move({ window = \"class:wz1\", workspace = \"$WS\" })"; sleep 0.3
  fi
done
reset wz1; drag_to wz1 $MX $MY;                                  near "top-left corner" wz1 $(expect cell Quarters 1)
reset wz1; drag_to wz1 $((MX + MW - 1)) $MY;                     near "top-right corner" wz1 $(expect cell Quarters 2)
reset wz1; drag_to wz1 $MX $((MY + MH - 1));                     near "bottom-left corner" wz1 $(expect cell Quarters 3)
reset wz1; drag_to wz1 $((MX + MW - 1)) $((MY + MH - 1));        near "bottom-right corner" wz1 $(expect cell Quarters 4)

# --- panel --------------------------------------------------------------
panel_drop() {
  local x y w h gx gy i
  read -r x y w h < <(geo "$1"); gx=$((x + w / 3)); gy=$((y - 15))
  read -r tx ty < <(expect panel "$2" "$3")
  warp $gx $gy; vp "move 1 0"; sleep 0.1; vp down; sleep 0.1
  for i in $(seq 1 15); do warp $((gx + (MX + MW / 2 - gx) * i / 15)) $((gy + (MY + 2 - gy) * i / 15)); sleep 0.02; done
  sleep 0.3
  for i in $(seq 1 10); do warp $((MX + MW / 2 + (tx - MX - MW / 2) * i / 10)) $((MY + 2 + (ty - MY - 2) * i / 10)); sleep 0.02; done
  sleep 0.5; vp up; sleep 0.7
}
reset wz1; panel_drop wz1 Thirds 2;                              near "panel thirds middle" wz1 $(expect cell Thirds 2)
reset wz1; panel_drop wz1 Centre 2;                              near "panel centre" wz1 $(expect cell Centre 2)
reset wz1; panel_drop wz1 Scratchpad 1
[[ $(hyprctl clients -j | jq -r '.[]|select(.class=="wz1")|.workspace.name') == special:scratchpad ]] && ok "panel scratchpad" || bad "panel scratchpad" "not on special:scratchpad"
hypr "hl.dsp.window.move({ window = \"class:wz1\", workspace = \"$WS\" })"; sleep 0.3

# --- plain drag and restore ---------------------------------------------
reset wz1; drag_to wz1 $FX $FY
drag_to wz1 $((MX + MW / 2)) $((MY + MH / 2))
read -r x y w h < <(geo wz1); [[ "$w $h" == "900 600" ]] && ok "drag out restores the size" || bad "drag out restores the size" "got $w x $h"

reset wz1; drag_to wz1 $FX $FY
omarchy bar set $ID fanOffset 26 --json >/dev/null; sleep 2
omarchy bar set $ID fanOffset 24 --json >/dev/null; sleep 2
drag_to wz1 $((MX + MW / 2)) $((MY + MH / 2))
read -r x y w h < <(geo wz1); [[ "$w $h" == "900 600" ]] && ok "restore survives a settings change" || bad "restore survives a settings change" "got $w x $h"

# --- fans ---------------------------------------------------------------
open wz2; open wz3
for c in wz1 wz2 wz3; do reset $c; drag_to $c $FX $FY; done
near "fan back" wz1 $(expect cell Halves $FCELL 3 0)
near "fan middle" wz2 $(expect cell Halves $FCELL 3 1)
near "fan front" wz3 $(expect cell Halves $FCELL 3 2)

# peek: rest on the back window's visible titlebar strip
read -r x y w h < <(geo wz1); warp $((x + w / 2)) $((y - 15)); vp "move 1 0"; sleep 0.6
[[ $(hyprctl getprop "address:$(addr wz1)" opacity) != 1 ]] && ok "peek" || bad "peek" "back window stays opaque"
warp $((MX + MW - 50)) $((MY + MH / 2)); vp "move 1 1"; sleep 0.3
[[ $(hyprctl getprop "address:$(addr wz1)" opacity) == 1 ]] && ok "peek ends" || bad "peek ends" "still see-through"

close wz2
near "close: back stays" wz1 $(expect cell Halves $FCELL 2 0)
near "close: front closes up" wz3 $(expect cell Halves $FCELL 2 1)
hypr "hl.dsp.focus({ window = \"class:wz3\" })"; sleep 0.2
drag_to wz3 $((MX + MW / 2)) $((MY + MH / 2))
near "drag out: last one fills the zone" wz1 $(expect cell Halves $FCELL)
close wz1 wz3

# --- new window size ----------------------------------------------------
omarchy bar set $ID newWindowSize 120 --json >/dev/null; sleep 2
open wz4
read -r x y w h < <(geo wz4)
want_w=$(lua -e "print(math.floor(math.min(math.min(1100, $MW * 0.64) * 1.2, $MW * 0.9)))")
want_h=$(lua -e "print(math.floor(math.min(math.min(760, $MH * 0.68) * 1.2, $MH * 0.9)))")
(( w - want_w <= 2 && want_w - w <= 2 && h - want_h <= 2 && want_h - h <= 2 )) && ok "new window size 120 %" || bad "new window size 120 %" "got $w x $h want $want_w x $want_h"
close wz4
omarchy bar set $ID newWindowSize 100 --json >/dev/null; sleep 2

vp_stop
echo "$pass passed, $fail failed"
(( fail == 0 ))
