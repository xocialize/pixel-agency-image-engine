#!/bin/zsh
# The Generative Fill quant gate (AB-A-0178): each int4 tier against its reference through the engine's fill route on the
# bake-off's cases, seed 7, one arm at a time; then each reference at seed 8 (how far a different draw lands) and Klein int8
# evicted. Needs the engine started with the gate arms (QuantGateArms):
#   .build/release/pixel-agency-image-engine --port 17611 --quant-gate-arms --no-advertise
# Score with quantgate.py (score / blind / unblind).
set -u
cd /Volumes/Satechi/Development/pixel-agency-image-engine
TB=Tools/TierBench/.build/release/TierBench
E=http://127.0.0.1:17611/mes/v0
C=/Volumes/Satechi/Development/pixel-agency-image-engine/bench/fillbake/cases.json
Q=bench/quantgate
T=fill,seamless,extend,remove
run() { # name arms seed
  echo "[$(date +%H:%M:%S)] start $1 arms $2 seed $3 | load $(sysctl -n vm.loadavg)"
  rm -rf "$Q/run-$1"
  "$TB" fillbake --engine $E --cases $C --out "$Q/run-$1" --models "$2" --tasks $T --seed $3 > "$Q/run-$1.log" 2>&1
  echo "[$(date +%H:%M:%S)] done $1: $(wc -l < "$Q/run-$1/results.jsonl") records, exit $? | load $(sysctl -n vm.loadavg)"
}
run sn1024 sensenova-u1-fast,sensenova-u1-fast-4bit 7
run klein768 klein-4b-768,klein-4b-int4-evict-768 7
run sn768 sensenova-u1-fast-768,sensenova-u1-fast-4bit-768 7
run anchor sensenova-u1-fast,klein-4b-768,sensenova-u1-fast-768 8
run klein8 klein-4b-int8-evict-768 7
echo "[$(date +%H:%M:%S)] ALL DONE"
