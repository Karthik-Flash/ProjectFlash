#!/usr/bin/env bash
# Fast local check without Vivado.  usage: ./run_iverilog.sh [N_IMAGES]
set -e
N=${1:-8}
D=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
cp "$D"/rtl/*.v "$D"/sim/tb_top.v "$D"/mem/*.mem "$T"/
cd "$T"
iverilog -g2012 -Ptb_top.N_IMAGES="$N" -o sim ./*.v
./sim | grep -vE "CONV COMPLETE|POOL|FSM|parallel|Progress|LOGITS:|drain"
