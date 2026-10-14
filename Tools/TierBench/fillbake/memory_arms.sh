#!/bin/zsh
# Per-tier memory and cold latency from the packages' own CLIs, GPU otherwise idle. Output: memory_arms.log
set -u
cd /Volumes/Satechi/Development/pixel-agency-image-engine/bench/fillbake
K=/Volumes/Satechi/Development/mlxengine-image/PROD/flux2-klein-swift/.build/release/klein-cli
KS="/Users/dustinnielson/Library/Application Support/MLXEngine/Models/models--mlx-community--FLUX.2-klein-4B-bf16"
S=/Volumes/Satechi/Development/mlxengine-image/PROD/sensenova-u1-swift/.build/release/sensenova-cli
W=/Volumes/Satechi/Development/mlxengine-image/weights/artifacts
P="Replace the bright magenta area with a brown dog sitting on the pavement. Match the picture's lighting, perspective and style, and keep everything else unchanged."
mkdir -p memory
run() { echo "=== $1"; shift; /usr/bin/time -l "$@" 2>&1 | grep -E "pkg-edit\]|\[cli\] (loaded|resident|8-step|peak)|maximum resident|peak memory footprint|real" ; }
# Klein: the engine's tier (bf16, resident) and the 16 GB candidates (int4 / int8 with the encoder evicted), 1024² and 768²
run "klein bf16 1024"       $K --pkg-edit inputs/fill-stopsign.png --snapshot "$KS" --size 1024 --prompt "$P" --out memory/klein_bf16_1024.png
run "klein int4 evict 1024" $K --pkg-edit inputs/fill-stopsign.png --snapshot "$KS" --quant 4 --evict --size 1024 --prompt "$P" --out memory/klein_int4e_1024.png
run "klein int4 evict 768"  $K --pkg-edit inputs/fill768-stopsign.png --snapshot "$KS" --quant 4 --evict --size 768 --prompt "$P" --out memory/klein_int4e_768.png
run "klein int8 evict 1024" $K --pkg-edit inputs/fill-stopsign.png --snapshot "$KS" --quant 8 --evict --size 1024 --prompt "$P" --out memory/klein_int8e_1024.png
run "klein int4 1024"       $K --pkg-edit inputs/fill-stopsign.png --snapshot "$KS" --quant 4 --size 1024 --prompt "$P" --out memory/klein_int4_1024.png
# SenseNova 8step-v2 int4 / int8 at 768² (1024² is in AB-R-0533)
run "sensenova int4 768"  $S --weights $W/SenseNova-U1.5-8B-MoT-8step-v2-4bit --edit-image inputs/fill768-stopsign.png --width 768 --height 768 --steps 8 --cfg 1.0 --seed 7 --prompt "$P" --out memory/sn_int4_768.npy
run "sensenova int8 768"  $S --weights $W/SenseNova-U1.5-8B-MoT-8step-v2-8bit --edit-image inputs/fill768-stopsign.png --width 768 --height 768 --steps 8 --cfg 1.0 --seed 7 --prompt "$P" --out memory/sn_int8_768.npy
run "sensenova int4 1024" $S --weights $W/SenseNova-U1.5-8B-MoT-8step-v2-4bit --edit-image inputs/fill-stopsign.png --width 1024 --height 1024 --steps 8 --cfg 1.0 --seed 7 --prompt "$P" --out memory/sn_int4_1024.npy
echo "=== MEMORY DONE"
