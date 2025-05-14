# sbc_test

> Automated SBC test script for Debian-based ARM single-board computers

`sbc_test.sh` will:

- Create (or clean) a `~/sbc_test` directory  
- Run `sudo apt update` & `sudo apt full-upgrade -y`, logging output to `updates.log`  
- Download & install the **latest** ARM64 `fastfetch` `.deb` from GitHub releases  
- Ensure **stress-ng** is installed  
- Perform a **5 min CPU burn-in** using `stress-ng` (logs to `stress-ng.log`)  
- Ping `8.8.8.8` **every 10 seconds for 30 minutes** (logs to `ping.log`)  
- Capture a snapshot of system info with `fastfetch` (logs to `fastfetch.log`)

All steps echo progress to the console and save detailed logs under `~/sbc_test`.

---

## Features

- **Idempotent setup**  
  Cleans or creates the test directory so you always start fresh  
- **Full-upgrade workflow**  
  Keeps your OS fully up-to-date before testing  
- **Auto-latest Fastfetch**  
  Pulls the newest ARM64 `.deb` via GitHub’s “latest” redirect  
- **Stress-ng only**  
  Broad coverage of CPU, cache, memory & ARM-specific workloads  
- **Timed network test**  
  30 min ping test at 10 s intervals with final summary  
- **Comprehensive logging**  
  Live console output via `tee` plus per-stage log files  

---

## Installation and Running

```bash
git clone https://github.com/in-sympathy/sbc_test.git
cd sbc_test
chmod +x sbc_test.sh
./sbc_test.sh
