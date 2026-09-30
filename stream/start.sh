#!/usr/bin/env bash
# Starts this player's game under Wine on the neko display. Runs as the neko user,
# supervised (restarted if the game exits). Writes the client's config from the
# container's env first, so one image serves every player.
set -euo pipefail
GAME=/opt/pemk/game
cd "$GAME"

: "${PEMK_HOST:=host.docker.internal}"
: "${PEMK_PORT:=9998}"
: "${PEMK_INSTANCE:=player}"
: "${PEMK_SCREEN:=1024x768}"

# The instance's config (Plugins/PEMK/README.md): its own account, session, log and
# local save. A DEV login can be pre-filled with PEMK_EMAIL / PEMK_PASSWORD.
cfg="mmo_config_${PEMK_INSTANCE}.txt"
{
  echo "host = ${PEMK_HOST}"
  echo "port = ${PEMK_PORT}"
  [ -n "${PEMK_EMAIL:-}" ]    && echo "email = ${PEMK_EMAIL}"
  [ -n "${PEMK_PASSWORD:-}" ] && echo "password = ${PEMK_PASSWORD}"
} > "$cfg"

# The window fills the virtual screen: the game canvas (512x384) is scaled up by the
# engine. PEMK_SCREEN matches NEKO_DESKTOP_SCREEN's WxH.
w="${PEMK_SCREEN%x*}"; h="${PEMK_SCREEN#*x}"
sed -i -E "s/(\"defScreenW\": *)[0-9]+/\1${w}/; s/(\"defScreenH\": *)[0-9]+/\1${h}/" mkxp.json

# Wine: a prefix per container, made once (the first start takes ~30 s longer).
export WINEPREFIX="${HOME}/.wine"
export WINEDEBUG="${WINEDEBUG:--all}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export RUBY_THREAD_VM_STACK_SIZE=16777216   # as PlayMMO-*.bat: headroom for the boot stack
[ -d "$WINEPREFIX" ] || wineboot -u >/dev/null 2>&1 || true

export PEMK_INSTANCE
args=()
[ "${PEMK_DEBUG:-0}" = "1" ] && args+=(debug)   # the F9 tools, as PlayMMO-debug.bat
exec wine64 Game.exe "${args[@]}"
