# Project FLASH — Project Brief, Technical Framework & Research Roadmap

Sep 29, 2026 · @Karthik

## 0. How to read this document

This is the long-form brief of Project FLASH, written so a professor can judge whether it is paper-worthy and so a newcomer can follow every term. It is deliberately exhaustive; a later pass will condense it to a 10-page printout.

**Who it is for.** Three readers: (1) the supervising professor, who needs the claims, the evidence and the gaps; (2) a newcomer to FPGA or machine learning, who needs every concept explained from scratch; (3) the editor or agent who will condense this into 10 pages, who needs to know which parts are load-bearing.

**Evidence labels used throughout.** Every number in this document carries one of four labels, because the project's earlier material mixed them up.

| Label | Meaning | Example |
| --- | --- | --- |
| MEASURED | Produced by a tool run on the current RTL and reproducible from the repository | 244/244 bit-exact logits in XSim |
| SYNTH-ESTIMATE | Reported by Vivado after synthesis only, before placement and routing | 2,006 LUTs at 224×224 |
| LEGACY | Reported in the hackathon deck on an older, since-corrected datapath; not to be quoted in a paper | 95.4% balanced accuracy, 35.9 W, 231 µs |
| PENDING | Planned, not yet run | post-implementation timing, SAIF-based power, on-board V1 latency |

**Sources.** The hackathon deck (AMD FPGA Hackathon 2026, 5th place), the project prep document and elevator pitch, `V0_SUMMARY.md`, `V1_synth_results_v1_1.md`, `V1_synth_results_v1_2.md`, the public repository [Karthik-Flash/ProjectFlash](https://github.com/Karthik-Flash/ProjectFlash), and external literature cited in the References section.

**Guidance for the condensing pass.** Sections 1, 5, 7, 8, 9, 12 and 14 carry the argument and should survive in some form. Section 3 (primer) and Section 17 (glossary) can be cut to an appendix or a single page. Section 11 (competitors) can shrink to one table. Section 9 (corrections) must not be dropped: it protects the team from a reviewer finding the same problems.

## 1. Executive summary

Project FLASH is a chest X-ray pneumonia screener whose entire neural network runs as hand-written Verilog on a low-cost AMD/Xilinx Zynq-7020 chip, with no internet and no GPU. Its strongest result today is not accuracy but correctness: the hardware reproduces the trained integer network bit for bit, and every number reported about the model is a number the chip will actually compute.

**Where it started.** Team FLASH (Karthikeya Reddy, ML; Yashwant Rajesh, architecture; BITS Pilani Hyderabad) placed 5th in the AMD FPGA Hackathon 2026 with a 28×28-pixel pneumonia classifier on a PYNQ-Z2 board. The hackathon version (called V0–V4 in the deck) worked end to end on the board, with the ARM processor loading an image and the FPGA returning a decision.

**What the post-hackathon audit found.** Rebuilding the design against a bit-exact software reference exposed five defects: three in the datapath (a misaligned 3×3 window, a max-pool read two cycles late, an FC read pointer off by one) and two in the testbench that hid them. The hackathon's headline 95.4% balanced accuracy was a Python number that the hardware could never have produced. After the fixes, the corrected design ("v0") matches the reference on 244 of 244 test images at the level of 32-bit output scores, at an honest 84.7% balanced accuracy.

**What V1 is.** V1 replaces the fixed 28×28 design with a general engine that reads the network's shape from a small table in memory. One convolution engine is reused for five layers, followed by global average pooling and a 64→2 classifier: 47,602 INT8 parameters, all stored on-chip. It adds a programmable decision threshold so clinicians can trade sensitivity against specificity without retraining. It is trained on the RSNA Pneumonia Detection dataset (26,684 adult patients, radiologist labels, real DICOM files), split by patient.

**Current numbers (V1.2, 224×224).**

| Quantity | Value | Status |
| --- | --- | --- |
| Test AUROC (4,003 patients) | 0.823 (95% CI 0.808–0.838) | MEASURED (golden model = hardware arithmetic) |
| Sensitivity / specificity at threshold fixed on validation | 91.0% / 53.9% | MEASURED |
| Opacity-vs-Normal AUROC (easy sub-task) | 0.936 | MEASURED |
| Clock / timing | 75 MHz, +0.085 ns slack, 0 failing paths | SYNTH-ESTIMATE |
| Resources | 2,006 LUT (3.8%), 2,840 FF, 14 DSP, 80 BRAM36 (57%) | SYNTH-ESTIMATE |
| RTL vs golden model | 16/16 images bit-exact (smoke sweep) | MEASURED, gate of 244 not yet run |
| Compute per image | 12.19 M multiply-accumulates ≈ 163 ms at 1 MAC/cycle | DERIVED, not measured |
| On-board run, power, post-route timing | — | PENDING (needs AXI wrapper) |

**What is not yet true.** V1 has not run on the board. Power has not been measured for V1. The model has only been tested on one public dataset of adults, while the pitch is about children in rural India. Specificity at the screening operating point is low (about 46% of healthy patients would be flagged). None of this blocks a hardware paper, but all of it blocks a clinical claim.

**Recommendation in one paragraph.** Publish first, patent later if ever. The accelerator's building blocks (INT8 convolution engines on Zynq) are well covered by prior art, and the hackathon deck and public GitHub repository have already disclosed the design, which weakens any patent in India and most other countries. The publishable contribution is a verification-first methodology for hand-written CNN accelerators, demonstrated on a medical task with clinically honest evaluation. Target a short paper at an FPGA venue (for example FPL, FPT, ARC or VLSID) within the next six months, and a journal version once the design runs on the board and has external validation. Section 14 gives the full reasoning and the procedures.

## 2. Problem statement and motivation

Pneumonia is treatable, but in places without a radiologist the chest X-ray that would confirm it often goes unread for hours or days. FLASH aims to give such facilities an instant, offline first-pass read.

### 2.1 The disease burden

Pneumonia is an infection in which the lungs' air sacs (alveoli) fill with fluid or pus, making breathing painful and reducing oxygen intake. The WHO reports that pneumonia killed 740,180 children under five in 2019, 14% of all deaths in that age group, and that it is the single largest infectious cause of death in children worldwide ([WHO fact sheet](https://www.who.int/en/news-room/fact-sheets/detail/pneumonia)). Deaths are highest in southern Asia and sub-Saharan Africa. Across all ages, pneumonia killed about 2.5 million people in 2019 ([Medical Dialogues, World Pneumonia Day 2021](https://medicaldialogues.in/photo-stories/world-pneumonia-day-2021-46)).

Note for the paper: the hackathon deck merged these two figures into "2.5 million deaths … in children under five". The correct statement is 2.5 million deaths at all ages and about 0.74 million in children under five. Section 9 lists this and other corrections.

### 2.2 The radiologist gap

India has roughly 20,000–22,000 practising radiologists for about 1.4 billion people, which is close to one per 100,000 people, and most of them work in large cities ([5C Network industry brief, May 2026](https://www.5cnetwork.com/resources/radiologist-shortage-india); [Radiology Today, Aug 2024](https://radiologytoday.net/enewsletter/2024/august)). Europe is cited at about 13 per 100,000 and the UK at about 9 per 100,000 in the same source. The WHO estimate that roughly two-thirds of the world lacks access to basic diagnostic imaging is widely cited (for example by Mariani et al., 2017, in the project's prep references).

A radiologist ratio alone overstates FLASH's addressable need, because many rural facilities lack the X-ray machine itself, not only the reader. The realistic deployment point is a facility that has an X-ray unit but no on-site radiologist: a community health centre, a sub-district or district hospital, a private rural clinic, or a mobile screening van.

### 2.3 Why offline, and why at the edge

Most commercial chest X-ray AI today runs in the cloud or on a hospital server. That model has three weaknesses in the target setting.

1. **Connectivity.** Upload of a full-resolution DICOM (typically 5–30 MB) over a weak rural link can take minutes or fail. An offline device works regardless of the network.
2. **Privacy.** Sending patient images to a remote server creates a data-protection obligation. In India this now falls under the Digital Personal Data Protection Act, 2023. An offline device keeps the image in the room.
3. **Cost and dependency.** Cloud AI is priced per scan or per subscription and depends on the vendor staying online. A one-time device has no recurring cost.

The hackathon deck framed the latency advantage as "cloud takes 200–500 ms". That argument is weak on its own: no clinical decision changes between 50 ms and 500 ms. The honest argument is availability (it works with no network), privacy (the image never leaves) and cost (no per-scan fee), with latency a side benefit.

### 2.4 Why an FPGA rather than a phone or a Raspberry Pi

A reviewer will ask this first, so the paper must answer it directly. A modern phone or a small single-board computer can already run a small CNN offline. The case for an FPGA rests on four properties, and the paper should claim only those that are measured.

| Property | What it means | FLASH evidence today |
| --- | --- | --- |
| Bit-exact determinism | The same image always gives the same 32-bit score, provably equal to the validated model | Demonstrated (v0: 244/244; V1: 16/16 and 4,003/4,003 golden-vs-training) |
| Low, predictable power | Only the logic that is needed toggles; no operating system in the inference path | v0: 0.116 W total on-chip from a simulation activity file; V1 not yet measured |
| Long product life and auditability | The hardware function is fixed and inspectable, which suits a regulated medical device | Argument only |
| Integration next to the detector | An FPGA can sit inside imaging equipment and process pixels as they stream | Future work |

If the V1 board measurement does not show a clear power or cost advantage over, for example, a phone-class processor running the same INT8 model, the paper should lead with determinism and verifiability rather than speed or energy.

## 3. Primer for newcomers

This section explains every concept the rest of the document uses, assuming no background in machine learning or chip design. A reader who already knows a topic can skip its subsection.

### 3.1 A chest X-ray is a grid of numbers

An X-ray passes through the body and darkens a detector where it is not absorbed. Air in healthy lungs absorbs little, so lungs look dark; bone and fluid absorb more, so they look bright. In pneumonia, fluid in the air sacs shows up as a hazy bright patch called an **opacity** or **consolidation**.

A digital X-ray is stored as a grid of **pixels**, each a number for brightness. Hospital scanners store 10–16 bits per pixel (thousands of grey levels) inside a **DICOM** file, the medical imaging standard, which also carries patient and scanner information. Before a model sees it, the image is converted to 8 bits per pixel (0 = black, 255 = white) and resized, for example to 224×224 = 50,176 pixels. FLASH V1's preprocessing follows the DICOM standard's own steps (rescale, windowing, inversion for "MONOCHROME1" images, letterboxing so the image is not stretched) and is tested on real scanner files.

### 3.2 Machine learning in one page

A **model** is a function with many adjustable numbers, called **parameters** or **weights**. **Training** shows the model thousands of labelled examples (image → "pneumonia" or "normal") and nudges the weights to reduce a **loss**, a number measuring how wrong the predictions are. One pass through all training images is an **epoch**.

Data is split three ways, and keeping them separate is the most important discipline in the field:

- **Training set**: used to adjust the weights.
- **Validation set**: used to choose settings (when to stop, which threshold), never to adjust weights directly.
- **Test set**: touched once, at the end, to report performance. Anything tuned on it is no longer an honest estimate.

For medical images the split must be **by patient**, so that two images of the same person never land on both sides.

### 3.3 A neuron and a network

A single artificial neuron multiplies each input by a weight, adds them up, adds a **bias**, and passes the result through an **activation function**. FLASH uses **ReLU** (rectified linear unit): negative values become 0, positive values pass unchanged. A **neural network** stacks many neurons in **layers**; the output of one layer is the input of the next.

The final layer produces one raw score per class, called a **logit**. With two classes, FLASH computes a **margin** = logit(pneumonia) − logit(normal). If the margin exceeds a **threshold** T, the image is flagged positive.

### 3.4 What a convolutional neural network (CNN) does

A plain network would connect every pixel to every neuron, which wastes parameters and ignores the fact that nearby pixels belong together. A **CNN** instead slides a small grid of weights, a **filter** or **kernel** (FLASH uses 3×3), across the image. At each position it multiplies the 9 pixels under it by the 9 weights and adds them. This operation is a **convolution**.

Worked example. Take a 3×3 patch of pixels and a filter that detects a dark-to-bright change from left to right:

| Pixel patch | Filter weights | Product |
| --- | --- | --- |
| 10 · 20 · 30 | −1 · 0 · +1 | −10 · 0 · +30 |
| 40 · 50 · 60 | −1 · 0 · +1 | −40 · 0 · +60 |
| 70 · 80 · 90 | −1 · 0 · +1 | −70 · 0 · +90 |

The nine products sum to 60. Adding a bias of 5 gives 65; ReLU leaves it at 65. A large output means "there is a left-to-right brightening here". Sliding the filter over every position produces a new grid called a **feature map**. Each filter learns to detect one pattern; a layer with 8 filters produces 8 feature maps, or 8 **channels**.

Key vocabulary:

- **Padding**: a border of zeros around the image so the filter can sit on edge pixels. FLASH pads by 1.
- **Stride**: how far the filter jumps between positions. Stride 2 halves the width and height of the output, so a 224×224 input becomes 112×112.
- **Pooling**: shrinking a feature map. **Max-pooling** keeps the largest value in each 2×2 block (used in v0). **Global average pooling (GAP)** averages each whole channel down to one number (used in V1).
- **Fully connected (FC) or dense layer**: every input connected to every output, used at the end to turn features into the two logits.
- **Multiply-accumulate (MAC)**: one multiplication plus one addition, the basic unit of CNN work. V1.2 needs 12.19 million MACs per image.

Why stacking works: early layers find edges and textures, middle layers combine them into shapes such as rib borders or hazy regions, and late layers respond to whole-image patterns such as "a dense patch in the lower right lung".

### 3.5 Quantization: from decimals to 8-bit integers

Training normally uses 32-bit floating-point numbers (decimals such as 0.3471). Floating-point arithmetic is expensive in hardware. **Quantization** replaces them with small integers, here **INT8** (−128 to 127) for weights and **UINT8** (0 to 255) for activations. An 8-bit multiplier is many times smaller and cheaper than a 32-bit floating-point one.

Rounding weights after training usually costs accuracy. **Quantization-aware training (QAT)** rounds during training, so the network learns to tolerate it. Rounding has no useful gradient, so training uses a **straight-through estimator (STE)**: the forward pass rounds, the backward pass pretends it did not. FLASH goes one step further and trains **directly in integer units**: the parameters are the integers the chip stores, so export has no scale factors to get wrong.

Between layers, sums grow large (a 22-bit accumulator in V1). FLASH brings them back to 8 bits by an **arithmetic right shift** (dividing by a power of two, which in hardware is just rewiring) and a **clamp** to 0–255, which also acts as ReLU.

### 3.6 How to read the accuracy numbers

| Metric | Plain meaning | Why it matters here |
| --- | --- | --- |
| Sensitivity (recall) | Of the sick patients, the share flagged | A screener must not miss pneumonia |
| Specificity | Of the healthy patients, the share cleared | Low specificity floods the referral queue |
| PPV (precision) | Of the flagged patients, the share truly sick | Depends heavily on how common the disease is |
| NPV | Of the cleared patients, the share truly healthy | The "rule-out" value of a screener |
| Balanced accuracy | Average of sensitivity and specificity | Used in v0; hides the trade-off |
| AUROC | Probability that a random sick patient scores higher than a random healthy one; 0.5 = coin toss, 1.0 = perfect | Threshold-free; the standard headline for medical classifiers |
| 95% confidence interval | Range the true value likely lies in, given sample size | Shows whether a difference is real or noise |

### 3.7 What an FPGA is

A CPU runs a program one instruction at a time on fixed circuitry. An **FPGA** (field-programmable gate array) is a chip of blank logic whose wiring you define, so you build the exact circuit the task needs and all of it runs in parallel on every clock tick. It can be rewired by loading a new configuration file, the **bitstream**. Its main resources:

| Resource | What it is | Zynq-7020 count |
| --- | --- | --- |
| LUT (look-up table) | A tiny programmable truth table; the basic logic gate | 53,200 |
| FF (flip-flop) | A 1-bit memory cell that updates on each clock tick | 106,400 |
| DSP48E1 slice | A hard-wired multiplier-adder block, ideal for MACs | 220 |
| BRAM36 | A 36-kilobit on-chip memory block | 140 (about 630 KB total) |

The **clock** sets the pace; FLASH runs at 75 MHz, so one tick is 13.33 ns. **Timing slack** is how much spare time the slowest signal path has within one tick; positive slack means the design meets its clock.

### 3.8 How a design becomes a circuit

1. **RTL (register-transfer level) design**: the circuit is described in a hardware language, here **Verilog**. It says what is stored in registers and how values move between them each clock tick.
2. **Simulation**: the Verilog runs in software (Vivado XSim, Icarus Verilog) with a **testbench** that feeds inputs and checks outputs. This is where bit-exactness is proven.
3. **Synthesis**: the tool converts Verilog into a netlist of LUTs, FFs, DSPs and BRAMs and gives a first estimate of size and speed.
4. **Implementation (place and route)**: the tool assigns every element a physical location and wires them. Only now are timing and resources final.
5. **Bitstream generation**: the configuration file is produced and loaded onto the board.

FLASH V1 has completed steps 1–3. Step 4 requires an interface wrapper (Section 7).

### 3.9 The Zynq: a processor and an FPGA on one chip (PS and PL)

The PYNQ-Z2 board carries an AMD/Xilinx **Zynq-7020** chip, which contains two halves:

- **PS (Processing System)**: two ARM Cortex-A9 processor cores running Linux, plus the DDR memory controller, USB, Ethernet and SD card. It runs ordinary software such as Python.
- **PL (Programmable Logic)**: the FPGA fabric, where FLASH's accelerator lives.

They talk over **AXI** (Advanced eXtensible Interface), ARM's standard on-chip bus:

- **AXI-Lite**: slow, register-style access. The PS writes a control word ("start", "threshold = −646") or reads a result ("margin = 312").
- **AXI-Stream**: a one-way flow of data words with a valid/ready handshake, suited to streaming pixels.
- **AXI-DMA**: a helper block that copies a buffer from DDR memory into an AXI-Stream without the CPU touching each byte.

**PYNQ** is AMD's Python framework that lets a Jupyter notebook on the ARM load a bitstream and talk to PL blocks. In the hackathon demo, the PS decoded and resized the image, DMA streamed it into the PL, the PL computed the result, and Python read it back.

The division of labour is deliberate: the PS does the irregular work (file decoding, DICOM handling, user interface) and the PL does the regular, heavy arithmetic (all CNN layers).

## 4. Project history: from hackathon to a verified baseline

The project went through nine design iterations in three phases: five hackathon versions that made the chip work, one audit that made it correct, and three V1 stages that made it general. The naming is confusing because the hackathon versions were called V0–V4 and the post-hackathon ones reuse "v0" and "V1"; this document writes the hackathon ones as **H-V0 … H-V4** to keep them apart.

### 4.1 Version log (newest first)

| Version | Phase | What changed | What it taught |
| --- | --- | --- | --- |
| V1.2 | Post-hackathon | Same RTL as V1.1, run at 224×224 on RSNA; synthesised at 75 MHz, 80 BRAM36 | The engine scales 28→224 by changing only data files |
| V1.1 | Post-hackathon | New architecture (5 strided convs + GAP + FC, layer-descriptor ROM, threshold register) on RSNA at 28×28 | Isolates new-dataset bugs from new-RTL bugs |
| v0 baseline | Post-hackathon audit | Golden model written first; 5 defects found and fixed; 244-image logit-level sweep | The hardware had never computed what the model computed |
| H-V4 | Hackathon | Accelerator placed behind AXI on the Zynq; ARM loads a 784-byte image, DMA streams it, FPGA returns a bit; 231 µs reported | End-to-end board demo works |
| H-V3 | Hackathon | Simulation passes 5/8 hand-picked tests; failures blamed on "model mismatch at row boundary" | The row-boundary failures were in fact the line-buffer bug |
| H-V2 | Hackathon | MAC pipeline clock-enabled only during convolution; vectorless power estimate fell from 35.9 W to 7.2 W | Vectorless power numbers are not measurements |
| H-V1 | Hackathon | Pool outputs shifted right by 8; FC bus widened to 512 bits; logits widened to 32 bits | Overflow in integer pipelines is silent |
| H-V0 | Hackathon | Feature maps held in a 62,720-flip-flop register array; placement failed; moved to BRAM with `(* ram_style = "block" *)` | Large arrays must live in block RAM |

### 4.2 What the hackathon version got right

- It ran the full CNN in synthesised logic on the PL, with the ARM only moving data, and showed a working board demo.
- It trained with quantization-aware training and exported INT8 weights as `.mem` hex files loaded by Verilog's `$readmemh`, which is a clean, reproducible hand-off.
- It found and fixed real physical-design problems (the flip-flop array that could not be placed, overflow, bus truncation).

### 4.3 What the audit found wrong

The post-hackathon rebuild started by writing a NumPy **golden model**: an integer-exact reference that computes exactly what the hardware should compute. It then dumped every intermediate tensor out of the simulator and compared them in Python. Five defects appeared that five hackathon versions had not caught.

| # | Module | Defect | Effect |
| --- | --- | --- | --- |
| 1 | `line_buffer.v` | Bottom-right tap of the 3×3 window read a location not yet written for the current row | All 784 windows had one wrong pixel |
| 1b | `line_buffer.v` | Window centred one row too early | Image row 27 was never convolved; the whole feature map shifted up by one row |
| 2 | `top_accelerator.v` | Max-pool captured BRAM data one cycle early (read latency is two cycles) | Pool inputs shifted; one of four values never read; comparator saw the previous window |
| 3 | `fc_layer.v` | FC1 read pointer off by one; FSM also re-triggered itself | Input 783 never read, input 1 used twice; a full 12,544-cycle pass re-ran silently |
| 4 | `tb_top.v` | Stimulus driven on the same clock edge the design samples | The first image after reset could miss its start pulse |
| 5 | `tb_top.v` | Decision sampled one cycle before it updated | The testbench read the previous image's answer |

The root cause behind all five: the old testbench checked a single decision bit on eight images, and those eight had been pre-filtered to cases where the model was very confident (>20% margin). A confident model gives the right bit even when the arithmetic is wrong, so the bugs were invisible. This is the central lesson and becomes the paper's methodology contribution (Section 8).

### 4.4 Consequence for the hackathon numbers

The hackathon's 95.4% balanced accuracy, its 231 µs latency and its board demo all ran on the defective datapath. They describe a circuit that has since been corrected. None of them should appear in a paper as a result of the current design; Section 9 lists each one with its replacement.

## 5. The v0 baseline (28×28, PneumoniaMNIST)

v0 is a small, fixed-shape CNN whose only purpose is to prove the datapath is arithmetically correct; it is closed and bit-exact on 244 of 244 test images at 84.7% balanced accuracy.

### 5.1 Dataset

**PneumoniaMNIST** is part of the MedMNIST benchmark collection. It is derived from the pediatric chest X-ray set of Kermany et al. (2018), collected at a children's hospital in Guangzhou, China, and downsampled to 28×28 grey pixels. It contains 5,856 images split 4,708 train, 524 validation, 624 test, with roughly 2.9 pneumonia images per normal image in training.

Two properties matter for the paper. First, 28×28 is far below clinical resolution; at that size a pixel spans a large block of lung, so fine texture is lost. Second, the official validation split comes from the same pool as training, while the test split is a separately held-out set. v0 measured the consequence: a longer training run reached 96.7% balanced accuracy on validation but only 82.1% on test, with specificity collapsing by 29 points. Selecting the best epoch on validation was selecting on the wrong distribution.

### 5.2 Network

| Layer | Operation | Input | Output | Parameters |
| --- | --- | --- | --- | --- |
| Conv2D + ReLU | 4 filters, 3×3, pad 1 | 1×28×28 | 4×28×28 | 36 + 4 |
| MaxPool2D | 2×2, stride 2, then right shift by 8 | 4×28×28 | 4×14×14 | 0 |
| Flatten | channel-major | 4×14×14 | 784 | 0 |
| FC1 + ReLU | dense | 784 | 16 | 12,544 + 16 |
| FC2 | dense, logits | 16 | 2 | 32 + 2 |
| Argmax | logit1 > logit0 | 2 | 1 bit | 0 |

Total: 12,634 INT8 parameters. Note that 99.3% of them sit in FC1, whose size is tied to the image size. This is the design flaw V1 removes.

### 5.3 Training and export

The hackathon version trained in 32-bit floating point with focal loss (a loss that down-weights easy examples) and class weights (3.88× for Normal) to counter class imbalance, then ran 50 epochs of quantization-aware training, folded batch normalisation into the convolution bias, and scaled weights to ±127.

The v0 notebook replaces this with training **directly in INT8 units**: the trainable parameters are the integers, clipped to \[−127, 127\] after each step, with straight-through rounding switched on partway through. Export is then simply round-and-clamp, with no scale factors, and the NumPy golden model is the trained model exactly. The notebook generates the weights, 244 zero-padded 30×30 test images and their expected 32-bit logits in one run; nothing the RTL consumes is written by hand.

### 5.4 Hardware modules

Seven Verilog modules on the PL:

- `line_buffer.v`: turns a stream of pixels (one per clock) into 3×3 windows using two row stores. After the fix it receives a pre-padded 30×30 frame and emits exactly 784 valid windows, bit-identical to PyTorch's `Conv2d(padding=1)`.
- `mac_unit.v`: 8-bit × 8-bit multiply with a 20-bit accumulator; four in parallel, one per filter.
- `relu.v`: checks the sign bit; negative becomes zero.
- `max_pool.v`: a 2×2 comparator tree, driven by an explicit 8-state read sequencer after the fix.
- `fc_layer.v`: a parameterised dense layer used for FC1 (784→16) and FC2 (16→2), one MAC per cycle.
- `fsm_control.v`: the master state machine that sequences convolution, pooling and the dense layers.
- `top_accelerator.v`: integration, feature-map BRAMs and the decision output.

### 5.5 Results

| Check | Result | Status |
| --- | --- | --- |
| Logits vs golden model, 244 images | 244/244 bit-exact | MEASURED |
| Conv feature map / pooled tensor / FC1 outputs vs golden | 0 mismatches of 3,136 / 784 / 16 | MEASURED |
| Conv accumulator range over full test set | −41,632 to 85,317 (6.1× headroom in 20 bits) | MEASURED |
| Post-implementation timing at 75 MHz | +0.290 ns setup slack, 0 of 3,173 endpoints failing, about 83.7 MHz achievable | MEASURED (implementation) |
| Total on-chip power | 0.116 W (0.105 W static, 0.011 W dynamic), medium confidence, activity from simulation | MEASURED (SAIF-based estimate) |
| Balanced accuracy / specificity / sensitivity (INT8, test) | 84.7% / 73.9% / 95.4% | MEASURED |

The 244 images are the first 122 normal and first 122 pneumonia test images, shuffled with a fixed seed and not filtered by confidence. The model gets 46 of them wrong on purpose: the hardware must reproduce the model **including its mistakes**, because a matching 32-bit score cannot happen by accident while a matching yes/no bit can.

### 5.6 What v0 hands to V1

1. A golden model written before the RTL, not after.
2. A regression harness that compares every intermediate tensor, so a mismatch points to a layer.
3. A padding-free line buffer parameterised by width.
4. Accumulator widths measured over whole datasets rather than estimated by hand.
5. A clean separation of two claims that had been tangled: "the hardware is correct" and "the model is accurate".
6. Two lessons for the model: choose operating points on data drawn from the same distribution as the test set, and build a threshold knob into the hardware because v0's argmax could not be tuned after training.

## 6. One chest X-ray, end to end

The ARM processor only decodes, resizes and moves the image; every multiplication of the neural network happens in the FPGA fabric, and only three numbers and one flag come back.

&#91;embedded content: V1.2 data path · PS prepares, PL computes, PS reports\]

The numbered boxes follow one image through V1.2. Steps 1–3 and 9 run as software on the PS; steps 4–8 are hardware on the PL.

### 6.1 Step by step

1. **Read the X-ray.** A DICOM file arrives from a USB stick, an SD card or the X-ray console. In a future standalone device the image could come straight from the detector.
2. **Preprocess (PS).** The standard DICOM grayscale pipeline runs in Python or C: stored values are rescaled, windowed to what a radiologist would see, inverted if the file is MONOCHROME1 (white-is-zero), letterboxed so the chest is not stretched, and resized to 224×224 unsigned 8-bit pixels. This exact function is exported from the training notebook, so the board sees the same pixels as training did.
3. **Hand off (PS → PL).** The 50,176-byte image is placed in DDR memory. The PS writes the decision threshold T (default −646 at 224) and a start command through AXI-Lite registers, and an AXI-DMA engine streams the pixels into the PL one byte per clock.
4. **Buffer the image (PL).** The pixels land in feature-map buffer A. Buffers A and B (128 KB each, in block RAM) take turns: each layer reads one and writes the other.
5. **Five convolution layers on one engine (PL).** The sequencer reads the first 128-bit word of the layer table (conv1: 1→8 channels, 224→112, shift 7) and starts the convolution engine. For every output position and channel the engine fetches 9 pixels per input channel and 9 weights, multiplies and adds them into a 22-bit accumulator starting from the bias, then shifts right and clamps to 0–255. conv1 alone produces 8×112×112 = 100,352 bytes in buffer B. The sequencer then loads the next word and repeats until conv5 leaves 64 channels of 7×7.
6. **Global average pool (PL).** 64 running sums, one per channel, each divided by 64 (a shift by 6), give 64 numbers that summarise the whole image.
7. **Classifier (PL).** A 64→2 dense layer produces two 32-bit logits, one for "normal" and one for "pneumonia".
8. **Decision (PL).** margin = logit(pneumonia) − logit(normal). The image is flagged if margin > T. Changing T in software moves the sensitivity/specificity trade-off without retraining.
9. **Report (PS).** The PS reads logit0, logit1, margin and the flag back over AXI-Lite and shows them on screen, or drives an LED or buzzer in a standalone build.

### 6.2 How this differs from the hackathon demo

In the hackathon (H-V4), the image was 28×28 (784 bytes), the network was the fixed v0 shape, and the output was a single bit from argmax with no threshold. The PS side ran in a Jupyter notebook reached over Wi-Fi from a laptop. The flow was the same in outline, but the PL arithmetic had the defects described in Section 4.3.

### 6.3 Why the split between PS and PL is drawn here

- **PS does what is irregular**: file formats, compression, windowing and user interface change often and are awkward in hardware.
- **PL does what is regular and heavy**: 12.19 million identical multiply-accumulates, which a dedicated pipeline does with predictable timing and without an operating system in the loop.
- **The boundary is small**: 50 KB in, three numbers and a bit out. Only the PS software changes between a laptop-driven demo and a standalone box; the bitstream stays identical.

The V1 AXI wrapper that connects `top_v1` to the DMA and registers is not yet built; it is the first item in the roadmap (Section 15).

## 7. V1: a table-driven integer CNN engine

V1 turns the fixed v0 circuit into a small general-purpose engine: the network's shape lives in a 7-entry table in on-chip memory, one convolution engine runs every convolution layer, and the same bitstream handles 28×28 and 224×224 inputs. It is synthesised at 75 MHz using 3.8% of the chip's logic and 57% of its block RAM.

### 7.1 Design goals and what changed from v0

| Aspect | v0 | V1 | Reason |
| --- | --- | --- | --- |
| Data | PneumoniaMNIST, 28×28 | RSNA Pneumonia DICOMs, 28×28 and 224×224 | Real hospital format; resolution that keeps lung texture |
| Network | conv → pool → flatten → FC16 → FC2 | 5 stride-2 3×3 convs → GAP → FC 64→2 | Flatten+FC tied parameter count to image size |
| Hardware structure | One hand-written module per layer | One conv engine + sequencer + layer table | Network changes need no Verilog changes |
| Requantisation | one fixed right shift by 8 | one power-of-two shift per layer | Layers have different ranges; shifts cost no multiplier |
| Decision | argmax, fixed | margin = logit1 − logit0, compared to a writable register T | Operating point tunable after deployment |
| Split | Official MedMNIST split | By patient, 70/15/15, stratified on the three-way class | Validation and test from the same distribution |
| Metrics | Balanced accuracy | AUROC with 95% CI, sensitivity/specificity at a pre-chosen T, subgroups | What clinical readers expect |

### 7.2 The network

| Layer | Operation | Output at 224 | Output at 28 | Parameters | MACs at 224 | Time at 75 MHz, 1 MAC/cycle (derived) |
| --- | --- | --- | --- | --- | --- | --- |
| conv1 | 3×3, stride 2, 1→8 | 8×112×112 | 8×14×14 | 80 | 903,168 | 12.0 ms |
| conv2 | 3×3, stride 2, 8→16 | 16×56×56 | 16×7×7 | 1,168 | 3,612,672 | 48.2 ms |
| conv3 | 3×3, stride 2, 16→32 | 32×28×28 | 32×4×4 | 4,640 | 3,612,672 | 48.2 ms |
| conv4 | 3×3, stride 2, 32→48 | 48×14×14 | 48×2×2 | 13,872 | 2,709,504 | 36.1 ms |
| conv5 | 3×3, stride 2, 48→64 | 64×7×7 | 64×1×1 | 27,712 | 1,354,752 | 18.1 ms |
| GAP | sum per channel, then right shift | 64 | 64 | 0 | — | <0.1 ms |
| FC | 64→2 | 2 logits | 2 logits | 130 | 128 | <0.1 ms |
| **Total** |  |  |  | **47,602** | **12,192,896** | **≈163 ms** |

Why this shape. Stride-2 convolutions compute a quarter of the windows a stride-1 convolution would (12.2 M MACs at 224 instead of about 49 M) and remove the separate pooling block that caused v0's defect #2. One operator type means one engine. With global average pooling the classifier always sees 64 numbers regardless of resolution, so the same weight file is legal at 28, 224 or 512; only the loop limits in the layer table change. At 47.6 k INT8 parameters (about 47 KB, 11 BRAM36 tiles) every weight stays on-chip permanently and never streams from DDR.

Caveat the paper must state: "resolution-agnostic" is true of the bitstream and weight shapes, not of accuracy. Weights trained at 224 must be retrained or at least re-validated at 512. At 28×28, conv5 sees a 2×2 map that is mostly padding, so V1.1 accuracy is not this architecture's real accuracy; V1.1 exists to bring up the RTL on the new data pipeline.

### 7.3 The integer arithmetic contract

Training, the golden model and the RTL all compute exactly this. Activations are unsigned 8-bit, weights signed 8-bit, biases signed 32-bit in accumulator units.

```latex
\begin{aligned}
\mathrm{acc}[o,y,x] &= b[o] + \sum_{c}\sum_{i,j=0}^{2} w[o,c,i,j]\; x_{\mathrm{pad}}[c,\,2y+i,\,2x+j] \\
\mathrm{out}[o,y,x] &= \mathrm{clamp}\big(\mathrm{acc}[o,y,x] \gg s_\ell,\; 0,\; 255\big) \\
\mathrm{gap}[c] &= \Big(\sum_{y,x}\mathrm{conv5}[c,y,x]\Big) \gg s_{\mathrm{gap}},\quad s_{\mathrm{gap}} = \lceil \log_2(H_5 W_5) \rceil \\
\mathrm{logit}[k] &= b_{fc}[k] + \sum_{c} W_{fc}[k,c]\;\mathrm{gap}[c] \\
\mathrm{margin} &= \mathrm{logit}[1]-\mathrm{logit}[0], \qquad \text{POSITIVE} \iff \mathrm{margin} > T
\end{aligned}
```

Each choice saves hardware. Unsigned activations use the sign bit ReLU would waste, doubling resolution. ReLU and 8-bit saturation merge into one clamp. Floor instead of rounding removes an adder (training absorbs the constant into the bias). Dividing by 64 instead of 49 in GAP is a wire instead of a divider, and training sees the same operation. 32-bit biases fix v0's problem that INT8 biases could not reach the logit scale. The threshold register exists because scaling the logits never changes the sign of margin − T, so T alone sets the operating point.

### 7.4 The layer-descriptor table

Each layer is one 128-bit word in a small ROM. The sequencer reads a word, loads its fields into counters and address offsets, starts the right engine, and moves on.

| Field | Bits | Meaning |
| --- | --- | --- |
| op | 4 | 1 = CONV3X3, 2 = GAP, 3 = FC; 0 deliberately unused so an unprogrammed word is detectable |
| kernel, stride, pad | 4 each | Convolution geometry |
| in\_c, out\_c | 12 each | Input and output channel counts |
| in\_h, in\_w, out\_h, out\_w | 12 each | Spatial sizes |
| shift | 6 | Requantisation shift for this layer |
| w\_base | 20 | Start of this layer's weights in the weight ROM |
| b\_base | 10 | Start of this layer's biases in the bias ROM |

The per-layer shifts are 7, 7, 7, 8, 8 for conv1–conv5 at 224 (all 7 at 28), 6 for GAP at 224 (0 at 28) and 0 for FC. Between V1.1 and V1.2 the audit confirmed that only the spatial sizes, two shifts and the threshold changed, which is exactly the set that should change.

### 7.5 Hardware modules

| Module | Role | Notes |
| --- | --- | --- |
| `top_v1.v` | Top level; weight, bias and threshold registers; latency alignment | Inserts one extra register on feature-map reads so every memory path is exactly two cycles |
| `layer_seq.v` | Walks the 7-entry table, starts the right engine, flips the ping-pong buffers | Also generates the GAP input stream |
| `conv_engine.v` | Shared 3×3 stride-2 INT8 convolution engine | One MAC per cycle, no stalls; pipeline operand-mux → register → multiply → register → accumulate; 9-bit × 8-bit signed products into a 22-bit accumulator; padding gated to zero rather than skipped |
| `fmap_ram.v` (×2) | Ping-pong feature-map buffers A and B, 128 KB each | Layer L reads one, writes the other |
| `gap_unit.v` | 64 running sums, then right shift | No clamp, to match the golden model exactly |
| `fc_unit.v` | 64→2 dense layer | Produces the two 32-bit logits |
| `decision.v` | margin = logit1 − logit0; positive if margin > T | Purely combinational |
| `line_buffer_v1.v` | Streaming 3×3 window generator | Built and unit-tested, not yet wired in; ready for a future windowed engine |

Each module has its own unit testbench (`tb_conv_engine.v`, `tb_gap.v`, `tb_fc.v`, `tb_line_buffer.v`) plus the full-system `tb_v1.v`.

### 7.6 Training V1

Training runs in integer units as in v0: a continuous ("soft") phase then a straight-through rounding ("hard") phase, 24 + 16 epochs at 224 (30 + 20 at 28). The loss is class-weighted cross-entropy with a learnable temperature on the logits, which the hardware never sees because positive scaling cannot flip a decision. The best epoch is chosen by the integer network's validation AUROC. The default threshold T is then the largest integer whose validation sensitivity is at least 90%, frozen before looking at test.

Data: 26,684 RSNA patients (one image each), split 18,678 / 4,003 / 4,003 by patient, 22.5% positive. Preprocessing follows the DICOM grayscale pipeline and passes seven self-tests on genuine computed-radiography files (15-bit, MONOCHROME1, JPEG 2000 lossless), because RSNA's own files are the easy 8-bit case.

### 7.7 Model results

All figures are computed from the golden model's integer margins, which equal the trained network on all 4,003 test images and which the RTL is required to match. There is no separate "software accuracy".

| Metric (RSNA test, 4,003 patients) | V1.1 (28×28) | V1.2 (224×224) |
| --- | --- | --- |
| AUROC (95% CI) | 0.814 (0.799–0.830) | 0.823 (0.808–0.838) |
| Validation AUROC | 0.834 | 0.838 |
| Sensitivity / specificity at T | 89.1% / 54.7% | 91.0% / 53.9% |
| PPV / NPV at T | 36.4% / 94.5% | 36.5% / 95.4% |
| Sensitivity / specificity at argmax (T = 0) | 76.1% / 73.1% | 74.1% / 74.7% |
| Opacity vs Normal AUROC | 0.933 | 0.936 |
| Opacity vs "No Lung Opacity / Not Normal" AUROC | 0.726 | 0.738 |
| AP view / PA view AUROC | 0.735 / 0.747 | 0.743 / 0.766 |
| Male / female AUROC | 0.810 / 0.821 | 0.821 / 0.826 |
| AUROC from view position alone (shortcut floor) | 0.706 | 0.706 |

How to read this honestly:

- **Resolution helps, modestly.** V1.2 beats V1.1 on every metric, but the test AUROC gain is +0.009 and the confidence intervals overlap. The consistency across all metrics is the evidence, not the size of any one gain.
- **The easy question is answered well; the hard one is not.** Separating pneumonia from clearly normal lungs reaches AUROC 0.936. Separating it from other abnormal findings (effusions, nodules) falls to 0.738.
- **There is a shortcut.** AP films are mostly bedside films of sicker, admitted patients; PA films are mostly walk-in patients. Knowing only the view gives AUROC 0.706. Within a single view, the model's AUROC drops to 0.74–0.77, so part of the headline comes from view mix. Specificity on AP films is only 19.6%.
- **The screening operating point is expensive.** At 91% sensitivity, 1,430 of 3,101 healthy test patients (46%) are flagged. PPV is 36.5%; NPV is 95.4%. That NPV is the useful number: a negative result is reliable, a positive result means "send for a read".
- **No sex gap** of any size appears.

### 7.8 Synthesis results

| Metric | V1.1 (28×28) | V1.2 (224×224) | Status |
| --- | --- | --- | --- |
| Target clock | 75 MHz | 75 MHz | — |
| Worst setup slack | +0.093 ns | +0.085 ns | SYNTH-ESTIMATE |
| Worst hold slack | +0.079 ns | +0.079 ns | SYNTH-ESTIMATE |
| Failing endpoints | 0 of 7,704 | 0 of 9,439 | SYNTH-ESTIMATE |
| LUT | 1,907 (3.6%) | 2,006 (3.8%) | SYNTH-ESTIMATE |
| FF | 2,323 (2.2%) | 2,840 (2.7%) | SYNTH-ESTIMATE |
| DSP48E1 | 14 (6.4%) | 14 (6.4%) | SYNTH-ESTIMATE |
| BRAM36 | 48 (34%), with the older 64 KB buffers | 80 (57%) | SYNTH-ESTIMATE |
| Critical path | conv row register → DSP → 6 carry-chain stages → feature-map RAM address, 10 levels | Same, 11 levels (one more carry stage for 17-bit addressing) | SYNTH-ESTIMATE |

Three observations for the paper. First, the critical path is **address arithmetic** (channel × height × width + row × width + column), not the multiply-accumulate; Vivado even placed DSPs on it, which is why 14 DSPs appear instead of the 1–3 expected. Replacing the multiplications with incrementing counters would shorten it and likely raise the clock. Second, BRAM is the binding resource: two 128 KB ping-pong buffers dominate, while the largest in-plus-out feature-map pair at 224 needs only about 150 KB (33 BRAM36), so sizing the buffers per layer would free roughly a third of the BRAM. Third, only 14 of 220 DSPs are used. Computing 8 or 16 output channels in parallel is the obvious next step and would cut the derived 163 ms to roughly 10–20 ms without changing the arithmetic contract.

### 7.9 V1 verification status

| Check | Result | Status |
| --- | --- | --- |
| Golden model vs training network (float64 CPU), every intermediate tensor, 244 images | 0 mismatches (over 24.5 M conv1 values alone) | MEASURED |
| Golden model vs training network, logits, whole test set | 4,003 / 4,003 exact | MEASURED |
| Independent audit re-computing everything from exported files only | 0 mismatches; layer table decodes field-for-field | MEASURED |
| RTL vs golden, V1.2 system sweep | 16 / 16 images: logits, margin and decision exact; 12 / 12 trace files | MEASURED |
| RTL vs golden, full 244-image gate | Not yet run | PENDING |
| Post-implementation timing, board run, power | Blocked on the AXI wrapper | PENDING |

One housekeeping gap from the audit: the manifest's SHA-256 hashes cover only 3 of 313 exported memory files, because the export glob is not recursive. It should be fixed before the artefact is published with the paper.

## 8. Verification methodology as a research contribution

The most defensible novelty in FLASH is not the accelerator but the way it is proven correct: a training-to-RTL chain in which the model, the golden reference and the hardware compute the same integers, checked at every layer on unfiltered data. Hand-written CNN accelerators in student and early-stage work routinely skip this, and FLASH has a documented case of five bugs surviving five versions because of it.

### 8.1 The chain of equalities

1. **Trained model = golden model.** The network is trained in integer units, so the exported integers are the model. The golden model is a separate pure-NumPy int64 program that reads only the exported files. Agreement proves both the arithmetic and the export encoding (hex, two's complement, ordering, base offsets). V1: 4,003 / 4,003 test logits exact.
2. **Golden model = RTL.** The simulator dumps every intermediate tensor and raw accumulator; Python diffs them against the golden model. A mismatch names the layer and the stage inside it. v0: 244 / 244; V1.2: 16 / 16 so far.
3. **Reported accuracy = hardware accuracy.** Because (1) and (2) hold, every clinical metric is computed from the golden model's integer margins and describes exactly what the chip will output.

### 8.2 The five rules

| Rule | What it replaces | Why |
| --- | --- | --- |
| Compare 32-bit logits, not the decision bit | Checking one pass/fail bit | A bit can be right by accident; a 32-bit integer essentially cannot |
| Use an unfiltered, balanced, fixed-seed test slice including misclassified images | Eight images pre-filtered to >20% confidence margin | Confident images hide arithmetic errors; selection bias hid three real bugs |
| Dump and compare every intermediate tensor | Only final outputs | Localises a mismatch to one layer, one stage |
| Measure accumulator ranges over whole datasets, and compute guaranteed bounds from actual weights | Hand-calculated worst cases after a silent overflow | Overflow in integer hardware is a silent wrong answer |
| Generate every RTL input (weights, vectors, expected outputs, layer table) from one notebook | Hand-built `.mem` files | Nothing hand-written can drift |

### 8.3 Three accumulator bounds

V1's notebook prints three bounds per layer. The **generic** bound assumes every weight is ±127 and is always safe but wasteful. The **guaranteed** bound uses the actual trained weights and the full 0–255 input range, and is safe for any image ever. The **measured** bound is what real images produce. V1 builds to the guaranteed bound (22-bit accumulator, 19-bit margin register). At 224 the measured logit range (−1,545 to 2,127) is 15–20× narrower than at 28, so the margin register runs at a small fraction of its range; that is a possible area saving, but the paper should argue for the guaranteed bound on safety grounds.

### 8.4 A proposed experiment that turns the story into evidence

The v0 defect history is a natural **fault-injection (mutation) study**. Re-insert each of the five historical defects, one at a time, and measure which verification strategy detects it.

| Strategy | Expected to catch | To be measured |
| --- | --- | --- |
| A. Decision bit, 8 high-margin images (hackathon) | Few or none | Detection rate per defect |
| B. Decision bit, 244 unfiltered images | Some | Detection rate per defect |
| C. Exact logits, 244 unfiltered images | All datapath defects | Detection rate, images needed to first detection |
| D. Exact intermediate tensors | All, with location | Detection rate, localisation accuracy |

This table, filled with real numbers, would be the most citable figure in the paper. It costs about a day of work because the old RTL is in version control. The same study can be repeated on V1 by injecting classic latency and addressing faults into `conv_engine.v`.

### 8.5 How this relates to existing tools

High-level synthesis flows such as AMD's FINN and the open-source hls4ml generate accelerators from a trained model and rely on C simulation and C/RTL co-simulation for equivalence. Integer-only inference itself is well established (Jacob et al., 2018, the basis of TensorFlow Lite's integer scheme). FLASH's angle is different: a hand-written RTL flow with training-time integer semantics, a published arithmetic contract, and a quantified argument for why logit-level, unfiltered verification is necessary. The paper should cite these tools and position FLASH as a methodology and case study for hand-written or hand-modified accelerators, not as a competitor to them.

## 9. Corrections: claims to retire or restate before publication

Eighteen statements in the hackathon deck, elevator pitch or prep references would not survive peer review as written. Each has a correct replacement, and several of the replacements make a stronger story. The professor should read this section before any other material from the hackathon.

### 9.1 Numbers

| # | Original claim | Problem | Use instead |
| --- | --- | --- | --- |
| 1 | 95.4% balanced accuracy | Python figure on a datapath the hardware never reproduced | v0: 84.7% balanced (hardware-exact). V1.2: AUROC 0.823 (0.808–0.838) on RSNA |
| 2 | 2.5 million pneumonia deaths a year in children under five | 2.5 M is all ages | 740,180 children under five in 2019 (WHO); about 2.5 M at all ages |
| 3 | "70% of low-resource settings lack radiologists" | Heading and supporting text do not match; no source for 70% | "About two-thirds of the world's population lacks access to basic diagnostic imaging" (WHO, as cited by Mariani et al., 2017) |
| 4 | Power 35.9 W → 7.2 W after clock gating | Both are Vivado vectorless estimates assuming near-100% switching | v0: 0.116 W total on-chip, from simulation activity (SAIF). V1: not yet measured |
| 5 | "\~100 mW" device power | That is the FPGA chip, not the system; the PYNQ-Z2 board with ARM and DDR draws several watts | Quote chip power and measured board power separately |
| 6 | 231 µs per inference | Measured on the defective H-V4 datapath at 28×28 | v0: re-measure on board. V1.2: about 163 ms derived at 1 MAC/cycle, to be measured |
| 7 | "8:1 imbalance" | Same slide says 1:2.9 | 1:2.9 (Normal : Pneumonia) in PneumoniaMNIST training |
| 8 | "Hardware simulation passes 5/8; 3 normal failures are model mismatch, RTL is clean" | The failures were the line-buffer defect | State that the audit traced them to RTL defects |

### 9.2 Method statements

| # | Original claim | Problem | Use instead |
| --- | --- | --- | --- |
| 9 | "Only images with >20% margin selected — guarantees hardware will agree" | This is selection bias and it hid three bugs | Present it as the negative example that motivated the methodology (Section 8) |
| 10 | "Nothing touches the ARM during inference … the distinction from every partial-hardware approach in the literature" | Full-PL CNN inference on Zynq is common (FINN, hls4ml and many papers) | "All CNN layers run in PL; the PS only moves data" as a design fact, not a novelty claim |
| 11 | Output named `cancer_detected` | Wrong disease; confusing to reviewers | `positive` (as in V1) or `pneumonia_flag` |
| 12 | "Cloud latency of 200–500 ms hinders real-time decisions" | No clinical decision depends on sub-second latency | Argue availability without network, privacy and per-scan cost |
| 13 | "We proved our RTL detects pneumonia offline on a test board" (pitch) | The board run was the defective design; the corrected v0 and V1 have not run on a board | "Our RTL is bit-exact with the trained model in simulation; on-board validation is in progress" |
| 14 | Pitch centres on a child in a rural clinic | V1 is trained on RSNA adults; v0's pediatric data is 28×28 | Either say the current model is adult and pediatric work is planned, or add a pediatric dataset (Section 15) |
| 15 | "Taking this forward to clinical trials" | A trial needs external validation, ethics approval and a regulatory pathway first | "Retrospective external validation, then a prospective pilot" (Section 15) |
| 16 | "512×512 images on PYNQ" | At 512 the first feature map alone is 8×256×256 = 512 KB, near the chip's total BRAM (about 630 KB) | Possible only with DDR tiling; list as future work with that caveat |

### 9.3 References

| # | Reference in prep document | Problem | Action |
| --- | --- | --- | --- |
| 17 | Hsu (2019), "Medical Physics International Journal", for "224×224 is optimal" | Could not be verified; the claim itself is too strong | Replace with Sabottke & Spieler (2020), *Radiology: Artificial Intelligence*, on image resolution in radiograph deep learning, after checking it |
| 18 | Devasia et al. (2023) for 1 radiologist per 100,000; Shelke et al. (2021) for >95% accuracy | Devasia is a tuberculosis model paper, not a workforce source; Shelke reports COVID-19 accuracy on public data, which does not transfer to FLASH | Cite a workforce source for the ratio; drop the implication that FLASH will reach 95% |

Every statistic in the final paper should be traced to a source the authors have opened themselves.

## 10. Viability of the use case: an honest assessment

The engineering is viable, the research contribution is viable, and the clinical product is viable only as a narrow, well-validated triage aid, not as a stand-alone diagnostic. The biggest risk is not the hardware; it is that offline chest X-ray AI already exists commercially, so FLASH must win on cost, power, embeddability or verifiability.

### 10.1 Four kinds of viability

| Dimension | Verdict | Evidence | What would change it |
| --- | --- | --- | --- |
| Technical | Strong | Bit-exact integer CNN at 224×224 in 3.8% of a Zynq-7020's logic; timing met at 75 MHz | A board run with measured latency and power |
| Research | Good for a short paper now; strong for a journal after board results | Verification methodology, fault-injection study, clinically framed evaluation | The fault-injection table (Section 8.4) |
| Clinical | Early | AUROC 0.823 on one adult public dataset; specificity 54% at 91% sensitivity; view-position shortcut | External validation on a second hospital's data; pediatric data; reader study |
| Commercial | Uncertain | Offline CXR AI already sold by established vendors (Section 11) | A clear cost, power or OEM-embedding advantage, or a niche incumbents ignore |

### 10.2 Where FLASH could genuinely fit

- **Embedded inside an X-ray machine**, especially portable and battery-powered units, where a few-watt, fanless, deterministic module is easier to integrate and certify than a PC or tablet.
- **High-volume screening vans and camps** that run on battery or solar and cannot rely on connectivity.
- **"Rule-out" triage**: with NPV around 95%, a negative result is informative; a positive result routes the film to a teleradiologist first. This is the workflow the operating-point choice already assumes.
- **Tuberculosis**, not only pneumonia. TB screening by chest X-ray with computer-aided detection is recommended by WHO for people aged 15 and over, has national programmes and funders, and is where most offline CXR AI is deployed today. The same engine and methodology apply; only the training data and label change.

### 10.3 Risks the professor should weigh

1. **Incumbents already work offline.** Several WHO-evaluated CAD products run on a local mini-PC or workstation without internet (Section 11). "Offline" alone is not a differentiator.
2. **Pediatric mismatch.** The pitch is about children, but V1 is trained on adults. WHO's TB CAD recommendation explicitly excludes under-15s, which signals how hard pediatric chest X-ray AI is. In many low-resource settings, childhood pneumonia is diagnosed clinically (breathing rate, chest in-drawing) without an X-ray at all.
3. **Specificity.** Flagging 46% of healthy patients would overwhelm a referral pathway unless the positive rate is acceptable to the teleradiology partner.
4. **Shortcut learning.** The view-position shortcut shows the model partly learns acquisition context; a different hospital's mix of AP and PA films could move performance.
5. **Model capacity.** 47.6 k parameters is tiny next to commercial models trained on millions of exams. The FPGA budget allows several times more, but BRAM is the constraint (Section 7.8).
6. **Regulation.** In India, AI software that informs diagnosis is a medical device under the Medical Devices Rules, 2017, regulated by CDSCO, and needs clinical evidence before sale.

### 10.4 What would make it compelling

- A measured system-level comparison against a phone-class processor and a mini-PC running the identical INT8 model: latency, energy per image, bill-of-materials cost.
- External validation on a second dataset (VinDr-CXR, or a partner hospital in Hyderabad) with a pre-registered operating point.
- A pediatric dataset, or an explicit decision to target adult pneumonia and TB first.
- Localisation output (a coarse heat-map) so a clinician can see why a film was flagged; commercial products all offer this.

## 11. Competitive and related-work landscape

Commercially, FLASH enters a mature market led by regulator-cleared chest X-ray AI that already runs offline; academically, FPGA pneumonia classifiers exist but rarely report bit-exact verification or clinically framed metrics. FLASH's opening is the intersection: dedicated low-power hardware with provable equivalence to the validated model.

### 11.1 Commercial chest X-ray AI

| Company / product | Origin | What it does | Offline? | Regulatory status (as reported) |
| --- | --- | --- | --- | --- |
| [Qure.ai qXR](https://www.businesswire.com/news/home/20260226643266/en/Qure.ai-Nets-Six-New-Indications-Cleared-by-the-FDA-Taking-the-Chest-X-ray-Crown-in-the-Radiology-AI-Race) | Mumbai, India | Multi-finding chest X-ray AI including TB, nodules, pleural and cardiac findings | Offline or hybrid deployments reported by TB programmes | 26 FDA-cleared indications across 9 products after six clearances in February 2026; CE; CDSCO licence reported by a reseller |
| [Delft Imaging CAD4TB](https://unicat.msf.org/cat/product/92522?page=501) | Netherlands | TB abnormality score 0–100 | Yes: sold with an offline mini-computer ("CAD4TBbox") and tablet; result in under a minute | CE; one of three products behind WHO's 2021 CAD recommendation |
| Lunit INSIGHT CXR | South Korea | Multi-finding chest X-ray AI | Local deployment available | One of the three products in WHO's 2021 analysis |
| [DeepTek Genki](https://www.clintonhealthaccess.org/wp-content/uploads/2026/09/CAD-Agreements_FAQ-Document.pdf) | Pune, India | TB screening plus 20+ findings, ages 4 and above, about 30 s per image | Yes, on existing X-ray workstations | Listed as WHO-recommended CAD in a September 2026 CHAI document |
| Teleradiology services (for example 5C Network) | India | Human radiologists reading remotely, often with AI pre-reads | No | Not devices; services |

The [WHO 2025 policy statement](https://www.who.int/publications/i/item/9789240110373) on CAD for TB screening followed an independent evaluation of submitted products by FIND and WHO's technical advisory group. A [2022 implementer survey](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC9621304/) of TB programmes using CAD found six working fully offline and eleven in hybrid mode (offline analysis, online sync), with qXR and CAD4TB the most used. WHO does not currently recommend CAD for TB in people under 15 ([Scanned review, 2025](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11913293/)).

**What this means for FLASH.** The incumbents run on general-purpose computers (a mini-PC, a laptop, a workstation, or the cloud), use models trained on millions of images, detect many findings, localise them, and hold regulatory clearances. FLASH cannot compete on breadth or accuracy in the near term. It can differentiate only on:

- **Form factor and power**: a chip-level module drawing roughly a watt or less that can sit inside a portable X-ray unit, versus a separate PC plus tablet.
- **Determinism and auditability**: a fixed-function datapath proven equal to the validated model, attractive for regulated embedded devices.
- **Cost at volume**: an OEM component rather than a software licence per scan. This needs a real bill-of-materials study.

A realistic commercial path is therefore a component supplier to X-ray equipment makers, or a licensed IP block, rather than a stand-alone competitor to qXR.

### 11.2 Academic work on FPGA medical-image classifiers

| Work | Platform | Task / data | Relevance to FLASH |
| --- | --- | --- | --- |
| FPGA implementation of a DCNN for tuberculosis and pneumonia detection, *IEEE Embedded Systems Letters*, 2024 (doi 10.1109/LES.2024.3370833) | FPGA | TB and pneumonia from chest X-rays | Closest direct prior art; must be read and compared |
| FPGA-based ResNet-50 acceleration for pneumonia detection ([listing](https://www.researchgate.net/figure/The-design-flow-for-CNN-on-PYNQ-Z2_fig2_357971914)) | Zynq UltraScale+ ZCU104 | Pneumonia, chest X-ray; quantised ResNet-50 | Large-model, larger-chip baseline; typically Vitis AI flow |
| [BCPNN stream accelerator](https://arxiv.org/pdf/2503.01561), 2025 | Alveo U55C (data-centre card) | PneumoniaMNIST 28×28 and BreastMNIST | Same 28×28 benchmark as v0; different network type and platform class |
| [PYNQ-Z2 ECG arrhythmia CNN](https://www.sciencedirect.com/science/article/abs/pii/S1746809425005749), 2025 | PYNQ-Z2 (same board) | 64×64 ECG beat images; HLS; 236 ms latency, 50% DSP, 30% BRAM | Same-board medical CNN; a fair resource and latency comparison point |
| [ZynqNet](https://arxiv.org/pdf/2005.06892) | Zynq-7045 | ImageNet classification | Classic reference for CNNs co-designed with a Zynq accelerator |
| FINN (AMD research), hls4ml, Vitis AI DPU | Various | Frameworks that generate accelerators | Must be discussed; FLASH should explain why hand-written RTL (transparency, verification, tiny footprint) |
| [CheXNet](https://arxiv.org/pdf/1711.05225), 2017 | GPU | 121-layer DenseNet on ChestX-ray14 pneumonia; compared with four radiologists on F1 | Canonical software baseline; shows pneumonia reading is hard even for radiologists |

A gap the paper can claim, after a proper literature search confirms it: FPGA medical classifiers commonly report accuracy from the software model and resources from synthesis, but rarely prove that the hardware reproduces the reported accuracy, and rarely report AUROC with confidence intervals, subgroup results or shortcut checks on patient-level splits. FLASH does all of these.

### 11.3 Literature search still to do

Before submission, search IEEE Xplore, ACM Digital Library and Google Scholar for: "FPGA pneumonia", "FPGA chest X-ray", "FPGA tuberculosis", "PneumoniaMNIST FPGA", "bit-exact CNN accelerator verification", "quantized CNN hardware equivalence checking", "integer-only inference FPGA medical". Build a comparison table with platform, input size, precision, accuracy metric, whether the accuracy was measured on hardware, LUT/DSP/BRAM, clock, latency and power.

## 12. Proposed paper

The recommended first paper is a short FPGA-venue paper whose headline is "a bit-exact, table-driven INT8 CNN engine for chest X-ray screening, and the verification discipline that makes its accuracy claims trustworthy". It should not be framed as "a new pneumonia detector", because the accuracy is not state of the art and the reviewers at FPGA venues care about hardware and methodology.

### 12.1 Title options

1. *FLASH: A Bit-Exact, Table-Driven INT8 CNN Engine for Offline Chest X-Ray Screening on a Low-Cost SoC-FPGA*
2. *When the Decision Bit Lies: Logit-Level Verification of a Hand-Written CNN Accelerator for Medical Screening*
3. *From Hackathon to Bit-Exact: Lessons from Verifying an FPGA Pneumonia Classifier*

Option 1 suits an applications track; option 2 leads with the methodology and is more memorable; option 3 suits a short or experience paper.

### 12.2 Draft abstract (about 180 words)

> Low-cost FPGAs are attractive for offline medical image screening, but hand-written accelerators are rarely shown to reproduce the accuracy their authors report. We present FLASH, a 47.6 k-parameter integer CNN for chest radiograph pneumonia screening implemented as a table-driven engine on a Zynq-7020. A single 3×3 stride-2 convolution engine, a global-average-pooling unit and a writable decision threshold execute a network described entirely by a 128-bit-per-layer descriptor ROM, so the same bitstream runs 28×28 and 224×224 inputs. The network is trained directly in integer units, making the trained model, a NumPy golden model and the RTL compute identical integers. We show that conventional decision-bit testing on confident images missed five datapath and testbench defects that logit-level, intermediate-tensor comparison exposed, and quantify detection rates by fault injection. At 224×224 on the RSNA dataset with a patient-level split, the hardware-exact model reaches test AUROC 0.823 (95% CI 0.808–0.838), using 2,006 LUTs, 14 DSPs and 80 BRAM36 at 75 MHz. \[Board latency and power to be added.\]

### 12.3 Contributions (as they would be listed in the paper)

1. A table-driven INT8 CNN engine in hand-written Verilog: one shared convolution engine, GAP, FC and a threshold register, resolution-independent at the bitstream level.
2. A training-to-RTL arithmetic contract (unsigned activations, per-layer power-of-two requantisation, 32-bit accumulator-unit biases, merged ReLU and saturation) under which training, golden model and hardware are bit-identical.
3. A verification methodology (logit-level, unfiltered, per-layer traces, dataset-measured and weight-guaranteed accumulator bounds) with a fault-injection study showing why weaker checks fail.
4. A clinically framed evaluation of the hardware-exact model: patient-level split, AUROC with confidence intervals, a pre-registered operating point, subgroup analysis and a shortcut floor.
5. Open artefacts: RTL, notebook, golden model and verification vectors (anonymised for review).

### 12.4 Paper structure (6–8 page short paper)

| Section | Content | Source in this document | Pages |
| --- | --- | --- | --- |
| 1. Introduction | Problem, why offline edge, why verification matters, contributions | Sections 2, 8 | 0.75 |
| 2. Background and related work | Integer inference; FPGA CNN frameworks; FPGA medical classifiers; CXR AI | Sections 3.5, 11 | 0.75 |
| 3. Arithmetic contract and training | Integer-unit training, the contract, operating point | Sections 7.3, 7.6 | 1 |
| 4. Architecture | Layer table, conv engine pipeline, ping-pong buffers, GAP, FC, decision | Sections 7.4, 7.5 | 1.25 |
| 5. Verification methodology | Chain of equalities, five rules, fault-injection results | Section 8 | 1.25 |
| 6. Results | Resources, timing, latency, power, accuracy, comparison table | Sections 7.7–7.9 | 1.25 |
| 7. Discussion and limitations | Shortcut, specificity, adult data, what is not claimed | Sections 9, 10 | 0.5 |
| 8. Conclusion | — | — | 0.25 |

### 12.5 Figures and tables the paper needs

- Figure 1: system overview, PS and PL, data path of one image (Section 6 diagram).
- Figure 2: conv engine pipeline with the tag pipeline and memory latencies.
- Figure 3: layer-descriptor word layout.
- Figure 4: ROC curve with the chosen operating point, V1.1 and V1.2 overlaid.
- Table: fault-injection detection rates (Section 8.4).
- Table: resources, clock, latency, power versus 3–5 comparable FPGA works.
- Table: subgroup AUROC and the shortcut floor.

### 12.6 Experiments still required, in priority order

| # | Experiment | Why a reviewer needs it | Effort estimate |
| --- | --- | --- | --- |
| 1 | Full 244-image RTL sweep at 224×224 | The stated gate; 16 images is thin | Hours to a day of simulation |
| 2 | Fault-injection study on the five historical defects | Turns the narrative into evidence | 1–2 days |
| 3 | AXI wrapper, implementation, bitstream, on-board run | Post-route resources and timing; real latency | 1–3 weeks |
| 4 | Measured board power (with and without inference) and SAIF-based chip power for V1 | Any energy claim | 2″3 days after #3 |
| 5 | Same INT8 model on the Zynq's ARM cores and on a phone-class or Raspberry Pi-class CPU | Answers "why an FPGA?" | 2–4 days |
| 6 | Parallel output channels (for example 8 MACs per cycle) | Shows the architecture scales in speed, not just resolution | 1–2 weeks |
| 7 | External validation on a second dataset (for example VinDr-CXR) | Needed for any clinical framing; optional for an FPGA venue | 1–3 weeks including credentialing |

Experiments 1, 2 and 5 are enough for a workshop or short paper. Adding 3 and 4 makes a solid conference paper. Adding 6 and 7 makes a journal paper.

### 12.7 Double-blind review practicalities

FPGA and ARC both review double-blind. The public GitHub repository and the hackathon deck identify the team, so the submission must cite the repository through an anonymising mirror (for example Anonymous GitHub), refer to the hackathon work in the third person, and avoid the project name if it is searchable. Keep the repository public; conferences do not treat a code release as prior publication, but check each venue's policy.

## 13. Target venues

The best immediate target is a short paper at ARC 2027 (submission 25 October 2026), followed by a fuller paper at FCCM, FPL or FPT 2027 once the design runs on the board, and a journal version in ACM TRETS or IEEE TBioCAS. The flagship FPGA symposium's deadline (8 October 2026) is too close and the work is not yet at its bar.

### 13.1 Conferences

Deadlines marked "confirmed" were read from the venue's own call for papers on 29 September 2026. Deadlines marked "typical" are inferred from past years and must be checked.

| Venue | Publisher | Fit for FLASH | Next deadline | Format | Recommendation |
| --- | --- | --- | --- | --- | --- |
| [ARC 2027](https://easychair.org/cfp/arc2027), Applied Reconfigurable Computing, Berlin, 31 Mar–2 Apr 2027 | Springer LNCS; selected papers invited to an ACM TRETS special issue | High: applications-oriented reconfigurable computing, welcomes work in progress | **25 Oct 2026 (confirmed)** | Short 8 pages (poster) or long 14 pages; anonymous | **First target**: short paper with experiments 1, 2 and 5 |
| [FPGA 2027](https://www.isfpga.org/call-for-papers/) (ACM/SIGDA ISFPGA), California, 14–16 Mar 2027 | ACM | Medium: premier venue, very high bar; "Applications and Design Studies" and "AI/ML on FPGAs" tracks | Abstract 1 Oct, paper 8 Oct 2026 (confirmed, no extensions) | Long 10 / short 6 pages; double-blind | Skip this cycle; aim for FPGA 2028 with a mature journal-grade story |
| FCCM 2027, Field-Programmable Custom Computing Machines | IEEE | High: accelerators and applications, likes comparisons with CPUs and GPUs | Early to mid January 2027 (typical) | Long and short papers | Second target if the board run and power are done by January |
| [FPL 2027](https://2026.fpl.org/calls/call-for-papers/), Field-Programmable Logic and Applications | IEEE | High: largest FPGA conference, strong applications track | Around late March to early April 2027 (typical; FPL 2026's final deadline was 3 April 2026) | Long and short papers | Good target for the full hardware paper |
| FPT 2027, Field-Programmable Technology | IEEE | High: Asia-Pacific FPGA venue, applications welcome | Around July–August 2027 (typical) | Long and short papers | Alternative to FPL |
| VLSID 2028 (VLSI Design), India | IEEE | Medium-high: Indian flagship; good visibility for an Indian startup | Around late August 2027 (typical; VLSID 2025's was 31 Aug 2024) | Regular and short papers | Good national venue; the 2027 cycle has closed |
| VDAT 2027, VLSI Design and Test, India | IEEE | Medium | Around May–June 2027 (typical) | Regular papers | Fallback national venue |
| ISCAS 2027 | IEEE Circuits and Systems Society | Medium: broad circuits and systems, has biomedical and ML-hardware tracks | Around early to mid October 2026 (typical) | 4–5 pages | Possible, but deadline is tight |
| BioCAS 2027, Biomedical Circuits and Systems | IEEE | High for the medical-hardware angle | Around June 2027 (typical) | 4 pages | **Best biomedical target** once external validation exists |
| EMBC 2027, Engineering in Medicine and Biology | IEEE EMBS | Medium: large biomedical engineering venue | Around February–March 2027 (typical) | 4 pages | Good for the clinical-evaluation angle |

### 13.2 Journals

| Journal | Publisher | Fit | Notes |
| --- | --- | --- | --- |
| ACM Transactions on Reconfigurable Technology and Systems (TRETS) | ACM | High | The natural journal home; ARC and FPGA best papers feed its special issues |
| IEEE Embedded Systems Letters | IEEE | High for a short, sharp result | 4-page letters; published the closest prior FPGA TB/pneumonia paper (2024) |
| IEEE Transactions on Biomedical Circuits and Systems (TBioCAS) | IEEE | High once clinical validation exists | Hardware plus medical evidence |
| IEEE Transactions on Circuits and Systems II: Express Briefs | IEEE | Medium | Short format, broad audience |
| IEEE Transactions on VLSI Systems | IEEE | Medium | Needs a stronger architectural novelty than FLASH has today |
| Journal of Real-Time Image Processing | Springer | Medium | Accepts embedded vision accelerators |
| Microprocessors and Microsystems | Elsevier | Medium | Accepts embedded accelerator case studies |
| IEEE Journal of Biomedical and Health Informatics (JBHI) | IEEE | Later | Only after external clinical validation |

### 13.3 Recommended sequence

1. **By 25 Oct 2026**: ARC 2027 short paper. Needs the full 244-image sweep, the fault-injection table and the CPU comparison.
2. **By January 2027**: board bring-up, measured latency and power. Submit to FCCM 2027 if ready, otherwise hold for FPL.
3. **By March–April 2027**: full paper to FPL 2027 (or an IEEE Embedded Systems Letter) with board results and parallel channels.
4. **By June 2027**: BioCAS 2027 with external validation on a second dataset.
5. **Late 2027**: consolidated journal paper in TRETS or TBioCAS.

A short paper followed by a substantially extended version elsewhere is normally acceptable, but each venue's policy on prior publication must be checked, and the same work must never be under review at two places at once.

## 14. Paper or patent?

Write the paper; do not file a patent on the current design. What exists today is already public and largely prior art, so a patent would be weak and costly; a paper builds credibility for the startup and the team's careers. Protect future genuinely new inventions by filing a provisional patent application before disclosing them.

This section is general information, not legal advice. Before filing anything, the team should speak to BITS Pilani's IP cell and a registered Indian patent agent.

### 14.1 Why a patent is weak for the current design

1. **It has already been disclosed.** The hackathon presentation, the public PneumoniaFPGA and ProjectFlash repositories, and their documentation describe the architecture in detail. India applies absolute novelty: a public disclosure anywhere before filing defeats novelty for what it discloses ([Intepat, July 2026](https://www.intepat.com/blog/what-can-be-patented-india)).
2. **India's grace period is narrow.** Section 31 protects only specific cases, such as display at a government-notified exhibition or a paper read before a learned society, and only if the application follows within 12 months. Since the 2024 rule amendments, claiming it requires Form 31 under Rule 29A with evidence ([Lexology, March 2026](https://www.lexology.com/library/detail.aspx?g=63c54e6a-af0d-40d8-afd8-bb8faf3732d6)). A hackathon or a GitHub push is unlikely to qualify. Europe has no general grace period; the US gives inventors 12 months after their own disclosure ([R.K. Dewan, 2025](https://www.rkdewan.com/blogs/patent-after-public-disclosure-in-india/)).
3. **The building blocks are prior art.** INT8 convolution engines, line buffers, ping-pong buffers, GAP units, layer-descriptor sequencers and threshold comparators on Zynq are all documented. Combining them for chest X-rays is likely to be judged obvious.
4. **Software exclusion.** Section 3(k) excludes computer programs per se; hardware-software inventions can pass if they show a technical effect beyond running a program on general hardware ([IIPRD, May 2026](https://www.iiprd.com/software-patents-in-india-understanding-section-3k-of-the-patents-act/)). FLASH's hardware would likely pass this test, so Section 3(k) is not the obstacle; points 1–3 are.
5. **Cost against value.** Drafting, filing, prosecution and later international filings run to lakhs of rupees over several years, for a claim that competitors can design around.

### 14.2 Why a paper is the right first move

| Criterion | Paper | Patent |
| --- | --- | --- |
| Fits what exists today | Yes: methodology and results are publishable | Weak: design already public and largely known |
| Time to outcome | Months | Grant typically takes years |
| Cost | Registration and travel; ACM open-access charge may apply | Agent fees plus official fees over years |
| Value to a startup | Credibility with hospitals, investors, grant panels | Only if claims are strong and enforceable |
| Value to the students | Publications count for admissions and hiring | Limited unless licensed |
| Effect on future patents | A paper becomes prior art against yourselves | Filing first preserves both options |

### 14.3 What could be worth patenting later

Keep these confidential until a provisional application is filed:

- A method or circuit for streaming inference directly from an X-ray detector's readout, inside the imaging device.
- A memory-tiling scheme that runs 512×512 or larger inputs on a small FPGA without external DDR, if it is genuinely new.
- A device-level mechanism that proves at run time that the deployed hardware still computes the certified model (for example, built-in self-test with golden vectors and signed logits), useful for regulators.
- A calibration method that adapts the decision threshold per site without retraining and without leaking patient data.

Trademark the name (for example "FLASH" in the medical-device class, if available) early; that is cheap and more valuable to a startup than a weak patent.

### 14.4 Indian patent procedure, step by step

| Step | What happens | Forms | Timing |
| --- | --- | --- | --- |
| 1. Ownership check | Confirm who owns the invention: students, BITS Pilani, or both, and any hackathon terms | Institute IP policy | Before anything else |
| 2. Prior-art search | Search patents (Indian Patent Office database, Google Patents, Espacenet) and papers | — | 1–2 weeks |
| 3. Provisional application | Describes the invention and secures a priority date; no claims required | Form 1 (application), Form 2 (provisional specification), Form 3 (foreign filings), Form 5 (inventorship), Form 28 (startup or small-entity status) | Day 0 |
| 4. Complete specification | Full description, drawings and claims | Form 2 (complete) | Within 12 months of the provisional |
| 5. Foreign protection (optional) | PCT international application claiming the Indian priority, then national phases | PCT request | PCT within 12 months; national phase at about 30–31 months |
| 6. Publication | Application published; early publication possible on request | Form 9 for early publication | 18 months from priority by default |
| 7. Request for examination | Examination begins only on request; startups can request expedited examination | Form 18, or Form 18A for expedited | Within 31 months of priority under the 2024 rules (verify) |
| 8. Examination and response | Examiner issues a report; applicant responds and may attend a hearing | Response to the First Examination Report | Response due within about 6 months of the report (extendable) |
| 9. Grant and renewal | Patent granted if objections are overcome; annual renewal fees keep it alive | Renewal fees | Up to 20 years from filing |

Fees are lower for natural persons, startups, small entities and educational institutions, and DPIIT-recognised startups can use the Startup India IP scheme for fee rebates and facilitator support. Check current amounts on the Indian Patent Office website before budgeting.

### 14.5 Conference paper procedure, step by step

1. Choose the venue and read its call for papers: page limit, template (IEEE, ACM sigconf or Springer LNCS), anonymity rules.
2. Register an abstract where required (ISFPGA required it a week before the paper).
3. Submit the anonymised PDF through the venue's system (EasyChair, HotCRP, EDAS). Declare conflicts of interest.
4. Peer review, typically 6–10 weeks, sometimes with a rebuttal window of a few days.
5. On acceptance, revise for the camera-ready deadline, sign the copyright or open-access agreement, add author names back.
6. Register at least one author and present in person (visa lead times for US or European venues can be months).
7. The paper appears in IEEE Xplore, the ACM Digital Library or Springer Link, and becomes citable prior art.

### 14.6 Immediate housekeeping

- **Add a licence to the repository.** The ProjectFlash repository has no licence file, which legally means "all rights reserved" and confuses reviewers and collaborators. Choose deliberately: Apache-2.0 (permissive with an explicit patent grant) or a non-commercial licence if the team wants to keep commercial options open.
- **Freeze a public snapshot** of the code used for the paper (a tagged release with a DOI via Zenodo).
- **Adopt a disclosure rule**: new inventions go to the professor and the IP cell before any talk, poster, repository push or hackathon.

## 15. Roadmap and future work

The next twelve months move FLASH from a verified simulation to a board-measured accelerator, then to new datasets with external validation, and only then towards a clinical pilot. Each phase ends at a gate that is also a publication or a go/no-go decision.

&#91;embedded content: FLASH roadmap · 5 phases, 5 gates\]

Phase 0 is the only phase that is time-critical today: everything in it feeds the 25 October ARC submission.

### 15.1 Future work: new datasets

The team plans to retrain and re-verify the same engine on new data. Because the network's shape lives in the layer table and weights in memory files, a new dataset needs a new training run and a new bit-exact sweep, not new Verilog.

| Dataset | Population and origin | Size (approximate, to verify) | Access | Role for FLASH |
| --- | --- | --- | --- | --- |
| Partner hospital (Hyderabad), to be arranged | Indian patients, the target population | Target a few thousand studies | Institutional Ethics Committee approval and data-sharing agreement | Most valuable: local external validation, then fine-tuning |
| VinDr-CXR | Adults, two Vietnamese hospitals, radiologist-labelled DICOM | About 18,000 images | PhysioNet credentialing | External test set with different scanners and population |
| PediCXR (VinDr-PCXR) | Children, Vietnam, radiologist-labelled | About 9,000 studies | PhysioNet credentialing | Brings the pediatric pitch back with real pediatric data at full resolution |
| Kermany pediatric set at full resolution | Children aged 1–5, Guangzhou | 5,856 images | Open (Mendeley Data) | Same source as PneumoniaMNIST, now at 224×224; direct comparison with v0 |
| MIMIC-CXR | Adults, Boston ICU and ED, native DICOM, report-derived labels | About 377,000 images | PhysioNet credentialing and training course | Large pre-training set; noisier labels |
| CheXpert, NIH ChestX-ray14 | Adults, US | About 224,000 and 112,000 images | Registration or open | Pre-training and robustness checks |
| TB sets (for example TBX11K, Shenzhen, Montgomery) | Mixed | Small to about 11,000 | Open | Extension to tuberculosis screening on the same engine |

Methodological rules carried forward: split by patient; choose the operating point on validation drawn from the same distribution as test; report AUROC with confidence intervals, subgroups (sex, age band, view, site) and the view-position shortcut floor; and keep the golden-model equality checks for every new weight file.

### 15.2 Future work: hardware

- **Parallel output channels.** Computing 8 or 16 output channels per clock uses DSPs that sit idle today and should cut the derived 163 ms per image by roughly the same factor.
- **Shorter critical path.** Replace multiplications in address generation with incrementing counters; this should raise the clock above 75 MHz.
- **Right-sized buffers.** Size the two feature-map memories per layer to free about a third of the BRAM for a larger model.
- **Line-buffer engine.** Wire in the already-verified `line_buffer_v1.v` so convolution reads each pixel once instead of nine times.
- **Standalone device.** Replace the Jupyter demo with a small C program on the ARM, an SD-card or USB input, and an LED or screen output; the bitstream stays the same.
- **Explainability.** Add a coarse class-activation heat-map, computed from the GAP and FC weights, so clinicians see where the model looked.
- **Other findings.** Multi-label output (pneumonia, TB, effusion) with the same backbone, as the hackathon's "other diseases" slide proposed.

### 15.3 Future work: clinical and regulatory path in India

1. **Retrospective external validation** on a partner hospital's anonymised images, approved by an Institutional Ethics Committee and following ICMR's 2023 ethical guidelines for AI in biomedical research and healthcare.
2. **Prospective pilot** as a triage aid: the device reads every film, a teleradiologist reads every film, and agreement is measured. Register the study with the Clinical Trials Registry – India (CTRI) if it is a clinical investigation.
3. **Regulatory route.** Software and devices that inform diagnosis are medical devices under the Medical Devices Rules, 2017, administered by CDSCO. The risk class and required clinical evidence must be confirmed with a regulatory consultant.
4. **Data protection.** Handle any personal data under the Digital Personal Data Protection Act, 2023; the offline design helps, but training data still needs consent or a lawful basis.
5. **Quality system.** A medical-device startup will eventually need an ISO 13485 quality management system and IEC 62304-style software life-cycle records; the project's existing single-source-of-truth notebook and regression harness are a good foundation.

## 16. Open questions for the professor

Ten decisions need the professor's input before writing starts; the first three are time-critical because the ARC deadline is 25 October 2026.

1. **Venue and timing.** Aim for the ARC 2027 short paper (26 days from today), or wait and target FCCM or FPL 2027 with board results?
2. **Framing.** Lead with the verification methodology (stronger novelty at FPGA venues) or with the medical application (stronger story, weaker novelty)?
3. **Authorship and affiliation.** Author order, the professor's role as co-author, and the affiliation line.
4. **Hardware access.** The repository notes that the board is not currently in hand. Can the lab provide a PYNQ-Z2 (and ideally a power meter) for the V1 bring-up?
5. **Comparison platforms.** Is a second board available (for example a Zynq UltraScale+ kit) or a Raspberry Pi-class computer for the "why an FPGA" comparison?
6. **Clinical data.** Does the department have a contact at a Hyderabad hospital for an external validation set, and what does the Institutional Ethics Committee require?
7. **Pediatric versus adult.** Keep the pediatric pneumonia story (needs new data) or reframe around adult pneumonia and tuberculosis first?
8. **Intellectual property.** What does BITS Pilani's IP policy say about student inventions, and did the AMD hackathon's terms assign any rights? When exactly was the hackathon presentation made public (this sets the US 12-month window)?
9. **Repository.** Keep it public during review (with an anonymised mirror) or make future work private until filings are decided?
10. **Funding.** Is there support for conference registration, open-access charges and travel, or should the team apply to student travel grants?

## 17. Glossary

| Term | Plain meaning |
| --- | --- |
| Accumulator | The register that holds a running sum during a multiply-accumulate; its bit width must fit the largest possible sum |
| AP / PA view | Two ways of taking a chest X-ray: front-to-back (AP, often bedside, sicker patients) or back-to-front (PA, standing, outpatients) |
| AUROC | Area under the ROC curve; probability a random sick case scores above a random healthy one |
| AXI, AXI-Lite, AXI-Stream, AXI-DMA | ARM's on-chip bus family: register access, streaming data, and a memory-to-stream copy engine |
| BRAM | Block RAM, dedicated on-chip memory tiles in an FPGA |
| Bit-exact | Two computations produce identical integers, not just similar values |
| Bitstream | The configuration file that programs an FPGA |
| CDSCO | Central Drugs Standard Control Organisation, India's medical device regulator |
| Clamp | Limit a value to a range, here 0–255 |
| CNN | Convolutional neural network |
| DICOM | The standard file format and protocol for medical images |
| DSP48E1 | A hard multiplier-adder block in AMD 7-series FPGAs |
| FF | Flip-flop, a 1-bit storage element updated each clock tick |
| FPGA | Field-programmable gate array, a chip whose logic is configured after manufacture |
| GAP | Global average pooling: one average per channel |
| Golden model | An independent, trusted reference implementation used to check hardware |
| INT8 / UINT8 | Signed (−128…127) or unsigned (0…255) 8-bit integers |
| Logit / margin | Raw class score / difference between the two class scores |
| LUT | Look-up table, the basic programmable logic cell |
| MAC | Multiply-accumulate |
| NPV / PPV | Share of negatives that are truly negative / share of positives that are truly positive |
| Ping-pong buffer | Two memories that swap roles each layer: one is read while the other is written |
| PL / PS | Programmable Logic (FPGA fabric) / Processing System (ARM cores) of a Zynq |
| QAT / STE | Quantization-aware training / straight-through estimator |
| ReLU | Activation that sets negatives to zero |
| RTL | Register-transfer level hardware description, here in Verilog |
| SAIF | Switching activity file from simulation, used for realistic power estimates |
| Sensitivity / specificity | Share of sick cases caught / share of healthy cases cleared |
| Shortcut learning | A model exploiting a cue correlated with the label (such as film type) instead of the disease |
| Slack (WNS / WHS) | Spare time on the worst setup / hold timing path; positive means timing is met |
| Stride | Step size of the sliding filter |
| Synthesis / implementation | Converting RTL to FPGA primitives / placing and routing them on the chip |
| Vectorless power | A power estimate that assumes default switching activity; not a measurement |
| Zynq-7020 | AMD/Xilinx system-on-chip with two ARM cores and FPGA fabric; the chip on the PYNQ-Z2 board |

## 18. References and sources

Web sources below were opened on 29 September 2026. Academic references marked "to verify" were not re-checked for this brief and must be confirmed against the original before citation.

### 18.1 Project materials

- Team FLASH, AMD FPGA Hackathon 2026 presentation (5th place) and project prep document.
- [Karthik-Flash/ProjectFlash](https://github.com/Karthik-Flash/ProjectFlash): README, `docs/V0_SUMMARY.md`, `docs/V0_CHANGELOG.md`, `docs/V1_audit_v1_1.md`, `docs/V1_audit_v1_2.md`, `docs/V1_synth_results_v1_1.md`, `docs/V1_synth_results_v1_2.md`, `colab/ProjectFlash_V1.ipynb`, `v1/mem/*/manifest.json`, `v1/rtl/*.v`.
- Karthik-Flash/PneumoniaFPGA (hackathon repository).

### 18.2 Health and workforce

- [WHO, Pneumonia in children, fact sheet, 11 Nov 2022](https://www.who.int/en/news-room/fact-sheets/detail/pneumonia).
- [Medical Dialogues, World Pneumonia Day 2021](https://medicaldialogues.in/photo-stories/world-pneumonia-day-2021-46) (2.5 million deaths, all ages, 2019).
- [5C Network, Radiologist shortage in India, May 2026](https://www.5cnetwork.com/resources/radiologist-shortage-india).
- [Radiology Today e-newsletter, Aug 2024](https://radiologytoday.net/enewsletter/2024/august).
- Adegbola R.A. (2012), *Clinical Infectious Diseases* 54:S89–S92; Mariani G. et al. (2017), *Nuclear Medicine Communications* 38:1024–1028 (from the prep document; to verify).

### 18.3 Datasets and medical AI

- Kermany D.S. et al. (2018), "Identifying medical diagnoses and treatable diseases by image-based deep learning", *Cell* 172(5) (source of PneumoniaMNIST; to verify).
- Yang J. et al. (2023), "MedMNIST v2", *Scientific Data* 10 (to verify).
- Shih G. et al. (2019), "Augmenting the NIH chest radiograph dataset with expert annotations of possible pneumonia", *Radiology: Artificial Intelligence* 1(1) (RSNA dataset; to verify).
- [Rajpurkar P. et al. (2017), CheXNet, arXiv:1711.05225](https://arxiv.org/pdf/1711.05225).
- Zech J.R. et al. (2018), "Variable generalization performance of a deep learning model to detect pneumonia in chest radiographs", *PLOS Medicine* (shortcut learning across hospitals; to verify).
- Sabottke C.F., Spieler B.M. (2020), "The effect of image resolution on deep learning in radiography", *Radiology: Artificial Intelligence* 2(1) (to verify).
- Nguyen H.Q. et al. (2022), "VinDr-CXR", *Scientific Data* (to verify).

### 18.4 Quantization and FPGA

- Jacob B. et al. (2018), "Quantization and training of neural networks for efficient integer-arithmetic-only inference", CVPR (to verify).
- Bengio Y., Léonard N., Courville A. (2013), straight-through estimator, arXiv:1308.3432 (to verify).
- Umuroglu Y. et al. (2017), "FINN", ACM FPGA (to verify).
- Duarte J. et al. (2018), hls4ml, *Journal of Instrumentation* (to verify).
- FPGA implementation of a DCNN for TB and pneumonia detection using CXR images, *IEEE Embedded Systems Letters* (2024), doi 10.1109/LES.2024.3370833 (authors to verify).
- [BCPNN stream accelerator on Alveo U55C, arXiv:2503.01561](https://arxiv.org/pdf/2503.01561).
- [HLS-compiled PYNQ-Z2 ECG arrhythmia CNN, *Biomedical Signal Processing and Control* (2025)](https://www.sciencedirect.com/science/article/abs/pii/S1746809425005749).
- [ZynqNet, arXiv:2005.06892](https://arxiv.org/pdf/2005.06892).
- [FPGA-based ResNet-50 for pneumonia detection on ZCU104 (ResearchGate listing)](https://www.researchgate.net/figure/The-design-flow-for-CNN-on-PYNQ-Z2_fig2_357971914).

### 18.5 Competitors and policy

- [Qure.ai qXR-Detect FDA clearances, Business Wire, 26 Feb 2026](https://www.businesswire.com/news/home/20260226643266/en/Qure.ai-Nets-Six-New-Indications-Cleared-by-the-FDA-Taking-the-Chest-X-ray-Crown-in-the-Radiology-AI-Race).
- [MSF catalogue entry, CAD4TB offline kit](https://unicat.msf.org/cat/product/92522?page=501).
- [CHAI, CAD agreements FAQ, Sept 2026](https://www.clintonhealthaccess.org/wp-content/uploads/2026/09/CAD-Agreements_FAQ-Document.pdf).
- [WHO policy statement on CAD for TB screening, 2025](https://www.who.int/publications/i/item/9789240110373).
- [User perspectives on X-ray and CAD for TB, 2022 survey (PMC)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC9621304/).
- [Scanned: global investments in CAD and ultraportable X-ray for TB (PMC)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11913293/).

### 18.6 Venues and intellectual property

- [FPGA 2027 call for papers](https://www.isfpga.org/call-for-papers/); [ARC 2027 call for papers](https://easychair.org/cfp/arc2027); [FPL 2026 call for papers](https://2026.fpl.org/calls/call-for-papers/).
- [Intepat, What can be patented in India, July 2026](https://www.intepat.com/blog/what-can-be-patented-india); [Lexology, Anticipation under the Patents Act, March 2026](https://www.lexology.com/library/detail.aspx?g=63c54e6a-af0d-40d8-afd8-bb8faf3732d6); [R.K. Dewan, Patent after public disclosure in India, 2025](https://www.rkdewan.com/blogs/patent-after-public-disclosure-in-india/); [IIPRD, Section 3(k), May 2026](https://www.iiprd.com/software-patents-in-india-understanding-section-3k-of-the-patents-act/).
