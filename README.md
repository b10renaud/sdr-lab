# SDR Lab

Hardened SDR installer and tooling for Ubuntu 24.04 LTS.

## What It Does

Installs a complete software-defined radio environment on a fresh 
Ubuntu 24.04 machine in a single script — plug in your RTL-SDR 
dongle and go.

## Requirements

- Ubuntu 24.04 LTS (noble)
- RTL-SDR Blog V4 dongle (or compatible RTL2832U device)
- Internet connection

## Usage

\```bash
chmod +x sdr_lab_install.sh
./sdr_lab_install.sh
\```

## What Gets Installed

- RTL-SDR Blog V4 drivers (built from source)
- SDR++ with full audio support
- GQRX
- GNU Radio
- dump1090 aircraft tracker
- Universal Radio Hacker (URH)
- SDRTrunk trunked radio decoder
- noaa-apt weather satellite decoder
- SDRangel

## Quick Start After Install

| What | Command |
|---|---|
| Visual waterfall | `sdrpp` |
| FM Radio | `rtl_fm -f 101.1M -M wbfm -s 200000 -r 48000 - \| aplay -r 48000 -f S16_LE -t raw -c 1` |
| Aircraft tracking | `dump1090-start` then open http://127.0.0.1:8080 |
| NOAA Weather Radio | `rtl_fm -f 162.550M -M fm -s 200000 -r 48000 - \| aplay -r 48000 -f S16_LE -t raw -c 1` |