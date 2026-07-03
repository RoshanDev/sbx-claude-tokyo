#!/usr/bin/env bash
set -euo pipefail

SANDBOX="${1:-claude-wsl}"
HOST_PORT="${HOST_PORT:-6080}"
SANDBOX_PORT=6080
DISPLAY_NUM="${DISPLAY_NUM:-99}"

echo "Starting sandbox keeper: ${SANDBOX}"
sbx run --name "${SANDBOX}" --detached >/dev/null

echo "Preparing X11 socket directory"
sbx exec -u root "${SANDBOX}" sh -lc 'mkdir -p /tmp/.X11-unix && chown root:root /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix'

echo "Starting Xvfb, Openbox, Chrome, x11vnc, and noVNC"
sbx exec "${SANDBOX}" sh -lc "
  pkill -f '[X]vfb :${DISPLAY_NUM}' 2>/dev/null || true
  pkill -f '[x]11vnc -display :${DISPLAY_NUM}' 2>/dev/null || true
  pkill -f '[w]ebsockify --web=/usr/share/novnc 0.0.0.0:${SANDBOX_PORT}' 2>/dev/null || true
  pkill -f '[g]oogle-chrome.*\\.chrome-claude-jp' 2>/dev/null || true
  pkill -x openbox 2>/dev/null || true
  rm -f /tmp/sbx-xvfb.log /tmp/sbx-openbox.log /tmp/sbx-chrome.log /tmp/sbx-x11vnc.log /tmp/sbx-novnc.log
"

sbx exec "${SANDBOX}" sh -lc "
  set -e
  setsid -f Xvfb :${DISPLAY_NUM} -screen 0 1280x900x24 -nolisten tcp -ac >/tmp/sbx-xvfb.log 2>&1
  sleep 1
  DISPLAY=:${DISPLAY_NUM} setsid -f openbox >/tmp/sbx-openbox.log 2>&1
  DISPLAY=:${DISPLAY_NUM} TZ=Asia/Tokyo LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 \
    setsid -f google-chrome \
      --no-sandbox \
      --disable-dev-shm-usage \
      --no-first-run \
      --no-default-browser-check \
      --lang=ja-JP \
      --user-data-dir=\"\$HOME/.chrome-claude-jp\" \
      --window-size=1280,900 \
      about:blank >/tmp/sbx-chrome.log 2>&1
  env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE \
    setsid -f x11vnc -display :${DISPLAY_NUM} -localhost -nopw -forever -shared -rfbport 5900 >/tmp/sbx-x11vnc.log 2>&1
  setsid -f websockify --web=/usr/share/novnc 0.0.0.0:${SANDBOX_PORT} localhost:5900 >/tmp/sbx-novnc.log 2>&1
  sleep 2
  netstat -ltnp 2>/dev/null | grep -E ':(5900|${SANDBOX_PORT})' || true
"

echo "Publishing ${HOST_PORT} on all IPv4 interfaces"
sbx ports "${SANDBOX}" --unpublish "0.0.0.0:${HOST_PORT}:${SANDBOX_PORT}/tcp4" >/dev/null 2>&1 || true
sbx ports "${SANDBOX}" --unpublish "127.0.0.1:${HOST_PORT}:${SANDBOX_PORT}" --unpublish "[::1]:${HOST_PORT}:${SANDBOX_PORT}" >/dev/null 2>&1 || true
sbx ports "${SANDBOX}" --publish "0.0.0.0:${HOST_PORT}:${SANDBOX_PORT}/tcp4"

WSL_IP="$(hostname -I | awk '{print $1}')"

echo
echo "Open from Windows:"
echo "  http://${WSL_IP}:${HOST_PORT}/vnc.html?autoconnect=1&resize=remote"
echo
echo "Claude login command:"
echo "  sbx exec -it -e SBX_NO_DISPLAY=1 ${SANDBOX} sh -lc 'claude auth login --claudeai'"
