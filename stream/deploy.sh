#!/usr/bin/env bash
# The whole thing on one host, in one go: the PEMK server, N seats, the lobby and
# Caddy as system services. Run after stream/host-setup.sh, from the repo root, with
# Graphics/ and Audio/ next to Game.exe.
#
#   PUBLIC_IP=203.0.113.7 DOMAIN=play.example.com bash stream/deploy.sh 5
#   PUBLIC_IP=192.168.1.20 bash stream/deploy.sh 3          # LAN, plain http
#
# Re-running it is safe: it regenerates the seats, rebuilds the image if the game
# changed, and restarts the services.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SEATS="${1:-3}"
: "${PUBLIC_IP:?set PUBLIC_IP to the address your friends reach}"
: "${DOMAIN:=}"

[ -f Game.exe ] || { echo "run from the game folder (no Game.exe here)"; exit 1; }
[ -d Graphics ] && [ -d Audio ] || { echo "Graphics/ and Audio/ are missing next to Game.exe - copy them from your Windows install first"; exit 1; }
command -v docker >/dev/null && command -v caddy >/dev/null && command -v bundle >/dev/null || { echo "run stream/host-setup.sh first"; exit 1; }

echo "== the PEMK server"
if [ ! -f server/.env ]; then
  pw="$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
  sed "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${pw}/" server/.env.example > server/.env
fi
# shellcheck disable=SC1091
POSTGRES_PASSWORD="$(grep '^POSTGRES_PASSWORD=' server/.env | cut -d= -f2-)"
(cd server && docker compose up -d --build)

echo "== ${SEATS} seats"
PUBLIC_IP="$PUBLIC_IP" DOMAIN="$DOMAIN" PEMK_HOST=host.docker.internal bash stream/gen.sh "$SEATS"
(cd stream && docker compose build)
# shellcheck disable=SC1091
set -a; . stream/.env; set +a

echo "== the lobby and Caddy as services"
sudo tee /etc/systemd/system/pemk-lobby.service >/dev/null <<UNIT
[Unit]
Description=PEMK lobby (the website)
After=network.target docker.service
[Service]
User=$(id -un)
WorkingDirectory=${ROOT}/server
Environment=DATABASE_URL=postgres://pemk:${POSTGRES_PASSWORD}@127.0.0.1:${PEMK_DB_PORT:-55433}/pemk
Environment=STREAM_DIR=${ROOT}/stream
Environment=LOBBY_SECRET=${LOBBY_SECRET}
Environment=LOBBY_SECURE=$([ -n "$DOMAIN" ] && echo 1 || echo 0)
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/env bundle exec ruby ${ROOT}/stream/lobby/lobby.rb
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
sudo tee /etc/systemd/system/pemk-caddy.service >/dev/null <<UNIT
[Unit]
Description=PEMK front door (Caddy)
After=network.target
[Service]
ExecStart=/usr/bin/caddy run --config ${ROOT}/stream/Caddyfile
ExecReload=/usr/bin/caddy reload --config ${ROOT}/stream/Caddyfile
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now pemk-lobby pemk-caddy
sudo systemctl restart pemk-lobby pemk-caddy
sleep 2
curl -sf http://127.0.0.1:8090/healthz >/dev/null && echo "lobby: up" || { echo "lobby: NOT up - journalctl -u pemk-lobby"; exit 1; }

echo
echo "== open: ${DOMAIN:+https://$DOMAIN/}${DOMAIN:-http://$PUBLIC_IP/}"
echo "   firewall: 80, 443 (TCP) and UDP 52000-$((52000 + SEATS * 20 - 1))"
echo "   seats: cd stream && docker compose ps      lobby: journalctl -fu pemk-lobby"
