#!/usr/bin/env bash
# Deploy the chatstub Dart backend on the server (Ubuntu 24.04).
# Installs the Dart SDK if needed, builds a native exe, runs it under
# systemd on 127.0.0.1:8444, and TLS-terminates it via nginx on :8443.
#
# Expects the source bundle already extracted under /opt/chatstub:
#   /opt/chatstub/dart/chatstub-server   (this app)
#   /opt/chatstub/cpp/dart_sip/packages  (path deps)
#
#   bash deploy-stub.sh
set -euo pipefail

BASE=/opt/chatstub
APP="$BASE/dart/chatstub-server"
DART=/usr/lib/dart/bin/dart
HOST=bizprozmco.com

echo "==> Ensuring Dart SDK"
if ! [ -x "$DART" ] && ! command -v dart >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y apt-transport-https wget gnupg
  wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /usr/share/keyrings/dart.gpg
  echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main' \
    > /etc/apt/sources.list.d/dart_stable.list
  apt-get update -y
  apt-get install -y dart
fi
command -v dart >/dev/null 2>&1 || export PATH="$PATH:/usr/lib/dart/bin"
DART="$(command -v dart || echo /usr/lib/dart/bin/dart)"
"$DART" --version

echo "==> pub get + compile"
cd "$APP"
"$DART" pub get
mkdir -p bin data
"$DART" compile exe bin/server.dart -o bin/chatstub-server

echo "==> Writing production config"
mkdir -p "$APP/config" "$APP/data"
cat > "$APP/config/prod.yaml" <<CFG
host: 127.0.0.1
port: 8444
publicHost: ${HOST}
tlsCertPath: ./certs/unused.crt
tlsKeyPath: ./certs/unused.key
dbPath: ./data/rainbow.db
fileStorePath: ./data/files
avatarStorePath: ./data/avatars
auth:
  appId: 65c681c01c8f11e9add8932b358ef81d
  appSecret: UYdu3wCXTdfyjImhURnIkZ0tac5J9XSLszIKBRUUWVB35b6nT3fWV2BhAGhojdBQ
  tokenTtlSeconds: 86400
  renewTtlSeconds: 172800
asterisk:
  ariUrl: http://127.0.0.1:8088/asterisk/ari
  ariUser: asterisk
  ariPassword: asterisk
  wsSipUrl: wss://${HOST}:8089/asterisk/ws
  sipDomain: ${HOST}
tls:
  enabled: false
  autoGenerate: false
logs:
  format: text
metrics:
  enabled: true
  path: /metrics
CFG

echo "==> systemd unit"
cat > /etc/systemd/system/chatstub-stub.service <<UNIT
[Unit]
Description=chatstub Dart backend (stub)
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP}
ExecStart=${APP}/bin/chatstub-server --config config/prod.yaml
Restart=on-failure
RestartSec=3
# Dev stub; runs as root for simplicity of /opt paths + data writes.

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now chatstub-stub.service
sleep 2
systemctl --no-pager --full status chatstub-stub.service | head -12 || true

echo "==> nginx websocket upgrade map"
cat > /etc/nginx/conf.d/chatstub-upgrade.conf <<'MAP'
map $http_upgrade $chatstub_conn_upgrade {
    default upgrade;
    ''      close;
}
MAP

echo "==> nginx TLS proxy on :8443 -> 127.0.0.1:8444"
cat > /etc/nginx/sites-enabled/chatstub-stub <<NGX
server {
    listen 8443 ssl http2;
    listen [::]:8443 ssl http2;
    server_name ${HOST};

    ssl_certificate     /etc/letsencrypt/live/${HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HOST}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:8444;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$chatstub_conn_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGX

echo "==> nginx test + reload"
nginx -t
systemctl reload nginx

echo "==> Health checks"
sleep 1
curl -sk -o /dev/null -w 'local  :8444/health -> %{http_code}\n' http://127.0.0.1:8444/health || true
curl -sk -o /dev/null -w 'tls    :8443/health -> %{http_code}\n' https://${HOST}:8443/health || true

echo ""
echo "==> Done. Stub: https://${HOST}:8443/  (proxied to 127.0.0.1:8444)"
echo "Logs: journalctl -u chatstub-stub -f"
