#!/usr/bin/env bash
#==============================================================================
# Send one command to an autopilot-controlled game window and print its reply.
#
#   tools/autopilot/ap.sh <channel-dir> <verb> [args...]
#
#   ap.sh autopilot/ap1 state              # JSON snapshot of the game
#   ap.sh autopilot/ap1 press USE          # tap a key (USE BACK ACTION UP DOWN...)
#   ap.sh autopilot/ap1 hold DOWN          # keep it down until "release DOWN"
#   ap.sh autopilot/ap1 wait 60            # let 60 frames pass
#   ap.sh autopilot/ap1 screenshot         # PNG in the channel directory
#
# The game must run as a debug launch with PEMK_AUTOPILOT=<channel-dir>; see
# Plugins/PEMK/011_Autopilot. AP_TIMEOUT sets the reply timeout in seconds (30).
# Exit status: 0 on a reply, 1 on timeout, 2 on bad usage.
#==============================================================================
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: ap.sh <channel-dir> <verb> [args...]" >&2
  exit 2
fi
dir="$1"
shift
if [ ! -d "$dir" ]; then
  echo "no channel directory: $dir (start the game with PEMK_AUTOPILOT=$dir)" >&2
  exit 2
fi

timeout="${AP_TIMEOUT:-30}"
id="$(date +%s%N)$$"
resp="$dir/resp.txt"

rm -f "$resp"
printf '%s %s\n' "$id" "$*" > "$dir/.cmd.tmp"
mv -f "$dir/.cmd.tmp" "$dir/cmd.txt"

deadline=$(( $(date +%s) + timeout ))
while :; do
  if [ -f "$resp" ]; then
    body="$(cat "$resp")"
    case "$body" in
      *"\"id\": \"$id\""*)
        rm -f "$resp"
        printf '%s\n' "$body"
        exit 0
        ;;
    esac
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf '{"ok": false, "error": "no reply within %ss"}\n' "$timeout"
    exit 1
  fi
  sleep 0.05
done
