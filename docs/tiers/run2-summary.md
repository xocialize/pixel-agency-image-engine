# Tier bench — Pixel Agency Image Engine

Run 2026-10-10T08:06:16Z, engine http://127.0.0.1:17610/mes/v0.

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
| image.generate | klein-4b-base | named | 9 | 80039 | 81770 |  | 16.0 | 0 |
| image.generate | klein-4b | named | 9 | 8780 | 10806 |  | 23.0 | 0 |
| image.generate | qwen-image-flash | named | 3 | 15916 | 18467 |  | — | 6 |
| image.generate | z-image-turbo | named | 9 | 13719 | 17883 |  | 28.0 | 0 |
| image.generate | z-image | named | 9 | 70360 | 74519 |  | 22.0 | 0 |

### judge

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) |  | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|
| image.describe | ? | default | 0 | — | — |  | — | 34 |
| image.score | ? | default | 0 | — | — |  | — | 34 |

### restore-deblur

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | psnr | psnr-degraded | ssim | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|---|---|
| image.restore | nafnet-restore | named | 8 | 259 | 266 | 26.7577 | 25.6038 | 0.7514 | 9.3 | 0 |
| image.restore | restormer-defocus | named | 7 | 2983 | 3322 | 26.5801 | — | 0.7962 | 28.0 | 0 |
| image.restore | restormer-motion | named | 7 | 2986 | 3318 | 25.9420 | — | 0.7480 | 46.0 | 0 |
| reference | (degraded input) | default | 6 | 0 | — | 26.7690 | — | 0.7564 | — | 0 |

### restore-denoise

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | psnr | psnr-degraded | ssim | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|---|---|
| image.restore | drunet-denoise | named | 7 | 408 | 681 | 27.6719 | — | 0.6437 | 48.0 | 0 |
| image.restore | nafnet-restore | named | 8 | 286 | 293 | 32.6385 | 24.0793 | 0.8914 | 9.3 | 0 |
| image.restore | restormer-denoise | named | 7 | 3002 | 3302 | 27.0476 | — | 0.8188 | 46.0 | 0 |
| image.restore | scunet-denoise | named | 7 | 14376 | 14776 | 33.3216 | — | 0.9032 | 45.0 | 0 |
| reference | (degraded input) | default | 6 | 0 | — | 23.9536 | — | 0.4658 | — | 0 |

### segment-1click

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | iou | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|
| image.segment | edgetam-segment | named | 51 | 160 | 148 | 0.6508 | 9.3 | 0 |
| image.segment | sam21-segment | named | 51 | 155 | 127 | 0.7721 | 9.3 | 0 |

### singles

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | score | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|
| image.colorize | ddcolor-colorize | default | 3 | 757 | 768 | — | 47.0 | 0 |
| image.describe | mage-vl | default | 3 | 1907 | 1905 | — | 47.0 | 0 |
| image.matte | birefnet-matte | default | 3 | 1118 | 1101 | — | 47.0 | 0 |
| image.relight | cidnet-relight | default | 3 | 853 | 859 | — | 47.0 | 0 |
| image.score | siglip2-quality | default | 3 | 187 | 204 | 0.9125 | 47.0 | 0 |

### tiers

| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | score | Footprint (GB) | Errors |
|---|---|---|---|---|---|---|---|---|
| image.colorize | ddcolor-colorize | best | 1 | 496 | — | — | 47.0 | 0 |
| image.colorize | ddcolor-colorize | draft | 1 | 764 | — | — | 47.0 | 0 |
| image.colorize | ddcolor-colorize | standard | 1 | 494 | — | — | 47.0 | 0 |
| image.describe | mage-vl | default | 1 | 4794 | — | — | 47.0 | 0 |
| image.edit | klein-4b | draft | 1 | 16325 | — | — | 23.0 | 0 |
| image.edit | klein-4b | standard | 1 | 15316 | — | — | 23.0 | 0 |
| image.edit | qwen-image-edit | best | 1 | 315241 | — | — | — | 0 |
| image.erase | lama-inpaint | best | 1 | 252 | — | — | — | 0 |
| image.erase | lama-inpaint | draft | 1 | 376 | — | — | — | 0 |
| image.erase | lama-inpaint | standard | 1 | 370 | — | — | — | 0 |
| image.extend | klein-4b | standard | 1 | 10603 | — | — | 23.0 | 0 |
| image.extend | lama-inpaint | draft | 1 | 624 | — | — | — | 0 |
| image.extend | qwen-image-edit | best | 1 | 313213 | — | — | — | 0 |
| image.fill | lama-inpaint | best | 1 | 256 | — | — | — | 0 |
| image.fill | lama-inpaint | draft | 1 | 1283 | — | — | — | 0 |
| image.fill | lama-inpaint | standard | 1 | 373 | — | — | — | 0 |
| image.generate | klein-4b | draft | 1 | 4334 | — | — | 23.0 | 0 |
| image.generate | z-image-turbo | standard | 1 | 7466 | — | — | 28.0 | 0 |
| image.generate | z-image | best | 1 | 20560 | — | — | 22.0 | 0 |
| image.matte | birefnet-matte | default | 1 | 1096 | — | — | 47.0 | 0 |
| image.relight | cidnet-relight | best | 1 | 62 | — | — | 47.0 | 0 |
| image.relight | cidnet-relight | draft | 1 | 420 | — | — | 47.0 | 0 |
| image.relight | cidnet-relight | standard | 1 | 64 | — | — | 47.0 | 0 |
| image.restore | nafnet-restore | best | 1 | 128 | — | — | 9.3 | 0 |
| image.restore | nafnet-restore | draft | 1 | 160 | — | — | 9.3 | 0 |
| image.restore | nafnet-restore | standard | 1 | 130 | — | — | 9.3 | 0 |
| image.score | siglip2-quality | default | 1 | 277 | — | 0.9331 | 47.0 | 0 |
| image.segment | sam21-segment | default | 1 | 193 | — | — | 9.3 | 0 |
| image.upscale | heart-upscale | best | 1 | 2603 | — | — | — | 0 |
| image.upscale | nerve-upscale | draft | 1 | 327 | — | — | — | 0 |
| image.upscale | realplksr-upscale | standard | 1 | 1001 | — | — | — | 0 |
