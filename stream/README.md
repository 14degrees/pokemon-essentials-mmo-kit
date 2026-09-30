# One website. Sign in, play.

A friend opens the address, signs in with their game account (or creates one on the
spot), and the game appears in the tab. Nothing to install, no URL or password to
hand out. Behind the address: a **lobby** (the website), a pool of **seats** (one
container each, running the game under Wine and streaming it with WebRTC: video,
audio, keyboard), and the PEMK server. The lobby gives a signed-in player a seat,
starts it with their login so the game signs in by itself, and joins the browser to
its stream. A seat nobody is watching goes back to the pool.

```
browser ──https──▶ Caddy ─┬─ /            ▶ lobby (stream/lobby/lobby.rb)  ──▶ Postgres (the game's accounts)
                          ├─ /slot1/      ▶ seat 1 (neko + Wine + Game.exe) ─┐
                          ├─ /slot2/      ▶ seat 2                          ├──▶ PEMK server :9998
                          └─ ...                                            ┘
        ◀──WebRTC (UDP)──── seats
```

Built on [neko](https://github.com/m1k1o/neko) for the streaming. The game itself is
the Windows build in this repo, untouched.

## Renting the box from the command line

With the [hcloud](https://github.com/hetznercloud/cli) CLI and an API token from the
Hetzner console, `bash stream/hcloud.sh ~/.ssh/id_ed25519.pub` creates the server,
its firewall (22, 80, 443, the WebRTC UDP range) and hands it `stream/cloud-init.yml`,
so the box installs Docker, Caddy, Ruby and the repo on its first boot. It prints the
IP. Then: point the domain, upload Graphics/ and Audio/, run `deploy.sh` over ssh.

## The short way

```bash
bash stream/host-setup.sh                                          # once: docker, caddy, ruby
# copy Graphics/ and Audio/ from your Windows install next to Game.exe
PUBLIC_IP=<the IP friends reach> DOMAIN=play.example.com bash stream/deploy.sh 5
```

`deploy.sh` brings up the server, builds and generates five seats, and installs the
lobby and Caddy as system services. Re-run it to change the seat count or after a
`git pull`. The long way, piece by piece, follows.

## Setting it up, on a Linux host with Docker

```bash
# 0. a fresh Ubuntu/Debian box: docker, caddy, ruby, and the repo
bash stream/host-setup.sh                      # (or do those four by hand)

# 1. the game folder must be complete: Graphics/ and Audio/ are not in git - copy them
#    from your Windows install next to Game.exe

# 2. the PEMK server (server/README.md), reachable from the containers
cd server && cp .env.example .env              # set POSTGRES_PASSWORD; PEMK_BIND is already 0.0.0.0
docker compose up -d --build

# 3. the seats: how many friends can play at once
cd .. && PUBLIC_IP=<the IP your friends reach> DOMAIN=play.example.com bash stream/gen.sh 5
cd stream && docker compose build              # Wine + the game, once; a few minutes
cd ..

# 4. the website and the front door
cd server && set -a && . ../stream/.env && set +a
DATABASE_URL=postgres://pemk:$POSTGRES_PASSWORD@127.0.0.1:55433/pemk LOBBY_SECURE=1 \
  bundle exec ruby ../stream/lobby/lobby.rb &                        # the lobby, :8090
sudo caddy run --config ../stream/Caddyfile &                        # https, one address
```

Then `https://play.example.com/`. Without a domain (`DOMAIN` unset) it is plain
`http://<PUBLIC_IP>/`, which browsers accept for WebRTC on a LAN.

Firewall: 80 and 443 TCP, and the seats' UDP ranges (52000-52019 for seat 1,
52020-52039 for seat 2, ...). The seats' web ports (8081+) and the lobby (8090) stay
on localhost behind Caddy.

## What happens when someone signs in

1. The lobby checks the email and password against the game's `accounts` table (the
   same bcrypt hashes the server uses; bans apply). "Create my account" makes one.
2. A free seat is written a session file (`stream/slots/slotN.env`: the login, so the
   game signs in by itself; a fresh random password for the stream) and started:
   `docker compose up -d --force-recreate slotN`. About 30 s: the container, Wine, the
   game's boot. The wait page polls.
3. When the seat's neko answers its API, the wait page logs the browser into it
   (`POST /slotN/api/login`, same origin, a cookie for that path) and goes there.
   The game is already at the load screen, signed in.
4. Every 30 s the lobby asks each seat whether anyone is connected. A seat with no
   viewer for `LOBBY_IDLE_MIN` minutes (10) after a 3-minute grace is stopped and
   freed; the player's progress is on the server, as always. Signing in again takes
   a seat again. "Cancel" on the wait page frees it at once.

The seat pool is the capacity: `gen.sh 5` means five people playing at once; the
sixth sees "every seat is taken" until one frees. Budget about 1 CPU core and 1 GB of
RAM per seat.

## Knobs

`stream/.env` (written by `gen.sh`, kept across runs):

| Var | Default | What |
|---|---|---|
| `PUBLIC_IP` | (required) | the address browsers reach, given to WebRTC (`NEKO_WEBRTC_NAT1TO1`) |
| `DOMAIN` | | the https address; unset = plain http on port 80 |
| `PEMK_HOST` / `PEMK_PORT` | `host.docker.internal` / 9998 | the PEMK server, from inside the seats |
| `SCREEN` / `FPS` | 1024x768 / 30 | the virtual screen; the game's canvas is scaled to it |
| `ADMIN_PASSWORD` | random | opens any seat's stream as admin (user `admin`), for support |

The lobby's env: `LOBBY_BIND` (127.0.0.1:8090), `LOBBY_SECRET` (cookie signing; set
it, or a restart signs everyone out), `LOBBY_SECURE=1` behind https, `LOBBY_IDLE_MIN`.

## Checking each layer

```bash
curl -s localhost:8090/healthz                                   # the lobby
cd stream && docker compose ps                                   # which seats run
docker compose logs slot1                                        # neko, X, audio
docker compose exec slot1 tail -50 /var/log/neko/pemk.log        # the game under Wine
docker compose exec slot1 cat /opt/pemk/game/mmo_slot1.log       # the PEMK client's log
```

- Stuck on "Starting your game": `docker compose ps` shows whether the seat started;
  `pemk.log` shows Wine. The lobby logs each seat it starts and why one failed.
- Joined, but a black stream: WebRTC cannot reach the browser. `PUBLIC_IP` wrong, or
  the seat's UDP range closed. `NEKO_WEBRTC_TCPMUX` is the fallback for networks that
  block UDP.
- The game shows "offline": the seat cannot reach `PEMK_HOST:PEMK_PORT`. On Linux
  hosts `host.docker.internal` needs the `extra_hosts` line gen.sh writes, and the
  server must bind `0.0.0.0`.

## Honest notes

- Written and tested here as far as it can be without Docker: the lobby's logic (sign
  in, create, bans, seats, the join, idle reaping) runs under tests against a fake
  container driver, and the compose output validates. The first `docker compose up`
  on your host is the first real run of Wine + the game + neko together. Use the
  checks above.
- The seat's session file holds the player's password in clear for the game to sign
  in with (mode 600, on the host, deleted when the seat is freed). A token-based
  client login would remove that; it is a small client change.
- Streaming latency: fine for battles and menus, noticeable walking. A web-native
  client (the browser rendering the game itself over `PEMK_WS_PORT`) is the long
  route, and removes the per-seat cost - `docs/CHAIN-DESIGN.md` §6.
