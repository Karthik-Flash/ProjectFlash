# Project FLASH

FPGA-accelerated pneumonia screening on chest X-rays. All inference — convolution,
pooling, both dense layers, argmax — runs as synthesised RTL on the PL. Nothing
touches the ARM core during inference.

Successor to [PneumoniaFPGA](https://github.com/Karthik-Flash/PneumoniaFPGA).

**Team FLASH** · BITS Pilani Hyderabad · Karthikeya Reddy (ML) · Yashwant Rajesh (Architecture)

---

## Status: v0 closed and verified

`v0_baseline` is the 28×28 PneumoniaMNIST accelerator. It exists to prove the
datapath is arithmetically correct before anything scales up.

```
bit-exact logits : 244 / 244
label agreement  : 244 / 244
*** RTL IS BIT-EXACT WITH THE GOLDEN MODEL ***
```

Every number below is measured. None is estimated.

### Verification

| Check                                   | Result                                                          |
| --------------------------------------- | --------------------------------------------------------------- |
| Logits vs golden model, 244 test images | **244 / 244 bit-exact**                                   |
| Conv feature map vs golden              | 0 mismatches / 3,136                                            |
| Pooled tensor vs golden                 | 0 mismatches / 784                                              |
| FC1 neuron outputs vs golden            | 0 mismatches / 16                                               |
| `torch(hard)` vs NumPy golden         | IDENTICAL                                                       |
| Conv accumulator range, full test set   | [−41,632, +85,317] vs 20-bit budget ±524,287 (6.1× headroom) |

### Implementation — 75 MHz, xc7z020clg400-1

| Metric                   | Value                                                     |
| ------------------------ | --------------------------------------------------------- |
| Worst negative slack     | **+0.290 ns**                                       |
| Worst hold slack         | +0.104 ns                                                 |
| Failing endpoints        | 0 / 3,173                                                 |
| Maximum achievable clock | ~83.7 MHz                                                 |
| Total on-chip power      | **0.116 W**                                         |
| Dynamic                  | 0.011 W                                                   |
| Device static            | 0.105 W (90% of total)                                    |
| Junction temperature     | 26.3 °C                                                  |
| Power confidence         | Medium — activity from a simulation SAIF, not vectorless |

### Model — INT8, what the hardware actually computes

|                         | Value |
| ----------------------- | ----- |
| Balanced accuracy       | 84.7% |
| Specificity (Normal)    | 73.9% |
| Sensitivity (Pneumonia) | 95.4% |

Two independent claims, deliberately kept separate: *the hardware is correct* and
*the model is 84.7%*. Earlier versions conflated them and reported a 95.4% that the
hardware could not reproduce.

Five defects were fixed getting here — three in the datapath, two in the testbench.
See [`docs/V0_CHANGELOG.md`](docs/V0_CHANGELOG.md) for each, and
[`docs/V0_SUMMARY.md`](docs/V0_SUMMARY.md) for the closing writeup.

## Layout

```
colab/
  ProjectFlash_V0.ipynb   trains, exports .mem, emits test vectors
v0_baseline/
  rtl/          seven Verilog modules
  sim/          tb_top.v, vivado_setup.tcl, run_sim.tcl, run_iverilog.sh
  mem/          weights + 244 verification vectors
  constraints/
tools/
  golden_model.py       standalone NumPy reference
docs/
  V0_CHANGELOG.md       per-defect detail
  V0_SUMMARY.md         v0 closing summary
  V1_HANDOFF.md         everything phase 2 needs to start
```

## Flow

Colab → Vivado → FPGA. Nothing in the RTL flow is hand-written data.

**1. Colab.** Run `colab/FLASH_v0_train_export_verify.ipynb`. It trains the network
directly in INT8 space, exports six weight `.mem` files, and writes N zero-padded
30×30 test images together with the exact logits the hardware must reproduce.
Download `flash_v0_mem.zip` and unzip into `v0_baseline/mem/`.

**2. Simulate.** With the Vivado project open, in the Tcl Console:

```tcl
cd C:/KarDRIVE/Projects/ProjectFlash
source v0_baseline/sim/vivado_setup.tcl
flash_set_n 244
```

then Run Behavioral Simulation. `flash_copy_mem` copies the `.mem` files into
`<proj>.sim/sim_1/behav/xsim/` — xsim resolves bare `$readmemh` paths against its
own run directory, and skipping this breaks the simulation silently with X's.
`N_IMAGES` must match `manifest.json` from the notebook.

**3. Implement.**

Then follow `v0_fix/README_power.md` to capture a SAIF and get a real power figure.
Vectorless analysis assumes ~100% switching on every net and produced 5.75 W for
this design; the SAIF-derived number is 0.116 W.

**4. Hardware.** Board not yet in hand. The AXI-Stream/DMA integration plan is
recorded in [`docs/V1_HANDOFF.md`](docs/V1_HANDOFF.md) §5.

## What the testbench actually checks

Per image it compares `logit0` and `logit1` against the golden model **bit for
bit**, and separately reports label agreement. The 244 images are a balanced slice
of the test set under a fixed seed, with **no confidence-margin filter** — the
earlier 8-image set was filtered to >20% margin, which is selection bias and is why
three genuine bugs went unnoticed for five versions.

Roughly 19% of the 244 are classified wrongly by the model. That is intentional. The
RTL is required to reproduce the reference model *including its mistakes*. A
decision bit can be right by accident; a matching 32-bit logit cannot.

## Input format

The accelerator consumes a **30×30 zero-padded frame** — 900 bytes, raw uint8,
row-major. Padding is no longer generated inside `line_buffer.v`, which is now a
pure valid-window generator (`window_valid = row>=2 && col>=2`). This makes the
convolution bit-identical to `torch.nn.Conv2d(padding=1)`, removes every border
special-case from the RTL, and makes resolution a single parameter.

## Architecture

| Layer         | Operation                   | In        | Out       |
| ------------- | --------------------------- | --------- | --------- |
| Conv2D + ReLU | 4 filters, 3×3, pad 1      | 1×28×28 | 4×28×28 |
| MaxPool2D     | 2×2 stride 2, then`>> 8` | 4×28×28 | 4×14×14 |
| Flatten       | channel-major               | 4×14×14 | 784       |
| FC1 + ReLU    | dense                       | 784       | 16        |
| FC2           | dense, logits               | 16        | 2         |
| Argmax        | `logit1 > logit0`         | 2         | 1 bit     |

12,634 INT8 parameters. Training happens **directly in INT8 space** — the
parameters *are* the quantised weights, with straight-through rounding enabled
partway through — so export is `round(clamp(w))` with no scale factors, and the
golden model is exactly the trained model.

## Next

Phase 2 moves to RSNA Pneumonia Detection at 224×224: a global-average-pooling
backbone (~47 k parameters, all resident in BRAM), one parameterised convolution
engine reused across layers under a layer-descriptor table, and an AXI-Stream/DMA
datapath.

Staged so one variable moves at a time — new architecture at 28×28 first, then the
new dataset at 28×28, then 224×224 — with a bit-exact sweep gating each step.
See [`docs/V1_HANDOFF.md`](docs/V1_HANDOFF.md).
