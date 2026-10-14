## Test against reference (same seed, same route)

| pair | task | n | identical | PSNR whole (median) | PSNR mask (median) | LPIPS whole (mean) | LPIPS mask (mean) |
|---|---|---|---|---|---|---|---|
| sn768 | fill | 15 | 0 | 34.6 | 21.4 | 0.010 | 0.194 |
| sn768 | seamless | 11 | 0 | 42.8 | 28.8 | 0.004 | 0.102 |
| sn768 | extend | 12 | 0 | 30.5 | 24.1 | 0.037 | 0.144 |
| sn768 | remove | 20 | 0 | 35.4 | 22.8 | 0.026 | 0.103 |
| sn768 | all | 58 | 0 | 35.0 | 23.5 | 0.020 | 0.135 |

## Each arm's own checks (score.py's automated failures)

| arm | task | n | auto-failed | retries | fallbacks | median warm s | change in region | purple tint | hole PSNR | left |
|---|---|---|---|---|---|---|---|---|---|---|
| int8 | fill | 15 | 0 | 0 | 0 | 3.8 | 51 | 0.008 | — | — |
| int8 | seamless | 11 | 0 | 0 | 0 | 3.7 | — | 0.000 | — | — |
| int8 | extend | 12 | 0 | 0 | 0 | 4.5 | — | 0.001 | — | — |
| int8 | remove | 20 | 0 | 0 | 0 | 2.9 | — | — | 14.2 | 0 |
| int4 | fill | 15 | 0 | 0 | 0 | 3.3 | 50 | 0.004 | — | — |
| int4 | seamless | 11 | 0 | 0 | 0 | 3.1 | — | 0.000 | — | — |
| int4 | extend | 12 | 0 | 0 | 0 | 3.7 | — | 0.001 | — | — |
| int4 | remove | 20 | 0 | 0 | 0 | 2.8 | — | — | 13.9 | 0 |
