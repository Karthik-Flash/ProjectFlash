# Project FLASH — V1 synthesis results, stage v1_1 (28×28)

Vivado 2022.2, PYNQ-Z2 (xc7z020clg400-1), synthesis only (implementation
skipped because top_v1 has 98 unconnected data ports meant for AXI, not
physical pins — see handoff §5).

## Timing

| Metric | Value |
|---|---|
| Target period | 13.333 ns (75.002 MHz) |
| WNS (setup slack) | **+0.093 ns** |
| WHS (hold slack) | +0.079 ns |
| Failing endpoints | 0 / 7,704 |
| Critical path | `u_conv/y_reg[1]` → DSP48E1 → 6× CARRY4 → LUT2/LUT4/LUT5 → `u_ram_a` RAMB36 addr |
| Critical path logic levels | 10 (CARRY4=6, DSP48E1=1, LUT2=1, LUT4=1, LUT5=1) |
| Data path delay | 12.494 ns (logic 7.977 ns / 63.8%, route 4.517 ns / 36.2%) |
| Max achievable frequency, est. | ~75.5 MHz |

Note: paths ending at output ports (`logit0`, `logit1`, `margin`,
`positive`, `result_valid`) report `Slack: inf` because those ports are
not constrained. That is intentional; they become AXI-Lite registers in
the deferred AXI wrapper (handoff §5).

## Utilization

| Resource | Used | Available | % |
|---|---|---|---|
| LUTs | 1,907 | 53,200 | 3.6% |
| FFs | 2,323 | 106,400 | 2.2% |
| DSPs (DSP48E1) | 14 | 220 | 6.4% |
| BRAM36 | 48 | 140 | 34% |
| BRAM18 | 1 | 280 | <1% |

Per-module breakdown (LUT/FF/DSP/BRAM36):

| Module | LUTs | FFs | DSPs | BRAM36 |
|---|---|---|---|---|
| top_v1 (top) | 2 | 71 | 2 | 16 |
| u_conv (conv_engine) | 471 | 178 | 5 | 0 |
| u_dec (decision) | 16 | 0 | 0 | 0 |
| u_fc (fc_unit) | 262 | 271 | 2 | 0 |
| u_gap (gap_unit) | 996 | 1,689 | 2 | 0 |
| u_ram_a (fmap_ram) | 0 | 0 | 0 | 16 |
| u_ram_b (fmap_ram) | 12 | 0 | 0 | 16 |
| u_seq (layer_seq) | 165 | 114 | 3 | 0 |

## Deltas from the audit's estimate

- **DSPs 14 vs predicted 1–3**: Vivado inferred DSPs for address arithmetic
  (`c*in_h*in_w + y*in_w + x`), not just the MAC. Non-issue at 6.4%; will
  be relevant to watch when V1.2 keeps the same arithmetic but at 224.
- **BRAM36 48 vs predicted 13**: two ping-pong fmap RAMs were sized at
  64 KB each for future v1_2 compatibility (v1_2 needs 100 KB per fmap).
  For v1_1 (largest fmap 1.6 KB) this is ~40× oversized but harmless at
  34%. Could shrink by parameterising the RAM depth on IMG size, deferred
  until v1_2 numbers are in hand.

## Known-not-yet-checked

- **Power**: not measured. Vectorless estimate will exist; per handoff §3.2
  it is not a real number. SAIF-based measurement pending.
- **Implementation**: not run; requires AXI wrapper.
- **v1_2 at 224×224**: same RTL, swap mem files, re-synth. Pending.
