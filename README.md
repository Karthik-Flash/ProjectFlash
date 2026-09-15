# Project FLASH

FPGA-accelerated pneumonia screening on chest X-rays. All inference — convolution,
pooling, both dense layers, argmax — runs as synthesised RTL on the PL. Nothing
touches the ARM core during inference.

Successor to [PneumoniaFPGA](https://github.com/Karthik-Flash/PneumoniaFPGA).

**Team FLASH** · BITS Pilani Hyderabad · Karthikeya Reddy (ML) · Yashwant Rajesh (Architecture)

---

## Status

`v0_baseline` is the verified 28×28 PneumoniaMNIST accelerator. It exists to prove
the datapath is arithmetically correct before anything scales up.

    bit-exact logits : 8 / 8
    label agreement  : 8 / 8
    *** RTL IS BIT-EXACT WITH THE GOLDEN MODEL ***

Three real datapath bugs inherited from `PneumoniaFPGA/V3` are fixed. See
[`docs/V0_CHANGELOG.md`](docs/V0_CHANGELOG.md).

## Layout

    colab/     FLASH_v0_train_export_verify.ipynb   trains, exports .mem, emits test vectors
    v0_baseline/
      rtl/         seven Verilog modules
      sim/         tb_top.v, run_sim.tcl, run_iverilog.sh
      mem/         weights + verification vectors (8-image smoke set committed)
      constraints/ pynq_z2.xdc
    tools/     golden_model.py    standalone NumPy reference
    docs/      V0_CHANGELOG.md

## Flow

Colab → Vivado → FPGA. Nothing in the RTL flow is hand-written data.

**1. Colab.** Run `colab/FLASH_v0_train_export_verify.ipynb`. It trains the network
directly in int8 space, exports six weight `.mem` files, and writes N zero-padded
30×30 test images together with the exact logits the hardware must reproduce.
Download `flash_v0_mem.zip` and unzip it into `v0_baseline/mem/`.

**2. Simulate.** From the repository root:

```bash
vivado -mode batch -source v0_baseline/sim/run_sim.tcl -tclargs 244
```

Or without Vivado, if you have Icarus installed:

```bash
bash v0_baseline/sim/run_iverilog.sh 244
```

The `-tclargs` / argument is `N_IMAGES` and must match `manifest.json` from the
notebook. The tcl script copies the `.mem` files into the xsim run directory, which
is the step that silently breaks a Vivado simulation if you skip it.

**3. Hardware.** Not yet. The gate for moving on is a clean bit-exact sweep, not a
passing decision bit.

## What the testbench actually checks

Per image it compares `logit0` and `logit1` against the golden model **bit for
bit**, and separately reports label agreement. The images are a balanced slice of
the test set taken in order, not cherry-picked by confidence margin. Some of them
the model classifies wrongly — that is intentional. The RTL is required to
reproduce the reference model including its mistakes. Anything less is not a
correctness test.

## Input format

The accelerator consumes a **30×30 zero-padded frame**, 900 bytes, raw uint8
pixels, row-major. Padding is no longer generated inside `line_buffer.v`. This
makes the convolution bit-identical to `torch.nn.Conv2d(padding=1)` and removes
every border special-case from the RTL.

## Architecture

| Layer | Operation | In | Out |
|---|---|---|---|
| Conv2D + ReLU | 4 filters, 3×3, pad 1 | 1×28×28 | 4×28×28 |
| MaxPool2D | 2×2, stride 2, then `>> 8` | 4×28×28 | 4×14×14 |
| Flatten | channel-major | 4×14×14 | 784 |
| FC1 + ReLU | dense | 784 | 16 |
| FC2 | dense, logits | 16 | 2 |
| Argmax | — | 2 | 1 bit |

12,634 int8 parameters. Target part `xc7z020clg400-1` (PYNQ-Z2).

## Next

Phase 2 moves to RSNA Pneumonia Detection at 224×224 with a global-average-pooling
backbone, a parameterised convolution engine reused across layers, and a real
AXI-Stream/DMA datapath. None of that starts until v0 sweeps clean.
