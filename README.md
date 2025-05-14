# sbc_benchmark

> Automated system preparation and stress-testing script for Debian-based SBCs

`sbc_benchmark.sh` will:

- Create (or clean) a `~/sbc_benchmark` directory  
- Run a full system update & full-upgrade, logging output to `updates.log`  
- Ensure `fastfetch`, `stress` & `stress-ng` are installed  
- Perform a 5 min CPU burn-in with `stress` (logs to `stress.log`)  
- Perform a 5 min CPU burn-in with `stress-ng` (logs to `stress-ng.log`)  
- Ping 8.8.8.8 for 120 min and capture final statistics to `ping.log`  
- Capture a snapshot of system info with `fastfetch` (logs to `fastfetch.log`)

All stages echo status to the console and save detailed logs in `~/sbc_benchmark`.

---

## Features

- **Idempotent setup** – Cleans or creates the benchmark directory so you always start fresh  
- **Full-upgrade workflow** – Keeps your OS fully up-to-date before testing  
- **Automated package checks** – Installs missing tools on the fly  
- **Timed stress tests** – Uses built-in timeouts to auto-stop after each target duration  
- **Long-duration network test** – 2 hour ping test with summary stats  
- **Comprehensive logging** – Live console output via `tee` plus per-stage log files  

---

## Requirements

- Debian-based Linux (e.g. Ubuntu, Debian, Armbian)  
- `bash` & `apt` with **sudo** privileges  
- Internet connection for package installs & ping test  

---

## Installation

```bash
git clone https://github.com/your-username/sbc_benchmark.git
cd sbc_benchmark
chmod +x sbc_benchmark.sh
./sbc_benchmark
