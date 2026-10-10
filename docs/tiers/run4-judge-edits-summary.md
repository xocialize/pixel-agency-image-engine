# Tier bench — Pixel Agency Image Engine

Run 2026-10-10T08:46:23Z, engine http://127.0.0.1:17610/mes/v0.

### edits

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) |  | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|
| image.edit | klein-4b | draft | 2 | 15407 | 16807 |  | 16.0 | 0 |
| image.edit | qwen-image-edit | best | 2 | 314267 | 319164 |  | 41.0 | 0 |
| image.erase | lama-inpaint | best | 2 | 888 | 895 |  | 41.0 | 0 |
| image.erase | lama-inpaint | standard | 2 | 829 | 1860 |  | 41.0 | 0 |
| image.extend | klein-4b | standard | 2 | 27320 | 29267 |  | 16.0 | 0 |
| image.extend | lama-inpaint | draft | 2 | 2016 | 1803 |  | 41.0 | 0 |
| image.extend | qwen-image-edit | best | 2 | 316225 | 319586 |  | 41.0 | 0 |
| image.fill | klein-4b | standard | 2 | 17897 | 20139 |  | 16.0 | 0 |
| image.fill | qwen-image-edit | best | 2 | 316769 | 319828 |  | 41.0 | 0 |

### generate

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | iqa | recall | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|---|
| image.generate | klein-4b-base | named | 8 | 80039 | — | 0.9142 | 1.0000 | — | 0 |
| image.generate | klein-4b | named | 8 | 8780 | — | 0.9032 | 1.0000 | 16.0 | 0 |
| image.generate | qwen-image-flash | named | 2 | 15916 | — | 0.9350 | 1.0000 | — | 0 |
| image.generate | z-image-turbo | named | 8 | 13719 | — | 0.9146 | 1.0000 | — | 0 |
| image.generate | z-image | named | 8 | 70360 | — | 0.8948 | 1.0000 | — | 0 |

### judge

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | score | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|
| image.describe | mage-vl | default | 34 | 1845 | — | — | — | 0 |
| image.score | siglip2-quality | default | 34 | 192 | — | 0.9084 | — | 0 |
