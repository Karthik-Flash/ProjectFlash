# V1.2 Board Debug Log

## 2026-10-08 — first board run: 0/244 bit-exact

Evidence archived in `docs/board_runs/2026-10-08/`:

- `flash_v1_2_board.ipynb`: the board notebook with outputs (244-image sweep,
  latency, threshold demo, sens/spec).
- `diag_1.json`: probe results (image 0 at three clocks, rolled image 0,
  synthetic images).

Not archived, because they were not downloaded from the board:
`Untitled.ipynb` (the probe notebook) and `diag_2.json` (half-images,
checker, single-pixel probes). Predictions for the `diag_2` probes are given
below so they can be checked later.

### Facts

| Fact | Value | Source |
|---|---|---|
| Bitstream | `v1/board/flash.bit`, VERSION `0xF1A50102` read back OK | notebook cell 1 |
| FCLK0 on the board | 66.666667 MHz (build value 66.666672) | notebook cell 1 |
| IP blocks | `top_v1_axi_0`, `axi_dma_0`, `processing_system7_0` | notebook cell 1 |
| Bit-exact images | **0 / 244** (logit0 0, logit1 0, margin 2, decision 234) | notebook cell 4 |
| STATUS.err | never set (no assertion fired across the run) | notebook cell 4 |
| CYCLES | 12,196,126 on every image, identical to xsim | notebook cell 6 |
| Compute latency | 182.94 ms/image at 66.67 MHz (5.47 images/s) | notebook cell 6 |
| Wall time | 158.8 s for 244 images (651 ms/image incl. `.mem` parsing) | notebook cell 6 |
| Threshold register | image 0 decision flips 1 -> 0 at THRESHOLD 0x7FFFFFFF | notebook cell 8 |
| Image 0 vs clock | identical result at 25, 50 and 66.67 MHz | `diag_1.json` |
| Board sens/spec (corrupted input) | TP 118, FN 4, TN 56, FP 66 | notebook cell 10 |

Because the result does not change with clock frequency, this is not a timing
failure. Because CYCLES matches simulation, the control flow is unchanged.

### 1. Golden model vs board on the probes

Golden = `v1/mem/v1_2/flash_v1_2/tools/golden_model_v1.py` on the v1_2 export
(it reproduces `exp_logit0/1.mem` for images 0-3). Values are
(logit0, logit1, margin). Threshold -646.

| Probe | Golden | Board | Exact |
|---|---|---|---|
| const 0 | -375, 106, 481 | -375, 106, 481 | **yes** |
| const 128 | 1003, 3, -1000 | 1003, 3, -1000 | **yes** |
| const 255 | -469, 1559, 2028 | -469, 1559, 2028 | **yes** |
| row ramp (pixel = row) | -40, 150, 190 | -40, 150, 190 | **yes** |
| col ramp (pixel = column) | -615, 868, 1483 | -629, 743, 1372 | no |
| img0 (25 / 50 / 66.67 MHz) | -82, -75, 7 | -119, 6, 125 | no |
| img0 roll +1 | -57, -5, 52 | -121, -35, 86 | no |
| img0 roll -1 | 148, -61, -209 | -78, -11, 67 | no |
| img0 roll +4 | 77, -320, -397 | -118, -486, -368 | no |
| img0 roll -4 | 126, -53, -179 | 15, 20, 5 | no |
| img0 roll +224 | 16, -3, -19 | -211, 69, 280 | no |
| img0 roll -224 | -63, -256, -193 | -115, -166, -51 | no |

Images that are constant along each row are exact. Anything that varies
within a row is wrong.

### 2. Hypothesis search — result: one exact model

**Model: the accelerator computes the golden model exactly, but on an input
in which every odd 32-bit word (4-pixel beat) is replaced by the even word
before it.** The hardware sees words w0, w0, w2, w2, w4, w4, … instead of
w0, w1, w2, w3, ….

```python
def dup_even(x):                      # x: 50176 uint8, row-major
    b = x.reshape(-1, 2, 4).copy()
    b[:, 1, :] = b[:, 0, :]
    return b.ravel()
board == golden(dup_even(x))          # logit0, logit1, margin, decision
```

| Model | 244 images exact | diag_1 probes exact |
|---|---|---|
| **golden(dup_even(x))** | **244 / 244** | **14 / 14** |
| golden(dup_odd(x)) (even word replaced by the odd one) | 0 / 244 | — |

This also explains which probes passed. A row is 224 pixels = 56 words, an
even number, so a word pair never crosses a row. Duplicating one word of a pair
changes nothing when the row is constant.

Hypotheses tested on the column ramp, none exact:

- all 24 byte orders within a 4-pixel beat
- per-row circular shift by -8..+8 columns
- per-row shift with zero fill and with edge fill
- horizontal flip
- block reversal (2, 4, 8, 16, 28, 32, 56, 112 pixels)
- zeroing column 0 / 223
- all 256 index maps within 4-beat groups and all 4 within 2-beat groups

Only the duplication maps (0,0), (0,0,2,2) and (0,0,2,2,4,4,6,6) matched; they
are the same model. The golden-model variants in the brief (asymmetric
padding, rounding, saturation/ReLU order) were not needed, because the
unmodified golden model matches exactly once the input is corrected. The
const-0/128/255 and row-ramp exact matches also rule them out: they exercise
every weight, bias, shift and border case.

**Interpretation.** The accelerator core (conv, GAP, FC, decision, layer
table, weights, biases) is bit-exact on silicon. The corruption is on the
input path, DDR -> HP0 -> `axi_dma_0` MM2S, before `top_v1_axi`. In the build,
`PCW_S_AXI_HP0_DATA_WIDTH = 32` and `C_M_AXI_MM2S_DATA_WIDTH = 32` (from
`flash.hwh`). "Every other 32-bit word repeated" is the signature of the HP0
AFI running in 64-bit mode while the PL side uses 32 bits: the PL takes the low
32 bits of each 64-bit read, which belong to the even address. The Zynq sets
the AFI width in `ps7_init` (FSBL), not in the bitstream. PYNQ boots with its
own PS configuration and does not re-run our `ps7_init` when it loads an
overlay. This is an inference from the data signature; it has not yet been
confirmed on the board.

Simulation could not catch this: `tb_v1_axi` drives `s_axis` directly, and
there is no PS, HP port or DMA in the testbench.

**Board-side confirmation to run next (read only):** read the HP0 AFI
read-channel control register, `pynq.MMIO(0xF8008000, 0x1000).read(0x00)`.
Bit 0 (`32BitEn`) = 0 means the AFI is in 64-bit mode, which confirms this.
The write channel is at 0x14.

### Predictions for the `diag_2` probes (not yet downloaded)

| Probe | Golden | Predicted board, dup_even model | Golden = board |
|---|---|---|---|
| top half 255 (rows<112) | -337, 635, 972 | -337, 635, 972 | yes |
| left half 255 (cols<112) | 106, 446, 340 | 106, 446, 340 | yes |
| checker ((r+c)%2)*255 | -750, 1786, 2536 | -750, 1786, 2536 | yes |
| single px 255 at (0,0) | -375, 106, 481 | -375, 106, 481 | yes |
| single px 255 at (0,1) | -375, 106, 481 | -375, 106, 481 | yes |
| single px 255 at (0,2) | -375, 106, 481 | -375, 106, 481 | yes |
| single px 255 at (0,3) | -375, 106, 481 | -375, 106, 481 | yes |
| single px 255 at (1,0) | -375, 106, 481 | -349, 102, 451 | no |
| single px 255 at (112,112) | -386, 114, 500 | -386, 114, 500 | yes |
| single px 255 at (223,223) | -386, 114, 500 | -375, 106, 481 | no |

Pixel (1,0) is in word 56 (even), so it is duplicated into pixels (1,4..7).
Pixel (223,223) is in word 12543 (odd), so it is overwritten by word 12542
(zeros) and the result equals const 0. A single pixel in row 0 does not move
the logits at all, so those four probes cannot tell the models apart.

### 3. Simulation vs build configuration

| Item | `tb_v1` (xsim 16/16) | `tb_v1_axi` (xsim PASS) | Block design / bitstream |
|---|---|---|---|
| DUT | `top_v1` | `top_v1_axi` | `top_v1_axi_0` (module reference) |
| `WEIGHTS_FILE` | override `../mem/v1_2/flash_v1_2/weights.mem` | default (absolute v1_2) | `c:/KarDRIVE/.../v1_2/flash_v1_2/weights.mem` (hwh) |
| `BIAS_FILE` | override, relative v1_2 | default (absolute v1_2) | absolute v1_2 (hwh) |
| `LAYER_TABLE_FILE` | override, relative v1_2 | default (absolute v1_2) | absolute v1_2 (hwh) |
| `N_PIXELS` / `DEFAULT_THRESHOLD` | n/a / tb writes -646 | defaults 50176 / -646 | 50176 / -646 (hwh) |
| `defparam` | none | none | none |
| `` `define `` | `layer_table.vh` via `` `include `` (xvlog `-i` v1_1 and v1_2 dirs) | `layer_table.vh` via `-i v1/mem/v1_2/flash_v1_2` | `v1/mem/v1_2/flash_v1_2/layer_table.vh`, global include |
| `.mem` loaded at synth | — | — | Synth 8-3876 for the three absolute v1_2 files, no 8-4445 |
| Pixel source | pixel_in/pixel_valid | AXI-Stream from the testbench | AXI DMA MM2S <- HP0 <- DDR |

- The OOC synth run `flash_bd_top_v1_axi_0_0_synth_1` read
  `C:/KarDRIVE/Projects/ProjectFlash/v1/mem/v1_2/flash_v1_2/layer_table.vh`
  (`flash_bd_top_v1_axi_0_0.tcl` lines 92-96: `include_dirs` = v1_2,
  `read_verilog` of that header, `is_global_include true`).
- `FLASH_IMG_*` is not used anywhere in `v1/rtl/*.v`, `tb_v1.v` or
  `tb_v1_axi.v`. The only macros used are `LT_*`, and they are identical in
  the v1_1 and v1_2 headers.
- The only configuration difference between simulation and build is the pixel
  source. That is where the fault is.

### 4. Synth log audit: BD OOC run vs standalone `top_v1` (`d1dc26f`)

Both runs give the **same** set of `Synth 8-*` warnings, and none is a
correctness issue:

| Warning | Count | Meaning |
|---|---|---|
| 8-7129 `layer_word[N]` unconnected in `fc_unit` / `gap_unit` | 74 / 26 | those units only use some descriptor fields |
| 8-3936 `tag_out_idx_reg[1..4]`, `fm_wr_addr_reg`, `gap_stream_addr_reg` trimmed 18 -> 17 bits | 6 | `fmap_ram` is 2^17 deep, so bit 17 is unused |
| 8-3936 `bias_stage1/2_reg` trimmed 32 -> 22 bits | 2 | by design, the accumulator takes `bias[21:0]` |
| 8-3936 `u_conv/b_base_r_reg` trimmed 10 -> 8 bits | 1 | b_base max is 168 |
| 8-6014 `tag_is_pad_reg[3]`, `[4]`, `dbg_acc_valid_reg` removed | 3 | only stages 1-2 are used; debug output has no load |
| 8-7080 parallel synthesis criteria not met | 1 | informational |
| 8-7052 (INFO) `u_ram_a/b` BRAM without optional output register | — | timing note only; the RTL relies on the 1-cycle read |

There are no latch, multi-driven-net, width-truncation, sensitivity-list or
constant-register warnings in `conv_engine`, `fmap_ram`, `layer_seq`,
`top_v1` or `top_v1_axi`, and no critical warnings in the OOC run.

### Status

- Root cause, as a model: input words duplicated (w0, w0, w2, w2, …) on the
  HP0/DMA read path. The core is exact on silicon.
- To confirm on the board: the AFI0 `32BitEn` read above, plus `diag_2.json`
  against the prediction table.
- Fix: not yet applied (this step was report only).
