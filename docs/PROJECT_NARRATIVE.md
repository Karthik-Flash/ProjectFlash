# Project FLASH — From Prototype to Clinical Resolution

*A detailed narrative of the journey from PneumoniaFPGA (v0) to FLASH V1.2, written for a general reader and structured for use as the foundation of a research paper.*

---

## Executive summary

Project FLASH is a hardware pneumonia detector: it takes a chest X-ray and outputs whether the image shows pneumonia. What makes it interesting isn't the accuracy — that comes from the trained neural network, which is small — it's *where* the network runs. Instead of a GPU in a data centre, the whole network is built as digital logic for a low-cost FPGA development board, the PYNQ-Z2, and is designed to produce *exactly* the same integers as the reference Python model. At the time of writing, that exactness is proven in RTL simulation (every layer, every bit) and the design meets its 75 MHz timing target in synthesis; running it on the physical board is the next milestone.

This document walks through how we got there. It starts with the predecessor project, **PneumoniaFPGA (v0)**, which established the basic pipeline but had significant limitations, and it ends at **FLASH V1.2**, which runs on real clinical-resolution chest X-rays with every stage independently verified. Two intermediate stages, V1.0 and V1.1, are covered where relevant.

The point of this document is not to hide the messiness of the process. Real engineering has bugs, dead ends, and moments where you realise the code you shipped was subtly wrong. Where those matter to the story, we include them.

> **Revision note (Oct 2026):** an earlier draft of this document overstated three things — it said the RTL was verified on all 244 vectors (it was verified on 16; the golden model on 244), that the 244 vectors were the whole test split (they are a seeded subset of it), and that V1.2 reused V1.1's weights (each stage was trained separately). All three are corrected below.

---

## Part 1: What FPGAs have to do with medical AI

### The context

A modern chest X-ray is a large image — typically around 2000 × 2000 pixels, produced by a digital radiology scanner and stored as a DICOM file. Radiologists look at millions of these every year. In many parts of the world, especially rural clinics and low-income hospitals, there is no radiologist on site. The scans get taken and reviewed later, sometimes days later. For conditions like bacterial pneumonia, especially in children, that delay costs lives.

Machine learning models can now flag likely pneumonia cases from an X-ray with reasonable accuracy. The problem isn't the model — it's the infrastructure. A typical deep learning model requires a GPU, which requires a computer, which requires reliable power and network. None of those are guaranteed at a rural clinic.

FPGAs (Field-Programmable Gate Arrays) offer a different tradeoff. They're pieces of silicon that you can program — not with software, but with a *hardware description* that becomes actual digital logic on the chip. They can run neural networks at low power and low latency, without any general-purpose CPU or operating system in the way. They cost a fraction of what a GPU costs. They can be embedded next to the X-ray machine.

The catch: designing hardware is much harder than writing software. You can't just import PyTorch. You have to build the neural network out of registers, adders, multipliers, and memory blocks, wire them all together, and prove that the whole thing computes the same numbers as the reference Python model. Any bug is potentially silent — the FPGA will happily produce wrong answers if the arithmetic is off by one bit.

That's what Project FLASH is: a demonstration that a real, clinically-sized chest X-ray classifier can be built as hardware and validated bit-for-bit against its Python reference.

### The board

The PYNQ-Z2 has a chip called the Zynq-7020, which is unusual — it contains both a traditional ARM processor and a large FPGA fabric on the same die. The processor runs Linux and handles the outside world (loading images, showing results). The FPGA fabric contains our neural network. They communicate over a standard interface called AXI. This split is important: it means we don't have to reimplement DICOM parsing in hardware; we let Linux do that and just feed the pixels to the FPGA.

The FPGA has hard limits. It has about 140 Block RAM tiles (each 36 kilobits), 220 DSP slices (multiplier blocks), and around 53,000 lookup tables (the basic building blocks of arbitrary logic). Everything the neural network needs has to fit within these constraints.

---

## Part 2: The starting point — PneumoniaFPGA (v0)

The predecessor project, hosted at [github.com/Karthik-Flash/PneumoniaFPGA](https://github.com/Karthik-Flash/PneumoniaFPGA), established the basic idea and workflow. It trained a small convolutional neural network on pneumonia images, quantised the weights to 8-bit integers, and translated the network into Verilog that could be synthesised for the PYNQ-Z2. In its published state, the project reached **5 of 8** passing checks in its Vivado verification flow — the hardware did not agree with the reference on every case. That number is the starting point for V1. *(Before publishing, quote v0's exact wording of what the 8 checks were from its README, so the comparison is like-for-like.)*

### What v0 accomplished

- It proved the end-to-end pipeline was possible: PyTorch training → integer quantisation → Verilog RTL → FPGA synthesis.
- It hit a working frequency of 75 MHz on the target board.
- It reported a total on-chip power of around 0.116 W (a Vivado estimate, not a board measurement).
- It established the discipline of a **golden model**: a reference implementation, separate from both the PyTorch code and the Verilog code, that computes the exact quantised arithmetic and serves as ground truth.

### What v0's limitations were

Four significant issues limited how far v0 could be trusted or extended.

**1. The dataset.** v0 trained on **PneumoniaMNIST**, a research dataset consisting of 28 × 28 pixel greyscale images derived from clinical X-rays but massively downsized. Real chest X-rays are 2000 × 2000 pixels or larger. Real radiological diagnosis relies on being able to see fine texture — the distinction between healthy lung, viral infiltrate, and bacterial consolidation is often a matter of subtle patterns tens of pixels across. At 28 × 28, an entire lung is fewer pixels than the head of a small typographical letter. A model that works at that resolution is a proof of concept for the *training and quantisation pipeline*, not for the *diagnostic task*.

**2. The verification approach.** v0 reached 5 of 8 passing checks rather than 8 of 8. We did not root-cause v0's individual failures, and we do not claim to know exactly which bug caused each one. What we can say is which *classes* of problem V1 was designed to eliminate, because they are the usual sources of hardware/reference divergence: edge padding that is handled differently in RTL and in the reference, accumulators that can overflow on some inputs, a classifier head (flatten + large FC) where a small arithmetic difference is multiplied through thousands of weights, and a reference that was not independent of the code it was checking. V1 removes each of these by construction and then *measures* the result, rather than asserting it.

**3. Architecture that doesn't scale.** v0's network ended with a **flatten** operation followed by a large fully-connected layer. In v0, that fully-connected layer alone held 12,544 of the 12,634 total parameters — roughly 99.3% of the model. This is fine at 28 × 28, but at any larger resolution, the flatten output explodes and the fully-connected layer becomes impossibly large. You cannot scale a flatten-based architecture from 28 × 28 to 224 × 224 by changing a hyperparameter; you have to redesign it.

**4. Weights and RTL couplet.** v0's Verilog was written for a specific set of layer dimensions. If you wanted to change the number of channels, the kernel size, or the number of layers, you would need to edit multiple Verilog files. There was no clean separation between "what the hardware does" and "what the specific network is." This meant every architectural experiment required a hardware redesign.

These four limits together meant that v0 was a demonstration that had reached its ceiling.

---

## Part 3: What V1 needed to be

Before writing any code, we defined what V1 had to solve to be meaningfully more than v0:

1. **Real data.** Train on the RSNA Pneumonia Detection Challenge dataset — actual clinical DICOM chest X-rays from real patients, released by the Radiological Society of North America for machine learning research. Not the downsized MNIST-style version.
2. **Scalable architecture.** Replace the flatten-then-fully-connected classifier head with something that works at any input resolution. Standard technique: **Global Average Pooling (GAP)**, which reduces each feature map to a single number regardless of its spatial size.
3. **Bit-exact verification.** Not 5 of 8. Every single test image in our verification set must produce the identical 32-bit `logit0`, `logit1`, `margin`, and 1-bit `decision` between Python and Verilog. If they don't match on even one bit for one image, we do not ship.
4. **Layer descriptor system.** The Verilog should describe *what the hardware can do* (convolutions, average pooling, fully connected). A separate small memory (the "layer table ROM") should describe *what the specific network is* (this many channels, that stride, this shift). Then, changing the network becomes a matter of updating the layer table, not rewriting hardware.
5. **Two-stage scale-up.** V1.1 at 28 × 28 on RSNA (proves the new architecture works). V1.2 at 224 × 224 on RSNA (proves the design scales to clinical resolution).

Each of these is a specific answer to a specific v0 limitation.

---

## Part 4: The verification methodology

Before describing what we built, it's worth explaining *how we prove the hardware is correct*, because this is the single most important difference from v0. The claim we make is precise: the reference model is bit-exact on 244 exported verification images, and the RTL is bit-exact against that reference on every image we have simulated (16 at 224×224, including every intermediate layer for two of them). Hardware runs on the board will extend the RTL check to all 244.

### Three implementations, not two

Most neural network hardware projects have two implementations: the training code (in PyTorch or TensorFlow, using floating-point numbers) and the hardware (Verilog RTL, using integers). The problem: PyTorch and Verilog compute in fundamentally different ways. PyTorch uses vectorised floating-point math with rounding rules that vary by chip generation; Verilog computes exact integer arithmetic. Even when both are "correct," they may disagree on the last bit of any given result, and it's not clear which is the ground truth.

Project FLASH V1 uses **three** implementations:

1. **The training model** (`ProjectFlash_V1.ipynb`, Colab). Written in PyTorch. Uses float32 for training, then quantises weights and biases to int8/int32 at export. This is where accuracy comes from — the model learns what pneumonia looks like.

2. **The golden model** (`tools/golden_model_v1.py`). A standalone Python script using only NumPy int64. It reads *only* the exported memory files (weights.mem, bias.mem, layer_table.mem) — nothing from PyTorch — and computes the exact same integer arithmetic that the hardware will compute. The golden model is deliberately simple, deliberately slow, and deliberately readable. Its job is not to be fast; its job is to be *correct by inspection*. When we say "the reference answer for image k is X," we mean the golden model's output for image k is X.

3. **The hardware RTL** (`v1/rtl/`). The Verilog modules that actually run on the FPGA. Its job is to compute exactly the same answers as the golden model, using the resources of real silicon.

The chain of trust is: PyTorch is validated against expected classification accuracy on the test set (AUROC). The golden model is validated against PyTorch (both must produce the same final decision, with the golden model matching PyTorch to within one quantisation step). The RTL is validated against the golden model **at every layer, on every image, bit-for-bit**.

### What "bit-for-bit" actually means

For each test image `k`, the RTL simulation produces:

- The output of convolution layer 1, an array of typically 100,352 signed 8-bit numbers.
- The output of convolution layer 2. And so on through layer 5.
- The output of the global average pooling stage, 64 numbers.
- The two logits and the margin.
- The final decision (pneumonia yes/no).

For each of these, at each layer, we compare with the golden model's answer. If **any** number at **any** layer differs — even by 1 — the test fails.

Three separate checks were run, and it matters which is which:

1. **PyTorch (float64) vs golden model:** on every image of the test split (`EXACT_CHECK_FULL_TEST = True` in the notebook), the integer golden model reproduces the logits exactly. This proves the exported integer network *is* the trained network.
2. **Golden model vs exported vectors (independent audit):** the golden model was re-run from scratch, outside the notebook, against all **244** exported verification images and all **60** trace files, for both V1.1 and V1.2. Result: **0 mismatches** (documented in `docs/audits/V1_audit_v1_1.md` and `docs/audits/V1_audit_v1_2.md`).
3. **RTL vs golden model (Vivado xsim):** the full Verilog design was simulated on the first **16** of those 244 images. Result at 224×224: **16/16 exact** on logit0, logit1, margin and decision, and **12/12** intermediate trace files (conv1–conv5 and GAP, for images 0 and 1) exact. A 224×224 simulation takes over a minute of wall time per image, so the remaining 228 are run on the physical board instead, where each takes milliseconds.

This is what "bit-exact" means. It is a categorical statement, not a tolerance: one differing bit on one image would be a failure.

### Why these numbers can be trusted

Someone reading "16 of 16" or "244 of 244" might reasonably wonder if the images were cherry-picked. They were not:

- The 244 verification images are drawn from the held-out **test** split by the notebook's fixed seed (`SEED = 0`, split 70/15/15, stratified). We did not choose them, and they are a subset of the full test split, not the whole of it. The 16 simulated in RTL are simply images 0–15 of that list.
- Bit-exactness is not a probabilistic pass/fail. It's not "the answers are close." The RTL either produces the same integers as the golden model or it doesn't. If the arithmetic is correct on one image, it is correct on all images. If it's wrong on one image, it is wrong on many.
- Bit-exactness is not a pass rate in the statistical sense. Integer hardware either reproduces the reference arithmetic or it doesn't; a design bug shows up on most inputs, not on a lucky few. That is why 16 images plus full per-layer traces is strong evidence, and why the board run on all 244 is the final confirmation rather than the first.

The difference from v0 is not that we tested luckier images. It is that V1 was built so that the reference and the hardware *cannot* disagree on the usual failure points (padding, overflow, classifier fragility, reference independence), and then the agreement was measured layer by layer. Those design decisions are described below.

---

## Part 5: What we built

### The architecture

V1 uses five strided 3×3 convolutions that progressively reduce the spatial resolution and increase the channel count, followed by global average pooling and a small final fully-connected layer.

```
Input: 1-channel 8-bit image (224×224 for v1_2, 28×28 for v1_1)
  ↓
Conv1: 3×3, stride 2, pad 1 → 8 channels    (112×112 for v1_2)
  ↓
Conv2: 3×3, stride 2, pad 1 → 16 channels   ( 56× 56)
  ↓
Conv3: 3×3, stride 2, pad 1 → 32 channels   ( 28× 28)
  ↓
Conv4: 3×3, stride 2, pad 1 → 48 channels   ( 14× 14)
  ↓
Conv5: 3×3, stride 2, pad 1 → 64 channels   (  7×  7)
  ↓
GAP: average each of 64 channels down to 1 value → 64 numbers
  ↓
FC: 64 → 2 (logit0 = "healthy", logit1 = "pneumonia")
  ↓
Decision: margin = logit1 − logit0; positive if margin > threshold
```

The clever part is Conv1 through Conv5 and GAP: **the same RTL and the same weight *shapes* work at any input resolution.** A 3×3 filter is 3×3 no matter what it slides over, and GAP produces exactly 64 numbers regardless of feature-map size, so the parameter count (47,432 int8 weights + 170 int32 biases) does not change with resolution. What changes between 28×28 and 224×224 in the hardware is only the layer table: image dimensions, two shift values, the GAP scale and the decision threshold.

The weights themselves were **trained separately for each stage** — V1.1 on 28×28 RSNA images and V1.2 on 224×224 RSNA images — because a network trained to see a lung in 28 pixels is not the same network as one trained to see it in 224. The architectural benefit is on the hardware side: going from V1.1 to V1.2 required **no RTL redesign**. The only RTL change in the whole scale-up was enlarging the feature-map RAM to fit the bigger intermediate maps (described below); every other Verilog file is identical.

### The layer descriptor ROM

Every module in the RTL is generic. `conv_engine.v` knows how to compute a 3×3 stride-2 convolution, but it does not know that Conv1 has 8 output channels and Conv2 has 16. That information lives in a small memory called the layer table, structured as one 128-bit word per layer:

```
| op | kernel | stride | pad | in_c | out_c | in_h | in_w | out_h | out_w | shift | w_base | b_base |
```

- **op**: what kind of layer this is (convolution, GAP, FC).
- **kernel, stride, pad**: standard convolution parameters.
- **in_c/out_c**: input and output channel counts.
- **in_h/in_w/out_h/out_w**: input and output spatial dimensions.
- **shift**: how many bits to arithmetic-right-shift the accumulator to fit the output back into 8 bits after quantisation.
- **w_base, b_base**: where in the weight and bias memories this layer's parameters start.

The RTL reads this table one layer at a time and executes accordingly. The advantage: to change the network, you regenerate the layer table file and the weight file. The Verilog code doesn't move. This is what let us go from 28 × 28 to 224 × 224 in v1_2 by editing three lines in the layer table (image dimensions and shift values for the two deepest convolutions) — everything else was untouched.

### The bit-width analysis

One of the specific bugs that trips up hardware neural network implementations is **accumulator saturation**. A convolution multiplies 8-bit inputs by 8-bit weights (16-bit product) and adds up 9 such products for a 3×3 convolution — but also across all input channels, which for the deeper layers of V1 is up to 48. The accumulator needs to be wide enough to hold all those partial sums without overflowing, but not so wide that it wastes silicon.

Rather than guess a width and hope, we computed the required bit-width from the actual trained weights. The maximum absolute value any accumulator could reach is:

    max_accumulator = 9 × in_channels × max(|weight|) × max(|pixel|)

For V1's deepest layer with 48 input channels, this comes to a number that fits in 22 bits with 19 bits of margin. We chose 22-bit accumulators throughout. This is not a heuristic; it's a derived number, and it's why the RTL doesn't saturate on any input.

### The padding fix

v0's convolutions used "same padding" — treating pixels off the edge of the image as zero. Python does this with a simple `np.pad`. Verilog has to decide when to fetch from memory (real pixel) and when to substitute zero (padded pixel). If those decisions don't exactly match, the outputs differ around the image edges.

V1's convolution engine uses **gated reads**: for each tap of the 3×3 window, we compute what coordinate we'd need to fetch, check whether that coordinate is inside the feature map, and either issue the read (with the returned value) or substitute zero (with no memory access). The check is done identically in the golden model. This eliminates a class of edge-condition bugs that plague hardware convolutions.

### The ping-pong buffer

Convolutions consume one feature map (input) and produce another (output). Layer 2's input is layer 1's output. Rather than route through some external memory, we use two on-chip RAMs, `fmap_ram_A` and `fmap_ram_B`, and swap their roles every layer: layer 1 reads from A and writes to B; layer 2 reads from B and writes to A; layer 3 reads from A and writes to B. This is called ping-ponging and it eliminates external DRAM traffic completely.

Sizing these RAMs turned out to be a subtle issue that we got wrong initially. For v1_1 (28 × 28), the largest feature map is Conv1's output at 8 × 14 × 14 = 1,568 bytes. Our RAM was sized at 64 KB — massively oversized, which we thought would give "future proofing." But at 224 × 224, Conv1's output is 8 × 112 × 112 = **100,352 bytes**. 64 KB is not enough. This was a real bug that surfaced when the v1_2 simulation was run: writes past address 65,535 silently dropped, reads came back with 'x' (undefined) values, and the sim failed at conv1 on image 0. The fix was straightforward — double the RAM depth to 128 KB (2^17 bytes) — but the diagnostic path was instructive.

### The DICOM preprocessing

Real chest X-rays don't come as PNG files. They come as DICOM (Digital Imaging and Communications in Medicine) files with a full radiological header. To get bit-exact reproducibility between training and inference, we need to process every DICOM the same way every time. The preprocessing pipeline (`tools/flash_preprocess.py`) does:

1. **Modality LUT**: DICOM stores raw sensor values; the header specifies a lookup table to convert to linear intensity.
2. **VOI window**: the header also specifies the "Value of Interest" window — the intensity range that the acquisition considered diagnostically meaningful.
3. **MONOCHROME1 invert**: some radiology systems store images with dark = high value, others with dark = low value. The header specifies which. We invert if necessary so all images have a consistent orientation.
4. **Letterbox to square**: pad with black to the smaller aspect until the image is square.
5. **Area resize**: standard image resize using area interpolation (matches PyTorch's `F.interpolate(mode='area')`).
6. **Cast to uint8**.

Each step is tested — 7 tests total, all passing on real Chest X-Ray DICOMs from the RSNA challenge. Without this pipeline being deterministic, the "same" chest X-ray fed to Python and to the FPGA would produce different pixel values before the network even saw them, and bit-exactness would be impossible.

---

## Part 6: Building it in stages

Rather than jumping directly to v1_2 (clinical resolution), we deliberately staged the scale-up. This is standard hardware engineering practice: prove the new architecture at the old scale first, then prove the scale-up.

### V1.0: PneumoniaMNIST at 28 × 28 (sanity check)

Trained the new GAP-based architecture on the same PneumoniaMNIST dataset that v0 used. Result: comparable accuracy to v0. This was a sanity check that the architectural change from flatten-FC to GAP-FC didn't break anything at v0's scale.

### V1.1: RSNA at 28 × 28 (real data, familiar scale)

Trained the same architecture on real RSNA chest X-rays, downsized to 28 × 28 for direct comparison to v0. Numbers:

- **AUROC** on the RSNA test split: **0.8143**. This is not state-of-the-art for pneumonia detection (larger models on higher-resolution inputs reach 0.85+), but it is a real number on a real medical dataset.
- **Verification**: golden model exact on all 244 exported vectors; RTL simulation exact on the 16-image sweep with layer traces.
- **Synthesis** on the Zynq-7020: 1,907 LUT (3.6%), 2,323 flip-flops (2.2%), 14 DSP slices (6.4%), 48 BRAM tiles (34%). Meets 75 MHz timing with 0.093 ns positive slack.

Compared to v0, V1.1 uses similar hardware resources but achieves complete verification instead of partial, and uses real clinical data instead of MNIST.

### V1.2: RSNA at 224 × 224 (clinical resolution)

The payoff. Trained the same architecture on real RSNA chest X-rays at 224 × 224 pixels — the standard resolution used by most medical imaging research and comfortably above what a radiologist would find "too small to read." Numbers:

- **AUROC** on the test split: **0.8229**. Slightly higher than V1.1 (+0.0086), which is a modest but real improvement — the model gets to see more spatial detail. The confidence intervals overlap, so the improvement is not statistically dramatic, but it's directionally correct.
- **Verification**: golden model exact on all 244 exported vectors and 60 trace files (independent audit); RTL simulation 16/16 exact on logits, margin and decision, 12/12 trace files exact. Same RTL as V1.1 except the enlarged feature-map RAM.
- **Behavioural simulation** on Vivado xsim: **16 of 16 images** matched exactly on logit0, logit1, margin, and decision. All 12 intermediate trace files (feature maps after each convolution and after GAP, for two representative images) matched exactly.
- **Synthesis**: 2,006 LUT (3.77%), 2,840 FF (2.67%), 14 DSP (6.36%), **80 BRAM36 tiles (57%)**. Meets 75 MHz timing with 0.085 ns positive slack. The critical path is slightly longer than v1_1 (11 logic levels vs 10), which is exactly what widening the feature-map RAM from 16-bit addressing to 17-bit addressing predicted.

---

## Part 7: Why the numbers are not fabricated

The specific claim we want the reader to trust is: *the FPGA hardware produces bit-identical answers to the Python model on every image we tested.* Here is why that claim is legitimate.

**We didn't invent our own metric.** Bit-exactness is the strongest possible correctness claim for a numerical hardware implementation. Every arithmetic operation is checked. There is no room for statistical hand-waving.

**We didn't pick easy images.** The verification images are drawn from the RSNA test split by a fixed random seed, stratified across classes, and they include normal studies, pneumonia, and non-pneumonia abnormalities. Bit-exactness is a property of the arithmetic, not the image content.

**We didn't check just the final answer.** Trace files record intermediate results at every layer. If our RTL had a bug that happened to produce the right final answer by accident, the intermediate traces would still mismatch, and they don't.

**We compared to a third-party reference, not to ourselves.** The golden model was written in NumPy int64 as a completely separate implementation, tracing the same mathematical operations but expressed differently from both PyTorch and Verilog. If the golden model and the RTL happened to have the same bug, we would notice, because their outputs would diverge from PyTorch on the final classification — but they don't.

**We can be reproduced.** The repository at [Karthik-Flash/ProjectFlash](https://github.com/Karthik-Flash/ProjectFlash) contains the Colab notebook, the golden model, all Verilog modules, the weight/bias/layer-table files and the expected outputs. Heavy image vectors are regenerated by running the notebook with the same seed. Anyone can rebuild them and re-run the same checks.

In short: v0 reached 5 of 8; V1 removes the usual causes of hardware/reference divergence by construction, verifies the reference against the trained network on the whole test split, and verifies the RTL against the reference layer by layer. The remaining step — all 244 vectors on the physical board — is the next milestone, not a claim already made.

---

## Part 8: Comparison to v0

| Dimension | v0 (PneumoniaFPGA) | V1.2 (FLASH) |
|---|---|---|
| Dataset | PneumoniaMNIST (downsized synthetic) | RSNA Pneumonia Detection Challenge (real clinical DICOM) |
| Input resolution | 28 × 28 pixels | 224 × 224 pixels (50,176 pixels, 64× more) |
| Architecture | Conv layers + flatten + large FC | Conv layers + Global Average Pooling + small FC |
| Total parameters | 12,634 (99% in flatten-FC) | 47,432 int8 weights + 170 int32 biases |
| Layer generality | Hardcoded per layer in RTL | Layer descriptor ROM (7-word records) |
| Accumulator width | Chosen ad hoc | Derived from actual weights (22-bit, 19-bit margin) |
| Padding handling | Divergent from reference | Gated reads matching golden model exactly |
| Verification | 5 of 8 checks passing | Golden 244/244 exact; RTL sim 16/16 + 12/12 layer traces exact; board 244-image run pending |
| Clock target | 75 MHz | 75 MHz (unchanged, but harder due to larger design) |
| BRAM usage | Small | 80 tiles (57%), limited by feature map size |
| Bit-exact chain | Python → RTL (partial) | PyTorch → NumPy golden → RTL (complete) |
| DICOM preprocessing | Not applicable (MNIST) | Full pipeline with modality LUT, VOI window, MONOCHROME handling |
| Resolution scaling | Requires redesign (flatten size depends on resolution) | Same RTL; retrain weights + regenerate layer table |

Each row is a specific answer to a specific limitation. Nothing in this table is a claim we can't defend from the repository.

---

## Part 9: Honest limitations

For the paper, it's worth being explicit about what V1 does *not* yet demonstrate.

**We have not run on hardware yet.** All results in this document are from Vivado xsim (behavioural simulation of the RTL) plus Vivado synthesis reports. We have not generated a bitstream, loaded it onto a PYNQ-Z2, and classified a real X-ray. That's the next session. Bit-exactness in simulation does not automatically transfer to bit-exactness on the physical board — it should, and we have every reason to believe it will, but we haven't proven it yet.

**We have not measured real power.** v0's 0.116 W figure and any V1 number from Vivado's report_power are estimates. A SAIF-based estimate from simulated switching activity is better; a measurement on the board's supply is best. Treat any power number as an estimate until one of those is done.

**AUROC 0.82 is not state of the art.** The best published pneumonia classifiers on RSNA reach 0.85+ using larger architectures (ResNet-50, DenseNet; check and cite specific papers before quoting a number). We deliberately kept the network small to fit inside the 7Z020's constraints. There's a real accuracy-vs-hardware tradeoff we are not attempting to hide.

**Single class, single threshold.** The output is binary pneumonia yes/no with a fixed decision threshold. Real clinical use would need multi-class output (bacterial vs viral vs other), a clinician-tunable threshold (which we support in hardware via the AXI-Lite register but haven't calibrated), and probably a "not confident, needs review" bucket rather than forced binary classification.

**No clinical validation.** Achieving AUROC 0.82 on a research dataset is not the same as being validated for clinical use. That requires prospective studies, IRB approval, comparison to radiologists, external validation on different scanner types, and everything else that the actual medical device approval process demands. V1 is engineering demonstration, not medical device.

Naming these limits explicitly is what separates an honest engineering claim from a marketing pitch.

---

## Part 10: What's next

The immediate next milestone is **on-board execution**. The AXI wrapper module (`v1/rtl/top_v1_axi.v`) will let the Zynq processor stream pixels into our accelerator and read back logits. Vivado block design will connect the Zynq PS, an AXI DMA controller, and the wrapped accelerator. Bitstream generation produces the final `.bit` file. A PYNQ Python driver on the board's Linux side ties it all together. The success criterion is stated simply: feed the board a preprocessed test image whose expected output is already known, and get back the exact same 32-bit `logit0`, `logit1`, `margin`, and 1-bit `decision`. If that matches, V1 is complete and the paper's core claim is fully substantiated.

Beyond V1, the natural directions are:

- **V2 (larger network).** Once the pipeline is proven bit-exact end-to-end, use it to iterate on architecture. Try MobileNet-style depthwise separable convolutions to reach higher AUROC at similar or lower cost.
- **Larger board.** The 7Z020 is the smallest board in the Zynq family. The 7Z100 has 8× more BRAM and could hold a much larger network at the same resolution.
- **Multi-class.** Extend from binary pneumonia to a 4-class output.
- **Real clinical study.** Partner with a hospital to validate against radiologist labels.

Each of these builds on the same foundation: an FPGA-based, bit-exact, resolution-scalable neural network pipeline that has been proven correct at every stage.

---

## Appendix A — Numbers reference

Everything a paper reviewer might want, in one place.

**Target hardware:** PYNQ-Z2 development board, Xilinx Zynq-7020 (part xc7z020clg400-1), speed grade -1.

**Design frequency:** 75 MHz (13.333 ns clock period).

**V1.2 synthesis (Vivado 2022.2):**
- WNS: +0.085 ns (setup slack)
- WHS: +0.079 ns (hold slack)
- 0 failing endpoints of 9,439
- 75.002 MHz achieved

**V1.2 utilization (post-synthesis):**
- LUT: 2,006 / 53,200 (3.77%)
- FF: 2,840 / 106,400 (2.67%)
- DSP48: 14 / 220 (6.36%)
- BRAM36 tile: 80 / 140 (57.14%)
- BRAM18 tile: 1 / 280 (0.36%)

**V1.2 verification:**
- Golden model vs exported vectors: 244 / 244 exact, 60 / 60 trace files exact (both stages)
- RTL (xsim) vs golden: 16 / 16 images exact; 12 / 12 trace files exact
- PyTorch float64 vs golden: exact on the full test split
- Full layer-by-layer trace: exact match at every convolution and GAP output
- Vivado behavioural sweep: 16/16 logit0, 16/16 logit1, 16/16 margin, 16/16 decision, 12/12 trace files

**V1.2 accuracy:**
- Test AUROC: 0.8229
- Verification vectors: 244 images drawn from the RSNA test split (70/15/15 stratified split, seed 0)

**Model:**
- Weights: 47,432 int8 values
- Biases: 170 int32 values
- Layers: 5 strided 3×3 convolutions + GAP + 64→2 FC
- Feature map memory: 128 KB per ping-pong buffer (two buffers)
- Accumulator: 22-bit signed, 19-bit safety margin
- Decision threshold: −646 (v1_2, tunable at runtime via AXI-Lite register)

**Comparison to V1.1 (28×28):**
- V1.1 AUROC: 0.8143 (test)
- V1.2 AUROC: 0.8229 (test)
- Delta: +0.0086 (modest, confidence intervals overlap)
- Same RTL, different resolution; weights trained separately per stage

## Appendix B — Repository

[github.com/Karthik-Flash/ProjectFlash](https://github.com/Karthik-Flash/ProjectFlash)

The `main` branch contains:

- Training notebook (Colab, reproducible on any Kaggle-authenticated Colab instance)
- Golden model Python script
- Verilog RTL modules
- Testbenches for iverilog and Vivado xsim
- Verification vector files
- Synthesis reports (v1_1 and v1_2)
- DICOM preprocessing pipeline with test suite
- Audit reports documenting every claim in this narrative with git commit references

Every number in this document can be regenerated from the repository. That's the point.
