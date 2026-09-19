# V1.2 Synthesis Results (224x224)

Target: PYNQ-Z2, xc7z020-clg400-1, sys_clk 75 MHz (13.333 ns period).
Vivado 2022.2, synthesis run against RTL at commit 57126bc (fmap_ram
widened to 128 KB) plus tb/timeout follow-ups on main. Constraints
from `v1/constr/v1.xdc`. Full reports: `V1_synth_timing_v1_2.rpt`,
`V1_synth_util_v1_2.rpt`.

## Timing

| Metric | Value |
|---|---|
| WNS  | +0.085 ns |
| WHS  | +0.079 ns |
| WPWS | +5.687 ns |
| Failing endpoints (setup / hold) | 0 / 0 |
| Total endpoints  | 9,439 |
| Achieved frequency | 75.002 MHz |

All constraints met. WNS is 8 ps tighter than v1_1 (+0.093), consistent
with the audit prediction that wider BRAM tiles at 224x224 would
stretch the routing budget.

### Critical path

Source `u_conv/y_reg[1]/C` -> destination `u_ram_a/mem_reg_0_0/ADDRBWRADDR[0]`.
11 logic levels: CARRY4=7, DSP48E1=1, LUT2=1, LUT4=1, LUT5=1. One more
CARRY4 than v1_1 -- expected, because `fmap_ram` grew from 16-bit to
17-bit addressing when doubling to 128 KB.

Data path delay 12.502 ns (logic 7.985 ns / route 4.517 ns). No
register-insertion needed; path meets requirement with margin.

## Utilization (post-synth, pre-place)

| Resource | Used | Available | % |
|---|---|---|---|
| LUT     | 2,006 | 53,200 | 3.77 |
| FF      | 2,840 | 106,400 | 2.67 |
| DSP48   | 14 | 220 | 6.36 |
| BRAM36  | 80 | 140 | 57.14 |
| BRAM18  | 1  | 280 |  0.36 |
| BUFG    | 1  | 32  |  3.13 |

Comparison to v1_1 (28x28):
- LUT +99, FF +517: minor; RTL unchanged, extra addressing muxes.
- DSP identical (14): arithmetic width unchanged.
- BRAM36 48 -> 80: fmap_ram doubled to 128 KB; ping-pong (A/B) doubles
  again. Weight/bias RAMs unchanged. 57% BRAM is the dominant footprint.

## What this proves

- Same RTL scales 28x28 -> 224x224 by swapping only export files.
- Bit-exact match against Python golden model on 16-image sweep (see
  xsim run: 16/16 logits, margins, decisions; 12/12 trace files).
- 75 MHz timing survives the 64 KB -> 128 KB memory scale-up.

## What this does not include

- No implementation results (98 unplaced IO ports; expected without the
  AXI wrapper). Real placement, physical utilization, and post-route
  timing land after the wrapper is built.
- No power measurement. SAIF-based power is next.
- No on-board execution. That needs the AXI wrapper + Zynq block
  design + bitstream.
