#!/bin/zsh
# The whole bake-off through the running engine, one task after another (the GPU is shared, so never two at once).
# Detached from the shell that launches it; progress goes to run_all.log, each task to its own run-*/results.jsonl.
set -u
cd /Volumes/Satechi/Development/pixel-agency-image-engine
TB=Tools/TierBench/.build/release/TierBench
B=bench/fillbake
run() { # name tasks models
  echo "[$(date +%H:%M:%S)] start $1 ($2) arms $3"
  rm -rf "$B/run-$1"
  "$TB" fillbake --cases "$B/cases.json" --out "$B/run-$1" --models "$3" --tasks "$2" > "$B/run-$1.log" 2>&1
  echo "[$(date +%H:%M:%S)] done $1: $(wc -l < "$B/run-$1/results.jsonl") records, exit $?"
}
run rest fill768,seamless,extend klein-4b,sensenova-u1-fast
run fill fill klein-4b,sensenova-u1-fast
run remove remove lama-inpaint,klein-4b,sensenova-u1-fast
echo "[$(date +%H:%M:%S)] ALL DONE"
