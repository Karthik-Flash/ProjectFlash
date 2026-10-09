# Board session 2026-10-08 — first V1.2 board run: 0/244, fault localised

Raw evidence from the PYNQ-Z2 (PYNQ 3.1.1), bitstream `flash.bit` (now
`v1/board/flash_hp32.bit`, SHA-256 `396a219b10690f26`, HP0 32-bit). Files are
stored byte for byte (`.gitattributes`: `docs/board_runs/** -text`); never edit
them. Analysis: [`docs/V1_board_debug_log.md`](../../V1_board_debug_log.md).

**Date.** The session took place on **2026-10-08**. These files carry no date
fields of their own. `diag_2.json` and `smoke_test_and_unzip.ipynb` were
written on the board on 2026-10-08 and copied to the PC on 2026-10-09, which
is why their file times on the PC say 2026-10-09.

| File | SHA-256 prefix | Bytes | What it is |
|---|---|---|---|
| `smoke_test_and_unzip.ipynb` | `f85091acf7e996ef` | 3,562 | First notebook of the session (on the board it was `Untitled.ipynb`): unzips the bundle and checks it (CRC check passes, 249 vector files), then loads `flash.bit` and prints PYNQ 3.1.1, the IP blocks, FCLK0 66.666667 MHz, VERSION 0xf1a50102 and DMA `C_SG_LENGTH_WIDTH` 26. |
| `flash_v1_2_board.ipynb` | `35fdd2270a7551f7` | 26,342 | The first 244-image sweep on the board, executed, with outputs: **0/244 bit-exact** (decision 234/244), with one `MISMATCH` line per image, latency, threshold demo and sens/spec. |
| `diag_1.json` | `62c8f81e63891fa5` | 645 | Probe results: image 0 at FCLK0 25/50/66.67 MHz, image 0 rolled by ±1, ±4 and ±224 pixels, constant images 0/128/255, row ramp, column ramp. Each value is (logit0, logit1, margin, decision, cycles). |
| `diag_2.json` | `7670c25ec09c8de3` | 1,096 | File hashes on the board, repeatability (fresh load, soft reset, interleaved runs), register dump, DMA status, and the half-image, checker and single-pixel probes. |

These files were the input to the offline hypothesis search in the debug log.
It found that the board's output equals the golden model applied to an input
in which every odd 32-bit word is replaced by the even word before it
(244/244 images, 24/24 probes).
