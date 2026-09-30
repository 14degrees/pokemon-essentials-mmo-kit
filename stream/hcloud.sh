#!/usr/bin/env bash
# Creates the host on Hetzner Cloud with the hcloud CLI: the server (Ubuntu 24.04,
# CPX41: 8 vCPU, 16 GB, enough for ~6 seats), a firewall with exactly the ports the
# website needs, your SSH key, and stream/cloud-init.yml so the box readies itself
# on first boot. Prints the IP to point your domain at.
#
#   hcloud context create pemk          # once: paste an API token from the Hetzner console
#   bash stream/hcloud.sh ~/.ssh/id_ed25519.pub [server-type] [location]
#
# Then, after the box has booted (a few minutes; `ssh root@IP` and read /etc/motd):
#   upload Graphics/ and Audio/ into /root/pemk, and
#   ssh root@IP 'cd pemk && PUBLIC_IP=<ip> DOMAIN=play.example.com bash stream/deploy.sh 5'
set -euo pipefail
cd "$(dirname "$0")/.."
KEY="${1:?path to your SSH public key}"
TYPE="${2:-cpx41}"
LOC="${3:-nbg1}"
command -v hcloud >/dev/null || { echo "install hcloud: https://github.com/hetznercloud/cli (brew install hcloud / winget install Hetzner.hcloud)"; exit 1; }

hcloud ssh-key describe pemk >/dev/null 2>&1 || hcloud ssh-key create --name pemk --public-key-from-file "$KEY"

if ! hcloud firewall describe pemk-play >/dev/null 2>&1; then
  hcloud firewall create --name pemk-play
  hcloud firewall add-rule pemk-play --direction in --protocol tcp --port 22    --source-ips 0.0.0.0/0 --source-ips ::/0 --description ssh
  hcloud firewall add-rule pemk-play --direction in --protocol tcp --port 80    --source-ips 0.0.0.0/0 --source-ips ::/0 --description http
  hcloud firewall add-rule pemk-play --direction in --protocol tcp --port 443   --source-ips 0.0.0.0/0 --source-ips ::/0 --description https
  hcloud firewall add-rule pemk-play --direction in --protocol udp --port 52000-52199 --source-ips 0.0.0.0/0 --source-ips ::/0 --description webrtc
fi

if ! hcloud server describe pemk-play >/dev/null 2>&1; then
  hcloud server create --name pemk-play --type "$TYPE" --image ubuntu-24.04 --location "$LOC" \
    --ssh-key pemk --firewall pemk-play --user-data-from-file stream/cloud-init.yml
fi
IP="$(hcloud server ip pemk-play)"
echo
echo "server pemk-play: $IP  (ssh root@$IP; first boot takes a few minutes - cat /etc/motd)"
echo "point your domain's A record at $IP, upload Graphics/ and Audio/ into /root/pemk, then:"
echo "  ssh root@$IP 'cd pemk && PUBLIC_IP=$IP DOMAIN=play.example.com bash stream/deploy.sh 5'"
