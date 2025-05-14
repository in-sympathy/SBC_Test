# sbc_benchmark

> Automated SBC benchmark script for Debian-based ARM single board computers

`sbc_benchmark.sh` will:

- Create (or clean) a `~/sbc_benchmark` directory  
- Run `sudo apt update` & `sudo apt full-upgrade -y`, logging output to `updates.log`  
- Download & install **fastfetch v2.43.0** from the official GitHub `.deb`  
- Ensure **stress-ng** is installed  
- Perform a **5 min CPU burn-in** using `stress-ng` (logs to `stress-ng.log`)  
- Ping `8.8.8.8` **every 5 seconds for 120 minutes** (logs to `ping.log`)  
- Capture a snapshot of system info with `fastfetch` (logs to `fastfetch.log`)

All steps echo progress to the console and save detailed logs under `~/sbc_benchmark`.

---

## Features

- **Idempotent setup**  
  Cleans or creates the benchmark directory so you always start fresh  
- **Full-upgrade workflow**  
  Keeps your OS fully up-to-date before benchmarking  
- **Fastfetch from `.deb`**  
  Installs the latest ARM64 build directly from GitHub  
- **Stress-ng only**  
  Broad coverage of CPU, cache, memory & ARM-specific workloads  
- **Timed network test**  
  2 hour ping test at 5 s intervals with final summary  
- **Comprehensive logging**  
  Live console output via `tee` plus per-stage log files  

---

## Requirements

- Debian-based ARM64 distribution (e.g. Armbian, Ubuntu Server)  
- `bash`, `curl`, `dpkg`, `apt` & sudo privileges  
- Internet connection  

---

## Installation

```bash
git clone https://github.com/your-username/sbc_benchmark.git
cd sbc_benchmark
chmod +x sbc_benchmark.sh
./sbc_benchmark.sh
