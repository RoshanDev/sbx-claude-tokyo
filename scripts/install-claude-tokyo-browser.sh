#!/usr/bin/env bash
set -euo pipefail

SANDBOX="${1:-claude-wsl}"
CHROME_DEB_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"

echo "Installing base packages in sandbox: ${SANDBOX}"
sbx exec -u root "${SANDBOX}" sh -lc '
  set -e
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl locales fontconfig fonts-noto-cjk \
    xvfb dbus-x11 x11vnc novnc websockify openbox
  locale-gen en_US.UTF-8 ja_JP.UTF-8
'

echo "Installing Google Chrome in sandbox: ${SANDBOX}"
sbx exec -u root "${SANDBOX}" sh -lc "
  set -e
  if ! command -v google-chrome >/dev/null 2>&1; then
    curl -L --fail --show-error \
      --output /tmp/google-chrome-stable_current_amd64.deb \
      '${CHROME_DEB_URL}'
    DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/google-chrome-stable_current_amd64.deb
  fi
  google-chrome --version
"

echo "Verifying Chrome locale and timezone signals"
sbx exec "${SANDBOX}" sh -lc '
  TZ=Asia/Tokyo LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 \
  google-chrome \
    --headless=new \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --disable-background-networking \
    --lang=ja-JP \
    --user-data-dir="$HOME/.cache/chrome-sbx-check" \
    --dump-dom "data:text/html,<script>document.write(JSON.stringify({timeZone:Intl.DateTimeFormat().resolvedOptions().timeZone,locale:Intl.DateTimeFormat().resolvedOptions().locale,languages:navigator.languages,language:navigator.language,offset:new Date().getTimezoneOffset()}))</script>" \
    2>/dev/null | sed -n "1,3p"
'

echo "Done."

