# Tier bench — Pixel Agency Image Engine

Run 2026-10-10T07:18:48Z, engine http://127.0.0.1:17610/mes/v0.

### edits

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) |  | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|
| image.edit | ? | best | 0 | — | 0 |  | — | 2 |
| image.edit | ? | draft | 0 | — | 0 |  | — | 2 |
| image.erase | ? | best | 0 | — | 0 |  | — | 2 |
| image.erase | ? | standard | 0 | — | 0 |  | — | 2 |
| image.extend | ? | best | 0 | — | 0 |  | — | 2 |
| image.extend | ? | draft | 0 | — | 0 |  | — | 2 |
| image.extend | ? | standard | 0 | — | 0 |  | — | 2 |
| image.fill | ? | best | 0 | — | 0 |  | — | 2 |
| image.fill | ? | standard | 0 | — | 0 |  | — | 2 |

### generate

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) |  | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|
| image.generate | klein-4b-base | named | 9 | 82512 | 461849 |  | 79.0 | 0 |
| image.generate | klein-4b | named | 9 | 9002 | 10779 |  | 47.0 | 0 |
| image.generate | qwen-image-flash | named | 1 | — | 621040 |  | — | 8 |
| image.generate | z-image-turbo | named | 9 | 14437 | 13403 |  | 72.0 | 0 |
| image.generate | z-image | named | 9 | 70726 | 75390 |  | 66.0 | 0 |

### judge

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) |  | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|
| image.describe | ? | default | 0 | — | — |  | — | 32 |
| image.score | ? | default | 0 | — | — |  | — | 32 |

### restore-deblur

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | psnr | psnr-degraded | ssim | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|---|---|
| image.restore | nafnet-restore | named | 8 | 258 | 275 | 26.7577 | 25.6038 | 0.7514 | 73.0 | 0 |
| image.restore | restormer-defocus | named | 7 | 3022 | 15762 | 26.5801 | — | 0.7962 | 71.0 | 0 |
| image.restore | restormer-motion | named | 7 | 3023 | 11532 | 25.9420 | — | 0.7480 | 70.0 | 0 |
| reference | (degraded input) | default | 6 | 0 | — | 26.7690 | — | 0.7564 | — | 0 |

### restore-denoise

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | psnr | psnr-degraded | ssim | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|---|---|
| image.restore | drunet-denoise | named | 7 | 436 | 10448 | 27.6719 | — | 0.6437 | 72.0 | 0 |
| image.restore | nafnet-restore | named | 8 | 291 | 852 | 32.6385 | 24.0793 | 0.8914 | 73.0 | 0 |
| image.restore | restormer-denoise | named | 7 | 3033 | 23555 | 27.0476 | — | 0.8188 | 70.0 | 0 |
| image.restore | scunet-denoise | named | 7 | 18781 | 19335 | 33.3216 | — | 0.9032 | 70.0 | 0 |
| reference | (degraded input) | default | 6 | 0 | — | 23.9536 | — | 0.4658 | — | 0 |

### segment-1click

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | iou | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|
| image.segment | edgetam-segment | named | 40 | 116 | 137 | 0.6050 | 72.0 | 11 |
| image.segment | sam21-segment | named | 40 | 116 | 128 | 0.7477 | 72.0 | 11 |

### singles

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | score | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|
| image.colorize | ddcolor-colorize | default | 3 | 772 | 778 | — | 61.0 | 0 |
| image.describe | mage-vl | default | 3 | 1844 | 1993 | — | 61.0 | 0 |
| image.matte | birefnet-matte | default | 3 | 1168 | 1158 | — | 61.0 | 0 |
| image.relight | cidnet-relight | default | 3 | 873 | 906 | — | 61.0 | 0 |
| image.score | siglip2-quality | default | 3 | 195 | 202 | 0.9125 | 61.0 | 0 |

### tiers

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | score | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|
| image.colorize | ddcolor-colorize | best | 1 | 503 | — | — | 61.0 | 0 |
| image.colorize | ddcolor-colorize | draft | 1 | 760 | — | — | 61.0 | 0 |
| image.colorize | ddcolor-colorize | standard | 1 | 496 | — | — | 61.0 | 0 |
| image.describe | mage-vl | default | 1 | 5330 | — | — | 61.0 | 0 |
| image.edit | klein-4b | draft | 1 | 15033 | — | — | 47.0 | 0 |
| image.edit | klein-4b | standard | 1 | 15401 | — | — | 47.0 | 0 |
| image.edit | qwen-image-edit | best | 1 | 333857 | — | — | — | 0 |
| image.erase | lama-inpaint | best | 1 | 241 | — | — | — | 0 |
| image.erase | lama-inpaint | draft | 1 | 383 | — | — | — | 0 |
| image.erase | lama-inpaint | standard | 1 | 381 | — | — | — | 0 |
| image.extend | klein-4b | standard | 1 | 9584 | — | — | 47.0 | 0 |
| image.extend | lama-inpaint | draft | 1 | 624 | — | — | — | 0 |
| image.extend | qwen-image-edit | best | 1 | 304618 | — | — | — | 0 |
| image.fill | lama-inpaint | best | 1 | 268 | — | — | — | 0 |
| image.fill | lama-inpaint | draft | 1 | 2025 | — | — | — | 0 |
| image.fill | lama-inpaint | standard | 1 | 376 | — | — | — | 0 |
| image.generate | klein-4b | draft | 1 | 4365 | — | — | 47.0 | 0 |
| image.generate | z-image-turbo | standard | 1 | 7527 | — | — | 72.0 | 0 |
| image.generate | z-image | best | 1 | 20578 | — | — | 66.0 | 0 |
| image.matte | birefnet-matte | default | 1 | 1109 | — | — | 61.0 | 0 |
| image.relight | cidnet-relight | best | 1 | 71 | — | — | 61.0 | 0 |
| image.relight | cidnet-relight | draft | 1 | 396 | — | — | 61.0 | 0 |
| image.relight | cidnet-relight | standard | 1 | 70 | — | — | 61.0 | 0 |
| image.restore | nafnet-restore | best | 1 | 135 | — | — | 73.0 | 0 |
| image.restore | nafnet-restore | draft | 1 | 159 | — | — | 73.0 | 0 |
| image.restore | nafnet-restore | standard | 1 | 136 | — | — | 73.0 | 0 |
| image.score | siglip2-quality | default | 1 | 360 | — | 0.9331 | 61.0 | 0 |
| image.segment | sam21-segment | default | 1 | 236 | — | — | 72.0 | 0 |
| image.upscale | heart-upscale | best | 1 | 2639 | — | — | 66.0 | 0 |
| image.upscale | nerve-upscale | draft | 1 | 319 | — | — | 66.0 | 0 |
| image.upscale | realplksr-upscale | standard | 1 | 998 | — | — | 66.0 | 0 |

### upscale-x2

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | psnr | ssim | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|---|
| image.upscale | heart-upscale | named | 7 | 2416 | 2386 | 31.3530 | 0.9138 | 66.0 | 0 |
| image.upscale | nacre-upscale | named | 7 | 14077 | 15293 | 28.7534 | 0.8671 | 70.0 | 0 |
| image.upscale | nerve-upscale | named | 7 | 292 | 294 | 30.1837 | 0.8748 | 66.0 | 0 |
| image.upscale | realplksr-upscale | named | 7 | 943 | 956 | 30.6515 | 0.9052 | 66.0 | 0 |
| image.upscale | seedvr2-upscale | named | 7 | 8724 | 7547 | 26.8775 | 0.7792 | 72.0 | 0 |

### upscale-x4

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | psnr | ssim | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|---|
| image.upscale | heart-upscale | named | 7 | 633 | 656 | 27.0521 | 0.7824 | 66.0 | 0 |
| image.upscale | nacre-upscale | named | 7 | 5042 | 22409 | 25.6290 | 0.7474 | 70.0 | 0 |
| image.upscale | nerve-upscale | named | 7 | 216 | 295 | 26.9734 | 0.7791 | 66.0 | 0 |
| image.upscale | realplksr-upscale | named | 7 | 309 | 316 | 26.4587 | 0.7557 | 66.0 | 0 |
| image.upscale | seedvr2-upscale | named | 7 | 8429 | 125359 | 25.6368 | 0.7357 | 72.0 | 0 |
