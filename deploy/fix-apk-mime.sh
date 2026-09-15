#!/usr/bin/env bash
set -euo pipefail
MT=/etc/nginx/mime.types
mkdir -p /root/nginx-backups
cp -a "$MT" /root/nginx-backups/mime.types.bak2
if ! grep -q 'vnd.android.package-archive' "$MT"; then
  # Insert the apk type just before the closing brace of the types{} block.
  sed -i 's/^}$/    application\/vnd.android.package-archive        apk;\n}/' "$MT"
fi
echo '--- tail ---'
tail -3 "$MT"
nginx -t
systemctl reload nginx
echo RELOADED
curl -sk -o /dev/null -w 'apk content-type: %{content_type}\n' https://bizprozmco.com/app/bizcom.apk
