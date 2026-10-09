# Project FLASH — V1.2.1 board verification: results and close-out

**For Claude Code.** The board run of 2026-10-09 succeeded. This file holds the
verified numbers and the tasks to close V1. The rules are unchanged:
- Repo `C:\KarDRIVE\Projects\ProjectFlash`, branch `main`.
- Commit author `Karthik-Flash`, **no Co-Authored-By trailer**, no force-push.
- **Every number below was measured on the board or derived from the board CSVs.**
  Re-derive each one from the files before you write it. If anything differs
  from this file, stop and report it; do not "fix" it.

---

## Task 0 — Organise the evidence (move first, delete only duplicates)

The board session files are currently loose in the repo root. Do this:

1. `git mv` or move the following into **`docs/board_runs/2026-10-09/`**:
   - `run1_hp64.ipynb`, `run2_hp32.ipynb`, `run3_hp32_afiforce.ipynb`
   - `results_flash_hp64.csv`, `results_flash_hp32.csv`, `results_flash_hp32_afiforce.csv`
   - `summary_flash_hp64.json`, `summary_flash_hp32.json`, `summary_flash_hp32_afiforce.json`
2. Move these into **`docs/board_runs/2026-10-08/`**; they belong to yesterday's session:
   - `diag_2.json`
   - `Untitled.ipynb`, renamed to `smoke_test_and_unzip.ipynb`. It is the
     2026-10-08 unzip plus smoke test: PYNQ 3.1.1, `flash.bit`, FCLK0 66.666667,
     VERSION 0xf1a50102, `C_SG_LENGTH_WIDTH` 26.
3. Add a short `README.md` in each `docs/board_runs/<date>/` folder that lists
   every file and what it is.
4. **Duplicates.** `v1/board/flash.bit/.hwh` is meant to be byte-identical to
   `v1/board/flash_hp32.bit/.hwh`.
   - Verify this with SHA-256.
   - Only if they are identical: `git rm` `flash.bit` and `flash.hwh`, and update
     every doc or script that still points at `v1/board/flash.bit`
     (grep the repo).
   - Record the removal in `V1_CHANGELOG.md`.
5. **Delete nothing else.** If you think other files are unwanted (scratch dirs,
   `NA/`, old logs), list them with a one-line reason each and ask me first.
   `board_bundle/` and `board_bundle.zip` are gitignored; leave them.
6. Verify, and report the results:
   - `results_flash_hp64.csv` and `results_flash_hp32_afiforce.csv` have
     identical board columns.
   - `results_flash_hp32.csv` board values equal, image by image, the MISMATCH
     lines of `docs/board_runs/2026-10-08/flash_v1_2_board.ipynb`. This shows
     the corrupted result reproduced across days and reboots.

---

## Task 1 — Write `docs/V1_board_results_v1_2.md` (the V1 hardware result)

Use the structure below and the verified facts in it. Write it in plain,
precise prose, with tables where they help. Mark derived values as derived.

### 1. Summary (put this first)

The V1.2.1 bitstream runs the full 224×224 pneumonia CNN on the PYNQ-Z2
fabric. It is **bit-exact to the NumPy golden model on all 244 verification
images**: logit0, logit1, margin and decision are 244/244 each.

A board-only integration bug caused 0/244 bit-exact on 2026-10-08. It was
localised offline with the golden model and fixed in the block design (RTL
unchanged). On 2026-10-09 its root cause was **confirmed by intervention on
the board**.

### 2. Setup

| Item | Value |
|---|---|
| Board | TUL PYNQ-Z2, xc7z020clg400-1 |
| Image | PYNQ **3.1.1** (README said 3.0.1; fix the README) |
| Date | 2026-10-09. The board has no RTC or NTP, so the JSON `date` fields read 2025-05-04 09:28–09:45. Use the real date in the doc and note why the JSON dates differ. |
| FCLK0 | 66.666667 MHz read back by PYNQ (Vivado actual 66.666672 MHz, IO PLL 1000/15) |
| Main bitstream | `flash_hp64.bit` SHA-256 prefix `0ee58d6c924cd162`, `.hwh` `7011237c69968c86` (V1.2.1: HP0 64-bit, DMA MM2S memory side 64-bit, stream 32-bit) |
| Confirmation bitstream | `flash_hp32.bit` `396a219b10690f26`, `.hwh` `5f8c18af7bdf3650` (V1.2: HP0 32-bit) |
| Timing (V1.2.1, post-route) | WNS +0.314 ns, WHS +0.030 ns, 0 failing of 15,451 endpoints |
| Utilisation (V1.2.1) | LUT 3,864 · FF 4,766 · RAMB36 81 + RAMB18 2 · DSP 14 (take % and details from `docs/V1_impl_*_hp64.rpt`) |
| Interface | AXI DMA simple mode → AXI4-Stream 32-bit (4 px/beat) into `top_v1_axi`; AXI-Lite registers; polling (no interrupt controller) |

### 3. Bit-exact verification — three runs on one boot

| Run | Bitstream | AFI RDCHAN_CTRL bit 0 | `.hwh` HP0 | AFI check | Bit-exact | logit0 / logit1 / margin / decision | TP / FN / TN / FP |
|---|---|---|---|---|---|---|---|
| 1 | flash_hp64 | 0 (64-bit, as booted) | 64 | OK | **244/244** | 244 / 244 / 244 / 244 | 117 / 5 / 57 / 65 |
| 2 | flash_hp32 | 0 (as booted) | 32 | MISMATCH | **0/244** | 0 / 0 / 2 / 234 | 118 / 4 / 56 / 66 |
| 3 | flash_hp32 + AFI_FORCE (bit 0: 0→1) | 1 | 32 | MISMATCH at load, then forced | **244/244** | 244 / 244 / 244 / 244 | 117 / 5 / 57 / 65 |

Other facts from all three runs:
- CYCLES = 12,196,126 on every image. VERSION 0xF1A50102.
- STATUS.err never set.
- Image 0 gives (−82, −75, 7, 1) when correct, and (−119, 6, 125, 1) when corrupted.
- The threshold demo works: image 0 at threshold 0x7FFFFFFF gives the same margin with decision 0.

### 4. Root cause of the 2026-10-08 failure (link `docs/V1_board_debug_log.md`)

- **Symptom.** 0/244 bit-exact, yet board and expected logits correlate at
  0.98, and 234/244 decisions agree. Deterministic. Unchanged at
  25/50/66.67 MHz. No state carried between runs. The DMA showed no errors.
- **Model.** `board == golden(dup_even(x))`: every odd 32-bit input word is
  replaced by the even word before it. This matched 244/244 images and 24/24
  probes. It also correctly predicted two probes before they were checked:
  px(1,0) → (−349, 102, 451) and px(223,223) → the const-0 result.
- **Mechanism.** The design had a 32-bit HP0 port, but PYNQ leaves the HP0
  AFI in 64-bit mode (RDCHAN_CTRL bit 0 = 0). PYNQ does not run the design's
  `ps7_init`. Each 32-bit read therefore returned the low half of a 64-bit word.
- **Confirmation (2026-10-09).** With the same 32-bit bitstream on the same
  boot, flipping one PS register bit took the result from 0/244 to 244/244
  (runs 2 and 3).
- **Fix (V1.2.1).** HP0 and the DMA memory side are 64-bit, matching PYNQ's
  default. This needed no runtime register write, and gave 244/244 (run 1).
  An AXI4→AXI3 protocol converter (`auto_pc`) was inserted. The accelerator
  netlist is unchanged: its INIT contents are identical, as verified.
- **Why simulation missed it.** `tb_v1_axi` drives AXI-Stream directly; the
  PS, AFI and DDR are not modelled. Lesson for V2: either model the memory
  path in simulation, or keep the AFI-vs-`.hwh` check in every board notebook.
  (That check is now in the notebook.)
- **Why the corrupted result looked plausible.** Duplicating 4-pixel groups
  acts like a horizontal blur, and the GAP CNN is robust to it. Decision-level
  agreement (234/244) would have hidden the bug. **Only logit-level bit-exact
  comparison caught it.**

### 5. Latency and throughput (run 1)

| Metric | Value | Source |
|---|---|---|
| Compute latency | 182.94 ms/image (12,196,126 cycles @ 66.666667 MHz), 5.47 img/s | CYCLES register |
| End to end, images pre-loaded | **184.73 ms/image, 5.41 img/s** | 244 back-to-back `run()` calls, `perf_counter` |
| Host overhead (copy, cache flush, registers, DMA, polling) | 1.79 ms/image (≈1%) | derived |
| Sweep wall time incl. `.mem` text parsing | 153.8 s (630 ms/image) | dominated by Python parsing, not the accelerator |

Runs 2 and 3 give 184.71 and 184.70 ms/image; the result is repeatable to 0.03 ms.

### 6. ARM Cortex-A9 baseline (same golden model, NumPy int64, on the board's PS)

| Run | ARM ms (image 0) | Model load |
|---|---|---|
| 1 | 743.9 | 0.20 s |
| 2 | 726.3 | 0.19 s |
| 3 | 665.1 | 0.19 s |

- Every ARM result equals exp_*[0], so the ARM and the FPGA produce **the same integers**.
- FPGA compute is **3.6–4.1× faster** than the ARM (665–744 ms vs 182.9 ms). This is derived.
- Be honest about what this baseline is. It is one image, one timed run per
  session, unoptimised NumPy int64 on a single core. A NEON int8
  implementation would be faster.
- For context, the same golden model takes 8.9 ms/image on the desktop PC
  (measured by Claude Code; state the CPU if known). The V1 engine does
  1 MAC/cycle by design, so the PC is faster. V1 proves a bit-exact integer
  pipeline; parallel MACs are V2 (14/220 DSPs are used).

### 7. Classification on the 244 verification images (held-out test images)

These are board-measured values. They are identical to the golden model by construction.

- **Confusion matrix** at T = −646 (the decision rule `margin > T`; there are
  no ties at T, so `>=` gives the same result):

|  | Predicted pneumonia | Predicted normal |
|---|---|---|
| **Pneumonia (122)** | TP 117 | FN 5 |
| **Normal (122)** | FP 65 | TN 57 |

- Sensitivity **0.959** (Wilson 95% CI 0.908–0.982).
- Specificity **0.467** (0.381–0.555).
- PPV 0.643, NPV 0.919, accuracy 0.713 (174/244).
- **AUROC on the 244 from board margins: 0.837** (bootstrap 95% CI
  0.785–0.885, 2000 resamples, seed 0). It is consistent with the
  notebook's full-test-set AUROC of 0.8229. **The headline accuracy metric
  stays 0.8229 with its CI.** The 244 are a seeded, balanced subset.
- **The errors are dominated by false positives: 65 FP vs 5 FN.** This is the
  chosen operating point, not a hardware effect. T = −646 was picked on
  *validation* data to reach ≥ 90% sensitivity (a screening point).
- **The false negatives are near-misses.** Their margins are −736, −719, −712,
  −712 and −670, all within about 90 of T.
- **The false positives are broad.** Margin quartiles are −639 / −318 / 0 /
  +593, with a maximum of +1928. Median margin is +792.5 for positives and
  −595.5 for negatives, so more than half the normal images lie above T.
- **Overfitting.** This data shows no evidence of it. The 244 are held-out
  test images, and their AUROC matches the test-set figure. The limitations
  are model discrimination (AUROC ≈ 0.82–0.84) and a sensitivity-heavy
  threshold. A real overfitting check needs train-vs-validation curves from
  the Colab notebook; cite those if they exist, otherwise don't claim either way.
- **Threshold trade-off, illustrative only.** This table is computed on test
  images, so it must **not** be used to choose a threshold. Any new
  threshold has to come from validation data.

| T | Sensitivity | Specificity |
|---|---|---|
| −646 | 0.959 | 0.467 |
| −400 | 0.885 | 0.566 |
| −200 | 0.852 | 0.656 |
| 0 | 0.779 | 0.738 |
| +200 | 0.713 | 0.787 |

- **Hypothesis to test in V2 (unverified).** In RSNA, label 0 combines
  "Normal" and "No Lung Opacity / Not Normal". The high-margin false positives
  may be abnormal-but-not-pneumonia studies. Check this against
  `stage_2_detailed_class_info.csv` before writing anything about it.

### 8. Power

The only figure is Vivado's estimate (V1.2.1): **1.494 W** total, of which
PS7 is about 1.256 W. It is an estimate, not a board measurement. Say so,
and list a board measurement (inline USB meter) or a SAIF-based estimate as
future work.

### 9. Limitations (state them plainly)

- 66.67 MHz rather than 75 MHz. The conv_engine address path is the
  critical path; this is a V2 pipeline item.
- 1 MAC/cycle, so 183 ms/image.
- The sensitivity and specificity come from 244 images. AUROC 0.82 is
  research-grade, not clinical.
- The DICOM → board path has not yet been run end to end on the board.
- Not a medical device.

### 10. Reproduce

`v1/board/README.md` lab order. Bundle `board_bundle.zip` (260 files),
notebook generated by `v1/board/make_notebook.py`.

### 11. Evidence index

List every file in `docs/board_runs/2026-10-08/` and `2026-10-09/`, with its
SHA-256 prefix.

---

## Task 2 — Update the other docs

- **`docs/V1_board_debug_log.md`:** add a "Resolved" section. Root cause
  confirmed by intervention on 2026-10-09, with runs 2 and 3, the fix, and
  the run 1 result.
- **`docs/BRINGUP_STATUS.md`:** set status to complete. Board-verified V1.2.1
  is the current hardware. Link the results doc.
- **`docs/V1_CHANGELOG.md`:** add a V1.2.1 entry covering the HP0/DMA 64-bit
  change, `auto_pc`, the new SHAs, the timing, the notebook additions
  (AFI check, AFI_FORCE, evidence files, throughput, ARM baseline), the
  generator script, and the removed duplicate `flash.bit`.
- **`docs/PROJECT_NARRATIVE.md`:** add the board-verification chapter:
  - 66.67 MHz rationale;
  - the AFI bug story (symptom → offline model → predicted probes →
    intervention → fix), which is the strongest methodological point for a paper;
  - latency and throughput, the ARM comparison, the power estimate;
  - the sensitivity/specificity trade-off.

  Keep its revision note. No overclaims: "bit-exact on 244 images" and
  "research prototype".
- **`v1/board/README.md`:** state that it was tested on PYNQ 3.1.1.

## Task 3 — Tag

When Tasks 0–2 are committed and pushed: create the annotated tag
**`v1.2.1-hw`** on that commit, with message "V1.2.1: 244/244 bit-exact on
PYNQ-Z2 (2026-10-09)", and run `git push origin v1.2.1-hw`. Report the
commit hash.

---

## Task 4 — Prepare the next board session: live demo notebook (no rebuild)

The goal is a credible, visual demo. Real X-rays are classified on the FPGA
live, side by side with the ARM, including the model's mistakes.

Write a generator `v1/board/make_demo_notebook.py` that produces
`v1/board/flash_v1_2_demo.ipynb`, and add the notebook to the bundle. Cells:

1. **Disclaimer (markdown).** Research prototype, not a medical device, no
   clinical use.
2. **Load.** Load `flash_hp64.bit`. Print the SHA. Run the AFI check and
   **assert OK**. Check VERSION and FCLK0.
3. **Pick six images from `results_flash_hp64.csv` logic** (deterministic,
   read from the `.mem` files): 2 TP, 2 TN, 1 FP and 1 FN, with their indices
   printed. Showing the errors is deliberate.
4. **For each image:**
   - Show it with `matplotlib` (gray, 224×224).
   - Time one FPGA `run()` with `perf_counter`.
   - Show logit0, logit1, margin and decision next to the golden expected
     values, the ground-truth label, and a "bit-exact" tick.
   - Lay it out as a 2×3 figure with a caption per image, plus a table.
5. **The same six images on the ARM** with the golden model. Show per-image
   time and an assert that the results equal the FPGA output. Print the
   speedup.
6. **Interactive (optional).** If `ipywidgets` imports, add an index
   slider (0–243) that runs one image live and redraws. Otherwise fall back
   to an `IDX = …` cell.
7. **Raw DICOM end to end (stretch, optional cell, off by default).**
   - First check whether the Colab export records which RSNA patientId each
     verification image came from. If it does, document how to bring 2–3
     matching DICOMs and a `pydicom` wheel for offline
     `pip install pydicom-*.whl`; the board has no internet.
   - Also check whether `flash_preprocess.py` needs OpenCV, and whether
     PYNQ 3.1.1 has `cv2`.
   - The cell: preprocess on the ARM, run on the FPGA, and assert the
     result equals `exp_*` for that index.
   - Report feasibility; don't fake it.
8. `buf.freebuffer()`.

Mock-test the demo on the PC as before, using a fake pynq backed by the
golden model. Then rebuild the bundle and zip, and update the README with a
"Demo" section. Commit and push. **No RTL or block-design change; the
bitstream is still `flash_hp64`.**

---

## Report back

Report the following:
1. Task 0 moves, the duplicate check, and the list of candidate deletions
   (not deleted).
2. Every number in the results doc that didn't match this file (expected:
   none).
3. Commit hashes and the tag hash.
4. Demo notebook status, plus DICOM end-to-end feasibility.
