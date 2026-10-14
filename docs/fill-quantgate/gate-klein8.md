## Test against reference (same seed, same route)

| pair | task | n | identical | PSNR whole (median) | PSNR mask (median) | LPIPS whole (mean) | LPIPS mask (mean) |
|---|---|---|---|---|---|---|---|
| klein8 | fill | 15 | 0 | 50.2 | 36.8 | 0.001 | 0.011 |
| klein8 | seamless | 11 | 0 | 57.7 | 43.7 | 0.000 | 0.011 |
| klein8 | extend | 12 | 0 | 47.5 | 41.4 | 0.011 | 0.062 |
| klein8 | remove | 20 | 13 | 99.0 | 99.0 | 0.000 | 0.001 |
| klein8 | all | 58 | 13 | 53.9 | 43.9 | 0.002 | 0.018 |

## Each arm's own checks (score.py's automated failures)

| arm | task | n | auto-failed | retries | fallbacks | median warm s | change in region | purple tint | hole PSNR | left |
|---|---|---|---|---|---|---|---|---|---|---|
| bf16 | fill | 15 | 0 | 0 | 0 | 9.6 | 45 | 0.004 | — | — |
| bf16 | seamless | 11 | 0 | 0 | 0 | 9.6 | — | 0.010 | — | — |
| bf16 | extend | 12 | 2 | 0 | 1 | 12.3 | — | 0.037 | — | — |
| bf16 | remove | 20 | 14 | 1 | 13 | 15.8 | — | — | 15.0 | 0 |
| int8 | fill | 15 | 0 | 0 | 0 | 10.2 | 46 | 0.004 | — | — |
| int8 | seamless | 11 | 0 | 0 | 0 | 10.2 | — | 0.010 | — | — |
| int8 | extend | 12 | 2 | 0 | 0 | 10.7 | — | 0.060 | — | — |
| int8 | remove | 20 | 14 | 1 | 13 | 19.9 | — | — | 15.0 | 0 |
