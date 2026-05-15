#!/usr/bin/env bash
set -euo pipefail

CONFIG_SRC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_SRC="$2"; shift 2 ;;
    -h|--help) echo "Usage: ./install.sh --config ./pocx-winners.conf"; exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$CONFIG_SRC" || ! -f "$CONFIG_SRC" ]]; then
  echo "Config file required."
  echo "Copy and edit the example first:"
  echo "  cp pocx-winners.conf.example pocx-winners.conf"
  echo "  nano pocx-winners.conf"
  echo "  ./install.sh --config ./pocx-winners.conf"
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_SRC"
: "${BASE_DIR:?BASE_DIR is required}"
: "${BITCOIN_CLI:?BITCOIN_CLI is required}"
WEB_PORT="${WEB_PORT:-8082}"
SERVICE_NAME="${SERVICE_NAME:-pocx-winners-dashboard}"
BLOCK_REWARD_BTCX="${BLOCK_REWARD_BTCX:-10}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$BASE_DIR/app"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/pocx_winners"
SCRIPTS_DIR="$BASE_DIR/scripts"
VENV_DIR="$BASE_DIR/.venv"
CONFIG_DEST="$CONFIG_DIR/pocx-winners.conf"

sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip jq bsdextrautils util-linux

mkdir -p "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR" "$SCRIPTS_DIR"
cp "$SCRIPT_DIR/app.py" "$APP_DIR/app.py"
cp -r "$SCRIPT_DIR/templates" "$APP_DIR/"
cp -r "$SCRIPT_DIR/static" "$APP_DIR/"
cp "$SCRIPT_DIR/scripts/pocx_block_winners.sh" "$SCRIPTS_DIR/pocx_block_winners.sh"
chmod +x "$SCRIPTS_DIR/pocx_block_winners.sh"

cat > "$CONFIG_DEST" <<CFG
BASE_DIR="$BASE_DIR"
BITCOIN_CLI="$BITCOIN_CLI"
WEB_PORT="$WEB_PORT"
BLOCK_REWARD_BTCX="$BLOCK_REWARD_BTCX"
SERVICE_NAME="$SERVICE_NAME"
CFG

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
"$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"

POCX_WINNERS_CONFIG="$CONFIG_DEST" "$SCRIPTS_DIR/pocx_block_winners.sh"

sudo tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null <<UNIT
[Unit]
Description=PoCX Winners Dashboard
After=network-online.target
Wants=network-online.target

[Service]
User=$USER
WorkingDirectory=$APP_DIR
Environment=POCX_WINNERS_CONFIG=$CONFIG_DEST
ExecStart=$VENV_DIR/bin/gunicorn -w 2 -b 0.0.0.0:$WEB_PORT app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"

# Install/update user crontab with flock protection.
CRON_LINE="*/2 * * * * flock -n /tmp/${SERVICE_NAME}.lock env POCX_WINNERS_CONFIG=$CONFIG_DEST $SCRIPTS_DIR/pocx_block_winners.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v "$SCRIPTS_DIR/pocx_block_winners.sh"; echo "$CRON_LINE" ) | crontab -

echo
echo "Installation complete."
echo "Base directory: $BASE_DIR"
echo "Config file:    $CONFIG_DEST"
echo "Service:        $SERVICE_NAME"
echo "URL:            http://<YOUR_NODE_IP>:$WEB_PORT/"
