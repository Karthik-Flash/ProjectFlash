# Project FLASH — V1 Project Report

**An offline pneumonia screener built as a bit-exact neural network in FPGA hardware**

Karthikeya Reddy and Yashwant Rajesh · BITS Pilani Hyderabad ·
[github.com/Karthik-Flash/ProjectFlash](https://github.com/Karthik-Flash/ProjectFlash) ·
report of 2026-10-09, revised 2026-10-11 (figures, accelerator metrics,
scaling section), tag `v1.2.1-hw` · paper version in [`paper/`](paper/README.md)

> **Research prototype. Not a medical device.** Nothing here is cleared or
> validated for clinical use.

**How numbers are labelled.** This report uses the four labels of the project
brief ([`docs/Project_FLASH_brief.pdf`](docs/Project_FLASH_brief.pdf)), and
each number also names the repository file it comes from.

| Label | Meaning |
|---|---|
| **Measured** | Produced by a tool or board run on the current design and reproducible from the repository: board notebooks, xsim, Vivado post-route timing and utilisation reports. |
| **Synthesis estimate** | Reported by Vivado as an estimate: post-synthesis timing and utilisation, and every power figure (Vivado power numbers are estimates even after routing). |
| **Derived** | Calculated from measured quantities. Every derived number in this report is recomputed by `tools/make_report_figures.py` into [`docs/figures/derived_numbers.json`](docs/figures/derived_numbers.json). |
| **Not yet done** | Planned work; no number exists. |

---

## 1. Summary

FLASH takes a chest X-ray and says whether it shows signs of pneumonia. The
whole convolutional neural network runs inside a low-cost AMD Zynq-7020 chip
on a PYNQ-Z2 board, with no network connection and no GPU. Its central
property is that the chip computes exactly what the trained network
computes. Every 32-bit output score matches an independent integer reference
model, bit for bit.

V1 is complete. The 224×224 network now runs on the board and reproduces the
reference model on **all 244 verification images**, for logit0, logit1,
margin and decision alike. Three bitstreams were verified: V1.2.1, its LED
variant, and the original V1.2 build with one processor register corrected.
Getting there required finding a fault that the project's simulations could
not show, because they do not model the processor's memory path. That fault,
and how it was located offline from the board's own outputs, is the main
methodological result of this report (Section 10).

| What | Value | Label | Source |
|---|---|---|---|
| Board matches the golden model, V1.2.1 (`flash_hp64`), 224×224 | **244 / 244** images, all four outputs exact | Measured | `docs/board_runs/2026-10-09/results_flash_hp64.csv` |
| Board matches, LED build (`flash_hp64_led`) | **244 / 244** | Measured | `docs/board_runs/2026-10-09/demo_flash_hp64_led_executed.ipynb` |
| Same result with the V1.2 bitstream after one AFI register write | **244 / 244** (0 / 244 without it) | Measured | `results_flash_hp32_afiforce.csv`, `results_flash_hp32.csv` |
| Clock | **66.67 MHz** (FCLK0 66.666667 MHz read back) | Measured | `summary_flash_hp64.json` |
| Post-route timing, V1.2.1 | WNS +0.314 ns, WHS +0.030 ns, 0 of 15,451 endpoints failing | Measured | `docs/reports/impl/V1_impl_timing_v1_2_hp64.rpt` |
| Chip usage, V1.2.1 | 7.26% LUT, 4.48% FF, 58.57% block RAM, 6.36% DSP | Measured | `docs/reports/impl/V1_impl_util_v1_2_hp64.rpt` |
| Time per image, compute | **182.94 ms** (12,196,126 cycles) | Measured | CYCLES register |
| Time per image, end to end | **184.73 ms**, 5.41 images/s | Measured | `summary_flash_hp64.json` |
| Same golden model on the board's ARM core | 665–744 ms per image (FPGA 3.6–4.1× faster) | Measured / Derived | `summary_*.json` |
| Model quality, V1.2, 4,003 unseen patients | AUROC **0.8229** (95% CI 0.8083–0.8379) | Measured | `v1/mem/v1_2/flash_v1_2/manifest.json` |
| Sensitivity / specificity at the chosen threshold, test set | 91.0% / 53.9% | Measured | `manifest.json` |
| Same on the 244 images, computed by the board | 0.959 / 0.467 | Measured | `results_flash_hp64.csv` |
| Chip power | 1.494 W total (1.256 W in the ARM side) | Synthesis estimate | `docs/reports/impl/V1_impl_power_v1_2_hp64.rpt` |
| Throughput and efficiency | 0.1333 GOP/s, 99.97% of the 1-MAC-per-clock peak | Derived | `derived_numbers.json` (`accel`) |

Three things are V2 future work, not V1 results (Section 13): a board run on
all 4,003 test images, measured board power, and DICOM end to end on the
board.

---

## 2. The problem

Pneumonia fills the small air sacs of the lungs with fluid. It is treatable,
yet the WHO reports that it killed 740,180 children under five in 2019, with
deaths highest in southern Asia and sub-Saharan Africa. A chest X-ray is the usual way
to confirm it, but someone has to read the X-ray. India has roughly one
radiologist per 100,000 people, concentrated in cities, so a film taken at a
small hospital can wait hours or days for a report. Both figures are as cited,
with their sources, in the brief
([`docs/archive/Project_FLASH_brief_longform_2026-09-29.md`](docs/archive/Project_FLASH_brief_longform_2026-09-29.md),
§2).

Most AI tools that read X-rays run on a server or in the cloud. That needs a
reliable connection and sends patient images off site. FLASH aims at a small
device that reads the film where it is taken and gives an immediate first
opinion, "likely normal" or "send for an urgent read". It is meant to help a
clinician prioritise, not to replace a radiologist.

We chose an FPGA rather than a phone or a small computer for one main reason:
the chip computes exactly what we validated, every time, with no operating
system or floating-point library in the way. That property is easy to test
and easy to explain to a regulator. Low power is the second reason; so far
it rests on a Vivado estimate, and measuring it is V2 work (Section 13).

---

## 3. Background in brief

**Images.** A chest X-ray is a grid of brightness values. Hospital scanners
store it as a DICOM file with 10–16 bits per pixel. FLASH's preprocessing
(`flash_preprocess.py`) applies the DICOM modality look-up table and the
window, inverts MONOCHROME1 images, letterboxes to a square, area-resizes to
224×224, and rounds to 8 bits. The network therefore sees 50,176 numbers
between 0 and 255.

**Convolution.** A convolutional neural network slides 3×3 grids of weights
over the image, multiplying and adding at every position. One multiply plus
one add is a multiply-accumulate (MAC). FLASH's network needs 12,192,896 MACs
per image (Derived, from `layer_table.json`).

**Integers.** FLASH is trained directly in integer units. The weights are
8-bit signed, activations 8-bit unsigned, biases 32-bit. After each layer the
sum is divided by a power of two (a bit shift) and clamped to 0..255, and the
clamp doubles as the ReLU activation. The numbers the chip stores *are* the
trained weights: no conversion step can go wrong.

**The two scores.** The last layer outputs two logits, for "normal" and
"pneumonia". The decision uses their difference, the *margin*. An image is
flagged when the margin exceeds a threshold T, which is stored in a register
and can be changed without retraining.

**The chip.** The Zynq-7020 has two halves. The *PS* (processing system) is a
pair of ARM Cortex-A9 cores running Linux, plus the DDR memory controller.
The *PL* (programmable logic) is the FPGA fabric that holds the accelerator.
They talk over AXI: AXI-Lite for registers, AXI-Stream for data flows, and an
AXI DMA engine that copies a buffer from DDR into a stream without the ARM
touching each byte. The fabric holds 53,200 LUTs, 106,400 flip-flops, 140
block-RAM tiles of 36 Kb and 220 DSP multipliers
(`docs/reports/synth/V1_synth_util_v1_2.rpt`).

**Correctness vocabulary.** The *golden model* is an independent NumPy
program, written in int64, that computes exactly what the hardware should.
*Bit-exact* means two computations produce identical integers. **AUROC** is
the chance that a random sick patient scores above a random healthy one: 0.5
is a coin toss, 1.0 is perfect, and it does not depend on T. **Sensitivity**
is the share of sick patients that are flagged. **Specificity** is the share
of healthy patients that are cleared.

---

## 4. How the project got here

The design went through three phases: five hackathon versions that made it
work, an audit that made it correct, and the V1 stages that made it general
and then put it on the board. Following the brief, the hackathon versions are
written H-V0…H-V4, to keep them apart from the later "v0" and "V1".

```mermaid
timeline
    title Project FLASH, from hackathon to verified board
    section Hackathon (AMD FPGA Hackathon 2026, 5th place)
        H-V0 to H-V4 : 28x28 classifier on the PYNQ-Z2, image in, decision out
                     : 5 of 8 hand-picked simulation tests pass
    section Audit (Sep 2026)
        v0 baseline : golden model first, logit-level checks
                    : 5 hidden bugs fixed, 244/244 bit-exact at 28x28
    section V1 in simulation (Sep 2026)
        V1.0 / V1.1 / V1.2 : GAP network, layer-table engine
                           : RSNA 28x28 then 224x224, RTL 16/16 in xsim
    section V1 on hardware (Oct 2026)
        2026-10-07 : AXI wrapper, block design, bitstream at 66.67 MHz
        2026-10-08 : first board run 0/244, AFI fault localised offline
                   : V1.2.1 built with HP0 64-bit
        2026-10-09 : 244/244 on the board, root cause confirmed by intervention
                   : LED demo, 244/244 re-verified
```

**The hackathon (H-V0 to H-V4).** Source: the archived long-form brief, §4.
H-V0 kept feature maps in a 62,720-flip-flop register array that could not be
placed; it was moved to block RAM. H-V1 widened buses after silent integer
overflow. H-V2 clock-gated the MAC pipeline, and Vivado's vector-less power
estimate fell from 35.9 W to 7.2 W. Both of those are estimates assuming
near-100% switching, not measurements. H-V3 passed 5 of 8 hand-picked
simulation tests, and the failures were blamed on the model. H-V4 ran end to
end on the board. The team placed 5th.

**The audit and v0.** After the hackathon a golden model was written first,
and every intermediate tensor from the simulator was compared with it. Five
hidden defects appeared (Section 7). With them fixed, the 28×28 design
matches the golden model on 244 of 244 images and every intermediate layer
(Measured; `v0_baseline/README.md`). It meets 75 MHz after placement with
about 83.7 MHz possible (Measured), and a SAIF-based power analysis gives
0.116 W (Synthesis estimate). The honest model accuracy is 84.7% balanced
accuracy on PneumoniaMNIST. That is lower than the hackathon's 95.4%, which
the buggy hardware could never have produced.

**Why V1.** v0 was tied to 28×28 by its dense layer and built from
hand-written per-layer modules. It had no adjustable threshold, and it used
tiny, pre-shrunk PneumoniaMNIST images. V1 replaced all four (Section 6.5).
V1.0 tested the new architecture on PneumoniaMNIST, V1.1 on RSNA at 28×28,
and V1.2 on RSNA at 224×224.

**On hardware.** On 2026-10-07 the AXI wrapper, block design and bitstream
were built. The first board run, on 2026-10-08, gave 0/244. The fault was
located offline the same day and fixed in the block design (V1.2.1). On
2026-10-09 the fix gave 244/244, and the root cause was confirmed by
intervention. An LED variant for live demonstrations was then built and
re-verified on the same 244 images. The commit-by-commit history is in
[`docs/V1_CHANGELOG.md`](docs/V1_CHANGELOG.md).

---

## 5. Data, model and integer rules

**Data.** V1 trains on the RSNA Pneumonia Detection dataset: 26,684 adult
patients, one frontal X-ray each, radiologist-labelled, stored as DICOM. It
is split by patient into 18,678 for training, 4,003 for validation and 4,003
for testing. The test prevalence is 22.5% (`manifest.json`). The
preprocessing passed all seven of its self-tests, including on genuine
scanner files (JPEG 2000, MONOCHROME1, modality LUT before window; manifest
`preprocessing self-test`). The board runs the same preprocessing function,
so the hardware sees exactly the pixels training saw.

**Network.** Five stride-2 3×3 convolutions, then global average pooling
(GAP), then a 64→2 dense layer.

| Layer | Operation | Output at 224×224 | Parameters | MACs per image |
|---|---|---|---|---|
| conv1 | 3×3, stride 2, 1→8 | 8×112×112 | 80 | 903,168 |
| conv2 | 3×3, stride 2, 8→16 | 16×56×56 | 1,168 | 3,612,672 |
| conv3 | 3×3, stride 2, 16→32 | 32×28×28 | 4,640 | 3,612,672 |
| conv4 | 3×3, stride 2, 32→48 | 48×14×14 | 13,872 | 2,709,504 |
| conv5 | 3×3, stride 2, 48→64 | 64×7×7 | 27,712 | 1,354,752 |
| GAP | average per channel | 64 | 0 | (3,136 additions) |
| FC | dense 64→2 | 2 logits | 130 | 128 |
| **Total** | | | **47,602** | **12,192,896** |

Parameters and MACs are Derived from `v1/mem/v1_2/flash_v1_2/layer_table.json`.
The parameter count (47,432 int8 weights + 170 int32 biases) matches the
manifest.

![MACs per layer](docs/figures/fig_layer_macs.png)

*Figure 1. Multiply-accumulates per layer at 224×224 (Derived from
`layer_table.json`). conv2 and conv3 dominate.*

Stride-2 convolutions shrink the image as they go, and they remove the
separate pooling step where one of the v0 bugs lived. GAP reduces each of
the 64 final feature maps to one number, so the classifier always sees 64
values whatever the image size. The same hardware therefore runs 28×28 and
224×224. The 47,602 parameters (about 47 KB) stay permanently on the chip.

**Integer rules.** Training, the golden model and the hardware share these
rules exactly:

- Pixels and activations are unsigned 8-bit; weights are signed 8-bit;
  biases are 32-bit.
- conv output = bias + Σ weight × pixel over the 3×3 window and every input
  channel, held in a 22-bit accumulator. The width comes from the trained
  weights themselves: per output channel, Σ max(w, 0)·255 + b and
  Σ min(w, 0)·255 + b bound the sum for *any* 8-bit image, and the widest
  layer needs 22 bits (`colab/ProjectFlash_V1.ipynb`, hardware-sizing cell).
  The range actually seen on 8,006 validation and test images is well inside
  it (manifest `acc_stats`).
- The sum is shifted right by a per-layer amount (7, 7, 7, 8, 8) and clamped
  to 0..255.
- GAP sums each 7×7 map and shifts right by 6, i.e. divides by 64 instead of
  49. That is a wire, not a divider, and training sees the same thing.
- margin = logit1 − logit0. The image is flagged if margin > T.

**Training and threshold.** Training runs in two phases: unconstrained
weights first, then weights rounded to integers on every pass. The version
that scores best on the validation set is kept. T was chosen on the
validation set so that at least 90% of pneumonia cases are caught, then
locked before the test set was examined. For V1.2, T = −646 (manifest).

**Model results (test set, 4,003 patients; Measured; `manifest.json`,
`docs/audits/V1_audit_v1_2.md`).**

| | V1.1 (28×28) | V1.2 (224×224) |
|---|---|---|
| AUROC (95% CI) | 0.8143 (0.7988–0.8299) | **0.8229 (0.8083–0.8379)** |
| Sensitivity / specificity at T | 89.1% / 54.7% | 91.0% / 53.9% |
| PPV / NPV at T | 36.4% / 94.5% | 36.5% / 95.4% |
| AUROC from the view position (AP/PA) alone | 0.7064 | 0.7064 |

Larger images help a little, but the confidence intervals overlap. V1.1's
subgroup AUROCs are all within 0.02 of V1.2's (`docs/audits/V1_audit_v1_2.md`,
"V1.1 vs V1.2"). Figure 2 breaks
V1.2's test AUROC down by subgroup.

![Subgroup AUROC](docs/figures/fig_subgroup_auroc.png)

*Figure 2. Test-set AUROC by subgroup (Measured, `manifest.json`). The
all-test interval is the manifest's bootstrap; the subgroup intervals are
Derived with the Hanley–McNeil formula, which overall gives a slightly wider
0.805–0.840. Bottom row: the board's own AUROC on the 244, with a bootstrap
interval.*

What a reviewer should take from Figure 2:
- The network separates pneumonia from clearly normal lungs well (0.936),
  and from other lung findings much less well (0.738).
- Within AP films or within PA films alone it scores only 0.74–0.77, while
  knowing nothing but the film type scores 0.706. Part of the overall 0.823
  therefore comes from a shortcut: AP films are taken at the bedside, of
  sicker patients.
- Men and women score the same within error (0.821 and 0.826).
- A "clear" result can be trusted (NPV 95.4%). A "flag" means "get this
  checked" (Section 9.4).

---

## 6. Hardware architecture

### 6.1 The PS/PL split

```mermaid
flowchart LR
    subgraph PS["PS - ARM Cortex-A9, Linux, PYNQ 3.1.1"]
        A["Jupyter notebook<br/>load overlay, checks<br/>(VERSION, FCLK0, AFI)"]
        B["image buffer in DDR<br/>pynq.allocate, 50,176 bytes"]
        C["control: THRESHOLD, CTRL.start,<br/>poll STATUS, read results"]
        D["UI: plots, slider,<br/>LED register writes"]
    end
    subgraph PL["PL - FPGA fabric, 66.67 MHz"]
        E["AXI DMA<br/>MM2S, simple mode"]
        F["top_v1_axi<br/>AXI-Stream in, AXI-Lite regs"]
        G["top_v1<br/>all inference"]
        H["axi_gpio_led<br/>LD0-LD3, RGB LD4/LD5"]
    end
    B -- "HP0, 64-bit, via AFI" --> E
    E -- "AXI4-Stream, 32-bit = 4 px/beat" --> F
    F --> G
    C -- "GP0 AXI-Lite 0x40000000" --> F
    A -- "GP0 AXI-Lite 0x40400000" --> E
    D -- "GP0 AXI-Lite 0x41200000" --> H
```

*Figure 3. What runs where. The PS handles I/O, buffers, control, the user
interface and LED writes. The PL does all of the inference, plus the DMA and
the GPIO.*

The ARM never computes any part of the network. It copies the image into a
DMA buffer, writes the threshold and a start bit, starts the DMA, polls a
status register (there is no interrupt controller in the design), and reads
back two logits, the margin, the decision and a cycle count.

### 6.2 The accelerator (`v1/rtl/`)

| Module | What it does |
|---|---|
| `layer_seq` | Reads the layer table one entry at a time, starts the right unit, swaps the two feature-map buffers between layers, and streams the GAP input. |
| `conv_engine` | The shared 3×3 stride-2 convolution: one MAC per clock, pipelined (operand mux → register → multiply → register → accumulate), 22-bit sum, then shift and clamp. Padding is gated reads: an out-of-image tap contributes zero. |
| `fmap_ram` ×2 | Buffers A and B, 128 KB each. Each layer reads one and writes the other ("ping-pong"). |
| `gap_unit` | 64 running sums over the last feature map, then the shift. |
| `fc_unit` | The 64→2 dense layer; two 32-bit logits. |
| `decision` | margin = logit1 − logit0; positive if margin > threshold. |
| `top_v1` | Connects everything, holds the weight, bias and layer-table ROMs, and lines up the memory read latencies. |
| `top_v1_axi` | The AXI wrapper (V1 hardware addition, below). |
| `line_buffer_v1` | A streaming window generator, built and tested but not instantiated; ready for a faster engine later. |

**The layer table** holds one 128-bit word per layer. To change the network,
regenerate it and the weight file; the Verilog stays the same (Section 6.5).

```mermaid
flowchart LR
    LT["layer table ROM<br/>7 x 128-bit"] --> SEQ["layer_seq"]
    SEQ -->|conv layers 1-5| CONV["conv_engine<br/>1 MAC/clock"]
    SEQ -->|GAP| GAP["gap_unit"]
    SEQ -->|FC| FC["fc_unit"]
    W["weight ROM 47,432 x int8<br/>bias ROM 170 x int32"] --> CONV
    W --> FC
    A["fmap_ram A<br/>128 KB"] <--> CONV
    B["fmap_ram B<br/>128 KB"] <--> CONV
    B --> GAP
    GAP --> FC --> DEC["decision<br/>margin > T"]
    IN["pixels from the wrapper"] --> A
```

*Figure 4. Inside `top_v1`. The input image lands in buffer A; conv1 reads A
and writes B, conv2 reads B and writes A, and so on. GAP reads conv5's output
from B.*

### 6.3 The AXI wrapper and register map

`top_v1_axi` accepts the image as **32-bit AXI-Stream beats, four pixels per
beat** (byte 0 first), 12,544 beats per image. It unpacks each beat and feeds
`top_v1` one pixel per clock. The brief described the interface as one byte
per clock. That is still how the core consumes pixels, but the bus carries
four per beat. The wrapper reproduces the exact drive sequence of the
simulation testbench: the threshold write, all 50,176 pixels, one idle
cycle, then **one** start pulse. `tready` is high only while the core is
accepting pixels. A `tlast` on the wrong beat sets an error bit.

| Offset | Register | Access | Meaning |
|---|---|---|---|
| 0x00 | CTRL | W | bit 0 start (arms a run), bit 1 soft reset |
| 0x04 | STATUS | R | bit 0 busy, bit 1 done, bit 2 ready_for_pixels, bit 3 err |
| 0x08 | THRESHOLD | RW | signed 32-bit T, reset −646 |
| 0x0C / 0x10 | LOGIT0 / LOGIT1 | R | signed 32-bit logits |
| 0x14 | MARGIN | R | signed 32-bit margin |
| 0x18 | DECISION | R | bit 0 = flagged |
| 0x1C | VERSION | R | 0xF1A50102 |
| 0x20 | CYCLES | R | core clocks from start to result |

### 6.4 Block design and address map

The block design (`v1/scripts/create_bd.tcl`) contains:
- the PS7 with the PYNQ-Z2 board preset;
- an AXI DMA in simple mode, read channel only, 26-bit length;
- `top_v1_axi` as a module reference;
- a processor reset block;
- the interrupts concatenated to `IRQ_F2P`;
- in the LED build, `axi_gpio_led`.

The DMA's memory side and HP0 are 64-bit (V1.2.1; Section 10). Vivado refuses
to connect the AXI4 DMA directly to the AXI3 HP0 port, so an `auto_pc`
protocol converter sits between them.

| Block | Base address | Range |
|---|---|---|
| `top_v1_axi_0` | 0x4000_0000 | 4 KB |
| `axi_dma_0` | 0x4040_0000 | 64 KB |
| `axi_gpio_led` (LED build only) | 0x4120_0000 | 64 KB |
| DMA → HP0 → DDR | 0x0000_0000 | 512 MB |

The LED GPIO has two channels. Channel 1 drives LD0–LD3 (pins R14, P14, N16,
M14) and channel 2 drives the two RGB LEDs (6 bits: bits 0/1/2 = LD4
blue/green/red, bits 3/4/5 = LD5). Both pin sets come from the PYNQ-Z2 board
files through Vivado's board automation; no pin was typed by hand.

### 6.5 How V1 scales to 224×224

**v0's limits.** v0 was a fixed 28×28 design. Each stage was its own
hand-written module (`line_buffer`, `mac_unit`, `relu`, `max_pool`,
`fc_layer`), with its sizes built in and a fixed state machine
(`fsm_control`) stepping through them. Its classifier flattened the 4×14×14
feature map into 784 values for a 784→16 dense layer. Flatten plus the two dense layers held
12,594 of its 12,634 parameters, 99.7% (Derived from the layer table in
`v0_baseline/README.md`). That layer grows with the image: at 224×224 the
same head would have 50,176 inputs and 802,816 weights in its first dense
layer alone (Derived).

**What V1 changed.**
- **Stride-2 convolutions instead of pooling.** Five 3×3 convolutions,
  stride 2, padding 1, channels 1→8→16→32→48→64. Each halves the feature map,
  and the separate pooling stage (where one v0 bug lived) is gone.
- **GAP before the classifier.** Global average pooling turns the last map
  into 64 numbers at any resolution, so the dense layer stays 64→2. The
  network has 47,602 parameters whatever the image size.
- **One engine, driven by a layer table.** A single `conv_engine` is reused
  for all five convolutions. `layer_seq` walks a ROM of 128-bit descriptors,
  one per layer. Each holds the operation, kernel, stride and padding (4 bits
  each); input and output channels, heights and widths (12 bits each); the
  shift (6 bits); and the weight and bias base addresses (20 and 10 bits). 124
  of the 128 bits are used, and the field layout is identical at 28×28 and
  224×224 (Derived, `layer_table.json` of both stages).
- **A/B ping-pong buffers.** Two `fmap_ram`s; each layer reads one and writes
  the other.
- **Padding as gated reads.** An out-of-image tap contributes zero. No padded
  frame is stored.
- **A 22-bit accumulator sized from the real weights** (Section 5), safe for
  any 8-bit input image.
- **Shift and clamp as ReLU.** One right shift per layer, then a clamp to
  0..255.
- **GAP divides by 64, as a shift.** The 49 values of each 7×7 map are summed
  and shifted right by 6. Training uses the same arithmetic.
- **A run-time threshold register.** T can change without retraining or
  rebuilding.

**What 28→224 needed.** New `.mem` files (weights, biases, layer table) and
one RTL change: `fmap_ram` grew from 64 KB to 128 KB, because conv1's output
at 224×224 is 8×112×112 = 100,352 bytes (bug 9 in Section 7). Nothing else
in the Verilog changed.

**What it cost.**
- **Work.** 227,360 MACs per image at 28×28 become 12,192,896 at 224×224,
  ×53.6 (Derived, both layer tables). The pixel count grows ×64. The ratio is
  lower because the small maps at 28×28 round up (7→4→2→1).
- **Memory.** Synthesising `top_v1` alone, block RAM went from 48 RAMB36
  plus 1 RAMB18 (48.5 tiles; V1.1 with the old 64 KB RAMs) to 80.5 tiles
  (Synthesis estimate). The full V1.2.1 design uses 82 (Measured).
- **Clock.** The convolution's address arithmetic, c·in_h·in_w + y·in_w + x
  as a DSP multiply-add into the block-RAM address, is the critical path. It
  sets the 66.67 MHz clock (Section 8).

**The AXI wrapper.** `top_v1_axi` puts the unchanged core on the chip's
buses. It takes a 32-bit AXI-Stream carrying 4 pixels per beat, provides the
AXI-Lite registers of Section 6.3, and counts the core's clock cycles
(CYCLES).

---

## 7. Verification method

FLASH's claim rests on a chain of three proof links, plus the board:

```mermaid
flowchart LR
    T["trained network<br/>(PyTorch, integer units)"] -- "link 1: identical logits<br/>4,003 / 4,003 test images" --> G["golden model<br/>(NumPy int64, reads only<br/>the exported files)"]
    G -- "link 2: RTL simulation<br/>16 / 16 images, 12 / 12 layer traces;<br/>wrapper 33 / 33 checks" --> R["RTL<br/>(Vivado xsim)"]
    R -- "link 3: board<br/>244 / 244 images,<br/>3 bitstreams" --> B["PYNQ-Z2<br/>(silicon)"]
    G -.->|"independent audit:<br/>244 vectors + 60 traces,<br/>0 mismatches"| G
```

*Figure 5. The proof chain. Each arrow is a bit-exact comparison of
integers, not a tolerance.*

1. **Trained network = golden model.** Training is done in integer units,
   so the exported weights *are* the model. The golden model reads only the
   exported files and gives identical logits on all 4,003 test images, with
   0 mismatches on the intermediates of the 244 verification images
   (Measured; manifest).
2. **Golden model = RTL.** The simulator dumps every layer's output, and
   Python compares it with the golden model, so a mismatch points to the
   exact layer. At 224×224: 16 of 16 images exact, and 12 of 12 per-layer
   trace files (Measured; `tb_v1`). The AXI wrapper passed a 33-check
   testbench with three images, varied bus timing and error cases (Measured;
   `tb_v1_axi`, `docs/BRINGUP_STATUS.md`). An independent audit re-ran the
   golden model against all 244 vectors and 60 trace files of both stages:
   0 mismatches (`docs/audits/`).
3. **RTL = board.** The board compares all four outputs on all 244 images
   with the expected files (Measured; Section 9).

**The verification set.** The 244 images are a seeded (`SEED = 0`), balanced
slice of the test split: 122 pneumonia, 122 not. They were chosen without
looking at the model's confidence, and the model gets 70 of them wrong at
T = −646 (Derived). The hardware must reproduce the mistakes too, because a
matching 32-bit score cannot happen by accident. The hackathon's test checked
one yes/no bit on eight images picked because the model was confident about
them. That is why three datapath bugs survived five versions.

**Bug ledger, all phases.**

| # | Phase | Defect | How it was found | Effect | Fix |
|---|---|---|---|---|---|
| 1 | Hackathon → v0 | Line buffer read one window pixel before it was written | Golden-model tensor diff | Every 3×3 window had one wrong pixel | Valid-window generator over a zero-padded frame |
| 2 | Hackathon → v0 | Line-buffer windows centred one row early | Same | Last row never used; whole map shifted | Same rewrite |
| 3 | Hackathon → v0 | Max-pool captured BRAM data one clock early | Same | Pool compared the wrong values | Explicit 8-state sequencer |
| 4 | Hackathon → v0 | Dense-layer read pointer off by one | Same | One input skipped, another used twice | Explicit read invariant |
| 5 | Hackathon → v0 | Testbench drove inputs on the sampling edge and read results one clock early | Same | Tests read the previous image's answer | Drive on negedge, sample after settle |
| 6 | V1 RTL | `gap_unit` testbench raced the DUT with blocking assignments | Reproduction in isolation | Samples bound to the wrong channel | Non-blocking drives (`6018958`) |
| 7 | V1 RTL | conv and FC units assume 2-cycle reads; `fmap_ram` is 1-cycle | Integration sweep | Arithmetic read the neighbouring pixel | One register stage on the read path (`f964249`) |
| 8 | V1 RTL | `layer_seq` needed two start pulses to relaunch | Integration sweep | Previous image's result left standing | Single-pulse relaunch (`f964249`) |
| 9 | V1.2 RTL | 64 KB feature-map RAM too small for 224×224 conv1 (100,352 bytes) | First 224×224 simulation | Writes dropped, X reads | 128 KB RAM (`57126bc`) |
| 10 | V1.2 testbench | 200 ms timeout too short for 224×224; an unsized 5 s literal would wrap at 32 bits, and xsim rejected the sized one | Simulation | Sweep cut off | Cycle-counted timeout (`1adcb86`, `142f11c`, `e192198`) |
| 11 | V1.2 synthesis | Synthesis loaded the **v1_1** weights through `top_v1.v`'s defaults | Log audit (`Synth 8-3876` lines) | A bitstream would have computed the wrong model with no error | v1_2 defaults and absolute paths (`d1dc26f`) |
| 12 | Documentation | Narrative overclaimed: RTL "244" (was 16), "whole test split" (a subset), V1.2 "reused V1.1 weights" (it did not) | Review | Claims ahead of evidence | Corrected with a revision note |
| 13 | Export | Manifest hashes cover only 3 of 313 `.mem` files per stage | Audit (`227186b`) | Vectors have no recorded checksum | Not yet fixed in the notebook (Section 12) |
| 14 | Wrapper testbench | `send_stream` took a beat twice | Timeout in the first xsim run | False failure; the wrapper was correct | TB fixed (`d2ecb7e`) |
| 15 | Board | HP0 AFI in 64-bit mode, PL port 32-bit | Board 0/244, then offline model search | Every odd 32-bit input word replaced | HP0 and DMA at 64 bits (V1.2.1); Section 10 |

Defects 1–5 are the "five hidden bugs" of the brief. Defects 11 and 15 are
the ones that would have produced a confidently wrong device, with no error
message.

---

## 8. Implementation results

| | V1.2 (HP0 32-bit) | **V1.2.1 `flash_hp64`** | **V1.2.1-led `flash_hp64_led`** |
|---|---|---|---|
| FCLK0 | 66.666672 MHz | 66.666672 MHz | 66.666672 MHz |
| WNS / WHS | +0.206 / +0.024 ns | **+0.314 / +0.030 ns** | **+0.344 / +0.025 ns** |
| Failing endpoints | 0 of 15,320 | 0 of 15,451 | 0 of 15,704 |
| LUT | 3,818 (7.18%) | 3,864 (7.26%) | 3,947 (7.42%) |
| Flip-flops | 4,745 (4.46%) | 4,766 (4.48%) | 4,899 (4.60%) |
| Block RAM (RAMB36 + RAMB18 → tiles) | 81 + 1 → 81.5 (58.21%) | 81 + 2 → 82 (58.57%) | 81 + 2 → 82 (58.57%) |
| DSP | 14 (6.36%) | 14 (6.36%) | 14 (6.36%) |
| Power, total (PS7) | 1.492 W (1.256 W) | 1.494 W (1.256 W) | 1.499 W (1.256 W) |
| `.bit` SHA-256 | `396a219b10690f26` | `0ee58d6c924cd162` | `7e0c3394fac1b57d` |

Timing and utilisation are Measured (post-route reports in
`docs/reports/impl/`). Power is a Synthesis estimate: vector-less, with
confidence Medium for the first two builds and Low for the LED build.
Percentages are Derived against the device totals. Block RAM, mostly the two
128 KB feature-map buffers, is the only substantial resource.

Of `flash_hp64`'s 3,864 LUTs, the accelerator uses 2,758; the DMA uses 528,
the GP0 interconnect 518, and the HP0 protocol converter 44. The LED GPIO
adds 64 LUTs and 132 flip-flops. The accelerator's netlist is the same in all
three builds: its 2,274 `INIT_xx` lines (weights, biases, layer table) are
identical (`docs/V1_board_debug_log.md`).

**Why 66.67 MHz, not 75 MHz.** The brief's 75 MHz was a synthesis estimate for
the accelerator alone (WNS +0.085 ns; Synthesis estimate). On the chip:
- The PS cannot generate 75 MHz for the fabric. Requesting it gives 76.92 MHz.
- The next achievable frequency, 71.43 MHz, failed post-route timing by
  0.925 ns (Measured; `docs/BRINGUP_STATUS.md`).
- The critical path is the convolution engine's feature-map address
  arithmetic, a DSP multiply-add into the block-RAM address pins. In
  `flash_hp64` this path takes 13.786 ns of the 15 ns budget, 70% of it logic
  (Measured).
- 66.67 MHz (1000 MHz / 15) meets timing.

The RTL was frozen for the board work, so the lower clock was accepted.
Pipelining the address path is the first V2 hardware item.

---

## 9. Board results

### 9.1 Bit-exactness

| Run (2026-10-09) | Bitstream | AFI RDCHAN_CTRL bit 0 | Bit-exact (logit0 / logit1 / margin / decision) | TP / FN / TN / FP |
|---|---|---|---|---|
| 1 | `flash_hp64` | 0, as booted | **244/244** (244 / 244 / 244 / 244) | 117 / 5 / 57 / 65 |
| 2 | `flash_hp32` | 0, as booted | **0/244** (0 / 0 / 2 / 234) | 118 / 4 / 56 / 66 |
| 3 | `flash_hp32` + `AFI_FORCE` | 0 → 1 | **244/244** | 117 / 5 / 57 / 65 |
| demo | `flash_hp64_led` | 0 | **244/244** | 117 / 5 / 57 / 65 |

All Measured (`docs/board_runs/2026-10-09/`). On every image of every run,
CYCLES = 12,196,126 and VERSION = 0xF1A50102, and the error bit was never
set. Runs 1 and 3 wrote byte-identical CSV files. Run 2 equals the
2026-10-08 failure image by image. The threshold register works: at T =
0x7FFFFFFF image 0 keeps its margin and its decision becomes 0.

![Gallery from the board](docs/figures/fig_demo_gallery_board.png)

*Figure 6. Board output from the live demo (Measured): the first six true
positives and first six true negatives by index, each classified live by the
FPGA (all 12 bit-exact) and by the ARM golden model.*

### 9.2 Accelerator metrics

The usual accelerator figures of merit, for `flash_hp64` at 66.67 MHz. The
derived values are in `derived_numbers.json` (`accel`, `latency`).

| Metric | Value | Label |
|---|---|---|
| Latency, compute (CYCLES = 12,196,126 at 66.666667 MHz) | **182.94 ms** | Measured cycles; Derived ms |
| Latency, end to end (244 back-to-back `run()` calls, images in memory) | **184.73 ms** | Measured |
| Throughput | 5.47 images/s compute; 5.41 images/s end to end | Derived |
| Work per image | 12,192,896 MACs = 24.39 MOP (2 operations per MAC) | Derived |
| Achieved compute rate | 0.13330 GOP/s (0.13201 end to end) | Derived |
| Peak at 1 MAC per clock | 0.13333 GOP/s; MAC-cycle efficiency 12,192,896 / 12,196,126 = **99.97%** | Derived |
| Resources, whole design | 14 DSP (6.4%), 82 BRAM tiles (58.6%), 3,864 LUT (7.3%) | Measured |
| Resources, accelerator alone (`top_v1_axi_0`) | 14 DSP, 80.5 BRAM tiles, 2,758 LUT | Measured |
| Power | 1.494 W chip; 0.238 W PL (chip minus PS7: 0.094 W PL dynamic + 0.144 W device static) | Synthesis estimate |
| Energy per inference (power × compute latency) | 273.3 mJ chip; 43.5 mJ PL | Derived from the Synthesis estimate |
| Energy efficiency | 0.089 GOP/s/W chip; 0.56 GOP/s/W PL | Derived from the Synthesis estimate |

The same integer model, side by side:

| Platform | Time per image | Label |
|---|---|---|
| Desktop PC (Intel Core i7-13650HX), NumPy int64 golden model | 8.7 ms (median of 21) | Measured |
| PYNQ-Z2 ARM Cortex-A9, same code | 665–744 ms (3 sessions); 706.6 ms mean over the 12 demo images | Measured |
| PYNQ-Z2 FPGA, compute | 182.94 ms | Measured |
| PYNQ-Z2 FPGA, end to end | 184.73 ms | Measured |

Host overhead (copy, cache flush, registers, DMA, polling) is 1.79 ms, 0.97%
of the end-to-end time (Derived). Runs 1–3 took 184.73, 184.71 and 184.70 ms
(Measured). The sweep's wall time, 153.8 s, is mostly the notebook parsing
`.mem` text files. The brief's 163 ms is what the measured cycle count gives
at 75 MHz: 162.62 ms (Derived).

CYCLES exceeds the network's MAC count by 3,230. Of those, 3,136 are the GAP
stream (64 channels × 49 values, one per clock), and about 94 are sequencing
and pipeline drain (Derived). The engine does one MAC per clock by design, so
it runs at its own peak: V1 is efficient against its design point, and that
point is low.

### 9.3 ARM baseline, honestly

The board's own ARM core ran the same golden model on image 0 once per
session: 743.9, 726.3 and 665.1 ms (Measured). In the demo it ran 12 images
at a mean of 706.6 ms against the FPGA's 185.0 ms, a speedup of 3.8×
(Measured). Every ARM result equalled the expected integers. Across sessions
the FPGA's compute is **3.6–4.1× faster** (Derived).

This baseline is weak, and the report says so: unoptimised NumPy int64 on
one Cortex-A9 core, where NEON int8 code or both cores would be faster. The
development PC runs the same code in **8.7 ms** (Measured;
`docs/figures/pc_golden_timing.json`). V1 shows that the integer network runs
exactly in hardware, not that the FPGA is fast. A Raspberry Pi comparison is
Not yet done.

### 9.4 Classification on the 244

| | Predicted pneumonia | Predicted no pneumonia |
|---|---|---|
| **Pneumonia (122)** | TP 117 | FN 5 |
| **No pneumonia (122)** | FP 65 | TN 57 |

| Metric | Value (95% CI) | Label |
|---|---|---|
| Sensitivity | 0.959 (Wilson 0.908–0.982) | Measured counts; Derived CI |
| Specificity | 0.467 (Wilson 0.381–0.555) | Same |
| PPV / NPV / accuracy | 0.643 / 0.919 / 0.713 (174 of 244) | Derived |
| AUROC from board margins | 0.837 (bootstrap 0.785–0.884; 2,000 resamples, seed 0) | Derived |
| **Test-set AUROC, 4,003 patients (headline)** | **0.8229 (0.8083–0.8379)** | Measured (manifest) |

![Board margins by RSNA class](docs/figures/fig_margins_by_class.png)

*Figure 7. Board margins on the 244 images by RSNA's three-way class
(Measured: margins from board run 1, classes from `manifest.json`). Dots are
images, boxes show the quartiles and median, and the dashed line is
T = −646. The Lung Opacity row is the 122 pneumonia cases.*

What the board shows about the model:

- **The errors are mostly false positives: 65 against 5.** That was the
  design choice: T was set on validation data for ≥90% sensitivity.
- **The five false negatives are near-misses.** Their margins are −736 to
  −670, all within 90 of T.
- **The false positives spread up to +1,928.** The median negative margin is
  −595.5, so 65 of the 122 negatives lie above T.
- **The "Not Normal" label explains much of it (Figure 7).** RSNA's negative
  class mixes "Normal" with "No Lung Opacity / Not Normal". The manifest
  records this three-way class for every verification image. 50 of the 76
  "Not Normal" negatives are flagged (65.8%), against 15 of the 46 "Normal"
  ones (32.6%) (Derived). Their median margins sit either side of T. On the
  full test set, pneumonia vs Normal scores AUROC 0.9363 and pneumonia vs Not
  Normal 0.7382 (Figure 2).
- **The 244 AUROC (0.837) is consistent with the test-set figure.** No
  overfitting is visible here. The repository's notebook has no saved
  training curves, so nothing more is claimed.

![Sensitivity and specificity vs threshold](docs/figures/fig_operating_characteristic.png)

*Figure 8. Sensitivity and specificity against the threshold, computed from
the 244 board margins (Derived). Filled dots mark T = −646 on these images
(0.959 / 0.467). Hollow diamonds mark the same T on the 4,003 test patients
(0.910 / 0.539; Measured, manifest). Illustrative only: T was fixed on
validation data, and these test images must not be used to move it.*

Moving T trades one error for the other. On the 244, T = 0 would give
sensitivity 0.779 and specificity 0.738 (Derived), but choosing T from test
data would make every number in this report optimistic.

![PPV and NPV vs prevalence](docs/figures/fig_ppv_npv_prevalence.png)

*Figure 9. What a flag means in deployment (Derived). PPV and NPV at the
test operating point (821 / 902 pneumonia cases flagged, 1,671 / 3,101
negatives cleared; `docs/audits/V1_audit_v1_2.md`), as disease prevalence
varies.*

PPV and NPV depend on how common pneumonia is where the device is used, so
the 244's own PPV (0.643) must not be quoted for deployment. The 244 are
balanced 50/50 by construction.
- **At the test set's 22.5% prevalence:** PPV 36.5%, NPV 95.4%.
- **At 5% prevalence:** PPV 9.4%, so about one flag in eleven is pneumonia,
  while NPV rises to 99.1%.

A FLASH "clear" is informative; a FLASH "flag" means "read this one first".

---

## 10. Case study: a bug only the board could show

**The symptom.** On 2026-10-08 the first V1.2 bitstream returned 0/244
bit-exact (Measured). Nothing else looked wrong:
- the logits correlated with the expected ones at 0.98;
- 234 of 244 decisions agreed;
- the result was the same at 25, 50 and 66.67 MHz, which ruled out timing;
- repeated runs, soft resets and different image orders gave identical
  outputs;
- the DMA reported no errors.

A test that compared decisions would have passed this hardware. **Only the
logit-level bit-exact comparison caught it.**

**Localising it offline.** Instead of guessing at the RTL, we treated the
golden model as an instrument and fed the board synthetic probes (Measured;
`docs/board_runs/2026-10-08/diag_1.json`):
- Constant images and a ramp that is constant along each row came back
  **exact**.
- A ramp along each row came back wrong.

That pointed at the order of pixels within a row. A search over candidate
corruptions found exactly one model that reproduces every board output: each
odd 32-bit word of the input (four pixels) is replaced by the even word before
it. Candidates included byte orders within a beat, row shifts, flips, block
reversals, beat permutations and padding variants.

`board == golden(dup_even(x))` holds on **244/244 images and 24/24 probes**
(Derived; `derived_numbers.json`). A 32-bit word pair never crosses a
224-pixel row, which is why the row-constant probes were immune.

![The AFI case study](docs/figures/fig_afi_case.png)

*Figure 10. Left: the failing run of 2026-10-08 against the expected margins
(Measured). The logits correlate at r = 0.98 and 234 of 244 decisions agree,
yet no image is bit-exact. Right: a crop of image 0 as sent and as the PL
received it (Derived from the dup_even model). The corruption works like a
mild horizontal blur, which the GAP network largely tolerates. That is why
the decisions looked right.*

**Predicting before checking.** The model and the golden model disagree on
only some probes. For the second probe set, the model's predictions were
written into the debug log before the board's results were looked at
(`diag_2.json` had not yet been copied off the board). Two single-pixel
probes discriminate: px(1,0) and px(223,223). The model predicted
(−349, 102, 451) and the const-0 result, where the golden model predicts the
const-0 result and (−386, 114, 500). The board's numbers matched the model's
predictions exactly (Measured; `diag_2.json`).

**The mechanism.** The DMA reads DDR through the PS's HP0 port. HP0 has a
bridge, the AFI, with its own data-width setting: bit 0 of the RDCHAN_CTRL
register.
- The V1.2 design used a 32-bit HP0.
- PYNQ boots the PS with the AFI in 64-bit mode and does not run the
  design's own PS initialisation code.
- Each 32-bit read therefore returned the low half of a 64-bit word, which is
  the even word.

**Confirmation by intervention.** On 2026-10-09, on one boot:
- The same 32-bit bitstream gave 0/244 (run 2).
- After writing that single register bit from 0 to 1, it gave 244/244
  (run 3).

Nothing else changed. That is a causal test, not a fit.

**The fix and the safeguard.** V1.2.1 makes HP0 and the DMA's memory side
64-bit, which matches PYNQ's default; no register write is needed (run 1:
244/244). Every board notebook now compares the AFI setting with the
bitstream's `.hwh` on load. The demo notebook refuses to run on a mismatch.

**Lessons for V2:**
- Simulation drove the stream directly and never modelled the PS memory
  path, so it could not see this fault. Either model the path or keep the
  board-side check.
- Compare integers on the board, never only decisions.
- Write predictions down before looking at the discriminating test.

The full record is [`docs/V1_board_debug_log.md`](docs/V1_board_debug_log.md).

---

## 11. The live demo

The demo notebook (`v1/board/flash_v1_2_demo.ipynb`, generated by
`make_demo_notebook.py`) runs from the board's folder with `flash_hp64_led`.
The executed copy is `docs/board_runs/2026-10-09/demo_flash_hp64_led_executed.ipynb`.

- **Load and checks.** It prints the bitstream SHA-256, VERSION and FCLK0. It
  checks the AFI against the `.hwh`, and on a mismatch it stops with "reboot
  the board and re-run". It never forces the register.
- **LED self-test.** LD0–LD3 on for 1 s, then both RGB LEDs red, green and
  blue (0.5 s each), then off.
- **Gallery.** The first six true positives and first six true negatives by
  index, chosen by a fixed rule stated in the notebook, not by hand. Each is
  run live on the FPGA and on the ARM golden model (Figure 6): 12/12
  bit-exact, mean 185.0 ms vs 706.6 ms (Measured).
- **Live sweep.** All 244 images with a running counter: 244/244 bit-exact,
  sensitivity 0.959, specificity 0.467, AUROC 0.8367 from the board's margins
  (Measured; 56.5 s including file loading).
- **Slider.** Any image, live. The board signals the decision:
  - pneumonia: LD0–LD3 blink at 4 Hz for 2.5 s with the RGB LEDs red;
  - negative: the RGB LEDs green for 1.5 s.
- **Limitations, shown rather than hidden.** The notebook ends with the first
  false positive and first false negative and states the operating-point
  trade-off.

![First false positive and false negative](docs/figures/fig_demo_errors_board.png)

*Figure 11. The demo's limitations cell (Measured): image 1, a negative with
margin +532, is flagged; image 61, a pneumonia case with margin −736, is
missed.*

---

## 12. Limitations

- **Not a medical device.** An AUROC of 0.82 on a research dataset is
  research grade. Clinical use would need prospective validation, comparison
  with radiologists, multiple sites and scanners, and regulatory work.
- **The model.** It has modest discrimination. Most of its false positives
  are abnormal-but-not-pneumonia studies, and part of its score comes from
  the AP/PA film type (Section 5).
- **Speed.** 66.67 MHz, not 75 MHz, and one MAC per clock, so 183 ms per
  image. A desktop CPU runs the same integer model faster.
- **Small-sample metrics.** The sensitivity and specificity measured on the
  board come from 244 images.

| Not yet done | Why it matters |
|---|---|
| Raspberry Pi–class comparison and an optimised ARM baseline | To state fairly what the FPGA adds. |
| External and paediatric data | Pneumonia deaths are concentrated in children; RSNA is adults from one source. |
| 75 MHz or faster | Needs the conv address path pipelined (V2). |
| Manifest hashes for all exported files | The audit found 3 of 313 `.mem` files hashed per stage. |

The full 4,003-image board run, measured power and DICOM on the board are
V2 future work (Section 13).

---

## 13. V2 future work

The project pauses after V1, and everything below is future work. Three
items would turn V1's software-side evidence into board-side evidence:

| V2 item | Why it is needed |
|---|---|
| Board run on all 4,003 test images | The 4,003-image accuracy is the golden model's. It is bit-exact to the board on 244 images, and a full board run would make it literally the board's output. |
| Measured board power | Power so far is only a Vivado estimate. |
| DICOM end to end on the board | DICOM preprocessing has only been verified on the PC. |

The full list, in priority order:

1. **A clinical operating point and better specificity.** This is the
   largest weakness, and the board data says where it comes from.
   - **Evidence:**
     - 65.8% of "Not Normal" negatives are flagged, against 32.6% of
       "Normal" ones;
     - test-set AUROC is 0.9363 against Normal but 0.7382 against Not Normal;
     - the AP/PA view alone scores 0.7064.
   - **Work:** treat "No Lung Opacity / Not Normal" explicitly (three-way
     training, or a separate abnormal output); report and select per view;
     choose T on validation data for a stated specificity as well as
     sensitivity.
   - **Why first:** it changes what the device is useful for, and it needs
     no hardware change, because T is a register.
2. **Parallel MACs.**
   - **Evidence:** only 14 of 220 DSP slices are used.
   - **Work:** several MACs per clock, which needs wider or parallel
     feature-map reads, because the engine currently reads one byte per
     clock. `line_buffer_v1` is built and tested for this.
   - **Why:** latency falls roughly in proportion; this is the step that
     makes the FPGA genuinely fast. Figure 12 projects it from the measured
     cycle count. At 16 MACs per clock the compute time would be 11.5 ms at
     66.67 MHz and 10.2 ms at 75 MHz (Derived projection). That is still not
     faster than the desktop PC's 8.7 ms, so V2's case for the FPGA must rest
     on power, determinism and cost rather than speed alone.

   ![V2 projection](docs/figures/fig_v2_projection.png)

   *Figure 12. Derived projection: compute latency against MACs per clock,
   from the measured 12,196,126 cycles. Assumptions: the MAC cycles scale
   ideally, the 3,230 non-MAC cycles stay fixed, and memory bandwidth keeps
   up (k MACs per clock need k activation bytes per clock). 75 MHz assumes
   the address path is pipelined. Host overhead (about 1.8 ms) is not
   included.*
3. **Pipeline the convolution address path, for ≥75 MHz.**
   - **Evidence:** this path is the post-route critical path; at 75 MHz the
     measured cycle count would give 162.62 ms (Derived).
   - **Why:** a cheap, local change with a direct speed gain.
4. **Measured board power** (table above). **Work:** an inline USB meter,
   idle and running, plus a SAIF-based estimate from post-implementation
   simulation. Low power is half of the case for an FPGA.
5. **A board run on all 4,003 test images** (table above). **Work:** export
   the test images and run them through the existing notebook: about 12
   minutes of compute at 182.94 ms each (Derived), plus file transfer.
6. **DICOM end to end on the board** (table above).
   - **Feasibility:** the manifest records the RSNA patient ID of every
     verification image, so matching DICOM files can be fetched.
     `flash_preprocess.py` needs pydicom and OpenCV, and whether PYNQ 3.1.1
     provides both offline is not yet checked.
   - **Work:** preprocess on the ARM, run on the FPGA, and assert equality
     with `exp_*` for that index.

---

## 14. Reproducibility

**Tools.** Vivado 2022.2; PYNQ 3.1.1 on the PYNQ-Z2. Training ran in Colab
with torch 2.11.0+cu128, NumPy 2.1.3, pydicom 3.0.2 and OpenCV 5.0.0
(manifest). The figures were made with Python 3.13.9 and NumPy 2.3.5.

| Step | Command (from the repository root) |
|---|---|
| Train and export | Run `colab/ProjectFlash_V1.ipynb` (`STAGE = 'V1.2'`, `SEED = 0`); unzip the export into `v1/mem/v1_2/flash_v1_2/` |
| RTL simulation, wrapper | `v1\scripts\sim_tb_v1_axi.bat` → `RESULT: PASS` |
| Synthesis of `top_v1` alone | `vivado -mode batch -source v1/scripts/synth_top_v1.tcl` |
| Block design, implementation, bitstream | `vivado -mode batch -source v1/scripts/build_hw.tcl -tclargs verilog/ProjectFlashV1_hw/ProjectFlashV1_hw.xpr 70.0 flash_hp64` (add `flash_hp64_led 1` for the LED build) |
| Notebooks | `python v1/board/make_notebook.py v1/board/flash_v1_2_board.ipynb 66.666672 top_v1_axi_0 axi_dma_0`; `python v1/board/make_demo_notebook.py v1/board/flash_v1_2_demo.ipynb` |
| Board bundle | `powershell -ExecutionPolicy Bypass -File v1\board\make_board_bundle.ps1` (263 files) |
| Board run | `v1/board/README.md`, sections 5–6 |
| Report figures and derived numbers | `python tools/time_golden_pc.py` then `python tools/make_report_figures.py` (also writes the paper's PDF figures to `paper/figures/`) |
| Paper | in `paper/`: `pdflatex flash_v1`, `bibtex flash_v1`, then `pdflatex flash_v1` twice |

**Artefacts (SHA-256 prefixes).**

| File | SHA-256 |
|---|---|
| `v1/board/flash_hp64.bit` / `.hwh` | `0ee58d6c924cd162` / `7011237c69968c86` |
| `v1/board/flash_hp64_led.bit` / `.hwh` | `7e0c3394fac1b57d` / `2b37db60135ed638` |
| `v1/board/flash_hp32.bit` / `.hwh` | `396a219b10690f26` / `5f8c18af7bdf3650` |
| `v1/mem/v1_2/flash_v1_2/vectors/img_0.mem` | `b646ab2d4af88b2e` |
| `v1/mem/v1_2/flash_v1_2/vectors/exp_logit0.mem` | `0d317dcf865a5210` |

`.gitattributes` keeps the bitstreams, the `.hwh` files and all board
evidence byte for byte, so these hashes hold on any checkout. The evidence
files and their hashes are listed in each `docs/board_runs/<date>/README.md`.

**Tags.** `v1.2.1-hw` marks this report and the verified V1.2.1 hardware.
The heavy verification vectors (244 images, 60 traces) are not in git. They
are regenerated by the notebook with the same seed and are also inside the
board bundle.

---

## 15. Resuming the project

For whoever restarts this later:

1. **Read first:** this report, then
   [`docs/V1_board_results_v1_2.md`](docs/V1_board_results_v1_2.md) and
   [`docs/V1_board_debug_log.md`](docs/V1_board_debug_log.md).
   [`docs/README.md`](docs/README.md) indexes everything else.
2. **Vivado project:** `verilog/ProjectFlashV1_hw/ProjectFlashV1_hw.xpr` is
   the only one to use. It is local and gitignored, and it is rebuilt from
   the repository by `v1/scripts/build_hw.tcl`. `ProjectFlashV1` is legacy:
   bare `top_v1`, which cannot be implemented. See `verilog/README.md`.
   Vivado 2022.2.
3. **Rebuild the hardware:** close the project in the GUI, then run
   `build_hw.tcl` as in Section 14. The default FCLK ceiling (70 MHz) gives
   the verified 66.666672 MHz. Check that every `runme.log` shows
   `Synth 8-3876` for the three v1_2 `.mem` files and no `8-4445`. The scripts
   copy the `.bit`/`.hwh` into `v1/board/` and the reports into
   `docs/reports/impl/`.
4. **Run the board:** build the bundle, copy it to
   `\\192.168.2.99\xilinx\jupyter_notebooks\flash_v1_2\`, boot fresh, and run
   `flash_v1_2_board.ipynb` with `flash_hp64.bit`. Expect AFI OK and
   244/244. The demo is `flash_v1_2_demo.ipynb`. Full steps:
   `v1/board/README.md`.
5. **Where the evidence lives:** `docs/board_runs/<date>/`, with one README
   per session listing SHA-256s. Never edit those files. Add a new dated
   folder for every new session, and note the real date there, because the
   board clock is unset.
6. **Golden model:** `v1/mem/v1_2/flash_v1_2/tools/golden_model_v1.py`. The v0
   one is `v0_baseline/tools/golden_model.py`.
7. **The first three V2 tasks:**
   1. Specificity: three-way training or an abnormal output, a per-view
      analysis, and T chosen on validation for a stated specificity
      (Section 13, item 1).
   2. Pipeline the convolution address path and re-close timing at 75 MHz
      or above.
   3. Parallel MACs in `conv_engine`, using the spare DSP slices.

   Re-verify 244/244 on the board after every change, and compare logits,
   not decisions.
