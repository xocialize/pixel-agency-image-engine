# Tier bench — Pixel Agency Image Engine

Run 2026-10-10T14:54:09Z, engine http://127.0.0.1:17610/mes/v0.

### generate-hard

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | iqa | recall | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|---|
| image.generate | klein-4b-base | named | 7 | 77698 | 79239 | 0.9020 | 0.9444 | 15.0 | 0 |
| image.generate | klein-4b | named | 7 | 15480 | 19690 | 0.8674 | 0.8889 | 15.0 | 0 |
| image.generate | z-image-turbo | named | 7 | 31449 | 41602 | 0.9034 | 0.9444 | 21.0 | 0 |
| image.generate | z-image | named | 7 | 68840 | 73128 | 0.8802 | 0.7778 | 21.0 | 0 |

### judge

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | score | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|
| image.describe | mage-vl | default | 24 | 1802 | — | — | — | 0 |
| image.score | siglip2-quality | default | 24 | 186 | — | 0.8882 | — | 0 |
