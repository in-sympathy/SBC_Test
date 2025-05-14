```bash
#!/usr/bin/env bash
# SBC_Test.sh — Automated SBC test script (using stress-ng only)
set -euo pipefail

# Determine the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# Logs directory inside the script folder
LOG_DIR="${SCRIPT_DIR}/Logs"

# 0. Prepare the Logs directory
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

# 2. Install fastfetch if missing (latest GitHub .deb)
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Checking/installing fastfetch ==="
if ! command -v fastfetch &>/dev/null; then
  echo ">>> fastfetch not found. Downloading latest ARM64 .deb..." | tee -a "${LOG_DIR}/updates.log"
  FASTFETCH_URL="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-aarch64.deb"
  curl -L --retry 3 "$FASTFETCH_URL" -o "${LOG_DIR}/fastfetch.deb" 2>&1 \
    | tee -a "${LOG_DIR}/updates.log"
  sudo dpkg -i "${LOG_DIR}/fastfetch.deb" 2>&1 | tee -a "${LOG_DIR}/updates.log"
  sudo apt-get install -f -y 2>&1 | tee -a "${LOG_DIR}/updates.log"
  rm "${LOG_DIR}/fastfetch.deb"
else
  echo ">>> fastfetch already installed." | tee -a "${LOG_DIR}/updates.log"
fi

# 3. Install stress-ng if missing
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Checking/installing stress-ng ==="
if ! command -v stress-ng &>/dev/null; then
  echo ">>> stress-ng not found. Installing..." | tee -a "${LOG_DIR}/updates.log"
  sudo apt install -y stress-ng 2>&1 | tee -a "${LOG_DIR}/updates.log"
else
  echo ">>> stress-ng already installed." | tee -a "${LOG_DIR}/updates.log"
fi

# 4. Run stress-ng for 5 minutes
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Running stress-ng for 5 minutes ==="
stress-ng --cpu 0 --cpu-method all --timeout 5m --verbose 2>&1 \
  | tee "${LOG_DIR}/stress-ng.log"
echo "=== $(date '+%Y-%m-%d %H:%M:%S') stress-ng completed ==="

# 5. Ping 8.8.8.8 every 10 seconds for 30 minutes
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Pinging 8.8.8.8 every 10s for 30 minutes ==="
ping -i 10 -w 1800 8.8.8.8 2>&1 | tee "${LOG_DIR}/ping.log"
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ping test completed ==="

# 6. Capture system info with fastfetch
echo
echo "=== $(date '+%Y-%m-%d %H:%M:%S') Capturing system info with fastfetch ==="
fastfetch 2>&1 | tee "${LOG_DIR}/fastfetch.log"
echo "=== $(date '+%Y-%m-%d %H:%M:%S') fastfetch output saved ==="

echo
echo "All done! Logs available in ${LOG_DIR}"
```
