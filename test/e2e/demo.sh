#!/bin/bash
# Records demo.gif: corner, edge, a custom layout in the panel, fan and drag out,
# with neutral terminals.
#
#   test/e2e/demo.sh <monitor> <workspace>   e.g. eDP-1 9
#
# The workspace must be empty and floating, and its right edge and top-left
# corner free of other monitors. Takes over the mouse for about 25 seconds.
# Needs what run.sh needs, plus wf-recorder and ffmpeg.
set -uo pipefail
MON=${1:?monitor} WS=${2:?workspace}
[[ $MON =~ ^[A-Za-z0-9-]+$ && $WS =~ ^[0-9]+$ ]] || { echo "bad monitor or workspace"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TMP=$(mktemp -d)
VP=$TMP/vpointer
cc -O2 -o "$VP" "$REPO/test/e2e/vpointer.c" $(pkg-config --cflags --libs wayland-client) || exit 1

hypr() { hyprctl dispatch "$1" >/dev/null; }
warp() { hypr "hl.dsp.cursor.move({ x = $1, y = $2 })"; }
geo() { hyprctl clients -j | jq -r --arg c "$1" '.[]|select(.class==$c)|"\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"'; }
mkfifo "$TMP/fifo"; "$VP" < "$TMP/fifo" & VP_PID=$!; exec 3>"$TMP/fifo"; sleep 0.2
vp() { printf '%s\n' "$1" >&3; }

term() {  # a terminal with a bare prompt and some neutral output
  setsid foot --app-id="$1" -T "Terminal" env PS1='$ ' ENV= sh -c "cd $REPO && clear && $2; exec sh -i" >/dev/null 2>&1 < /dev/null 3>&- &
  sleep 1.2
}
size() {
  hypr "hl.dsp.window.resize({ window = \"class:$1\", x = $2, y = $3, relative = false })"
  hypr "hl.dsp.window.move({ window = \"class:$1\", x = $4, y = $5 })"
  hypr "hl.dsp.focus({ window = \"class:$1\" })"; sleep 0.3
}
# Glide from (x0,y0) to (x1,y1) in n steps, eased.
glide() {
  local i
  for i in $(seq 1 "$5"); do
    read -r x y < <(lua -e "local t=$i/$5 t=t<.5 and 2*t*t or 1-(-2*t+2)^2/2 print(math.floor($1+($3-$1)*t), math.floor($2+($4-$2)*t))")
    warp "$x" "$y"; sleep 0.012
  done
}
grab() {  # grab $1's titlebar, return its point in GX GY
  read -r x y w h < <(geo "$1"); GX=$((x + w / 3)); GY=$((y - 15))
  warp $GX $GY; vp "move 1 0"; sleep 0.15; vp down; sleep 0.15
}
drop() { sleep 0.6; vp up; sleep 0.9; }

hyprctl monitors -j | jq -c --arg m "$MON" '.[]|select(.name==$m)' > "$TMP/monitor.json"
# One custom layout for the panel to show; the user's own come back at the end.
ID=io.github.derjungeherr.window-zones
LAYOUTS=$(omarchy bar get $ID layouts 2>/dev/null | jq -c 'if type == "array" then . else [] end' 2>/dev/null || echo '[]')
trap 'omarchy bar set $ID layouts "${LAYOUTS:-[]}" --json >/dev/null' EXIT
omarchy bar set $ID layouts '[{"cols":[60,40],"split":[false,true]}]' --json >/dev/null; sleep 2
"$HERE/plugin-env.sh" "$TMP" || { echo "could not read the running plugin"; exit 1; }
read -r MX MY MW MH < <(jq -r '"\(.x) \(.y) \(.width / .scale | floor) \(.height / .scale | floor)"' "$TMP/monitor.json")
hypr "hl.dsp.focus({ monitor = \"$MON\" })"; hypr "hl.dsp.focus({ workspace = \"$WS\" })"; sleep 0.4

term demo-a 'ls --color=never'
term demo-b 'lua test/window-zones.test.lua && lua test/runtime.test.lua'
size demo-a 700 400 $((MX + 120)) $((MY + 640))
size demo-b 700 400 $((MX + 980)) $((MY + 160))
warp $((MX + MW / 2)) $((MY + MH / 2 + 200))

wf-recorder -o "$MON" -r 30 -f "$TMP/raw.mp4" >/dev/null 2>&1 3>&- & REC=$!
sleep 1.2

# 1. Top-left corner: a quarter.
grab demo-b; glide $GX $GY $MX $MY 45; drop
# 2. Right edge: a half.
grab demo-a; glide $GX $GY $((MX + MW - 1)) $((MY + MH / 2)) 45; drop
# 3. A third window, through the panel under the clock: the custom 60 / 40, bottom right.
term demo-c 'echo "drag me under the clock"'
size demo-c 700 420 $((MX + 550)) $((MY + 420)); sleep 0.4
read -r tx ty < <(lua "$REPO/test/e2e/expect.lua" "$TMP/monitor.json" "$TMP/env" panel "Custom 1" 3)
grab demo-c; glide $GX $GY $((MX + MW / 2 + 190)) $((MY + 2)) 40; sleep 0.7
glide $((MX + MW / 2 + 190)) $((MY + 2)) "$tx" "$ty" 30; drop
# 4. Onto the taken right half: the two fan out.
grab demo-c; glide $GX $GY $((MX + MW - 1)) $((MY + MH / 2 + 60)) 45; drop
sleep 0.6
# 5. Drag out: back to its earlier size.
grab demo-c; glide $GX $GY $((MX + MW / 2 - 150)) $((MY + MH / 2)) 45; drop
sleep 1

kill -INT $REC; wait $REC 2>/dev/null
exec 3>&-; wait $VP_PID 2>/dev/null
for c in demo-a demo-b demo-c; do hypr "hl.dsp.window.close({ window = \"class:$c\" })"; done
# Without the dock strip at the bottom (it shows the user's apps), 960 px wide.
H=$(jq -r '.height' "$TMP/monitor.json"); W=$(jq -r '.width' "$TMP/monitor.json"); S=$(jq -r '.scale' "$TMP/monitor.json")
CROP=$(lua -e "print(math.floor($H - 57 * $S) // 2 * 2)")
ffmpeg -loglevel error -y -ss 0.8 -i "$TMP/raw.mp4" -vf "crop=$W:$CROP:0:0,fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" "$REPO/demo.gif"
rm -rf "$TMP"
echo "wrote $REPO/demo.gif"
