#!/usr/bin/env bash
# A fresh Ubuntu/Debian host -> everything the website needs: Docker, Caddy, Ruby with
# the server's gems. Run once, as a user with sudo, from the repo (stream/README.md
# takes it from there). Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
fi
sudo usermod -aG docker "$USER" || true

echo "== caddy"
if ! command -v caddy >/dev/null; then
  sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  sudo apt-get update && sudo apt-get install -y caddy
  sudo systemctl disable --now caddy || true     # run it by hand with stream/Caddyfile (or point the unit at it)
fi

echo "== ruby + the server's gems (the lobby runs on the host)"
sudo apt-get install -y ruby ruby-dev ruby-bundler build-essential libpq-dev libpq5
(cd server && bundle config set --local path vendor/bundle && bundle install)

echo "== done. Next: stream/README.md, from step 1 (Graphics/ and Audio/ next to Game.exe)."
echo "   log out and in again so your user is in the docker group."
