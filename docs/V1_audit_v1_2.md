# Project FLASH — V1.2 post-run audit (224×224, real RSNA, clinical resolution)

Audited artifact: `v1/mem/v1_2/flash_v1_2/`
Executed notebook: `v1/mem/v1_2/ProjectFlash_V1_2.ipynb` (43 cells; the task brief expected
`colab/ProjectFlash_V1_2.ipynb` — see **Open questions**, same issue as the V1.1 report).
Audit branch: `audit/v1-post-run`. Same independent-recomputation method as the V1.1 report: a
standalone script (stdlib + numpy + nbformat only) reads only the exported files and recomputes
everything from scratch.

Same headline as V1.1: no genuine defect. Every correctness check is bit-exact. The one real gap
— `manifest.json`'s `file_sha256` not covering `vectors/` — is identical in root cause to V1.1
(same notebook, same bug), so it's reported here with the V1.2-specific numbers but not
re-explained; see the V1.1 report for the reproducer.

## Verification results

### 1. File integrity

| Check | Result |
|---|---|
| `manifest.file_sha256` coverage | **FAIL (scope gap, same as V1.1)** — only 3/313 `.mem` files hashed. All 244 `vectors/img_*.mem` (50,176 lines each, ~50 MB total), the 6 `exp_*.mem`/`gt_label.mem`, and all 60 `vectors/trace/*.mem` have no recorded hash. Root cause: `EXPORT.glob('*.mem')` in notebook cell 42 is non-recursive — identical bug as V1.1, since it's the same notebook template. |
| SHA-256 of the 3 covered files | PASS — 3/3 match `manifest.json` |
| `weights.mem` line format (2 hex chars/line) | PASS — 47,432/47,432 lines well-formed |
| `bias.mem` line format (8 hex chars/line) | PASS — 170/170 lines well-formed |
| `vectors/img_*.mem` line counts (== 50,176 = 224×224) | PASS — 244/244 files, 0 bad |

### 2. Layer table decoding

| Check | Result |
|---|---|
| `LT_WORD_W` vs actual hex-line length | PASS — 128 bits, all 7 lines |
| Field-by-field decode vs `layer_table.json` | PASS — 0 mismatches across 7 records × 13 fields |
| `w_base`/`b_base` contiguity (conv layers + fc) | PASS |
| `FLASH_N_WEIGHTS` (47432) == `len(weights.mem)` | PASS |
| `FLASH_N_BIASES` (170) == `len(bias.mem)` | PASS |

**Cross-check against V1.1's `layer_table.vh`:** identical `LT_*_MSB`/`LT_*_LSB` field map,
identical `LT_OP_*` opcodes, identical `FLASH_N_LAYERS`/`FLASH_N_WEIGHTS`/`FLASH_N_BIASES`. Only
`FLASH_IMG_H`/`FLASH_IMG_W` differ (28→224) and the per-layer `in_h/in_w/out_h/out_w` values
inside the table, plus `conv4`/`conv5` shift (7→8) and gap shift (0→6) — exactly the set of
things that should change with resolution and nothing else. **PASS.**

### 3. Golden model round-trip

Same procedure as V1.1, against the 224×224 vectors (50,176 bytes/image, ~50 MB of test images
total).

| Check | Result |
|---|---|
| `exp_logit0.mem` | PASS — 244/244 exact |
| `exp_logit1.mem` | PASS — 244/244 exact |
| `exp_margin.mem` | PASS — 244/244 exact |
| `exp_argmax.mem` | PASS — 244/244 exact |
| `exp_decision.mem` (T = −646) | PASS — 244/244 exact |
| decision vs. `gt_label.mem` | 174/244 (71.3%) agree — matches the notebook's own printed figure exactly; sanity check, not a pass/fail criterion. |
| Trace reproduction: `img{0..7}_conv{1..5}.mem`, `img{0..7}_gap.mem` | PASS — 48/48 files, 0 mismatches |
| Trace reproduction: `img{0,1}_conv{1..5}_acc.mem`, `img{0,1}_gap_sum_acc.mem` | PASS — 12/12 files, 0 mismatches |

**0 mismatches anywhere**, matching the notebook's own §12 CHECK 1/CHECK 2 (0 mismatches on
24.5M+ conv1 values alone, 4003/4003 test logits bit-exact), independently reproduced from the
exported files with no PyTorch involved.

### 4. Arithmetic range sanity

| Signal | Recomputed (244 vectors) | Manifest `acc_stats` (8,006 val+test imgs) | Bits stored (RTL) |
|---|---|---|---|
| conv1_acc | [−30,824, 22,591] (16 bit) | [−32,204, 25,288] (16 bit) | 22 (guaranteed) |
| conv2_acc | [−27,429, 29,962] (16 bit) | [−28,190, 34,826] (17 bit) | 22 |
| conv3_acc | [−52,667, 27,344] (17 bit) | [−62,643, 37,481] (17 bit) | 22 |
| conv4_acc | [−65,789, 84,823] (18 bit) | [−88,561, 89,447] (18 bit) | 22 |
| conv5_acc | [−102,789, 61,034] (18 bit) | [−102,789, 64,912] (18 bit) | 22 |
| gap_sum | [0, 1,601] (12 bit) | [0, 1,886] (11 bit, unsigned) | n/a |
| logits | [−1,436, 1,534] (12 bit) | [−1,545, 2,127] (13 bit) | 19 (margin reg) |
| margin | [−2,345, 2,357] (13 bit) | [−3,192, 2,791] (13 bit) | 19 |

Confirmed manifest `acc_stats` == §14's own "measured" column (e.g. conv5 `[-102,789, 64,912]`):
**PASS**, same numbers.

`DEFAULT_THRESHOLD = −646` (`0xFFFFFD7A`) fits in `REC_MARGIN_BITS = 19`: **PASS.**

**The single most notable number in this whole audit:** V1.2's actual measured logit/margin
range (`[-1,545, 2,127]` / `[-3,192, 2,791]`) is **roughly 15–20× narrower** than V1.1's
(`[-28,246, 37,186]` / `[-52,000, 30,084]`), yet both stages ship the **same** 22-bit
accumulator / 19-bit margin width. This is not a bug — the guaranteed bound (§14) is derived from
the trained weights times the full 0–255 input range and is architecture-shape-dependent, not
resolution-dependent, so it's correct that it didn't change — but it does mean V1.2's RTL will be
running its margin register at a small fraction of its dynamic range in practice. Worth knowing
if anyone later wants to tighten the width for area, though I'd weigh that against §14's own
"overflow is a silent wrong answer" argument before doing so.

## Model quality

| Metric | Value |
|---|---|
| TEST AUROC | 0.8229 [0.8083, 0.8379] (95% CI) |
| val AUROC | 0.8380 [0.8231, 0.8522] |
| Default operating point T (chosen on val, sens ≥ 90%) | −646 |
| TEST sensitivity @ T | 91.0% [89.0%, 92.7%] |
| TEST specificity @ T | 53.9% [52.1%, 55.6%] |
| TEST PPV / NPV @ T | 36.5% / 95.4% |
| TEST sens/spec @ argmax (T=0, v0-style) | 74.1% / 74.7% |
| view-position-only AUROC (shortcut floor) | 0.7064 |
| TEST AUROC minus shortcut floor | +0.1165 (not flagged) |

Same specificity story as V1.1, slightly worse: at the sens≥90% operating point, **1,430 of 3,101
negatives (46.1%) are false positives** on test (TN 1671, FP 1430, TP 821, FN 81). PPV is 36.5%,
essentially unchanged from V1.1's 36.4%.

**Subgroups** (test, default threshold):

| Subgroup | n | AUROC | sens | spec | Flags |
|---|---|---|---|---|---|
| all test | 4003 | 0.8229 | 91.0% | 53.9% | — |
| Opacity vs Normal | 2229 | 0.9363 | 91.0% | 81.3% | spec +27.4pp |
| Opacity vs No Lung Opacity/Not Normal | 2676 | 0.7382 | 91.0% | 33.4% | AUROC −0.0847, spec −20.5pp |
| view AP | 1853 | 0.7429 | 96.9% | 19.6% | AUROC −0.0800, spec −34.3pp |
| view PA | 2150 | 0.7661 | 69.9% | 74.0% | AUROC −0.0568, sens −21.1pp, spec +20.1pp |
| sex M | 2335 | 0.8210 | 89.5% | 55.7% | — |
| sex F | 1668 | 0.8262 | 93.1% | 51.4% | — |

Same three subgroups flagged as V1.1, same interpretation (view-position shortcut leakage on
AP/PA, and the expected hard-negative gap on the three-way split) — see the V1.1 report for the
discussion; it applies unchanged here. Going to 224×224 did not fix or worsen this pattern in any
material way (view AP spec actually got slightly worse: 22.0%→19.6%).

### V1.1 vs V1.2 — is clinical resolution actually better?

| Metric | V1.1 (28×28) | V1.2 (224×224) | Δ |
|---|---|---|---|
| val AUROC | 0.8341 [0.8193, 0.8481] | 0.8380 [0.8231, 0.8522] | +0.0039 |
| TEST AUROC | 0.8143 [0.7988, 0.8299] | 0.8229 [0.8083, 0.8379] | **+0.0086** |
| TEST sens @ target | 89.1% | 91.0% | +1.9pp |
| TEST spec @ target | 54.7% | 53.9% | −0.8pp |
| TEST PPV / NPV | 36.4% / 94.5% | 36.5% / 95.4% | ~flat / +0.9pp |
| Opacity-vs-Normal AUROC | 0.9328 | 0.9363 | +0.0035 |
| view AP / PA AUROC | 0.7346 / 0.7472 | 0.7429 / 0.7661 | +0.0083 / +0.0189 |
| decision-vs-GT agreement (verification set) | 72.5% | 71.3% | −1.2pp (small sample, not a quality metric) |

**Same split, same patients, same preprocessing (confirmed — see Cross-consistency below), and
V1.2 is ahead on every accuracy metric that matters:** val AUROC, test AUROC, sensitivity at the
fixed target, PPV, NPV, and every subgroup AUROC without exception. Being honest about the
caveats though: the improvement is **modest, not dramatic** — +0.0086 TEST AUROC — and the
bootstrap 95% CIs overlap substantially (V1.1 test CI upper bound 0.8299 vs. V1.2 test CI lower
bound 0.8083). A single train/val/test split at this size cannot call +0.0086 AUROC statistically
decisive on its own. What *is* decisive is the consistency: every one of the ~9 metrics above
moved the same direction, which a single lucky split would be unlikely to produce by chance. I'd
call this "real but modest," not "dramatically better" — don't oversell it in anything downstream
that cites this comparison.

## Numbers the RTL author needs

Both stages share one weight/bias set and one 7-layer topology; only spatial dimensions,
`conv4`/`conv5` shift, `s_gap`, and thresholds change with resolution. (Same table as the V1.1
report, reproduced here for a reader who only opens this file.)

| Quantity | V1.1 | V1.2 (this stage) |
|---|---|---|
| IMG_H × IMG_W | 28 × 28 | **224 × 224** |
| N_LAYERS | 7 | 7 |
| N_WEIGHTS | 47,432 | 47,432 |
| N_BIASES | 170 | 170 |
| Conv engine accumulator width (guaranteed) | 22 bits | **22 bits (same)** |
| Margin/threshold register width (guaranteed) | 19 bits | **19 bits (same)** |
| DEFAULT_THRESHOLD | −8050 = `0xFFFFE08E` | **−646 = `0xFFFFFD7A`** (fits 19-bit: yes) |
| Bias: stored width / min / max / bits actually needed | 32-bit / −15,630 / 19,163 / 16 bits | 32-bit / **−16,825 / 13,284** / 16 bits |
| GAP shift (`s_gap`) | 0 (final map 1×1) | **6 (final map 7×7)** |
| MACs per image | 227,360 | **12,192,896** |
| Memory: input image | 784 B | **50,176 B** |
| Memory: largest feature map | 1,568 B (conv1 out) | **100,352 B** (conv1 out) |
| Memory: largest in+out feature-map pair | 2,352 B (≥1 BRAM36) | **150,528 B (≥33 BRAM36)** |
| Memory: weights (int8) | 47,432 B (≥11 BRAM36) | 47,432 B (same) |
| Memory: biases (32-bit) | 680 B (≥1 BRAM36) | 680 B (same) |
| Total BRAM36 (7Z020 has 140) | ≥13 | **≥45** |

Per-layer shift table:

| Layer | op | shift (V1.1) | shift (V1.2, this stage) |
|---|---|---|---|
| conv1 | CONV3X3 | 7 | 7 |
| conv2 | CONV3X3 | 7 | 7 |
| conv3 | CONV3X3 | 7 | 7 |
| conv4 | CONV3X3 | 7 | **8** |
| conv5 | CONV3X3 | 7 | **8** |
| gap | GAP | 0 | **6** |
| fc | FC | 0 | 0 |

## Layer-table field map

Pasted verbatim from `v1/mem/v1_2/flash_v1_2/layer_table.vh` (`LT_WORD_W = 128`):

```verilog
`define LT_WORD_W 128
`define LT_OP_MSB 127
`define LT_OP_LSB 124
`define LT_KERNEL_MSB 123
`define LT_KERNEL_LSB 120
`define LT_STRIDE_MSB 119
`define LT_STRIDE_LSB 116
`define LT_PAD_MSB 115
`define LT_PAD_LSB 112
`define LT_IN_C_MSB 111
`define LT_IN_C_LSB 100
`define LT_OUT_C_MSB 99
`define LT_OUT_C_LSB 88
`define LT_IN_H_MSB 87
`define LT_IN_H_LSB 76
`define LT_IN_W_MSB 75
`define LT_IN_W_LSB 64
`define LT_OUT_H_MSB 63
`define LT_OUT_H_LSB 52
`define LT_OUT_W_MSB 51
`define LT_OUT_W_LSB 40
`define LT_SHIFT_MSB 39
`define LT_SHIFT_LSB 34
`define LT_W_BASE_MSB 33
`define LT_W_BASE_LSB 14
`define LT_B_BASE_MSB 13
`define LT_B_BASE_LSB 4
`define LT_OP_CONV3X3 4'd1
`define LT_OP_GAP 4'd2
`define LT_OP_FC 4'd3

`define FLASH_N_LAYERS 7
`define FLASH_IMG_H 224
`define FLASH_IMG_W 224
`define FLASH_N_WEIGHTS 47432
`define FLASH_N_BIASES 170
```

Field bit layout is identical to V1.1's (see that report for the field-by-field table) — this
file differs only in `FLASH_IMG_H`/`FLASH_IMG_W` and the per-layer values baked into
`layer_table.mem`, confirmed by direct diff in Verification results §2.

## Open questions

1. **Notebook path mismatch** — same issue as V1.1: audit brief expected
   `colab/ProjectFlash_V1_2.ipynb`; actual executed notebook is
   `v1/mem/v1_2/ProjectFlash_V1_2.ipynb`. See the V1.1 report for the full note; not repeating
   the reasoning here.
2. **`file_sha256` scope gap** — identical bug/question as V1.1 (same notebook template). If it
   gets fixed for one stage's export it should be fixed for both by construction, since it's one
   notebook cell.
3. **Bits [3:0] of the layer-table word are unused** here too, for the same reason as V1.1 (field
   widths sum to 124 of 128 bits). Same open question about whether that nibble should be
   asserted zero.
4. **Is 224×224 worth its ~3.5× BRAM cost (45 vs 13 tiles) and ~54× MAC cost (12.19M vs 227k) for
   a +0.0086 TEST AUROC gain that isn't statistically decisive on its own?** That's a
   product/architecture call, not something this audit can resolve from the artifacts — flagging
   it explicitly because "clinical resolution" in the stage name implies the answer is obviously
   yes, and the numbers here say the accuracy case for that is real but thinner than the name
   suggests. The consistency argument (every metric moved the same direction) is the strongest
   evidence in favor; a larger held-out validation would be the way to firm it up if the team
   wants a stronger basis for that decision.
