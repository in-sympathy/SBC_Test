#!/usr/bin/env bash
# sbc_benchmark.sh — Automated SBC benchmark script
set -euo pipefail

LOG_DIR="${HOME}/sbc_benchmark"

# 0. Prepare the benchmark directory
if [ -d "$LOG_DIR" ]; then
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') Cleaning existing $LOG_DIR ==="
  rm -rf "${LOG_DIR:?}/"*
else
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') Creating $LOG_DIR ==="
  mkdir -p "$LOG_DIR"
fi

# 1. System update & full-upgrade
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Starting system update & full-upgrade ==="
sudo apt update            2>&1 | tee "${LOG_DIR}/updates.log"
sudo apt full-upgrade -y   2>&1 | tee -a "${LOG_DIR}/updates.log"

# 2. Install missing packages
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Checking/installing fastfetch, stress, stress-ng ==="
for pkg in fastfetch stress stress-ng; do
  if ! command -v "$pkg" &>/dev/null; then
    echo ">>> $pkg not found. Installing..." | tee -a "${LOG_DIR}/updates.log"
    sudo apt install -y "$pkg" 2>&1 | tee -a "${LOG_DIR}/updates.log"
  else
    echo ">>> $pkg already installed." | tee -a "${LOG_DIR}/updates.log"
  fi
done

# 3. Run stress for 5 minutes
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Running stress for 5 minutes ==="
stress --cpu "$(nproc)" --timeout 300 --verbose 2>&1 \
  | tee "${LOG_DIR}/stress.log"
echo "=== $(date '+%Y-%m-%d %H:%M:%S') stress completed ==="

# 4. Run stress-ng for 5 minutes
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Running stress-ng for 5 minutes ==="
stress-ng --cpu 0 --cpu-method all --timeout 5m --verbose 2>&1 \
  | tee "${LOG_DIR}/stress-ng.log"
echo "=== $(date '+%Y-%m-%d %H:%M:%S') stress-ng completed ==="

# 5. Ping 8.8.8.8 for 120 minutes
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Pinging 8.8.8.8 for 120 minutes ==="
ping -w 7200 8.8.8.8 2>&1 | tee "${LOG_DIR}/ping.log"
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ping test completed ==="

# 6. Capture system info with fastfetch
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Capturing system info with fastfetch ==="
fastfetch 2>&1 | tee "${LOG_DIR}/fastfetch.log"
echo "=== $(date '+%Y-%m-%d %H:%M:%S') fastfetch output saved ==="

echo
echo "All done!  Logs available in ${LOG_DIR}"
