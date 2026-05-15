#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${POCX_WINNERS_CONFIG:-}"
if [[ -z "$CONFIG_FILE" ]]; then
  if [[ -f "./pocx-winners.conf" ]]; then
    CONFIG_FILE="./pocx-winners.conf"
  elif [[ -f "./config/pocx-winners.conf" ]]; then
    CONFIG_FILE="./config/pocx-winners.conf"
  else
    echo "Config file not found. Set POCX_WINNERS_CONFIG=/path/to/pocx-winners.conf"
    exit 1
  fi
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${BASE_DIR:?BASE_DIR is required in config}"
: "${BITCOIN_CLI:?BITCOIN_CLI is required in config}"
BLOCK_REWARD_BTCX="${BLOCK_REWARD_BTCX:-10}"

DATA_DIR="$BASE_DIR/pocx_winners"
RAW="$DATA_DIR/winners_raw.tsv"
SUMMARY="$DATA_DIR/winners_summary.csv"
LAST_FILE="$DATA_DIR/last_height.txt"
META="$DATA_DIR/meta.json"
LATEST="$DATA_DIR/latest_blocks.json"
LOCK_FILE="$DATA_DIR/scan.lock"

WINDOW_24H=720
WINDOW_7D=5040
WINDOW_30D=21600

mkdir -p "$DATA_DIR"

command -v jq >/dev/null || { echo "jq is missing. Install it with: sudo apt install jq"; exit 1; }
command -v awk >/dev/null || { echo "awk is missing"; exit 1; }
command -v flock >/dev/null || { echo "flock is missing. Install util-linux."; exit 1; }

if [[ ! -x "$BITCOIN_CLI" ]]; then
  echo "bitcoin-cli not found or not executable: $BITCOIN_CLI"
  exit 1
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another scan is already running. Exiting."
  exit 0
fi

TIP=$("$BITCOIN_CLI" getblockcount)

if [[ -f "$LAST_FILE" ]]; then
  LAST_DONE=$(cat "$LAST_FILE")
  START_HEIGHT=$((LAST_DONE + 1))
else
  START_HEIGHT=0
  : > "$RAW"
fi

TMP_NEW=$(mktemp)
trap 'rm -f "$TMP_NEW"' EXIT

if (( START_HEIGHT <= TIP )); then
  echo "Reading new blocks: $START_HEIGHT to $TIP"
  for ((h=START_HEIGHT; h<=TIP; h++)); do
    echo -ne "Block $h / $TIP\r"
    HASH=$("$BITCOIN_CLI" getblockhash "$h")
    HEADER=$("$BITCOIN_CLI" getblockheader "$HASH")
    echo "$HEADER" | jq -r --arg h "$h" --arg reward "$BLOCK_REWARD_BTCX" '[($h|tonumber), .time, .difficulty, (.signer_address // .pocx_proof.account_id // "unknown"), ($reward|tonumber)] | @tsv' >> "$TMP_NEW"
    echo "$h" > "$LAST_FILE"
  done
  echo
  cat "$TMP_NEW" >> "$RAW"
else
  echo "No new blocks. Current height: $TIP"
fi

# De-duplicate by block height. Keeps the latest line for each height.
if [[ -s "$RAW" ]]; then
  awk -F'\t' '{ line[$1]=$0 } END { for (h in line) print line[h] }' "$RAW" | sort -n -k1,1 > "$RAW.tmp"
  mv "$RAW.tmp" "$RAW"
fi

CURRENT_LAST=$(awk -F'\t' 'END {print $1}' "$RAW")
[[ -n "${CURRENT_LAST:-}" ]] && echo "$CURRENT_LAST" > "$LAST_FILE"

AVG_DIFF=$(awk -F'\t' '{s+=$3;n++} END {if(n>0) printf "%.8f", s/n; else print "0"}' "$RAW")
CUR_DIFF=$(tail -n 1 "$RAW" | awk -F'\t' '{print $3}')
CUR_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$META" <<METAEOF
{
  "height": ${CURRENT_LAST:-0},
  "tip": $TIP,
  "current_difficulty_tb": ${CUR_DIFF:-0},
  "average_difficulty_tb": ${AVG_DIFF:-0},
  "updated_at": "$CUR_TIME",
  "auto_refresh_seconds": 120
}
METAEOF

# latest blocks for browser-side watched-address notifications
awk -F'\t' 'BEGIN{print "["} {rows[NR]=$0} END{start=NR-100; if(start<1) start=1; first=1; for(i=start;i<=NR;i++){split(rows[i],a,"\t"); if(!first) printf ",\n"; first=0; printf "{\"height\":%s,\"time\":%s,\"difficulty\":%s,\"address\":\"%s\"}", a[1],a[2],a[3],a[4]} print "\n]"}' "$RAW" > "$LATEST"

{
  echo "rank,address,first_block,last_block,blocks_total,total_reward_btcx,blocks_24h,size_24h_tb,blocks_7d,size_7d_tb,blocks_30d,size_30d_tb,size_all_tb"
  awk -F'\t' -v tip="$TIP" -v w24="$WINDOW_24H" -v w7="$WINDOW_7D" -v w30="$WINDOW_30D" '
  {
    h=$1; diff=$3; addr=$4; reward=$5
    count_total[addr]++; reward_total[addr]+=reward
    if (!(addr in first_block) || h < first_block[addr]) first_block[addr]=h
    if (!(addr in last_block)  || h > last_block[addr])  last_block[addr]=h
    diff_sum_all += diff; total_all++
    if (h > tip - w24) { count_24[addr]++; diff_sum_24 += diff; total_24++ }
    if (h > tip - w7)  { count_7[addr]++;  diff_sum_7  += diff; total_7++  }
    if (h > tip - w30) { count_30[addr]++; diff_sum_30 += diff; total_30++ }
  }
  END {
    avg24 = total_24 > 0 ? diff_sum_24 / total_24 : 0
    avg7  = total_7  > 0 ? diff_sum_7  / total_7  : 0
    avg30 = total_30 > 0 ? diff_sum_30 / total_30 : 0
    avgall = total_all > 0 ? diff_sum_all / total_all : 0
    for (addr in count_total) {
      size24  = total_24  > 0 ? avg24  * count_24[addr] / total_24 : 0
      size7   = total_7   > 0 ? avg7   * count_7[addr]  / total_7  : 0
      size30  = total_30  > 0 ? avg30  * count_30[addr] / total_30 : 0
      sizeall = total_all > 0 ? avgall * count_total[addr] / total_all : 0
      printf "%s,%d,%d,%d,%.8f,%d,%.2f,%d,%.2f,%d,%.2f,%.2f\n", addr, first_block[addr], last_block[addr], count_total[addr], reward_total[addr], count_24[addr], size24, count_7[addr], size7, count_30[addr], size30, sizeall
    }
  }' "$RAW" | sort -t',' -k4,4nr | awk -F',' 'BEGIN{rank=1} {print rank "," $0; rank++}'
} > "$SUMMARY"

echo "Done."
echo "Last scanned block: $(cat "$LAST_FILE")"
echo "Summary: $SUMMARY"
