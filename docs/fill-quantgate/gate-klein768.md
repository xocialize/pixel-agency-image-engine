## Test against reference (same seed, same route)

| pair | task | n | identical | PSNR whole (median) | PSNR mask (median) | LPIPS whole (mean) | LPIPS mask (mean) |
|---|---|---|---|---|---|---|---|
| klein768 | fill | 15 | 0 | 33.9 | 19.9 | 0.010 | 0.176 |
| klein768 | seamless | 11 | 0 | 40.0 | 26.0 | 0.004 | 0.085 |
| klein768 | extend | 12 | 0 | 28.5 | 22.1 | 0.039 | 0.155 |
| klein768 | remove | 20 | 11 | 99.0 | 99.0 | 0.015 | 0.068 |
| klein768 | all | 58 | 11 | 36.1 | 24.4 | 0.016 | 0.117 |

## Each arm's own checks (score.py's automated failures)

| arm | task | n | auto-failed | retries | fallbacks | median warm s | change in region | purple tint | hole PSNR | left |
|---|---|---|---|---|---|---|---|---|---|---|
| bf16 | fill | 15 | 0 | 0 | 0 | 9.6 | 45 | 0.004 | — | — |
| bf16 | seamless | 11 | 0 | 0 | 0 | 9.6 | — | 0.010 | — | — |
| bf16 | extend | 12 | 2 | 0 | 1 | 12.3 | — | 0.037 | — | — |
| bf16 | remove | 20 | 14 | 1 | 13 | 15.8 | — | — | 15.0 | 0 |
| int4 | fill | 15 | 1 | 0 | 0 | 10.6 | 42 | 0.004 | — | — |
| int4 | seamless | 11 | 0 | 0 | 0 | 11.2 | — | 0.010 | — | — |
| int4 | extend | 12 | 1 | 0 | 0 | 13.6 | — | 0.043 | — | — |
| int4 | remove | 20 | 12 | 2 | 11 | 16.0 | — | — | 14.7 | 0 |
