# SBC_Test.sh — Comprehensive SBC Post-Repair Burn-In, Diagnostics & Fair Benchmark

## Overview
`SBC_Test.sh` is a **full-system stress test, diagnostics, and benchmark script** for **single board computers (SBCs)** — Raspberry Pi, Radxa, Orange Pi, Qualcomm-based boards (Arduino Uno Q / Ventuno Q), Jetson, and similar aarch64/arm Linux devices.

It is built for two jobs:
1. **Post-repair validation** — confirm a board runs reliably under sustained load.
2. **Fair cross-board comparison** — produce numbers you can honestly compare between different boards, not just "whatever the distro governor happened to allow."

The script:
- Stresses **CPU**, **memory**, **threads**, and **mutex** performance using [`sysbench`](https://github.com/akopytov/sysbench)
- Measures **real DRAM bandwidth and latency** with [`tinymembench`](https://github.com/ssvb/tinymembench) — identical routines on every board, so the result isn't contaminated by the compiled `memcpy` or cache behaviour
- Pins the **CPU frequency governor to `performance`** for the duration of the test (then restores it), so every board runs at full clocks
- Runs a **network sanity test** against the **LAN gateway** (isolates the board's NIC/Wi-Fi from ISP variance)
- Collects **telemetry** every second across **all CPU cores** and **all thermal zones** (temperature, peak/mean clock, throttle status, load)
- Captures a **hardware/software snapshot** with [`fastfetch`](https://github.com/fastfetch-cli/fastfetch)
- Generates a **comprehensive report** combining:
  - OS & kernel version
  - CPU core count, **cluster layout** (big.LITTLE policies & max freqs), and **governor used during the test**
  - RAM & swap stats
  - Active network adapters & IP addresses
  - Storage usage & block device layout
  - Parsed benchmark results, including **per-core (single-thread)**, **all-core**, **oversubscribed**, and a **parallel-scaling ratio**
  - **memcpy/cache throughput** (sysbench, at 1 and N threads) *and* **real DRAM bandwidth + latency** (tinymembench)
  - Temperature, observed clock range, **clock-vs-advertised** throttle signal
  - Network packet loss and latency
  - Full `fastfetch` hardware profile
- Prints a **colorized PASS/FAIL summary** to the terminal

---

## Why "fair"? (changes from the original)
The original script produced numbers that couldn't be compared honestly across boards. This version fixes that:

| Area | Before | Now |
|------|--------|-----|
| **CPU governor** | Whatever the distro defaulted to (often `schedutil`/`powersave`) | Pinned to `performance` during the test, restored afterward |
| **CPU baseline** | Hardcoded 8 threads + a *lighter* prime (360000) → oversubscribed small boards, not comparable | True **single-thread** pass using the **same** prime (600000) as the N/2N passes → clean per-core score |
| **Scaling** | — | Reports **parallel-scaling ratio** (all-core ÷ single-thread) |
| **Memory** | One sysbench pass, labelled as if it were DRAM bandwidth | sysbench relabelled honestly as a **memcpy/cache** test (1t + Nt); **tinymembench added** for real DRAM bandwidth + latency |
| **Telemetry clock** | Read only `cpu0` (a little core on big.LITTLE) | Peak/mean across **all cores** |
| **Telemetry temp** | Read only `thermal_zone0` | Hottest of **all thermal zones** |
| **Throttle status** | Printed `none` on non-Pi (Pi-only `vcgencmd`) — false confidence | Honest `n/a` on non-Pi, plus **peak clock vs advertised max** as a real signal |
| **Threads test** | Always `n/a` (parsed the wrong line) | Computes events/sec from events ÷ time |
| **Network** | Pinged `8.8.8.8` (measured your ISP) | Pings the **LAN gateway** by default (measures the board's link) |
| **apt full-upgrade** | Always ran (mutated the system mid-benchmark) | **Opt-in** (`ENABLE_APT_UPGRADE=1`) |

> **Why two memory tests?** sysbench `memory` is a memcpy loop that largely lives in cache and depends on the distro's compiled `memcpy` — so it can rank boards backwards (it flattered an iGPU-less board's strong cores over a board with genuinely faster RAM). tinymembench uses its own identical routines and buffers big enough to bypass cache, so it measures the actual memory subsystem — bandwidth *and* latency, which sysbench cannot report at all. Keep both: sysbench shows "as the software sees it," tinymembench shows the hardware truth.

---

## Requirements
- **Debian/Ubuntu-based Linux** (Raspberry Pi OS, Ubuntu, Debian; works on other aarch64 distros too)
- **Network connection** (for dependency install and the ping test)
- **Bash 4.0+**
- **`sudo`** — required to set the CPU governor (and for `apt`)
- Packages:
  - `sysbench` ≥ 1.0.x
  - `fastfetch`
  - `build-essential` + `git` — to build tinymembench (auto-installed on first run)
  - `curl`, `lsblk`, `ip`, `df`, `free`, `grep`, `awk`
  - `vcgencmd` — **Raspberry Pi only**, optional. On non-Pi boards the script reads `/sys/class/thermal` and `cpufreq` instead.

The script auto-installs `sysbench` and `fastfetch` if missing, and builds `tinymembench` once (cloned into `./tinymembench/`, reused on later runs).

> **Governor note:** setting the governor needs `sudo` and a writable `cpufreq` interface. If a board clamps or lacks it, the report says `could not set; left as-is` rather than pretending — and the telemetry clock data still shows what actually happened.

---

## Installation
```bash
git clone https://github.com/<yourusername>/SBC_Test.git
cd SBC_Test
chmod +x SBC_Test.sh
```

## Usage
```bash
sudo ./SBC_Test.sh          # quick profile (default, ~9-11 min)
sudo ./SBC_Test.sh -l       # long burn-in soak (~15 min)
./SBC_Test.sh -h            # show options (no sudo needed)
```
`sudo` is recommended so the governor can be pinned for fair results. Logs and the final report are written to `./Logs/`, and the report prints a `Profile: quick|long` line so you know which mode produced it.

### Modes
| Flag | Profile | Runtime | Use when |
|------|---------|---------|----------|
| `-q`, `--quick` | Fast benchmark (**default**) | ~9–11 min | Comparing boards — same metrics, shorter thermal soak |
| `-l`, `--long` | Long burn-in | ~15 min | Post-repair stability — extended CPU soak catches slow thermal creep |
| `-h`, `--help` | — | — | Print options and exit |

Both modes run the same tests and produce the same metrics; `-l` only lengthens the sustained CPU soak.

Full report:
```bash
cat Logs/report.txt
```

---

## Configuration
Edit the variables at the top of the script:

| Variable | Default | Purpose |
|----------|---------|---------|
| `SINGLE_PASS_SECS` | `30` | Single-thread CPU pass |
| `CPU_PASS_SECS` | `120` | All-core pass (doubles as the thermal heat-soak) |
| `CPU_2NT_PASS_SECS` | `60` | Oversubscribed (2N) pass — redundancy check, no soak |
| `THREADS_PASS_SECS` | `60` | Threads test |
| `MUTEX_PASS_SECS` | `60` | Mutex test |
| `CPU_MAX_PRIME` | `600000` | Prime ceiling used by **all** CPU passes (keep identical across boards) |
| `MEM_TOTAL_SIZE` | `1G` | Data processed per sysbench memory subtest (rate is size-independent) |
| `MEM_BLOCK_SIZES` | `4K 64K 1M` | Memory block sizes swept |
| `MEM_ACCESS_MODES` | `seq rnd` | Sequential and random access |
| `MEM_OPS` | `read write` | Memory operations |
| `PIN_GOVERNOR` | `1` | Set `performance` during the test and restore after |
| `ENABLE_TINYMEMBENCH` | `1` | Build & run tinymembench for real DRAM bandwidth + latency |
| `TMB_DIR` | `./tinymembench` | Where tinymembench is cloned/built |
| `ENABLE_APT_UPGRADE` | `0` | Set `1` to `apt full-upgrade` before testing (mutates the system) |
| `PING_TARGET` | `""` (auto) | Empty = default gateway; set an IP/host to override |
| `PING_COUNT_SECS` | `60` | Duration of the ping test |
| `ENABLE_FILEIO` | `0` | Set `1` to run the flash-wearing file I/O test |

> The durations above are the **quick** (`-q`, default) profile. Passing **`-l`** overrides the five `*_PASS_SECS` values with the long burn-in profile (60 / 300 / 120 / 180 / 180 s). Edit the values here to tune the quick profile.

---

## Reading the report

**CPU** — all rows are sysbench `events/sec` (higher is better), measured with the same prime ceiling:
- `Single-thread (1t)` — per-core performance; the fairest cross-board number.
- `All-core (Nt)` — full-chip throughput.
- `Oversub (2Nt)` — should roughly equal all-core on these ARM cores (no SMT); a big gap suggests scheduling oddities.
- `Parallel scaling` — all-core ÷ single-thread; ideal ≈ core count.

**Memory (sysbench, MiB/s)** — this is a **memcpy/cache** test, *not* raw DRAM bandwidth. Useful as "how fast the software moves memory," but read it alongside the DRAM section, not instead of it:
- *single thread* — one core streaming through a buffer.
- *N threads* — aggregate, across all cores.

**DRAM (tinymembench)** — the real memory test, identical routines on every board:
- `memcpy` / `memset` / `NEON copy` — sustained one-core DRAM bandwidth (higher is better). This is the number to trust for "which board has faster RAM."
- `latency, deepest block` — single-random-read latency in ns at the largest buffer (lower is better) = real DRAM access latency. Bandwidth and latency don't always agree: wide high-bandwidth memory often has *higher* latency, so a board can win one and lose the other.

**Temperature / Clock:**
- `Clock (all cores)` — peak/min/avg observed across every core.
- `Clock vs advertised` — observed peak against `cpuinfo_max_freq`; well below 100% under sustained load is a throttling signal on non-Pi boards.
- `Throttling` — real flags on a Pi (`vcgencmd get_throttled`); `n/a` on other platforms, where you judge from the clock data above.

**Network** — packet loss and latency to the gateway (or your override target).

---

## Notes & caveats
- **Runtime** is ~9–11 minutes in the default quick (`-q`) profile, ~15 minutes with `-l` (long burn-in). Both produce identical metrics; `-l` only extends the sustained CPU soak.
- **First run builds tinymembench** (`git clone` + `make`, ~1 min, needs internet). The binary is cached in `./tinymembench/` and reused on later runs; set `ENABLE_TINYMEMBENCH=0` to skip it.
- The **governor is restored** on exit even if the script is interrupted (trap on EXIT), along with stopping the telemetry logger.
- `vcgencmd`-based throttle flags are **Raspberry Pi only**; on other SoCs the clock-vs-advertised signal is the honest substitute.
- `MEM_TOTAL_SIZE` controls run *length*, not the reported *rate* — changing it doesn't change comparability of sysbench MiB/sec figures.
- The file I/O test is **off by default** because it wears flash; enable it only when you specifically want storage numbers.
