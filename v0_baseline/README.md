# v0 baseline — 28×28 PneumoniaMNIST accelerator (closed)

The audited successor of the hackathon design (H-V0…H-V4, repository
[PneumoniaFPGA](https://github.com/Karthik-Flash/PneumoniaFPGA)). v0 exists to
prove the datapath arithmetic is correct before anything scales up. It is
closed; the current hardware is V1.2.1 in `v1/` (see the
[root README](../README.md)). This page preserves the v0 status that used to
be the repository's front page (until 2026-10-09).

```
bit-exact logits : 244 / 244
label agreement  : 244 / 244
*** RTL IS BIT-EXACT WITH THE GOLDEN MODEL ***
```

## Verification (Vivado xsim)

| Check | Result |
|---|---|
| Logits vs golden model, 244 test images | **244 / 244 bit-exact** |
| Conv feature map vs golden | 0 mismatches / 3,136 |
| Pooled tensor vs golden | 0 mismatches / 784 |
| FC1 neuron outputs vs golden | 0 mismatches / 16 |
| `torch(hard)` vs NumPy golden | IDENTICAL |
| Conv accumulator range, full test set | [−41,632, +85,317] vs 20-bit budget ±524,287 (6.1× headroom) |

## Implementation — 75 MHz, xc7z020clg400-1

| Metric | Value |
|---|---|
| Worst negative slack | **+0.290 ns** |
| Worst hold slack | +0.104 ns |
| Failing endpoints | 0 / 3,173 |
| Maximum achievable clock | ~83.7 MHz |
| Total on-chip power | **0.116 W** (Vivado estimate from a simulation SAIF; not a board measurement) |
| Dynamic / device static | 0.011 W / 0.105 W |
| Junction temperature | 26.3 °C |

Vectorless power analysis assumes about 100% switching on every net and gave
5.75 W for this design; the SAIF-based estimate is 0.116 W.

## Model (INT8, what the hardware computes)

| | Value |
|---|---|
| Balanced accuracy | 84.7% |
| Specificity (Normal) | 73.9% |
| Sensitivity (Pneumonia) | 95.4% |

Two independent claims, kept separate: *the hardware is correct* and *the
model is 84.7%*. The hackathon reported a 95.4% balanced accuracy that the
defective hardware could not reproduce.

Five defects were fixed getting here (three in the datapath, two in the
testbench): [`docs/v0/V0_CHANGELOG.md`](../docs/v0/V0_CHANGELOG.md); closing
write-up: [`docs/v0/V0_SUMMARY.md`](../docs/v0/V0_SUMMARY.md).

## Layout

```
v0_baseline/
  rtl/            seven Verilog modules (top_accelerator, line_buffer, mac_unit, max_pool, relu, fc_layer, fsm_control)
  sim/            tb_top.v, vivado_setup.tcl, run_sim.tcl, run_iverilog.sh
  mem/            weights + 244 verification vectors (30x30 zero-padded frames)
  constraints/    pynq_z2.xdc, top_accelerator.xdc
  tools/
    golden_model.py   standalone NumPy reference (was tools/golden_model.py until 2026-10-09)
colab/ProjectFlash_V0.ipynb   trains in INT8 space, exports .mem, emits test vectors
```

## Architecture

| Layer | Operation | In | Out |
|---|---|---|---|
| Conv2D + ReLU | 4 filters, 3×3, pad 1 | 1×28×28 | 4×28×28 |
| MaxPool2D | 2×2 stride 2, then `>> 8` | 4×28×28 | 4×14×14 |
| Flatten | channel-major | 4×14×14 | 784 |
| FC1 + ReLU | dense | 784 | 16 |
| FC2 | dense, logits | 16 | 2 |
| Argmax | `logit1 > logit0` | 2 | 1 bit |

12,634 INT8 parameters. The accelerator consumes a **30×30 zero-padded
frame** (900 bytes, raw uint8, row-major); `line_buffer.v` is a pure
valid-window generator, bit-identical to `torch.nn.Conv2d(padding=1)`.

## Simulate

With the v0 Vivado project open (`verilog/ProjectFlashV0`, local), in the Tcl
console:

```tcl
cd C:/KarDRIVE/Projects/ProjectFlash
source v0_baseline/sim/vivado_setup.tcl
flash_set_n 244
```

then Run Behavioral Simulation. `flash_copy_mem` copies the `.mem` files into
the xsim run directory, because xsim resolves bare `$readmemh` paths against
its own run directory.

## What the testbench checks

Per image it compares `logit0` and `logit1` with the golden model bit for bit
and separately reports label agreement. The 244 images are a balanced slice
of the test set under a fixed seed with **no confidence-margin filter**. The
hackathon's 8-image set was filtered to >20% margin, which is why three
genuine bugs went unnoticed for five versions. The model classifies 46 of the
244 wrongly, on purpose: the RTL must reproduce the reference including its
mistakes.
