## Test against reference (same seed, same route)

| pair | task | n | identical | PSNR whole (median) | PSNR mask (median) | LPIPS whole (mean) | LPIPS mask (mean) |
|---|---|---|---|---|---|---|---|
| sn1024 | fill | 15 | 0 | 32.1 | 18.2 | 0.010 | 0.191 |
| sn1024 | seamless | 11 | 0 | 44.8 | 30.8 | 0.004 | 0.085 |
| sn1024 | extend | 12 | 0 | 30.3 | 24.6 | 0.033 | 0.113 |
| sn1024 | remove | 20 | 0 | 42.7 | 30.4 | 0.018 | 0.084 |
| sn1024 | all | 58 | 0 | 37.7 | 26.7 | 0.016 | 0.118 |

## Each arm's own checks (score.py's automated failures)

| arm | task | n | auto-failed | retries | fallbacks | median warm s | change in region | purple tint | hole PSNR | left |
|---|---|---|---|---|---|---|---|---|---|---|
| int8 | fill | 15 | 0 | 0 | 0 | 6.5 | 50 | 0.004 | — | — |
| int8 | seamless | 11 | 0 | 0 | 0 | 6.9 | — | 0.003 | — | — |
| int8 | extend | 12 | 0 | 0 | 0 | 7.7 | — | 0.003 | — | — |
| int8 | remove | 20 | 0 | 0 | 0 | 4.7 | — | — | 17.7 | 0 |
| int4 | fill | 15 | 0 | 0 | 0 | 6.2 | 50 | 0.004 | — | — |
| int4 | seamless | 11 | 0 | 0 | 0 | 6.1 | — | 0.002 | — | — |
| int4 | extend | 12 | 0 | 0 | 0 | 6.8 | — | 0.003 | — | — |
| int4 | remove | 20 | 0 | 0 | 0 | 4.1 | — | — | 16.7 | 0 |
