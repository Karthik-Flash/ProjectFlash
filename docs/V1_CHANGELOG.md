# v1 — what changed and why (v1_0 → v1_2.1)

Built only from `git log` on `main`. Short hashes cite the commit each claim comes
from. V1.1 is the 28×28 stage, V1.2 the 224×224 stage; both share one RTL.

---

## Step 1 — Audit the exports before writing RTL (`227186b`)

Every `.mem` file's format, the layer-table decode against `layer_table.json`, and
the golden-model round-trip were recomputed independently for both stages: all 244
verification vectors and all 60 trace files, 0 mismatches.

One real gap found: `manifest.json`'s `file_sha256` covers only 3 of 313 `.mem`
files per stage, because the notebook's `EXPORT.glob('*.mem')` is non-recursive.
`vectors/` and `vectors/trace/` therefore have no recorded checksum. Not a
correctness defect, but worth fixing in the notebook.

Model quality: V1.2 leads V1.1 on every reported metric, but only by ~0.009 test
AUROC with overlapping bootstrap CIs. Real but modest.

## Step 2 — Notebook and minimal exports (`c0549f8`, `9a1837e`)

`colab/ProjectFlash_V1.ipynb` became the single source of truth for training,
export and vector generation. Only the hardware-facing subset went into git:
`weights.mem`, `bias.mem`, the layer descriptor table (`.mem`/`.vh`/`.json`),
`sim_config.vh`, `manifest.json`, the golden model, the DICOM preprocessor, and the
per-image expected logits/margin/decision. The 244 `img_*.mem`, 60 trace files,
`model_state.pt` and report figures regenerate from the notebook and stay out
(v1_2 vectors alone are ~50 MB).

Committed per stage: 47,432 int8 weights, 170 int32 biases, a 7-line layer table.
The two stages share the same RTL and the same weight-array shape, but **each
stage was trained separately, so the weight values differ**:

| File | SHA-256 |
|---|---|
| `v1/mem/v1_1/flash_v1_1/weights.mem` | `49EC63B1D9E9D2B12B6F4D0D1955B4BBC01AC14E6AF4A644844643BDFA1C2D00` |
| `v1/mem/v1_2/flash_v1_2/weights.mem` | `0C29226E41EBDFEFB018BE1F19F9ADCF703E1D895FD39E89EBCD21EDB3B89E05` |

The message of `c0549f8` says the weights are "shared across v1_1 and v1_2". That
is wrong: only the shape is shared. In the layer table, `IMG_H/W`, conv4/5 shift,
`s_gap` and `DEFAULT_THRESHOLD` differ per stage. `9a1837e` adds the smoke-test
directories to `.gitignore`.

## Step 3 — RTL bring-up, module by module (merged in `b3cabca`)

Each module was verified bit-exact against golden data before the next was built.

| Commit | Module | Evidence |
|---|---|---|
| `7707dc9` | `conv_engine` — 3×3 stride-2 int8 conv, 22-bit accumulate | conv1 acc + output on img_0, all 1,568 values |
| `8399736` | `line_buffer_v1` — streaming 3×3/stride-2 windower | 196/196 windows; negative control (broken pad gate) fails 182/196 |
| `80890b5` | `fmap_ram`, `decision` | standalone smoke tests, then exercised in the full sweep |
| `6018958` | `gap_unit` — 64-channel global average pool | 64/64 channels vs `img0_gap` trace |
| `9bd2cf9` | `fc_unit` — 64→2 int32 matmul | img_0 logits (1528, 4605) exact |
| `f964249` | `layer_seq`, `top_v1` — full 7-layer pipeline | 16/16 logit0, logit1, margin, decision; 12/12 trace files |

Notes carried in those commits:

- This iverilog (0.9.7) parses neither unpacked-array ports nor 2D arrays, so
  array ports are flattened to packed buses (`win_flat`, `gap_out_flat`,
  `gap_in_flat`) (`8399736`, `6018958`, `9bd2cf9`).
- `gap_unit` applies no clamp. `s_gap = ceil(log2(in_h*in_w))` guarantees
  `sum >> s_gap ≤ 255`, and the golden model clamps nothing (`6018958`).
- `gap_unit` testbench: blocking assignments at the posedge raced the DUT and
  mis-bound samples to the wrong channel. Fixed with non-blocking drives
  (`6018958`).
- `fc_unit` zero-extends GAP activations. Reading 200 as signed int8 gives −56
  and wrecks the logits (`9bd2cf9`).

### Integration defects fixed in `f964249`

- `conv_engine` and `fc_unit` assume 2-cycle memory reads, but `fmap_ram` is
  1-cycle. `top_v1` adds one register stage on the feature-map read path and
  builds the ROMs with two stages. `gap_unit` uses the 1-cycle data directly, so
  its valid/channel tag are delayed one cycle instead.
- `layer_seq` needed two start pulses to relaunch from `S_DONE`, leaving the
  previous image's result standing. One pulse now relaunches.

`line_buffer_v1` is **not** instantiated in `top_v1`: `conv_engine` does its own
per-tap addressing and has no port for a 9-tap window bus. It stays verified
standalone for a future windowed `conv_engine`.

## Step 4 — Vivado project and V1.1 synthesis (`e0b5fdd`, `e1e2e86`, `9ed6f5b`)

`e0b5fdd`: Vivado 2022.2 project at `verilog/ProjectFlashV1/`, xc7z020clg400-1,
75 MHz. xsim matches iverilog: 16/16 logits/margin/decision, 12/12 traces. Only
the XDC is committed. `.mem` files are copied into the xsim run dir out-of-band.

`e1e2e86`: V1.1 (28×28) synthesis met 75 MHz with WNS +0.093 ns, 0 failing
endpoints, 34% BRAM, 6% DSP. Implementation deliberately skipped: `top_v1` has 98
unconstrained data ports meant to become AXI-Lite registers. `.gitignore` gains
`!docs/*.rpt` so the reports are kept.

`9ed6f5b`: the XDC's TCL port guard used a bare `error`, which aborts constraint
processing. Guard dropped; pins, IOSTANDARDs and the 13.333 ns `sys_clk` clock are
unchanged.

## Step 5 — Retarget to V1.2 (224×224)

**Testbench (`a8d3ee8`).** Same RTL, `top_v1` and XDC. Only testbench constants
and memory paths change, plus two required fixes: `WEIGHTS_FILE`/`BIAS_FILE`/
`LAYER_TABLE_FILE` are overridden at instantiation (they still default to the
v1_1 export in `top_v1.v`), and `DEFAULT_THRESHOLD` moves from −8050 to −646 per
v1_2's `sim_config.vh`.

**`fmap_ram` 64 KB → 128 KB (`57126bc`).** v1_2's conv1 output is 100,352 bytes
(8 × 112 × 112), which does not fit 65,536. Depth doubled to 131,072 (2^17). Also
corrects a self-contradictory line in the v1_1 synth write-up.

**Testbench timeout, three passes.**

- `1adcb86`: 200 ms → 5 s. xsim probe showed ~150 ms per image, ~2.5 s per
  16-image sweep. Written as a 64-bit sized literal to avoid 32-bit wrap.
- `142f11c`: xsim rejected the bare sized literal; parenthesised
  `#(5_000_000_000)` parses on both xsim and iverilog.
- `e192198`: `#` delay replaced by a clock-cycle count
  (`while (to_cycles < 1_024_000_000)`), immune to timescale. The in-code comment
  states a ~32M-cycle budget with 4× headroom; the literal bound is 1.024e9.

## Step 6 — V1.2 synthesis (`78d9e58`)

| | V1.1 (`e1e2e86`) | V1.2 (`78d9e58`) |
|---|---|---|
| Input | 28×28 | 224×224 |
| WNS @ 75 MHz | +0.093 ns | +0.085 ns |
| Failing endpoints | 0 | 0 |
| BRAM | 34% | 80 BRAM36 (57%) |
| DSP | 6% | 14 |
| LUT / FF | — | 2006 / 2840 |
| `fmap_ram` | 64 KB | 128 KB |

The V1.2 critical path adds one CARRY4 over V1.1, from the 17-bit `fmap_ram`
address. xsim sweep bit-exact 16/16 against the Python golden model.

Implementation still fails IO placement (98 unplaced ports). The AXI wrapper is
the next step.

*Note added 2026-10-07 (`7c16219`, `d1dc26f`): the `78d9e58` run loaded the
**v1_1** `.mem` files through `top_v1.v`'s parameter defaults. Its LUT/FF
figures are superseded; see Step 7.*

## Step 7 — Honest V1.2 synthesis, AXI wrapper, wrapper simulation (`7c16219`, `d1dc26f`, `726391e`, `d2ecb7e`)

- `top_v1.v` parameter defaults now point at the v1_2 files. Re-synthesis
  logged `Synth 8-3876` for all three v1_2 files and gave WNS +0.085 ns,
  WHS +0.079 ns, 2,675 LUT, 2,845 FF, 80 RAMB36 + 1 RAMB18, 14 DSP at 75 MHz
  (synthesis estimate). The +669 LUT come from the weight ROM, whose logic
  depends on its contents.
- `top_v1_axi.v`: an AXI4-Stream input (32-bit, 4 pixels per beat) and an
  AXI4-Lite register map (CTRL, STATUS, THRESHOLD, LOGIT0/1, MARGIN,
  DECISION, VERSION = 0xF1A50102, CYCLES). It mirrors `tb_v1`: pixels first,
  then a single start pulse.
- `tb_v1_axi.v`: xsim PASS, 33 checks; CYCLES = 12,196,126 per image.

## Step 8 — V1.2 block design and bitstream (`8bb4a58`, `21ace48`)

- Block design `flash_bd`: PS7, AXI DMA (simple mode, MM2S only),
  `top_v1_axi` as a module reference, interrupts concatenated to `IRQ_F2P`.
  Built in the new project `verilog/ProjectFlashV1_hw`.
- FCLK0: the PS cannot make 75 MHz. At 71.428566 MHz the design failed
  post-route timing (WNS −0.925 ns). At **66.666672 MHz** it met timing
  (WNS +0.206 ns, WHS +0.024 ns, 0 of 15,320 failing).
- Board notebook, bundle script and README.

## Step 9 — First board run: 0/244, fault localised offline (`0b1a0d5`, `0952fbf`)

- 2026-10-08, PYNQ 3.1.1: **0/244** bit-exact, 234/244 decisions agree,
  unchanged at 25/50/66.67 MHz.
- Hypothesis search with the golden model: `board == golden(dup_even(x))`
  (each odd 32-bit input word replaced by the even word before it) on
  244/244 images and 24/24 probes. Diagnosis: HP0 port 32-bit while the HP0
  AFI runs in 64-bit mode.
- The V1.2 bitstream is kept as `flash_hp32.bit/.hwh` for the confirmation
  test.

## Step 10 — V1.2.1: HP0 and DMA memory side 64-bit (`2791452`, `40f5040`, `3c40e7e`, `1b51d87`, `b2d6ba9`, `d0b8efc`)

- `create_bd.tcl`: `PCW_S_AXI_HP0_DATA_WIDTH` 64,
  `c_m_axi_mm2s_data_width` 64. Unchanged: stream 32-bit, length width 26,
  simple mode, FCLK0 66.666672 MHz. A direct DMA→HP0 connection is refused
  (`[BD 41-1285]`, AXI4 vs AXI3), so `axi_mem_intercon` keeps only an
  `auto_pc` protocol converter. RTL unchanged.
- `flash_hp64.bit` `0ee58d6c924cd162`, `.hwh` `7011237c69968c86`. Post-route
  WNS +0.314 ns, WHS +0.030 ns, 0 of 15,451 failing. 3,864 LUT, 4,766 FF,
  81 RAMB36 + 2 RAMB18, 14 DSP. Power estimate 1.494 W. The accelerator
  netlist came from the IP cache; all 2,274 `INIT_xx` lines are identical to
  V1.2.
- Notebook: `BIT` selector, a read-only AFI-vs-`.hwh` check, an `AFI_FORCE`
  cell (off by default), auto-saved `results_*.csv` / `summary_*.json`, a
  throughput cell, and an ARM golden-model baseline. Generator
  `v1/board/make_notebook.py`.

## Step 11 — V1.2.1 verified on the board, root cause confirmed (`d22628a`)

- 2026-10-09, one boot. Run 1 `flash_hp64`: **244/244**. Run 2 `flash_hp32`:
  0/244, image by image identical to 2026-10-08. Run 3 `flash_hp32` with AFI
  RDCHAN_CTRL bit 0 written 0 → 1: **244/244**; its CSV is byte-identical to
  run 1's.
- Run 1 latency: 182.94 ms compute (CYCLES), 184.73 ms end to end.
- ARM golden model: 665.1–743.9 ms per image.
- Classification on the 244: TP 117, FN 5, TN 57, FP 65.

## Step 12 — V1.2.1-led and the live demo (`f5d4254`, `3e28697`)

- `axi_gpio_led` on the GP0 interconnect at **0x41200000**, two channels,
  pins from the PYNQ-Z2 board files: LD0–3 = R14/P14/N16/M14; RGB LD4/LD5 via
  the `rgb_led` interface (bits 0/1/2 = LD4 B/G/R, 3/4/5 = LD5 B/G/R).
  Software writes GPIO_TRI = 0 first, because the board interface keeps the
  pins tri-state.
- `flash_hp64_led.bit` `7e0c3394fac1b57d`, `.hwh` `2b37db60135ed638`.
  Post-route WNS +0.344 ns, WHS +0.025 ns, 0 of 15,704 failing. 3,947 LUT,
  4,899 FF. Power estimate 1.499 W. The accelerator netlist is identical to
  `flash_hp64`.
- Demo notebook (`make_demo_notebook.py`): a non-cherry-picked 12-image
  gallery (12/12 bit-exact; ARM mean 706.6 ms vs FPGA 185.0 ms, 3.8×), a live
  244-image sweep (**244/244 re-verified on the board**), a slider with LED
  output, and a limitations section.

## Step 13 — V1 close-out (`d6b77ce` and later)

- Evidence filed in `docs/board_runs/2026-10-08/` and `2026-10-09/`, stored
  byte for byte.
- Repository restructured (`docs/audits/`, `docs/reports/`, `docs/v0/`,
  `docs/archive/`).
- **`v1/board/flash.bit` and `flash.hwh` removed**: they were byte-identical
  to `flash_hp32.bit/.hwh` (`396a219b10690f26` / `5f8c18af7bdf3650`).
- `build_hw.tcl` and `create_bd.tcl` default to an FCLK ceiling of 70 MHz,
  i.e. the verified 66.666672 MHz.
- Project report: `PROJECT_FLASH_REPORT.md`. Tag `v1.2.1-hw`.
