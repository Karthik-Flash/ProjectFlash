# docs/reports/: Vivado reports, indexed

Every report here is raw Vivado output for one build. Tool: Vivado 2022.2,
part xc7z020clg400-1. Timing and utilisation are measured by the tool on the
routed design; every power figure is a vector-less Vivado estimate.

## The builds

| Tag in file names | Build | Bitstream (SHA-256 prefix) | Clock | Where the reports came from |
|---|---|---|---|---|
| `v1_2` | V1.2, HP0 and DMA at 32 bits (`v1/board/flash_hp32.bit`; failed on the board, 0/244) | `396a219b10690f26` | 66.67 MHz | `build_hw.tcl`, 2026-10-07 |
| `v1_2_71MHz_FAILED` | First V1.2 attempt at 71.43 MHz; not used, kept as negative evidence | none kept in the repo | 71.43 MHz | `build_hw.tcl`, 2026-10-07 |
| `v1_2_hp64` | V1.2.1, HP0 and DMA at 64 bits (`v1/board/flash_hp64.bit`; 244/244 on the board) | `0ee58d6c924cd162` | 66.67 MHz | timing, utilisation, power: `build_hw.tcl`, 2026-10-08. The other reports: `report_hw.tcl` on a rebuild of 2026-10-11 (below) |
| `v1_2_hp64_led` | V1.2.1 plus `axi_gpio_led` (`v1/board/flash_hp64_led.bit`; 244/244, live demo) | `7e0c3394fac1b57d` | 66.67 MHz | timing, utilisation, power: `build_hw.tcl`, 2026-10-09. The other reports: `report_hw.tcl` on the same routed checkpoint, 2026-10-11 |

**The `v1_2_hp64` rebuild.** The routed checkpoint of the board-tested
`flash_hp64` build was overwritten by the later LED build in the same
project. To produce the extra reports without touching that project, the build
was repeated on 2026-10-11 in a separate project from the same scripts and
sources. The rebuild is the same implementation: its bitstream configuration
data (everything after the sync word) is byte-identical to
`v1/board/flash_hp64.bit`, which differs only in the timestamp of its header;
its `.hwh` differs only in its `TIMESTAMP` attribute; and its timing summary
and hierarchical utilisation match `V1_impl_timing_v1_2_hp64.rpt` and
`V1_impl_util_v1_2_hp64.rpt` line for line apart from the date and command
lines. WNS +0.314 ns, WHS +0.030 ns in both.

## impl/: post-route reports

| File pattern | What it shows | Builds |
|---|---|---|
| `V1_impl_timing_<tag>.rpt` | `report_timing_summary -max_paths 10`: WNS, TNS, WHS, failing endpoints, clock summary, the 10 worst setup and hold paths per path group | `v1_2`, `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_impl_timing_v1_2_71MHz_FAILED.rpt` | Same, for the 71.43 MHz attempt: WNS -0.925 ns, TNS -216.964 ns, 554 of 15,320 endpoints failing. The reason the design runs at 66.67 MHz | 71.43 MHz attempt |
| `V1_impl_util_<tag>.rpt` | `report_utilization -hierarchical`: LUT, FF, block RAM and DSP per block (accelerator, DMA, interconnects, GPIO) | `v1_2`, `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_impl_power_<tag>.rpt` | `report_power`, vector-less estimate: total, PS7, PL dynamic and static, confidence level | `v1_2`, `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_impl_paths_<tag>.rpt` | `report_timing`: the 10 worst setup paths, then the 10 worst hold paths, cell by cell | `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_impl_design_<tag>.rpt` | `report_design_analysis -timing`: the 10 worst paths in one table (logic and net delay, logic levels, cell chain) | `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_impl_utilsum_<tag>.rpt` | `report_utilization`, flat: totals per site type (slices, block RAM, DSP, I/O, clocking) | `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_impl_clocks_<tag>.rpt` | `report_clocks`: one clock, `clk_fpga_0`, period 14.999 ns, from the PS FCLK0 | `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_impl_clockutil_<tag>.rpt` | `report_clock_utilization`: global buffers and clock regions used | `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_impl_io_<tag>.rpt` | `report_io`: every package pin; in the LED build the LED pins (LD0 to LD3 on R14, P14, N16, M14; RGB on L15, G17, N15, G14, L14, M15) | `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_impl_drc_<tag>.rpt` | `report_drc`: 45 warnings and 2 advisories in each build, no errors | `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_impl_methodology_<tag>.rpt` | `report_methodology`: `LUTAR-1` in both; ten `TIMING-18` (LED pins without I/O delays) in the LED build | `v1_2_hp64`, `v1_2_hp64_led` |
| `V1_bd_addrmap_<tag>.csv` | Every address segment of the block design: master address space, slave segment, offset, range, high address | `v1_2_hp64`, `v1_2_hp64_led` |

## synth/: synthesis of the core alone

| File | What it shows | Build |
|---|---|---|
| `V1_synth_results_v1_1.md` | Summary and per-module breakdown, 28×28 stage | `top_v1`, V1.1 |
| `V1_synth_timing_v1_1.rpt`, `V1_synth_util_v1_1.rpt` | Synthesis timing estimate at 75 MHz and utilisation | `top_v1`, V1.1 |
| `V1_synth_results_v1_2.md` | Summary, 224×224 stage | `top_v1`, V1.2 |
| `V1_synth_timing_v1_2.rpt`, `V1_synth_util_v1_2.rpt` | Synthesis timing estimate at 75 MHz (WNS +0.085 ns) and utilisation | `top_v1`, V1.2 |

Superseded V1.2 synthesis reports that loaded the wrong (28×28) weights are in
`docs/archive/`.

## Pictures (in docs/figures/)

| File | What it shows | Build |
|---|---|---|
| `bd_layout_v1_2_hp64.pdf`, `.svg` | Block design layout, written by `write_bd_layout` | `v1_2_hp64` (rebuild project) |
| `bd_layout_v1_2_hp64_led.pdf`, `.svg` | Same, with `axi_gpio_led` | `v1_2_hp64_led` |
| `vivado_block_design_flash_hp64_led.png` | Screenshot of the block design in the Vivado GUI | `v1_2_hp64_led` |
| `vivado_dashboard_flash_hp64_led.png` | Screenshot of the project summary: WNS +0.344 ns, 15,704 endpoints, 45 DRC warnings, utilisation and power | `v1_2_hp64_led` |

## Regenerating

```
vivado -mode batch -source v1/scripts/build_hw.tcl  -tclargs <project.xpr> 70.0 flash_hp64      (timing, util, power)
vivado -mode batch -source v1/scripts/report_hw.tcl -tclargs <project>.runs/impl_1/flash_bd_wrapper_routed.dcp v1_2_hp64
vivado -mode gui   -source v1/scripts/export_bd.tcl -tclargs <project.xpr> v1_2_hp64 exit
```

`write_bd_layout` refuses to run in batch mode, hence `-mode gui` for the
last step; the script exits by itself.
