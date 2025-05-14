#!/usr/bin/env bash
# SBC_Test.sh — Automated SBC test script (using stress-ng only)
set -euo pipefail

# Uncomment to see every command as it's executed:
# set -x

# 1) Figure out where this script lives, so we can put Logs next to it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOG_DIR="$SCRIPT_DIR/Logs"

# 2) Prepare the Logs directory
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ➤ Preparing logs in $LOG_DIR"
if [ -d "$LOG_DIR" ]; then
  rm -rf "${LOG_DIR:?}/"*
else
  mkdir -p "$LOG_DIR"
fi

# 3) System update & full-upgrade
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ➤ Running apt update & full-upgrade"
sudo apt update 2>&1 | tee "$LOG_DIR/updates.log"
sudo apt full-upgrade -y 2>&1 | tee -a "$LOG_DIR/updates.log"

# 4) Install fastfetch if missing
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ➤ Checking for fastfetch"
if ! command -v fastfetch >/dev/null; then
  echo "  fastfetch not found – downloading latest .deb" | tee -a "$LOG_DIR/updates.log"
  FASTFETCH_URL="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-aarch64.deb"
  curl -L --retry 3 "$FASTFETCH_URL" -o "$LOG_DIR/fastfetch.deb" 2>&1 \
    | tee -a "$LOG_DIR/updates.log"
  sudo dpkg -i "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log"
  sudo apt-get install -f -y 2>&1 | tee -a "$LOG_DIR/updates.log"
  rm "$LOG_DIR/fastfetch.deb"
else
  echo "  fastfetch already installed" | tee -a "$LOG_DIR/updates.log"
fi

# 5) Install stress-ng if missing
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ➤ Checking for stress-ng"
if ! command -v stress-ng >/dev/null; then
  echo "  stress-ng not found – installing via apt" | tee -a "$LOG_DIR/updates.log"
  sudo apt install -y stress-ng 2>&1 | tee -a "$LOG_DIR/updates.log"
else
  echo "  stress-ng already installed" | tee -a "$LOG_DIR/updates.log"
fi

# 6) Run stress-ng
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ➤ Running stress-ng (5m)"
stress-ng --cpu 0 --cpu-method all --timeout 5m --verbose 2>&1 \
  | tee "$LOG_DIR/stress-ng.log"

# 7) Ping test
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ➤ Pinging 8.8.8.8 every 10s for 30m"
ping -i 10 -w 1800 8.8.8.8 2>&1 | tee "$LOG_DIR/ping.log"

# 8) fastfetch snapshot
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ➤ Capturing system info with fastfetch"
fastfetch 2>&1 | tee "$LOG_DIR/fastfetch.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ➤ All done! Logs in $LOG_DIR"
