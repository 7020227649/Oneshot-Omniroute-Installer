#!/usr/bin/env bash
set -Eeuo pipefail
STACK=/opt/one-shot-omniroute
DATA=/var/lib/one-shot-omniroute
BACKUPS=/var/backups/one-shot-omniroute
ACME=/var/www/one-shot-omniroute
NGINX=/etc/nginx/conf.d/one-shot-omniroute.conf
UNIT=one-shot-omniroute-install.service
RAW=${ONE_SHOT_REPO_RAW:-https://raw.githubusercontent.com/7020227649/Oneshot-Omniroute-Installer/main}
die(){ echo "[error] $*" >&2; exit 1; }
args(){
  [[ $# == 0 || $# == 3 ]] || die 'Usage: install.sh [domain email password]'
  if [[ $# == 3 ]]; then DOMAIN=$1; EMAIL=$2; PASSWORD=$3; else
    [[ -r /dev/tty ]] || die 'Domain, email, and password are required.'
    read -r -p 'Domain: ' DOMAIN </dev/tty
    read -r -p 'Email: ' EMAIL </dev/tty
    read -r -s -p 'Dashboard password (12+ characters): ' PASSWORD </dev/tty; echo
  fi
  [[ $DOMAIN =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die 'Invalid domain.'
  [[ $EMAIL =~ ^[^[:space:]@#]+@[^[:space:]@#]+\.[^[:space:]@#]+$ ]] || die 'Invalid email.'
  [[ ${#PASSWORD} -ge 12 ]] || die 'Password must be at least 12 characters.'
}
check_os(){
  source /etc/os-release
  [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || die 'Ubuntu 22.04 is required.'
  case "$(dpkg --print-architecture)" in amd64|arm64);; *) die 'Only amd64 and arm64 are supported.';; esac
  local ram; ram=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo); (( ram >= 768 )) || die 'At least 768 MB RAM is required.'
}
swap_setup(){
  local current; current=$(free -m | awk '/^Swap:/ {print $2}')
  if (( current < 1024 )); then
    [[ -e /swapfile ]] && die '/swapfile exists; refusing to overwrite it.'
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  printf 'vm.swappiness=10\nvm.vfs_cache_pressure=50\n' >/etc/sysctl.d/99-one-shot-omniroute.conf; sysctl --system >/dev/null
}
packages(){
  export DEBIAN_FRONTEND=noninteractive; dpkg --configure -a || true; apt-get update -y
  apt-get install -y ca-certificates curl gnupg nginx certbot python3
  if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings; curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; chmod a+r /etc/apt/keyrings/docker.asc
    source /etc/os-release
    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-jammy}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update -y; apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker nginx
}
files(){
  install -d -m 0755 "$STACK" "$DATA/app" "$DATA/redis" "$BACKUPS" "$ACME"; chown -R 1000:1000 "$DATA/app"
  cat >"$STACK/.env" <<EOF
OMNIROUTE_VERSION=3.8.54
DASHBOARD_PORT=20128
API_PORT=20129
LIVE_WS_PORT=20132
APP_BIND_HOST=127.0.0.1
REQUIRE_API_KEY=true
INITIAL_PASSWORD=$PASSWORD
OMNIROUTE_MEMORY_MB=512
NEXT_PUBLIC_BASE_URL=https://$DOMAIN
BASE_URL=http://omniroute:20128
DATA_DIR=$DATA
DOMAIN=$DOMAIN
EMAIL=$EMAIL
EOF
  chmod 600 "$STACK/.env"; curl -fsSL "$RAW/compose.yaml" -o "$STACK/compose.yaml"; chmod 600 "$STACK/compose.yaml"
  for helper in status logs restart update backup; do curl -fsSL "$RAW/scripts/omniroute-$helper" -o "$STACK/omniroute-$helper"; chmod 755 "$STACK/omniroute-$helper"; ln -sfn "$STACK/omniroute-$helper" "/usr/local/bin/omniroute-$helper"; done
}
proxy_http(){
  cat >"$NGINX" <<EOF
server { listen 80; server_name $DOMAIN; location /.well-known/acme-challenge/ { root $ACME; } location / { return 301 https://\$host\$request_uri; } }
EOF
  nginx -t; systemctl reload nginx
}
stack(){
  (cd "$STACK" && docker compose pull && docker compose up -d --remove-orphans)
  for _ in {1..60}; do docker inspect --format '{{.State.Health.Status}}' one-shot-omniroute 2>/dev/null | grep -q healthy && return; sleep 3; done
  docker compose -f "$STACK/compose.yaml" logs --tail=100 omniroute || true; die 'OmniRoute did not become healthy.'
}
https(){
  certbot certonly --webroot --webroot-path "$ACME" --agree-tos --non-interactive --no-eff-email --keep-until-expiring -m "$EMAIL" -d "$DOMAIN"
  cat >"$NGINX" <<EOF
map \$http_upgrade \$omni_connection { default upgrade; '' close; }
server { listen 80; server_name $DOMAIN; location /.well-known/acme-challenge/ { root $ACME; } location / { return 301 https://\$host\$request_uri; } }
server { listen 443 ssl http2; server_name $DOMAIN; client_max_body_size 32m; ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem; ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem; ssl_protocols TLSv1.2 TLSv1.3; location / { proxy_pass http://127.0.0.1:20128; proxy_http_version 1.1; proxy_set_header Host \$host; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$omni_connection; proxy_read_timeout 3600s; proxy_buffering off; } }
EOF
  nginx -t; systemctl reload nginx; install -d /etc/letsencrypt/renewal-hooks/deploy; printf '#!/bin/sh\nsystemctl reload nginx\n' >/etc/letsencrypt/renewal-hooks/deploy/one-shot-omniroute; chmod 755 /etc/letsencrypt/renewal-hooks/deploy/one-shot-omniroute; systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}
main(){
  [[ $EUID == 0 ]] || die 'Run as root or with sudo.'; args "$@"
  if [[ ${ONE_SHOT_INSTALLER_SERVICE:-0} != 1 ]]; then install -d "$STACK"; curl -fsSL "$RAW/install.sh" -o "$STACK/install.sh"; chmod 755 "$STACK/install.sh"; systemd-run --unit="$UNIT" --collect --property=Type=exec /usr/bin/env ONE_SHOT_INSTALLER_SERVICE=1 /bin/bash "$STACK/install.sh" "$DOMAIN" "$EMAIL" "$PASSWORD"; echo "Follow: sudo journalctl -fu $UNIT"; return; fi
  check_os; swap_setup; packages; files; proxy_http; stack; https; echo "OmniRoute is ready: https://$DOMAIN"
}
main "$@"
