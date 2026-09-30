# Play in a browser tab: one streamed game per player

Each friend opens a URL, logs in with their password, and plays their own character.
Behind the URL is their own copy of the game, running on your host and streamed to
the tab with WebRTC (video, audio, keyboard), the way cloud gaming works. The game
is untouched: it is `Game.exe` under Wine, connecting to the PEMK server like any
client. What this buys: everybody in a browser, this week, with the full game. What
it costs: one game process per player on the host, and streaming latency.

Built on [neko](https://github.com/m1k1o/neko) (the display, audio, WebRTC and web
page), plus Wine and the game (`Dockerfile`), one container per player (`gen.sh`).

## Setup, on a Linux host with Docker

```bash
# 1. the game folder must be complete here: Game.exe, Data/, Graphics/, Audio/, Plugins/
#    (Graphics/ and Audio/ are not in git - copy them from your Windows install)
# 2. the PEMK server, as usual (server/README.md); it listens on 9998
# 3. one container per player
export PUBLIC_IP=<the IP your friends reach>      # LAN IP, or the public IP / VPN IP
export PEMK_HOST=<this host's LAN IP>             # where the containers find the server
bash stream/gen.sh ash misty brock                # prints each player's URL and password
cd stream && docker compose up --build -d         # first build: Wine + the game, a few minutes
```

Each player: `http://PUBLIC_IP:8081/ash/`, `:8082/misty/`, ... user `neko`, the printed
password (kept in `stream/.env`, never committed). The first start of a container
takes about 30 s longer (Wine builds its prefix), then the game boots; the load screen
offers **Create account** as on Windows. Everything after that is the normal game.

Firewall: each player's web port (8081+) TCP and their UDP range (52000-52019,
52020-52039, ...). WebRTC media goes over the UDP range directly, not through a proxy.

### One https address

Browsers allow WebRTC on `http://` only for `localhost`; over the internet you need
https. `gen.sh` writes a `Caddyfile` for `DOMAIN=play.example.com`: one domain, a
path per player (`https://play.example.com/ash/`), certificates from Let's Encrypt.
Run [Caddy](https://caddyserver.com) on the host next to the containers
(`caddy run --config stream/Caddyfile`), open 80/443, and keep the UDP ranges open.
On a LAN, `http://` to the host's IP works as is in Chrome and Firefox when the page
and the media come from the same private address; if not, use the domain.

## Knobs (stream/.env, then `gen.sh` again)

| Var | Default | What |
|---|---|---|
| `PUBLIC_IP` | (required) | the address the browsers reach, given to WebRTC (`NEKO_WEBRTC_NAT1TO1`) |
| `PEMK_HOST` / `PEMK_PORT` | `host.docker.internal` / 9998 | the PEMK server, from inside the containers |
| `SCREEN` / `FPS` | 1024x768 / 30 | the virtual screen; the game's 512x384 canvas is scaled to it |
| `DOMAIN` | | the https address for the Caddyfile |
| `PASSWORD_<PLAYER>` | random | that player's login; `ADMIN_PASSWORD` opens any room as admin |

A container's env also takes `PEMK_DEBUG=1` (the F9 tools, as `PlayMMO-debug.bat`)
and `PEMK_EMAIL` / `PEMK_PASSWORD` to pre-fill a login.

## How to check each layer when something is off

```bash
docker compose logs play-ash                 # neko, X, PulseAudio
docker compose exec play-ash tail -50 /var/log/neko/pemk.log     # the game under Wine
docker compose exec play-ash cat /opt/pemk/game/mmo_ash.log      # the PEMK client's own log
docker compose exec play-ash glxinfo -B      # software OpenGL on the virtual display
```

- The page loads but stays black: WebRTC cannot reach you. `PUBLIC_IP` wrong, or the
  UDP range closed. `NEKO_WEBRTC_TCPMUX` (one TCP port per player) is the fallback for
  networks that block UDP - set it in the compose file and open that port.
- The page shows a desktop but no game: read `pemk.log`. Wine prints the reason
  (a missing DLL, no OpenGL).
- The game runs but shows "offline": `PEMK_HOST` is not reachable from the container.
  On Linux hosts `host.docker.internal` needs the `extra_hosts` line the generator
  writes; the server must bind `0.0.0.0` (`PEMK_BIND`), not `127.0.0.1`.

## Honest notes

- This stack was written and validated (`docker compose config`, the scripts) without
  running it: the working copy here has no Docker daemon, no Graphics/ or Audio/ folder,
  and no Wine. The first `docker compose up` on your host is its first run. The pieces
  are each well trodden (neko streams desktops for a living; mkxp-z runs under Wine),
  the joint between them is what needs your first run. Use the checks above.
- A Linux build of mkxp-z instead of Wine is a small change to `start.sh` (exec the
  binary instead of `wine64 Game.exe`) once one is dropped into the game folder; it
  would be lighter and faster. The Windows build is used because it is the one in the
  repo and known to run this game.
- Latency is streaming latency: fine for a turn-based RPG, noticeable when walking.
  30 fps default; `FPS=60` costs bandwidth.
- Each player is a full game process: budget about 1 CPU core and 1 GB RAM per
  concurrent player on the host.
- A web-native client (the game rendered by the browser itself, over `PEMK_WS_PORT`)
  is the long-term route and a separate, much larger build - `docs/CHAIN-DESIGN.md` §6.
