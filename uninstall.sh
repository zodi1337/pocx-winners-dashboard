#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="${SERVICE_NAME:-pocx-winners-dashboard}"
sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
sudo rm -f "/etc/systemd/system/$SERVICE_NAME.service"
sudo systemctl daemon-reload
sudo systemctl reset-failed
crontab -l 2>/dev/null | grep -v "pocx_block_winners.sh" | crontab - || true
echo "Service and cron entry removed. Project files were left in place."
