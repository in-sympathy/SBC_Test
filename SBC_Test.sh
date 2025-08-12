#!/usr/bin/env bash
# SBC_Test.sh — Comprehensive SBC sanity test (sysbench + telemetry + ping)
set -euo pipefail

# ---------- Config ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOG_DIR="$SCRIPT_DIR/Logs"
THREADS="$(nproc --all)"

# Durations for CPU/threads/mutex passes (seconds)
CPU_PASS_SECS=300
THREADS_PASS_SECS=180
MUTEX_PASS_SECS=180

# Memory sweep settings
MEM_TOTAL_SIZE="4G"       # amount to process per subtest (not resident at once)
MEM_BLOCK_SIZES=("4K" "64K" "1M")
MEM_ACCESS_MODES=("seq" "rnd")
MEM_OPS=("read" "write")

# Optional: enable file I/O test (heavy wear on flash) by setting to 1
ENABLE_FILEIO=0
FILEIO_TOTAL_SIZE="2G"    # total test file size
FILEIO_MODE="rndrw"       # rndrd|rndwr|rndrw|seqrd|seqwr
FILEIO_DURATION=180

# ---------- Prep ----------
mkdir -p "$LOG_DIR"
echo "[$(date '+%F %T')] ➤ Logs: $LOG_DIR"
: > "$LOG_DIR/updates.log"

echo "[$(date '+%F %T')] ➤ apt update & full-upgrade"
sudo apt update 2>&1 | tee -a "$LOG_DIR/updates.log"
sudo apt full-upgrade -y 2>&1 | tee -a "$LOG_DIR/updates.log"

echo "[$(date '+%F %T')] ➤ Ensure tools exist"
if ! command -v sysbench >/dev/null; then
  sudo apt install -y sysbench 2>&1 | tee -a "$LOG_DIR/updates.log"
fi
if ! command -v fastfetch >/dev/null; then
  FASTFETCH_URL="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-aarch64.deb"
  curl -L --retry 3 "$FASTFETCH_URL" -o "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log"
  sudo dpkg -i "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log" || true
  sudo apt -f install -y 2>&1 | tee -a "$LOG_DIR/updates.log"
  rm -f "$LOG_DIR/fastfetch.deb"
fi

# ---------- Telemetry (runs in background during tests) ----------
TELEM_LOG="$LOG_DIR/telemetry.csv"
echo "timestamp,temp_c,arm_hz,throttled,loadavg1,loadavg5,loadavg15" > "$TELEM_LOG"

telemetry() {
  while :; do
    ts="$(date '+%F %T')"
    if command -v vcgencmd >/dev/null; then
      temp_c="$(vcgencmd measure_temp 2>/dev/null | sed -E 's/[^0-9.]//g')"
      arm_hz="$(vcgencmd measure_clock arm 2>/dev/null | awk -F= '{print $2}')"
      throttled="$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}')"
    else
      raw="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)"
      temp_c="$(awk "BEGIN{printf \"%.1f\", $raw/1000}")"
      arm_hz="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)"
      throttled="N/A"
    fi
    read -r l1 l5 l15 _ < /proc/loadavg
    echo "$ts,$temp_c,$arm_hz,$throttled,$l1,$l5,$l15" >> "$TELEM_LOG"
    sleep 1
  done
}
telemetry &
TELEM_PID=$!
cleanup() { kill "$TELEM_PID" 2>/dev/null || true; }
trap cleanup EXIT

# ---------- CPU tests ----------
echo "[$(date '+%F %T')] ➤ sysbench CPU (baseline)"
sysbench cpu --cpu-max-prime=360000 --threads=8 --time=0 --events=10000 --verbosity=5 run \
  2>&1 | tee "$LOG_DIR/sysbench_cpu_baseline.log"

echo "[$(date '+%F %T')] ➤ sysbench CPU (${THREADS} threads, ${CPU_PASS_SECS}s)"
sysbench cpu --cpu-max-prime=600000 --threads="$THREADS" --time=$CPU_PASS_SECS --events=0 --verbosity=5 run \
  2>&1 | tee "$LOG_DIR/sysbench_cpu_nt.log"

echo "[$(date '+%F %T')] ➤ sysbench CPU ($((THREADS*2)) threads, ${CPU_PASS_SECS}s)"
sysbench cpu --cpu-max-prime=600000 --threads="$((THREADS*2))" --time=$CPU_PASS_SECS --events=0 --verbosity=5 run \
  2>&1 | tee "$LOG_DIR/sysbench_cpu_2nt.log"

# ---------- Memory tests ----------
echo "[$(date '+%F %T')] ➤ sysbench MEMORY sweep"
for bs in "${MEM_BLOCK_SIZES[@]}"; do
  for mode in "${MEM_ACCESS_MODES[@]}"; do
    for op in "${MEM_OPS[@]}"; do
      name="mem_${op}_${mode}_${bs}"
      echo "[$(date '+%F %T')]  • $name total=$MEM_TOTAL_SIZE threads=$THREADS"
      sysbench memory \
        --threads="$THREADS" --time=0 --events=0 --verbosity=5 \
        --memory-total-size="$MEM_TOTAL_SIZE" \
        --memory-block-size="$bs" \
        --memory-access-mode="$mode" \
        --memory-oper="$op" \
        run 2>&1 | tee "$LOG_DIR/sysbench_${name}.log"
    done
  done
done

# ---------- Threads test ----------
echo "[$(date '+%F %T')] ➤ sysbench THREADS (${THREADS_PASS_SECS}s)"
sysbench threads \
  --threads="$THREADS" --time=$THREADS_PASS_SECS --events=0 --verbosity=5 \
  --threads-yields=100 --threads-locks=8 \
  run 2>&1 | tee "$LOG_DIR/sysbench_threads.log"

# ---------- Mutex test ----------
echo "[$(date '+%F %T')] ➤ sysbench MUTEX (${MUTEX_PASS_SECS}s)"
sysbench mutex \
  --threads="$THREADS" --time=$MUTEX_PASS_SECS --events=0 --verbosity=5 \
  --mutex-num=4096 --mutex-locks=200000 --mutex-loops=10000 \
  run 2>&1 | tee "$LOG_DIR/sysbench_mutex.log"

# ---------- Optional: File I/O ----------
if [[ "$ENABLE_FILEIO" -eq 1 ]]; then
  echo "[$(date '+%F %T')] ➤ sysbench FILEIO (may wear flash!)"
  pushd "$LOG_DIR" >/dev/null
  sysbench fileio --file-total-size="$FILEIO_TOTAL_SIZE" --file-test-mode=$FILEIO_MODE prepare
  sysbench fileio --file-total-size="$FILEIO_TOTAL_SIZE" --file-test-mode=$FILEIO_MODE \
    --time=$FILEIO_DURATION --events=0 --verbosity=5 --threads="$THREADS" --file-io-mode=async \
    --file-extra-flags=direct --file-fsync-freq=0 run | tee "$LOG_DIR/sysbench_fileio.log"
  sysbench fileio --file-total-size="$FILEIO_TOTAL_SIZE" --file-test-mode=$FILEIO_MODE cleanup
  popd >/dev/null
fi

# ---------- Network sanity ----------
echo "[$(date '+%F %T')] ➤ Pinging 8.8.8.8 every 1s for 10m"
set +e
ping -i 1 -w 600 8.8.8.8 2>&1 | tee "$LOG_DIR/ping.log"
PING_EXIT=${PIPESTATUS[0]}
set -e
echo "Ping exit status: $PING_EXIT" | tee -a "$LOG_DIR/ping.log"

# ---------- fastfetch snapshot ----------
echo "[$(date '+%F %T')] ➤ Capturing system info with fastfetch"
fastfetch 2>&1 | tee "$LOG_DIR/fastfetch.log"

# ---------- Done ----------
echo "[$(date '+%F %T')] ➤ All done! Logs in $LOG_DIR"
