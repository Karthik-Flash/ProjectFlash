# Project FLASH — v0 baseline: closing summary

**Status: closed.** The 28×28 accelerator is arithmetically verified against a
bit-exact reference model across 244 test images. Phase 2 (RSNA, 224×224) starts
from this datapath.

---

## 1. What v0 was for

v0 is not a model milestone. It exists to answer one question: **does the RTL
compute what the trained network computes?** Five prior versions could not answer
that, because there was no reference to compare against and the testbench checked a
single decision bit on eight hand-selected images.

Everything below follows from replacing that with a golden model and a logit-level
comparison.

## 2. Defects found and fixed

All five were found by dumping intermediate tensors out of the simulator and
diffing them in Python, not by reading code.

### 2.1 `line_buffer.v` — 3×3 window misaligned (two faults)

The window's bottom-right tap read `row2[col_wr+1]`, a location not yet written for
the current row. It still held the previous row's pixel, so **every one of the 784
windows carried one corrupt tap**.

Separately the window was emitted centred on `(row_wr-1, col_wr)`. Streaming 784
pixels therefore produced centres for image rows −1 through 26: image row 27 was
never convolved, and an all-padding row was written into feature-map row 0. The
entire feature map was shifted up by one.

**Fix.** Padding is no longer synthesised from comparators. The caller streams a
30×30 zero-padded frame and the module became a plain valid-window generator — two
line stores, three column taps, `window_valid = (row>=2 && col>=2)`. Exactly 784
windows, bit-identical to `torch.nn.Conv2d(padding=1)`, no border special-cases, and
resolution becomes a single parameter.

### 2.2 `top_accelerator.v` — max-pool read pipeline off by two cycles

`fm_rd_addr` is a register *and* the BRAM output is a register, so address-to-data
is two cycles. The pool FSM captured after one. Consequences: the four values in
`pool_buffer` were shifted by one address, the fourth element of each 2×2 block was
never read at all, and `pool_result` was sampled in the same cycle `pool_buffer[3]`
was being written — so the comparator tree saw the *previous* window's value.

**Fix.** Explicit 8-state sequencer: issue the four addresses, capture with correct
latency, let the combinational `max_pool` settle, then write.

### 2.3 `fc_layer.v` — FC1 read pointer off by one

`READ_PREFETCH` issued address 1 and the first `COMPUTE` cycle re-issued address 1,
burning a slot. The input sequence became `pm[0], pm[1], pm[1], pm[2], …`, so
`pm[783]` was never read and `pm[1]` was multiplied by two different weights.

**Fix.** Removed the `input_value` staging register and made the invariant explicit
— `bram_rd_data == mem[input_idx]` every `COMPUTE` cycle — by issuing `input_idx + 2`
one cycle ahead. Also stopped `DONE_STATE` returning to `IDLE` while the FSM still
asserted `start`, which was silently re-triggering a full 12,544-cycle pass.

### 2.4 `tb_top.v` — two testbench faults masking the above

Stimulus was driven on `posedge`, the same edge the DUT samples. A race: the first
image after reset intermittently missed `start` entirely. All stimulus now moves on
`negedge`.

`cancer_flag` is registered *on* `output_valid`, so the decision pin settles one
clock after `result_valid` rises. The old testbench sampled immediately and was
reading the **previous image's decision**.

## 3. Architecture (unchanged from V3)

| Layer | Operation | In | Out |
|---|---|---|---|
| Conv2D + ReLU | 4 filters, 3×3, pad 1 | 1×28×28 | 4×28×28 |
| MaxPool2D | 2×2 stride 2, then `>> 8` | 4×28×28 | 4×14×14 |
| Flatten | channel-major | 4×14×14 | 784 |
| FC1 + ReLU | dense | 784 | 16 |
| FC2 | dense, logits | 16 | 2 |
| Argmax | `logit1 > logit0` | 2 | 1 bit |

12,634 INT8 parameters. Target `xc7z020clg400-1` (PYNQ-Z2).

**Input format changed.** The accelerator now consumes a 30×30 zero-padded frame
(900 bytes, raw uint8, row-major) rather than a bare 28×28 image.

## 4. Verification methodology

The change that mattered more than any individual fix.

| | V3 | v0 |
|---|---|---|
| Test images | 8, filtered to >20% logit margin | 244, balanced slice of the test set, no margin filter |
| Checked | `cancer_detected` bit | `logit0` and `logit1`, 32 bits each, exact |
| Reference | none | NumPy integer golden model |
| Reproducible | hand-built `.mem` files | generated end-to-end by one notebook |

The 244 images are the first 122 normal and first 122 pneumonia indices of the test
set, shuffled under a fixed seed. **The model classifies 46 of them incorrectly, and
that is deliberate.** The requirement is that the RTL reproduces the reference model
*including its mistakes*. A decision bit can be right by accident; a matching 32-bit
logit cannot.

## 5. Hardware results

```
bit-exact logits : 244 / 244
label agreement  : 244 / 244
*** RTL IS BIT-EXACT WITH THE GOLDEN MODEL ***
```

| Check | Result |
|---|---|
| Conv feature map vs golden | 0 mismatches / 3,136 |
| Pooled tensor vs golden | 0 mismatches / 784 |
| FC1 neuron outputs vs golden | 0 mismatches / 16 |
| Logits vs golden, 244 images | 244 / 244 exact |
| Conv accumulator range, full test set | [−41,632, 85,317] |
| 20-bit signed budget | [−524,288, 524,287] — **6.1× headroom** |
| Simulation wall clock (XSim, 244 images) | ~30 s |

The accumulator measurement is worth keeping: in V1 it was found by hand after a
silent wraparound. It is now measured automatically over the whole test set on every
notebook run.

## 6. Model results, stated honestly

| | Old V3 deck | v0 |
|---|---|---|
| Balanced accuracy | 95.4% | **84.7%** |
| Specificity (Normal) | 98.5% | 73.9% |
| Sensitivity (Pneumonia) | 91.5% | 95.4% |
| Reproduced by hardware | **no** | **yes, bit-exact** |

The 95.4% was a Python figure measured on a datapath that computed corrupted
feature maps. It was never achievable in hardware. 84.7% that the FPGA reproduces
exactly is the stronger claim, but it is a genuine regression in model quality and
should be presented as such.

### 6.1 A distribution gap between val and test

A longer training run (150 epochs vs 110) scored **96.7% balanced on validation** and
**82.1% on test** with the same weights. Specificity fell 29 points while sensitivity
moved less than one. That is not ordinary overfitting.

PneumoniaMNIST derives its validation split from the same collection as train, while
the test split is the originally held-out set. Selecting the best epoch on
validation therefore selects on the wrong distribution, and additional training
sharpens the fit to it. The shorter run generalised better.

**Carried into V1:** select the operating point on a split drawn from the same
distribution being reported, and split RSNA by `patientId`.

### 6.2 There is no threshold knob in hardware

Argmax is `logit1 > logit0`. Biases are INT8 while logits are order 10⁷, so the
operating point cannot be shifted after training. The sensitivity/specificity
balance has to be baked in at training time.

**Carried into V1:** design a programmable rescale or comparison offset into the
argmax stage so the operating point is tunable without retraining.

## 7. Repository

```
colab/FLASH_v0_train_export_verify.ipynb   trains in INT8 space, exports .mem, emits vectors
v0_baseline/rtl/                           7 Verilog modules
v0_baseline/sim/tb_top.v                   N-image bit-exactness sweep
v0_baseline/sim/vivado_setup.tcl           wires an existing Vivado project, copies .mem
v0_baseline/mem/                           weights + 244 verification vectors
tools/golden_model.py                      standalone NumPy reference
docs/V0_CHANGELOG.md                       per-bug detail
```

The notebook trains **directly in INT8 space** — parameters are the quantised
weights, with straight-through rounding enabled partway through — so export is
`round(clamp(w))` with no scale factors, and the golden model is exactly the trained
model. Confirmed by `torch(hard) vs numpy golden: IDENTICAL`.

## 8. Remaining v0 tasks

- [ ] Re-run the notebook at 110 epochs, confirm ~84.7%, re-sweep 244, commit those weights
- [ ] Run Synthesis → Implementation; capture post-implementation LUT / FF / BRAM / DSP
- [ ] Generate a SAIF from the behavioural simulation and run power analysis with it
      (the 35.9 W in the old deck was Vivado's vectorless estimator assuming 100%
      switching — it was never a real measurement and should not be quoted)
- [ ] Push to `github.com/Karthik-Flash/ProjectFlash`

## 9. What v0 establishes for V1

1. A golden model written **before** the RTL, not after.
2. A regression harness that checks intermediate tensors, so a mismatch localises to
   a layer instead of producing a wrong final answer.
3. A line buffer with no border logic, parameterised on width — the piece that
   scales directly to 224×224.
4. Measured accumulator headroom rather than hand-computed bounds.
5. Separation of two claims that were previously tangled: *the hardware is correct*
   and *the model is accurate* are now independent numbers that move independently.

---

*Team FLASH · BITS Pilani Hyderabad · Karthikeya Reddy (ML) · Yashwant Rajesh (Architecture)*
