# SBC_Test

> Automated SBC test script for Debian-based ARM single-board computers

`SBC_Test.sh` will:

- Create (or clean) a `Logs` directory next to the script  
- Run `sudo apt update` & `sudo apt full-upgrade -y`, logging output to `updates.log`  
- Download & install the **latest** ARM64 `fastfetch` `.deb` from GitHub releases  
- Ensure **stress-ng** is installed  
- Perform a **5 min CPU burn-in** using `stress-ng` (logs to `stress-ng.log`)  
- Ping `8.8.8.8` **every 10 seconds for 30 minutes** (logs to `ping.log`)  
- Capture a snapshot of system info with `fastfetch` (logs to `fastfetch.log`)

All steps echo progress to the console and save detailed logs under the `Logs` folder adjacent to the script.

---

## Features

- **Local Logs folder**  
  Stores all output in `./Logs` so nothing lands in your home directory  
- **Idempotent setup**  
  Cleans or creates the logs directory so you always start fresh  
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

## Requirements

- Debian-based ARM64 distribution (e.g. Armbian, Ubuntu Server)  
- `bash`, `curl`, `dpkg`, `apt` & sudo privileges  
- Internet connection  

---

## Installation and Running

```bash
git clone https://github.com/in-sympathy/SBC_Test.git
cd SBC_Test
chmod +x SBC_Test.sh
./SBC_Test.sh
