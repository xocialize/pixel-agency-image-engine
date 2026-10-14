## Test against reference (same seed, same route)

| pair | task | n | identical | PSNR whole (median) | PSNR mask (median) | LPIPS whole (mean) | LPIPS mask (mean) |
|---|---|---|---|---|---|---|---|
| sn1024-reseed | fill | 15 | 0 | 27.5 | 14.1 | 0.023 | 0.410 |
| sn1024-reseed | seamless | 11 | 0 | 33.1 | 19.1 | 0.011 | 0.249 |
| sn1024-reseed | extend | 12 | 0 | 22.1 | 16.7 | 0.079 | 0.287 |
| sn1024-reseed | remove | 20 | 0 | 33.8 | 22.9 | 0.036 | 0.129 |
| sn1024-reseed | all | 58 | 0 | 29.2 | 17.3 | 0.037 | 0.257 |
| klein768-reseed | fill | 15 | 0 | 28.7 | 14.9 | 0.023 | 0.402 |
| klein768-reseed | seamless | 11 | 0 | 31.5 | 17.6 | 0.016 | 0.336 |
| klein768-reseed | extend | 12 | 1 | 26.0 | 19.7 | 0.058 | 0.207 |
| klein768-reseed | remove | 20 | 12 | 99.0 | 99.0 | 0.022 | 0.110 |
| klein768-reseed | all | 58 | 13 | 29.5 | 19.0 | 0.029 | 0.248 |
| sn768-reseed | fill | 15 | 0 | 28.0 | 14.6 | 0.025 | 0.477 |
| sn768-reseed | seamless | 11 | 0 | 31.9 | 18.0 | 0.013 | 0.294 |
| sn768-reseed | extend | 12 | 0 | 23.8 | 18.4 | 0.073 | 0.272 |
| sn768-reseed | remove | 20 | 0 | 29.3 | 18.6 | 0.045 | 0.194 |
| sn768-reseed | all | 58 | 0 | 28.2 | 16.8 | 0.040 | 0.302 |

## Each arm's own checks (score.py's automated failures)

| arm | task | n | auto-failed | retries | fallbacks | median warm s | change in region | purple tint | hole PSNR | left |
|---|---|---|---|---|---|---|---|---|---|---|
| sn7 | fill | 15 | 0 | 0 | 0 | 6.5 | 50 | 0.004 | — | — |
| sn7 | seamless | 11 | 0 | 0 | 0 | 6.9 | — | 0.003 | — | — |
| sn7 | extend | 12 | 0 | 0 | 0 | 7.7 | — | 0.003 | — | — |
| sn7 | remove | 20 | 0 | 0 | 0 | 4.7 | — | — | 17.7 | 0 |
| sn8 | fill | 15 | 0 | 0 | 0 | 6.2 | 52 | 0.004 | — | — |
| sn8 | seamless | 11 | 0 | 0 | 0 | 6.5 | — | 0.007 | — | — |
| sn8 | extend | 12 | 0 | 0 | 0 | 7.0 | — | 0.003 | — | — |
| sn8 | remove | 20 | 0 | 0 | 0 | 4.7 | — | — | 17.7 | 0 |
| k7 | fill | 15 | 0 | 0 | 0 | 9.6 | 45 | 0.004 | — | — |
| k7 | seamless | 11 | 0 | 0 | 0 | 9.6 | — | 0.010 | — | — |
| k7 | extend | 12 | 2 | 0 | 1 | 12.3 | — | 0.037 | — | — |
| k7 | remove | 20 | 14 | 1 | 13 | 15.8 | — | — | 15.0 | 0 |
| k8 | fill | 15 | 0 | 0 | 0 | 10.6 | 47 | 0.003 | — | — |
| k8 | seamless | 11 | 0 | 0 | 0 | 11.1 | — | 0.012 | — | — |
| k8 | extend | 12 | 1 | 2 | 1 | 10.4 | — | 0.004 | — | — |
| k8 | remove | 20 | 14 | 3 | 11 | 14.7 | — | — | 14.2 | 0 |
| s7 | fill | 15 | 0 | 0 | 0 | 3.8 | 51 | 0.008 | — | — |
| s7 | seamless | 11 | 0 | 0 | 0 | 3.7 | — | 0.000 | — | — |
| s7 | extend | 12 | 0 | 0 | 0 | 4.5 | — | 0.001 | — | — |
| s7 | remove | 20 | 0 | 0 | 0 | 2.9 | — | — | 14.2 | 0 |
| s8 | fill | 15 | 0 | 0 | 0 | 3.2 | 50 | 0.003 | — | — |
| s8 | seamless | 11 | 0 | 0 | 0 | 3.4 | — | 0.000 | — | — |
| s8 | extend | 12 | 0 | 0 | 0 | 4.2 | — | 0.001 | — | — |
| s8 | remove | 20 | 0 | 0 | 0 | 2.8 | — | — | 14.4 | 0 |
