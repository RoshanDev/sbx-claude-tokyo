#!/usr/bin/env bash
set -euo pipefail

SANDBOX="${1:-claude-wsl}"
HOST_PORT="${HOST_PORT:-6080}"
SANDBOX_PORT=6080
DISPLAY_NUM="${DISPLAY_NUM:-99}"
SESSION="${TMUX_SESSION:-sbx-claude-novnc}"

echo "Unpublishing noVNC port"
sbx ports "${SANDBOX}" --unpublish "0.0.0.0:${HOST_PORT}:${SANDBOX_PORT}/tcp4" >/dev/null 2>&1 || true
sbx ports "${SANDBOX}" --unpublish "127.0.0.1:${HOST_PORT}:${SANDBOX_PORT}" --unpublish "[::1]:${HOST_PORT}:${SANDBOX_PORT}" >/dev/null 2>&1 || true

tmux kill-session -t "${SESSION}" 2>/dev/null || true

echo "Stopping noVNC processes in sandbox: ${SANDBOX}"
sbx exec "${SANDBOX}" sh -lc "
  pkill -f '[w]ebsockify --web=/usr/share/novnc 0.0.0.0:${SANDBOX_PORT}' 2>/dev/null || true
  pkill -f '[x]11vnc -display :${DISPLAY_NUM}' 2>/dev/null || true
  pkill -f '[g]oogle-chrome.*\\.chrome-claude-jp' 2>/dev/null || true
  pkill -f '[X]vfb :${DISPLAY_NUM}' 2>/dev/null || true
  pkill -x openbox 2>/dev/null || true
"

echo "Done. Use 'sbx stop ${SANDBOX}' if you also want to stop the sandbox."
