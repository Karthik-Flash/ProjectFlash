# Project FLASH — V1.1 post-run audit (28×28, real RSNA)

Audited artifact: `v1/mem/v1_1/flash_v1_1/`
Executed notebook: `v1/mem/v1_1/ProjectFlash_V1_1.ipynb` (43 cells; the task brief expected
`colab/ProjectFlash_V1_1.ipynb` — see **Open questions**).
Audit branch: `audit/v1-post-run`. All numbers below were independently recomputed from the
exported files with a standalone script (stdlib + numpy + nbformat only); none are copy-pasted
from the notebook without being reproduced first, except where explicitly marked "notebook
output" for cross-reference.

No genuine defect was found. Every correctness check (file format, layer-table decode, golden
model vs. exported vectors, trace files, decision/argmax logic) is bit-exact. One real gap was
found in the **provenance tooling**, not the data: `manifest.json`'s `file_sha256` map covers only
3 of 313 `.mem` files. It is reported first because it's the only thing here that a future export
run could silently get wrong without anyone noticing.

## Verification results

### 1. File integrity

| Check | Result |
|---|---|
| `manifest.file_sha256` coverage | **FAIL (scope gap)** — only 3/313 `.mem` files hashed: `bias.mem`, `layer_table.mem`, `weights.mem`. All 244 `vectors/img_*.mem`, the 6 `exp_*.mem`/`gt_label.mem` files, and all 60 `vectors/trace/*.mem` files have **no recorded hash**. |
| SHA-256 of the 3 covered files | PASS — 3/3 match `manifest.json` |
| `weights.mem` line format (2 hex chars/line) | PASS — 47,432/47,432 lines well-formed |
| `bias.mem` line format (8 hex chars/line) | PASS — 170/170 lines well-formed |
| `vectors/img_*.mem` line counts (== 784 = 28×28) | PASS — 244/244 files, 0 bad |

**Reproducer / root cause for the FAIL:** `ProjectFlash_V1.ipynb` cell 42 builds the hash map as

```python
file_sha256={str(p.relative_to(EXPORT)): sha(p) for p in sorted(EXPORT.glob('*.mem'))}
```

`Path.glob('*.mem')` is **not recursive** — it only matches files directly inside `EXPORT`
(`weights.mem`, `bias.mem`, `layer_table.mem`), never anything under `EXPORT/vectors/` or
`EXPORT/vectors/trace/`. Section 16's own prose claims "a SHA-256 of every exported memory
file," which is false as written. This does not invalidate anything below — I independently
recomputed every vector and trace file from the golden model and they are bit-exact (see §3) —
but it means nobody re-running this notebook would notice if a vector file were corrupted or
regenerated inconsistently, since the manifest wouldn't catch it. Fix for the next notebook
revision: `EXPORT.rglob('*.mem')`.

### 2. Layer table decoding

Decoded all 7 records from `layer_table.mem` (128-bit words) using the `LT_*_MSB`/`LT_*_LSB`
fields parsed out of `layer_table.vh`, and compared every field against `layer_table.json`.

| Check | Result |
|---|---|
| `LT_WORD_W` vs actual hex-line length | PASS — 128 bits = 32 hex chars, all 7 lines |
| Field-by-field decode vs `layer_table.json` (op, kernel, stride, pad, in_c, out_c, in_h, in_w, out_h, out_w, shift, w_base, b_base) | PASS — 0 mismatches across 7 records × 13 fields |
| `w_base[i] + n_w[i] == w_base[i+1]` (conv layers + fc) | PASS |
| `b_base[i] + n_b[i] == b_base[i+1]` (conv layers + fc) | PASS |
| `FLASH_N_WEIGHTS` (47432) == `len(weights.mem)` | PASS |
| `FLASH_N_BIASES` (170) == `len(bias.mem)` | PASS |

### 3. Golden model round-trip

Loaded `tools/golden_model_v1.py` fresh (not the notebook's in-memory copy), read all 244
`vectors/img_*.mem`, ran `GoldenModel(export_dir).run(...)`, and compared against the exported
vectors.

| Check | Result |
|---|---|
| `exp_logit0.mem` | PASS — 244/244 exact |
| `exp_logit1.mem` | PASS — 244/244 exact |
| `exp_margin.mem` (recomputed as `logit1 - logit0`) | PASS — 244/244 exact |
| `exp_argmax.mem` (recomputed as `logit1 > logit0`) | PASS — 244/244 exact |
| `exp_decision.mem` (recomputed as `margin > DEFAULT_THRESHOLD`, T = −8050 from `sim_config.vh`) | PASS — 244/244 exact |
| decision vs. `gt_label.mem` | 177/244 (72.5%) agree — **not a verification check**, just confirms the vector file matches the notebook's own printed figure ("golden decision... agrees with ground truth on 177/244 (72.5%)"), which it does. |
| Trace reproduction: `img{0..7}_conv{1..5}.mem`, `img{0..7}_gap.mem` (uint8) | PASS — 48/48 files, 0 byte mismatches |
| Trace reproduction: `img{0,1}_conv{1..5}_acc.mem`, `img{0,1}_gap_sum_acc.mem` (int32) | PASS — 12/12 files, 0 mismatches |

**0 mismatches anywhere.** This matches (independently, not by trusting it) the notebook's own
CHECK 1 / CHECK 2 in §12, which report 0 mismatches against the **training-framework** float64
PyTorch model. My check is a different, complementary one: it runs the **exported** golden model
standalone against the **exported** vector files, with no PyTorch involved at all — so it
verifies the export pipeline (hex encoding, two's-complement, base offsets) rather than the
arithmetic contract.

### 4. Arithmetic range sanity

Recomputed accumulator min/max by re-running the golden model with `acc_stats=` over the 244
verification vectors, and separately read `manifest.json`'s `acc_stats` (computed by the notebook
over the full val+test = 8,006 images). These are **two different populations by design** — the
244-image set is a small balanced verification slice, not a statistical sample — so narrower
recomputed ranges are expected, not a defect:

| Signal | Recomputed (244 vectors) | Manifest `acc_stats` (8,006 val+test imgs) | Manifest bits stored |
|---|---|---|---|
| conv1_acc | [−27,513, 23,118] (16 bit) | [−28,154, 27,889] (16 bit, §14 "measured") | 22 (guaranteed) |
| conv2_acc | [−30,708, 20,282] (16 bit) | [−36,087, 24,363] (17 bit) | 22 |
| conv3_acc | [−40,574, 28,018] (17 bit) | [−40,574, 29,781] (17 bit) | 22 |
| conv4_acc | [−66,602, 57,588] (18 bit) | [−71,549, 57,588] (18 bit) | 22 |
| conv5_acc | [−59,476, 50,072] (17 bit) | [−66,060, 65,592] (18 bit) | 22 |
| gap_sum | [0, 255] (9 bit) | [0, 255] (9 bit, unsigned) | n/a |
| logits | [−19,700, 26,662] (16 bit) | [−28,246, 37,186] (17 bit) | 19 (margin reg) |
| margin | [−28,698, 24,848] (16 bit) | [−52,000, 30,084] (17 bit) | 19 |

I independently confirmed the manifest's `acc_stats` column above matches §14's own "measured"
column verbatim (e.g. conv1 `[-28,154, 27,889]`) — **PASS**, they are the same numbers, computed
from the same dict in the same notebook run.

`DEFAULT_THRESHOLD = −8050` (0xFFFFE08E) fits in `REC_MARGIN_BITS = 19`: **PASS**
(range of a 19-bit signed register is [−262,144, 262,143]).

Worth noting for the RTL author, not a defect: `sim_config.vh` ships `REC_ACC_BITS=22` and
`REC_MARGIN_BITS=19`, which are the **guaranteed** bound from §14 (derived from the actual
trained weights times the full 0–255 input range), not the measured bound from either population
above. That's deliberately wider than anything actually observed — the right call for a medical
device per §14's own reasoning ("an accumulator overflow is a silent wrong answer").

## Model quality

*(golden-model integer margins on the RSNA test split, 4,003 patients, from `manifest.json`;
not sugar-coated.)*

| Metric | Value |
|---|---|
| TEST AUROC | 0.8143 [0.7988, 0.8299] (95% CI) |
| val AUROC | 0.8341 [0.8193, 0.8481] |
| Default operating point T (chosen on val, sens ≥ 90%) | −8050 |
| TEST sensitivity @ T | 89.1% [86.9%, 91.0%] |
| TEST specificity @ T | 54.7% [52.9%, 56.4%] |
| TEST PPV / NPV @ T | 36.4% / 94.5% |
| TEST sens/spec @ argmax (T=0, v0-style) | 76.1% / 73.1% |
| view-position-only AUROC (shortcut floor) | 0.7064 |
| TEST AUROC minus shortcut floor | +0.1079 (rule of thumb: flag if <0.05 — **not flagged**) |

**Specificity at the chosen operating point is 54.7%.** At 22.5% test prevalence and T tuned to
90% sensitivity, this means roughly **1,405 of 3,101 negatives (45.3%) are false positives** at
the default threshold (confirmed against the notebook's own confusion counts: TP 804, FN 98, TN
1696, FP 1405). That is a real, not cosmetic, cost of the high-sensitivity operating point — PPV
is 36.4%. This is inherent to the screening-tool design choice (§13), not an export or arithmetic
defect, but it should not be read past without comment.

**Subgroups** (test, default threshold; flag rule: AUROC >0.05 below overall, or sens/spec >10pp
from overall):

| Subgroup | n | AUROC | sens | spec | Flags |
|---|---|---|---|---|---|
| all test | 4003 | 0.8143 | 89.1% | 54.7% | — |
| Opacity vs Normal | 2229 | 0.9328 | 89.1% | 82.4% | spec +27.7pp |
| Opacity vs No Lung Opacity/Not Normal | 2676 | 0.7257 | 89.1% | 34.0% | AUROC −0.0886, spec −20.7pp |
| view AP | 1853 | 0.7346 | 96.2% | 22.0% | AUROC −0.0797, spec −32.7pp |
| view PA | 2150 | 0.7472 | 63.8% | 73.9% | AUROC −0.0671, sens −25.3pp, spec +19.2pp |
| sex M | 2335 | 0.8099 | 88.2% | 55.9% | — |
| sex F | 1668 | 0.8209 | 90.4% | 53.0% | — |

Three subgroups are flagged, and none of them look like a bug — they read as the model leaning
partly on the AP/PA shortcut measured in §7 (AUROC(view alone) = 0.706), exactly as §13 warns to
check for:
- **view AP vs view PA** is the clearest evidence: AP-only AUROC (0.7346) and PA-only AUROC
  (0.7472) are both close to the view-only shortcut floor (0.7064) and far below the combined
  AUROC (0.8143). Specificity on AP is especially bad (22.0%) — the model is much worse at
  telling opacity from normal *within* a single view than the headline number suggests, because
  part of the headline number is coming from view mix.
- **"Opacity vs No Lung Opacity/Not Normal"** (0.7257) being the hard three-way split is expected
  and named as such in §13 — this is the model's real ceiling on the difficult negative class,
  not a defect.
- Sex subgroups show no meaningful gap.

**Same three subgroups are flagged for V1.2** with almost identical numbers (see
`V1_audit_v1_2.md`) — this looks like a property of the dataset/task (view position correlates
with prevalence: P(opacity|AP)=38.3% vs P(opacity|PA)=9.3%, per §7), not something resolution
fixes.

## Numbers the RTL author needs

Both stages share one weight/bias set and one 7-layer topology; only spatial dimensions,
`conv4`/`conv5` shift, `s_gap`, and thresholds change with resolution.

| Quantity | V1.1 (this stage) | V1.2 |
|---|---|---|
| IMG_H × IMG_W | 28 × 28 | 224 × 224 |
| N_LAYERS | 7 | 7 |
| N_WEIGHTS | 47,432 | 47,432 |
| N_BIASES | 170 | 170 |
| Conv engine accumulator width (guaranteed) | **22 bits**, signed | 22 bits (same) |
| Margin/threshold register width (guaranteed) | **19 bits**, signed | 19 bits (same) |
| DEFAULT_THRESHOLD | **−8050** = `0xFFFFE08E` (fits 19-bit: yes) | −646 = `0xFFFFFD7A` (fits: yes) |
| Bias: stored width / min / max / bits actually needed | 32-bit storage / −15,630 / 19,163 / **16 bits** | 32-bit storage / −16,825 / 13,284 / 16 bits |
| GAP shift (`s_gap`) | **0** (final map 1×1) | 6 (final map 7×7) |
| MACs per image | 227,360 | 12,192,896 |
| Memory: input image | 784 B | 50,176 B |
| Memory: largest feature map | 1,568 B (conv1 out) | 100,352 B (conv1 out) |
| Memory: largest in+out feature-map pair | 2,352 B (≥1 BRAM36) | 150,528 B (≥33 BRAM36) |
| Memory: weights (int8) | 47,432 B (≥11 BRAM36) | 47,432 B (same) |
| Memory: biases (32-bit) | 680 B (≥1 BRAM36) | 680 B (same) |
| Total BRAM36 (7Z020 has 140) | ≥13 | ≥45 |

Per-layer shift table (from `layer_table.vh`, decoded and confirmed against `layer_table.json`):

| Layer | op | shift (V1.1) | shift (V1.2) |
|---|---|---|---|
| conv1 | CONV3X3 | 7 | 7 |
| conv2 | CONV3X3 | 7 | 7 |
| conv3 | CONV3X3 | 7 | 7 |
| conv4 | CONV3X3 | 7 | **8** |
| conv5 | CONV3X3 | 7 | **8** |
| gap | GAP | 0 | **6** |
| fc | FC | 0 | 0 |

Note conv4/conv5 shift and `s_gap` are the two values that actually change between stages (besides
`w_base`/`b_base`, which are identical since weights are shared, and `in_h/in_w/out_h/out_w`,
which scale with resolution) — everything else in the layer table is stage-invariant.

## Layer-table field map

Pasted verbatim from `v1/mem/v1_1/flash_v1_1/layer_table.vh` (`LT_WORD_W = 128`):

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
`define FLASH_IMG_H 28
`define FLASH_IMG_W 28
`define FLASH_N_WEIGHTS 47432
`define FLASH_N_BIASES 170
```

| Field | Bits | Width | Extract as |
|---|---|---|---|
| op | [127:124] | 4 | `word[127:124]` — 1=CONV3X3, 2=GAP, 3=FC |
| kernel | [123:120] | 4 | `word[123:120]` |
| stride | [119:116] | 4 | `word[119:116]` |
| pad | [115:112] | 4 | `word[115:112]` |
| in_c | [111:100] | 12 | `word[111:100]` |
| out_c | [99:88] | 12 | `word[99:88]` |
| in_h | [87:76] | 12 | `word[87:76]` |
| in_w | [75:64] | 12 | `word[75:64]` |
| out_h | [63:52] | 12 | `word[63:52]` |
| out_w | [51:40] | 12 | `word[51:40]` |
| shift | [39:34] | 6 | `word[39:34]` |
| w_base | [33:14] | 20 | `word[33:14]` — index into `weights.mem` |
| b_base | [13:4] | 10 | `word[13:4]` — index into `bias.mem` |
| (unused) | [3:0] | 4 | reserved/padding to fill 128 bits |

Decoded and cross-checked against `layer_table.json` for all 7 records — 0 mismatches (see
Verification results §2). Bits [3:0] are unused padding — the field layout consumes bits
[127:4], leaving the low nibble unassigned; this was not called out in `layer_table.vh` itself
and is only visible from summing field widths (4+4+4+4+12+12+12+12+12+12+6+20+10 = 124 bits, word
is 128), so confirm with the RTL author whether that nibble is reserved for future use or simply
padding before relying on it being zero.

## Open questions

1. **Notebook path mismatch.** The audit brief expected `colab/ProjectFlash_V1_1.ipynb` and
   `colab/ProjectFlash_V1_2.ipynb`. The repository instead has a single template at
   `colab/ProjectFlash_V1.ipynb` (41 cells, unexecuted or differently-executed) plus the two
   **executed** notebooks actually used for grading here, at `v1/mem/v1_1/ProjectFlash_V1_1.ipynb`
   and `v1/mem/v1_2/ProjectFlash_V1_2.ipynb` (43 cells each, identical structure). I used the
   latter two, since they're the ones with real outputs and carry the actual export provenance,
   but I did not diff them against `colab/ProjectFlash_V1.ipynb` cell-by-cell to confirm it's the
   same source before or after these runs. If `colab/ProjectFlash_V1.ipynb` is meant to be the
   single canonical source going forward, worth confirming it matches what actually produced
   these exports.
2. **`file_sha256` scope gap** (see Verification results §1) — is the 3-file-only hash coverage
   intentional (only the files whose content the RTL directly instantiates need a checksum) or an
   oversight (`glob` vs `rglob`)? I can't tell intent from the artifacts; flagging for the
   notebook author either way, since the section-16 prose over-promises what it currently does.
3. **Bits [3:0] of the layer-table word are unused** (see field map above) — not asserted zero
   anywhere I found; worth an explicit `assert` or comment in the exporting notebook cell if they
   must stay zero for the RTL's word-read logic to be safe against future field additions.
4. `v1/mem/smoke_28/v1_1_smoke/` internally labels itself stage **"V1.1"** in its own
   `manifest.json`, despite living in a directory named `smoke_28` separate from
   `v1/mem/v1_0/flash_v1_0_smoke/` (labeled stage "V1.0"). Both are synthetic-data smoke exports
   with different metrics — not duplicates — but the naming makes it easy to grab the wrong one
   for a "V1.0 baseline" cross-check. Used here only to confirm the layer-table field map is
   stage-invariant (it is — see the diff in the companion V1.2 report).
5. `v1/rtl/` and `v1/sim/` exist but are empty — confirms RTL bring-up genuinely hasn't started,
   consistent with the audit's stated purpose.
