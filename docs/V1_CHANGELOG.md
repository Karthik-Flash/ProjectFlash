# v1 — what changed and why (v1_0 → v1_2)

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

Committed per stage: 47,432 int8 weights, 170 int32 biases, a 7-line layer table,
**shared across v1_1 and v1_2**. Only `IMG_H/W`, conv4/5 shift, `s_gap` and
`DEFAULT_THRESHOLD` differ per stage. `9a1837e` adds the smoke-test directories to
`.gitignore`.

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
