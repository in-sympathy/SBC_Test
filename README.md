# SBC_Test.sh — Comprehensive SBC Post-Repair Burn-In & Diagnostics

## Overview
`SBC_Test.sh` is a **full-system stress test and diagnostics script** designed for **single board computers (SBCs)** such as the Raspberry Pi 5.  
It is optimized for **post-repair validation** to confirm that the board operates reliably under sustained load.

The script:
- Stresses **CPU**, **memory**, **threads**, and **mutex performance** using [`sysbench`](https://github.com/akopytov/sysbench)
- Runs a **10-minute network sanity test** (ping)
- Collects **telemetry** (temperature, CPU clock, throttling status, load) every second
- Captures a **hardware/software snapshot** with [`fastfetch`](https://github.com/fastfetch-cli/fastfetch)
- Generates a **comprehensive report** combining:
  - OS & kernel version
  - RAM & swap stats
  - Active network adapters & IP addresses
  - Storage usage & block device layout
  - Parsed benchmarking results
  - Temperature & throttling analysis
  - Network packet loss and latency
  - Full `fastfetch` hardware profile
- Prints a **colorized PASS/FAIL summary** to the terminal

---

## Requirements
- **Debian-based Linux** (tested on Raspberry Pi OS, Ubuntu)
- **Internet connection** (for installing dependencies & ping test)
- Bash 4.0+  
- Packages:
  - `sysbench` ≥ 1.0.x
  - `fastfetch`
  - `vcgencmd` (Raspberry Pi-specific, optional but recommended)
  - `curl`, `lsblk`, `ip`, `df`, `free`, `grep`, `awk`

The script will automatically install `sysbench` and `fastfetch` if missing.

---

## Installation
Clone the repository and make the script executable:
```bash
git clone https://github.com/<yourusername>/<yourrepo>.git
cd <yourrepo>
chmod +x SBC_Test.sh
