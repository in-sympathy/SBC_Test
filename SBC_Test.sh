#!/usr/bin/env bash
# SBC_Test.sh — Comprehensive SBC sanity + fair benchmark (sysbench + telemetry + ping + report)
#
# CHANGES vs original (fairness / correctness):
#   [FAIR] Pins CPU governor to 'performance' during tests, restores afterward.
#   [FAIR] Single-thread CPU baseline uses the SAME prime (600000) as N/2N -> per-core score.
#   [FAIR] Adds parallel-scaling ratio (Nt / 1t).
#   [FAIR] Memory sweep runs at 1 thread AND N threads (subsystem vs aggregate).
#   [FAIR] Telemetry samples ALL cores and ALL thermal zones (not just cpu0 / zone0).
#   [FAIR] Honest throttle label on non-Pi; reports observed vs advertised max clock.
#   [FIX ] Threads test eps computed from events/time (was always n/a).
#   [FIX ] Network test pings the LAN gateway by default (isolates board NIC from ISP).
#   [FIX ] apt full-upgrade is opt-in (was always-on, mutated system mid-benchmark).
#   [NEW ] tinymembench added for REAL DRAM bandwidth + latency; sysbench memory is
#          relabeled honestly as a memcpy/cache test (it is NOT raw DRAM bandwidth).
#   [PERF] Fast benchmark profile by default (~7-9 min); -l for the long soak, -h for help.
#          Quick mode skips the (redundant) sysbench memory sweep; tinymembench covers memory.
set -uo pipefail   # NOTE: '-e' intentionally dropped; benchmarks tolerate non-zero exits.

# ---------- CLI ----------
usage() {
  cat <<EOF
Usage: $(basename "$0") [-q | -l] [-h]

  -q, --quick   Fast benchmark profile (~7-9 min) — DEFAULT. Shorter thermal soak and
                skips the redundant sysbench memory sweep (tinymembench still measures
                real DRAM). Best for comparing boards.
  -l, --long    Long burn-in profile (~15 min). Extended sustained CPU soak plus the
                full sysbench memory sweep. For post-repair stability / slow throttle.
  -h, --help    Show this help and exit.

Run with sudo so the CPU governor can be pinned (fair results).
Finer knobs (memory size, apt-upgrade, tinymembench, file I/O) are at the top
of the script.
EOF
}

MODE="quick"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quick) MODE="quick" ;;
    -l|--long)  MODE="long"  ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

# ---------- Config ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOG_DIR="$SCRIPT_DIR/Logs"
THREADS="$(nproc --all)"

# ---------- Run profile ----------
# Durations (seconds). Default = quick (-q); -l switches to the long burn-in soak.
SINGLE_PASS_SECS=30       # single-thread per-core pass (eps stabilises in seconds)
CPU_PASS_SECS=120         # all-core pass — doubles as the thermal heat-soak
CPU_2NT_PASS_SECS=60      # oversubscribed pass — redundancy check, needs no soak
THREADS_PASS_SECS=60
MUTEX_PASS_SECS=60

if [[ "$MODE" == "long" ]]; then
  SINGLE_PASS_SECS=60
  CPU_PASS_SECS=300       # long sustained soak to catch slow thermal creep
  CPU_2NT_PASS_SECS=120
  THREADS_PASS_SECS=180
  MUTEX_PASS_SECS=180
fi

# sysbench memory is a memcpy/cache test, now redundant with tinymembench (real DRAM),
# so quick mode skips it; the long burn-in keeps it for completeness.
if [[ "$MODE" == "long" ]]; then ENABLE_SYSBENCH_MEM=1; else ENABLE_SYSBENCH_MEM=0; fi

# Same prime ceiling for ALL cpu passes so 1t / Nt / 2Nt are directly comparable
CPU_MAX_PRIME=600000

# Memory sweep
MEM_TOTAL_SIZE="1G"       # processed per subtest; rate (MiB/sec) is size-independent
MEM_BLOCK_SIZES=("4K" "64K" "1M")
MEM_ACCESS_MODES=("seq" "rnd")
MEM_OPS=("read" "write")
# thread modes for memory: 1 (fair, per-subsystem) + N (aggregate). Deduped for 1-core boards.
if [[ "$THREADS" -gt 1 ]]; then MEM_THREAD_MODES=(1 "$THREADS"); else MEM_THREAD_MODES=(1); fi

# Behavior toggles
PIN_GOVERNOR=1            # 1 = set 'performance' during test and restore after
ENABLE_APT_UPGRADE=0      # 1 = run 'apt full-upgrade' before testing (mutates system)
PING_TARGET=""            # "" = auto (default gateway); set an IP/host to override
PING_COUNT_SECS=60
ENABLE_TINYMEMBENCH=1     # 1 = build & run tinymembench for REAL DRAM bandwidth + latency
TMB_DIR="$SCRIPT_DIR/tinymembench"

# Optional file I/O test (heavy flash wear)
ENABLE_FILEIO=0
FILEIO_TOTAL_SIZE="2G"
FILEIO_MODE="rndrw"
FILEIO_DURATION=180

# ---------- Helpers ----------
cecho() {
  local c="$1"; shift
  local reset="\033[0m" green="\033[32m" yellow="\033[33m" red="\033[31m" cyan="\033[36m"
  case "$c" in
    green)  printf "%b%s%b\n" "$green"  "$*" "$reset" ;;
    yellow) printf "%b%s%b\n" "$yellow" "$*" "$reset" ;;
    red)    printf "%b%s%b\n" "$red"    "$*" "$reset" ;;
    cyan)   printf "%b%s%b\n" "$cyan"   "$*" "$reset" ;;
    *) echo "$*";;
  esac
}

# ---------- CPU governor (save / set / restore) ----------
GOV_BACKUP=()
GOV_SET="(unchanged)"
set_governor() {
  local want="$1" applied=0
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -e "$p/scaling_governor" ] || continue
    local cur; cur="$(cat "$p/scaling_governor" 2>/dev/null || echo unknown)"
    GOV_BACKUP+=("$p=$cur")
    if echo "$want" | sudo tee "$p/scaling_governor" >/dev/null 2>&1; then applied=1; fi
  done
  if [[ "$applied" -eq 1 ]]; then
    # read back what actually stuck (some boards clamp)
    GOV_SET="$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || echo "$want")"
  else
    GOV_SET="(could not set; left as-is)"
  fi
}
restore_governor() {
  local kv p g
  for kv in "${GOV_BACKUP[@]:-}"; do
    [[ -z "$kv" ]] && continue
    p="${kv%%=*}"; g="${kv#*=}"
    echo "$g" | sudo tee "$p/scaling_governor" >/dev/null 2>&1 || true
  done
}

# ---------- Prep ----------
mkdir -p "$LOG_DIR"
echo "[$(date '+%F %T')] ➤ Logs: $LOG_DIR"
: > "$LOG_DIR/updates.log"

echo "[$(date '+%F %T')] ➤ apt update"
sudo apt update 2>&1 | tee -a "$LOG_DIR/updates.log" || true
if [[ "$ENABLE_APT_UPGRADE" -eq 1 ]]; then
  echo "[$(date '+%F %T')] ➤ apt full-upgrade (ENABLE_APT_UPGRADE=1)"
  sudo apt full-upgrade -y 2>&1 | tee -a "$LOG_DIR/updates.log" || true
fi

echo "[$(date '+%F %T')] ➤ Ensure tools exist"
if ! command -v sysbench >/dev/null; then
  sudo apt install -y sysbench 2>&1 | tee -a "$LOG_DIR/updates.log" || true
fi
if ! command -v fastfetch >/dev/null; then
  FASTFETCH_URL="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-aarch64.deb"
  curl -L --retry 3 "$FASTFETCH_URL" -o "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log" || true
  sudo dpkg -i "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log" || true
  sudo apt -f install -y 2>&1 | tee -a "$LOG_DIR/updates.log" || true
  rm -f "$LOG_DIR/fastfetch.deb"
fi

# tinymembench: real DRAM bandwidth + latency (build once if missing)
if [[ "$ENABLE_TINYMEMBENCH" -eq 1 && ! -x "$TMB_DIR/tinymembench" ]]; then
  echo "==> Building tinymembench ..."
  command -v git  >/dev/null || sudo apt install -y git             2>&1 | tee -a "$LOG_DIR/updates.log" || true
  command -v make >/dev/null || sudo apt install -y build-essential 2>&1 | tee -a "$LOG_DIR/updates.log" || true
  [[ -d "$TMB_DIR" ]] || git clone --depth 1 https://github.com/ssvb/tinymembench.git "$TMB_DIR" \
      2>&1 | tee -a "$LOG_DIR/updates.log" || true
  ( cd "$TMB_DIR" && make ) 2>&1 | tee -a "$LOG_DIR/updates.log" || true
fi

# Advertised max clock + cluster layout (read once)
ADV_MAX_HZ=0
for f in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq; do
  [ -e "$f" ] || continue
  v="$(cat "$f" 2>/dev/null || echo 0)"
  if [[ "$v" =~ ^[0-9]+$ ]] && (( v > ADV_MAX_HZ )); then ADV_MAX_HZ="$v"; fi
done
CLUSTERS="$(for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -e "$p/cpuinfo_max_freq" ] || continue
  printf '%s:%sMHz ' "$(basename "$p")" "$(( $(cat "$p/cpuinfo_max_freq")/1000 ))"
done)"
GOV_AVAIL="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo 'n/a')"

# Pin governor for fair, full-clock testing
if [[ "$PIN_GOVERNOR" -eq 1 ]]; then
  echo "[$(date '+%F %T')] ➤ Setting CPU governor to 'performance'"
  set_governor performance
fi

# ---------- Telemetry (background) ----------
TELEM_LOG="$LOG_DIR/telemetry.csv"
echo "timestamp,temp_c,hz_max,hz_mean,throttled,load1" > "$TELEM_LOG"

telemetry() {
  while :; do
    ts="$(date '+%F %T')"
    throttled="unsupported"
    temp_c="0.0"
    if command -v vcgencmd >/dev/null; then
      temp_c="$(vcgencmd measure_temp 2>/dev/null | sed -E 's/[^0-9.]//g')"
      throttled="$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}')"
      [[ -z "$throttled" ]] && throttled="0x0"
    else
      # hottest thermal zone across the SoC
      tmax=0
      for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -e "$z" ] || continue
        r="$(cat "$z" 2>/dev/null || echo 0)"
        [[ "$r" =~ ^[0-9]+$ ]] || continue
        (( r > tmax )) && tmax="$r"
      done
      temp_c="$(awk -v r="$tmax" 'BEGIN{printf "%.1f", r/1000}')"
    fi
    # clock: peak and mean across ALL cores
    hz_max=0; hz_sum=0; hz_n=0
    for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
      [ -e "$c" ] || continue
      h="$(cat "$c" 2>/dev/null || echo 0)"
      [[ "$h" =~ ^[0-9]+$ ]] || continue
      (( h > hz_max )) && hz_max="$h"
      hz_sum=$(( hz_sum + h )); hz_n=$(( hz_n + 1 ))
    done
    hz_mean=0; (( hz_n > 0 )) && hz_mean=$(( hz_sum / hz_n ))
    read -r l1 _ < /proc/loadavg
    echo "$ts,$temp_c,$hz_max,$hz_mean,$throttled,$l1" >> "$TELEM_LOG"
    sleep 1
  done
}
telemetry &
TELEM_PID=$!
cleanup() {
  kill "$TELEM_PID" 2>/dev/null || true
  [[ "$PIN_GOVERNOR" -eq 1 ]] && restore_governor
}
trap cleanup EXIT

# ---------- CPU tests (same prime for all -> comparable) ----------
echo "[$(date '+%F %T')] ➤ sysbench CPU single-thread (${SINGLE_PASS_SECS}s, prime=${CPU_MAX_PRIME})"
sysbench cpu --cpu-max-prime=$CPU_MAX_PRIME --threads=1 --time=$SINGLE_PASS_SECS --events=0 --verbosity=5 run \
  2>&1 | tee "$LOG_DIR/sysbench_cpu_1t.log"

echo "[$(date '+%F %T')] ➤ sysbench CPU ${THREADS} threads (${CPU_PASS_SECS}s)"
sysbench cpu --cpu-max-prime=$CPU_MAX_PRIME --threads="$THREADS" --time=$CPU_PASS_SECS --events=0 --verbosity=5 run \
  2>&1 | tee "$LOG_DIR/sysbench_cpu_nt.log"

echo "[$(date '+%F %T')] ➤ sysbench CPU $((THREADS*2)) threads (${CPU_2NT_PASS_SECS}s)"
sysbench cpu --cpu-max-prime=$CPU_MAX_PRIME --threads="$((THREADS*2))" --time=$CPU_2NT_PASS_SECS --events=0 --verbosity=5 run \
  2>&1 | tee "$LOG_DIR/sysbench_cpu_2nt.log"

# ---------- Memory tests (sysbench memcpy/cache sweep — skipped in quick mode) ----------
if [[ "$ENABLE_SYSBENCH_MEM" -eq 1 ]]; then
  echo "[$(date '+%F %T')] ➤ sysbench MEMORY sweep (threads: ${MEM_THREAD_MODES[*]})"
  for t in "${MEM_THREAD_MODES[@]}"; do
    for bs in "${MEM_BLOCK_SIZES[@]}"; do
      for mode in "${MEM_ACCESS_MODES[@]}"; do
        for op in "${MEM_OPS[@]}"; do
          name="mem_${op}_${mode}_${bs}_${t}t"
          echo "[$(date '+%F %T')]  • $name total=$MEM_TOTAL_SIZE threads=$t"
          sysbench memory \
            --threads="$t" --time=0 --events=0 --verbosity=5 \
            --memory-total-size="$MEM_TOTAL_SIZE" \
            --memory-block-size="$bs" \
            --memory-access-mode="$mode" \
            --memory-oper="$op" \
            run 2>&1 | tee "$LOG_DIR/sysbench_${name}.log"
        done
      done
    done
  done
else
  echo "[$(date '+%F %T')] ➤ sysbench MEMORY sweep skipped (quick mode; tinymembench covers memory)"
  rm -f "$LOG_DIR"/sysbench_mem_*.log 2>/dev/null || true   # clear stale logs so the report shows 'skipped'
fi

# ---------- Real DRAM bandwidth + latency (tinymembench) ----------
TMB_LOG="$LOG_DIR/tinymembench.log"
if [[ "$ENABLE_TINYMEMBENCH" -eq 1 && -x "$TMB_DIR/tinymembench" ]]; then
  echo "[$(date '+%F %T')] ➤ tinymembench (real DRAM bandwidth + latency) ..."
  "$TMB_DIR/tinymembench" 2>&1 | tee "$TMB_LOG"
else
  echo "(tinymembench not built — skipping real DRAM test)" | tee "$TMB_LOG"
fi

# ---------- Threads test ----------
echo "[$(date '+%F %T')] ➤ sysbench THREADS (${THREADS_PASS_SECS}s)"
sysbench threads \
  --threads="$THREADS" --time=$THREADS_PASS_SECS --events=0 --verbosity=5 \
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

# ---------- Network sanity (LAN gateway by default) ----------
if [[ -z "$PING_TARGET" ]]; then
  PING_TARGET="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
  [[ -z "$PING_TARGET" ]] && PING_TARGET="8.8.8.8"   # fallback if no gateway
fi
echo "[$(date '+%F %T')] ➤ Pinging ${PING_TARGET} every 1s for ${PING_COUNT_SECS}s"
ping -i 1 -w "$PING_COUNT_SECS" "$PING_TARGET" 2>&1 | tee "$LOG_DIR/ping.log"
echo "Ping exit status: ${PIPESTATUS[0]}" | tee -a "$LOG_DIR/ping.log"

# ---------- fastfetch snapshot ----------
echo "[$(date '+%F %T')] ➤ Capturing system info with fastfetch"
fastfetch 2>&1 | tee "$LOG_DIR/fastfetch.log" || true

# ---------- Report generator ----------
REPORT="$LOG_DIR/report.txt"

OS_NAME="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown}")"
KERNEL="$(uname -r)"
UPTIME="$(uptime -p || true)"
MEM_HUMAN="$(free -h | awk '/^Mem:/ {printf "Total: %s, Used: %s, Free: %s, Avail: %s", $2,$3,$4,$7}')"
SWAP_HUMAN="$(free -h | awk '/^Swap:/ {printf "Total: %s, Used: %s, Free: %s", $2,$3,$4}')"
ACTIVE_IFS="$(ip -br link 2>/dev/null | awk '$2=="UP"{print $1}' | grep -v '^lo$' || true)"
IP_TABLE=$(
  while read -r IF; do
    [[ -z "$IF" ]] && continue
    IP4="$(ip -4 -br addr show dev "$IF" 2>/dev/null | awk '{print $3}' | tr -d '\n')"
    IP6="$(ip -6 -br addr show dev "$IF" 2>/dev/null | awk '{print $3}' | tr -d '\n')"
    printf "%s  IPv4: %s  IPv6: %s\n" "$IF" "${IP4:-n/a}" "${IP6:-n/a}"
  done <<< "$ACTIVE_IFS"
)
DF_TABLE="$(df -hT)"
LSBLK_TABLE="$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL)"

# Telemetry summary: max/avg temp, peak/min/avg clock across all cores
read -r MAXT AVGT MAXHZ MINHZ AVGHZ <<<"$(
  awk -F, '
    NR>1 {
      t+=$2; if($2>mt)mt=$2;
      hz=$3;
      if(hz+0>0){ if(hz>maxhz)maxhz=hz; if(minhz==0||hz<minhz)minhz=hz; hs+=hz; hn++ }
      n++
    }
    END {
      if(n==0){ print "0 0 0 0 0" }
      else { printf "%.1f %.1f %.0f %.0f %.0f\n", mt, t/n, maxhz, minhz, (hn?hs/hn:0) }
    }' "$TELEM_LOG"
)"

# Throttle: honest on non-Pi
if grep -q ',unsupported,' "$TELEM_LOG" 2>/dev/null; then
  THROTTLING="n/a (no vcgencmd on this platform — see clock vs advertised)"
  THROT_KNOWN=0
else
  THROTTLING="$(awk -F, 'NR>1 && $5!="0x0" {print $5; exit}' "$TELEM_LOG" 2>/dev/null)"
  [[ -z "$THROTTLING" ]] && THROTTLING="none"
  THROT_KNOWN=1
fi

# Clock-vs-advertised (soft throttle signal for non-Pi)
CLOCK_NOTE="n/a"
if [[ "${ADV_MAX_HZ:-0}" -gt 0 && "${MAXHZ:-0}" -gt 0 ]]; then
  PCT="$(awk -v o="$MAXHZ" -v a="$ADV_MAX_HZ" 'BEGIN{printf "%.0f", (o/a)*100}')"
  CLOCK_NOTE="peak ${MAXHZ} Hz / advertised ${ADV_MAX_HZ} Hz (${PCT}% of max)"
fi

PING_SUMMARY="$(grep -E "packet loss|rtt min/avg/max|round-trip min/avg/max" "$LOG_DIR/ping.log" | tail -n 2 || true)"

# CPU parses (events per second)
CPU_1T_EPS="$(grep -m1 "events per second" "$LOG_DIR/sysbench_cpu_1t.log"  | awk -F: '{print $2}' | xargs || true)"
CPU_NT_EPS="$(grep -m1 "events per second" "$LOG_DIR/sysbench_cpu_nt.log"  | awk -F: '{print $2}' | xargs || true)"
CPU_2NT_EPS="$(grep -m1 "events per second" "$LOG_DIR/sysbench_cpu_2nt.log" | awk -F: '{print $2}' | xargs || true)"
SCALING="$(awk -v n="${CPU_NT_EPS:-0}" -v s="${CPU_1T_EPS:-0}" 'BEGIN{ if(s>0) printf "%.2f", n/s; else print "n/a" }')"

# Threads test: compute eps = events / time (the line that was always n/a before)
TH_EPS="$(grep -m1 "events per second" "$LOG_DIR/sysbench_threads.log" | awk -F: '{print $2}' | xargs || true)"
if [[ -z "$TH_EPS" ]]; then
  TH_EV="$(grep -m1 "total number of events" "$LOG_DIR/sysbench_threads.log" | grep -oE '[0-9]+' | head -1 || true)"
  TH_TM="$(grep -m1 "total time:" "$LOG_DIR/sysbench_threads.log" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
  TH_EPS="$(awk -v e="${TH_EV:-0}" -v t="${TH_TM:-0}" 'BEGIN{ if(t>0) printf "%.2f", e/t; else print "n/a" }')"
fi

MUTEX_TOTAL="$(grep -m1 "total time:" "$LOG_DIR/sysbench_mutex.log" | awk -F: '{print $2}' | xargs || true)"
MUTEX_AVG="$(grep -m1 "avg:"         "$LOG_DIR/sysbench_mutex.log" | awk -F: '{print $2}' | xargs || true)"

# tinymembench parses (REAL DRAM — identical routines on every board)
TMB_MEMCPY="$(grep -m1 'standard memcpy' "$TMB_LOG" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)? MB/s' | head -1 || true)"
TMB_MEMSET="$(grep -m1 'standard memset' "$TMB_LOG" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)? MB/s' | head -1 || true)"
TMB_NEON="$(grep -m1 -E 'NEON LDP/STP copy +:' "$TMB_LOG" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)? MB/s' | head -1 || true)"
TMB_LAT_LINE="$(grep -E '^[[:space:]]*[0-9]+[[:space:]]*:' "$TMB_LOG" 2>/dev/null | tail -1 || true)"
TMB_LAT_BLOCK="$(echo "$TMB_LAT_LINE" | awk -F: '{print $1}' | xargs || true)"
TMB_LAT_NS="$(echo "$TMB_LAT_LINE" | sed -E 's/.*:[[:space:]]*([0-9.]+)[[:space:]]*ns.*/\1/' || true)"

# Memory results (robust rate extraction), grouped by thread count
mem_block() {
  local tt="$1" f b rate
  shopt -s nullglob
  for f in "$LOG_DIR"/sysbench_mem_*_"${tt}t".log; do
    b="$(basename "$f")"
    rate="$(grep -m1 -oE '[0-9]+(\.[0-9]+)? MiB/sec' "$f" | head -1 || true)"
    [[ -z "$rate" ]] && rate="$(grep -m1 -oE '[0-9]+(\.[0-9]+)? MB/sec' "$f" | head -1 || true)"
    printf "  %-40s %s\n" "$b:" "${rate:-n/a}"
  done
}

# ---------- PASS/FAIL heuristics ----------
PASS_TEMP=1; PASS_THROT=1; PASS_PING=1
(( $(printf "%.0f" "${MAXT:-0}") <= 85 )) || PASS_TEMP=0
if [[ "$THROT_KNOWN" -eq 1 ]]; then
  [[ "$THROTTLING" == "none" ]] || PASS_THROT=0
fi
LOSS_PCT="$(echo "$PING_SUMMARY" | grep -m1 "packet loss" | sed -E 's/.* ([0-9]+)% packet loss.*/\1/' || echo 0)"
[[ "$LOSS_PCT" =~ ^[0-9]+$ ]] || LOSS_PCT=0
(( LOSS_PCT == 0 )) || PASS_PING=0

# ---------- Build report ----------
{
  echo "==================== SBC TEST REPORT ===================="
  echo "Date: $(date)"
  echo
  echo "----- System Summary -----"
  echo "OS:        $OS_NAME"
  echo "Kernel:    $KERNEL"
  echo "Uptime:    $UPTIME"
  echo "CPU cores: $THREADS"
  echo "Clusters:  ${CLUSTERS:-n/a}"
  echo "Governor:  during test = ${GOV_SET}   (available: ${GOV_AVAIL})"
  echo "Profile:   ${MODE}"
  echo "Memory:    $MEM_HUMAN"
  echo "Swap:      $SWAP_HUMAN"
  echo
  echo "Active Adapters & IPs:"
  [[ -n "$IP_TABLE" ]] && echo "$IP_TABLE" || echo "  (none UP)"
  echo
  echo "Storage (filesystems):"
  echo "$DF_TABLE"
  echo
  echo "Storage (block devices):"
  echo "$LSBLK_TABLE"
  echo
  echo "----- CPU TEST RESULTS (events/sec, higher=better; prime=${CPU_MAX_PRIME}) -----"
  printf "Single-thread (1t) : %s   [per-core]\n" "${CPU_1T_EPS:-n/a}"
  printf "All-core     (%dt) : %s\n" "$THREADS" "${CPU_NT_EPS:-n/a}"
  printf "Oversub     (%dt) : %s\n" "$((THREADS*2))" "${CPU_2NT_EPS:-n/a}"
  printf "Parallel scaling   : %sx  (ideal ~= %s)\n" "${SCALING}" "$THREADS"
  echo
  echo "----- MEMORY: memcpy / cache throughput (sysbench, MiB/sec) -----"
  if [[ "$ENABLE_SYSBENCH_MEM" -eq 1 ]]; then
    echo " NOTE: this is a memcpy loop through cache + the libc memcpy — NOT raw DRAM"
    echo "       bandwidth. See the DRAM (tinymembench) section below for real numbers."
    echo " [single thread]"
    mem_block 1
    if [[ "$THREADS" -gt 1 ]]; then
      echo " [${THREADS} threads — aggregate]"
      mem_block "$THREADS"
    fi
  else
    echo " skipped in quick mode (redundant with tinymembench) — run with -l to include it."
    echo " See the DRAM (tinymembench) section below for real memory numbers."
  fi
  echo
  echo "----- DRAM: real bandwidth + latency (tinymembench, single-thread) -----"
  printf " memcpy (copy)          : %s\n" "${TMB_MEMCPY:-n/a}"
  printf " memset (fill)          : %s\n" "${TMB_MEMSET:-n/a}"
  printf " NEON LDP/STP copy      : %s\n" "${TMB_NEON:-n/a}"
  printf " latency, deepest block : %s ns @ %s bytes (single random read)\n" "${TMB_LAT_NS:-n/a}" "${TMB_LAT_BLOCK:-?}"
  echo "   (bandwidth higher=better, latency lower=better; identical routines every board)"
  echo
  echo "----- THREADS TEST RESULTS -----"
  printf "Events/sec: %s\n" "${TH_EPS:-n/a}"
  echo
  echo "----- MUTEX TEST RESULTS -----"
  printf "Total time: %s | Avg: %s\n" "${MUTEX_TOTAL:-n/a}" "${MUTEX_AVG:-n/a}"
  echo
  echo "----- TEMPERATURE / CLOCK SUMMARY -----"
  printf "Max Temp: %.1f°C | Avg Temp: %.1f°C\n" "${MAXT:-0}" "${AVGT:-0}"
  printf "Clock (all cores): peak %.0f Hz | min %.0f Hz | avg %.0f Hz\n" "${MAXHZ:-0}" "${MINHZ:-0}" "${AVGHZ:-0}"
  echo "Clock vs advertised: ${CLOCK_NOTE}"
  echo "Throttling: $THROTTLING"
  echo
  echo "----- NETWORK TEST RESULTS (target: ${PING_TARGET}) -----"
  [[ -n "$PING_SUMMARY" ]] && echo "$PING_SUMMARY" || echo "(no ping summary parsed)"
  echo
  echo "----- fastfetch (hardware snapshot) -----"
  cat "$LOG_DIR/fastfetch.log" 2>/dev/null || echo "(fastfetch log missing)"
  echo "==========================================================="
} | tee "$REPORT" >/dev/null

# ---------- Colorized quick summary ----------
cecho cyan "=== QUICK STATUS ==="
[[ $PASS_TEMP -eq 1 ]] && cecho green "Thermals: OK (max ${MAXT:-0}°C)" || cecho red "Thermals: HOT! (max ${MAXT:-0}°C)"
if [[ "$THROT_KNOWN" -eq 1 ]]; then
  [[ $PASS_THROT -eq 1 ]] && cecho green "Throttling: none" || cecho red "Throttling flags: $THROTTLING"
else
  cecho yellow "Throttling: $THROTTLING"
fi
[[ $PASS_PING -eq 1 ]] && cecho green "Network: OK (loss ${LOSS_PCT}%)" || cecho yellow "Network loss: ${LOSS_PCT}%"
cecho cyan "Governor during test: ${GOV_SET}"
echo
cecho cyan "Full report saved to: $REPORT"
echo

echo "[$(date '+%F %T')] ➤ All done! Logs in $LOG_DIR"
