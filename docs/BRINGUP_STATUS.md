# V1.2 Hardware Bring-up — Status

> **STATUS: COMPLETE (2026-10-09).** The current hardware is **V1.2.1**
> (`v1/board/flash_hp64.bit`, plus the LED variant `flash_hp64_led.bit`). It is
> **bit-exact on all 244 verification images on the PYNQ-Z2**. Results:
> [`V1_board_results_v1_2.md`](V1_board_results_v1_2.md). Full write-up:
> [`PROJECT_FLASH_REPORT.md`](../PROJECT_FLASH_REPORT.md). What happened after
> this bring-up run (the board failure, its root cause, the fix) is summarised
> in the next section; the rest of the file is the record of the unattended
> run of 2026-10-07. File names in it were updated where files moved later.

## After the bring-up: board sessions of 2026-10-08 and 2026-10-09

| Date | Event | Result | Evidence |
|---|---|---|---|
| 2026-10-08 | First board run of the V1.2 bitstream (HP0 32-bit; then `flash.bit`, now `flash_hp32.bit`) | **0/244** bit-exact; 234/244 decisions agree | `docs/board_runs/2026-10-08/` |
| 2026-10-08 | Offline fault localisation with the golden model and 24 probes | `board == golden(dup_even(x))` on 244/244 images and 24/24 probes: HP0 AFI in 64-bit mode, PL port 32-bit | `docs/V1_board_debug_log.md` |
| 2026-10-08 | V1.2.1 built: HP0 and DMA memory side 64-bit, RTL unchanged | WNS +0.314 ns, WHS +0.030 ns at 66.666672 MHz | `docs/reports/impl/*_v1_2_hp64.rpt` |
| 2026-10-09 | Run 1 `flash_hp64`; run 2 `flash_hp32`; run 3 `flash_hp32` + one AFI register bit | **244/244**; 0/244; **244/244** (cause confirmed by intervention) | `docs/board_runs/2026-10-09/` |
| 2026-10-09 | V1.2.1-led (`axi_gpio_led`) built and run in the live demo | WNS +0.344 ns; **244/244** re-verified on the board | `docs/board_runs/2026-10-09/demo_flash_hp64_led_executed.ipynb` |

# V1.2 Hardware Bring-up — record of the unattended run, 2026-10-07

> **Main Vivado project: `verilog/ProjectFlashV1_hw/ProjectFlashV1_hw.xpr`.**
> It holds the block design, the completed runs and the bitstream, and further
> work happens there. It was created during this run as the fallback, because
> the Vivado GUI (PID 33980) had `verilog/ProjectFlashV1/ProjectFlashV1.xpr`
> open. Writing to a project the GUI holds would be overwritten by the GUI.
> `ProjectFlashV1` was left unchanged (backed up) and is now legacy: it is the
> bare `top_v1` project and cannot be implemented (98 IO pins).

**Outcome:** all seven phases are done. The wrapper passes xsim
(33/33 checks). The bitstream meets timing at **FCLK0 = 66.666672 MHz**
(post-route WNS +0.206 ns). It was built from the absolute v1_2 `.mem`
files. The board bundle is ready. The only thing left is the board run.

---

## Phase by phase

| Phase | Result | Commit |
|---|---|---|
| 0 Safety | Done. GUI open on the project, so the fallback project is used for Phase 5. | (no commit) |
| 1 Fix-ups + docs cleanup | Done | `7c16219` |
| 2 Honest V1.2 standalone synthesis | Done, v1_2 files confirmed in the log | `d1dc26f` |
| 3 AXI wrapper `top_v1_axi.v` | Done, compiles on iverilog 0.9.7 `-g2005` and xvlog | `726391e` |
| 4 Wrapper simulation | **PASS** (33 checks, 0 failures), on the second run after one testbench fix | `d2ecb7e` |
| 5 Block design + implementation + bitstream | Done, on the second try (lower FCLK0) | `8bb4a58` |
| 6 Board package | Done | `21ace48` |
| 7 This file | Done | (this commit) |

All commits: author Karthik-Flash, no `Co-Authored-By` trailer (checked with
`git log -1 --format=%B` after each). Pushed after each phase, no force-push.

---

## Decisions I made, and why

1. **Fallback project** (`verilog/ProjectFlashV1_hw/`). See the banner above.
   Rule from the brief, Phase 0.
2. **Backup:** `verilog/ProjectFlashV1/ProjectFlashV1.xpr.bak_20261007`
   (gitignored folder).
3. **Board files:** the PYNQ-Z2 board files were already installed
   (`C:/Xilinx/Vivado/2022.2/data/boards/board_files/pynq-z2/A.0`, board part
   `tul.com.tw:pynq-z2:part0:1.0`). The PS7 uses the board preset, so nothing
   was downloaded. The preset produces 4 `PSU-1..4` critical warnings about
   negative DQS-to-clock delays (-0.051, -0.006, -0.009, -0.033 ns). They come
   from the vendor preset and are normal for PYNQ-Z2 designs. PYNQ sets up DDR
   at boot anyway.
4. **Single start pulse, pixels before start.** `tb_v1` streams all 50176
   pixels first, waits one idle cycle, then gives **one** start pulse. The
   double pulse mentioned in the handoff was fixed in `layer_seq` in `f964249`,
   and `tb_v1` does not double-pulse. Pixels must come before `start` because
   `top_v1`'s `start` zeroes its pixel address and `layer_seq` begins reading
   buffer A on the same pulse. So in the wrapper, `CTRL.start` **arms** a run:
   threshold write, then the stream, then the core start after the last pixel.
   Software order is unchanged from the handoff notebook (write CTRL, then
   start the DMA). Starting the DMA first also works: `tready` stays low until
   the run is armed.
5. **Threshold is written to the core at every run**, not once after reset.
   The value seen by `decision` is the same as in `tb_v1`, and software can
   change `THRESHOLD` between images.
6. **CYCLES** = core cycles from the core start pulse to `result_valid`
   (compute only, no streaming). This is the number for the paper.
7. **Error handling.** If `tlast` comes before the last beat: `err` is set, the
   run is aborted, the core gets a 16-cycle reset (so its pixel address returns
   to 0) and `done` is raised (no hang). If the last beat has no `tlast`: `err`
   is set and the run still completes. `CTRL` bit 1 = self-clearing soft reset
   (16 cycles).
8. **FCLK0 = 66.666672 MHz** (IO PLL 1000 MHz / 15), not 75 MHz:
   - The PS cannot make 75 MHz. Request 75 gives 76.923 MHz actual; request
     74 gives 71.428566 MHz.
   - **Try 1, 71.428566 MHz:** post-route WNS **-0.925 ns** (TNS -216.9 ns).
     Critical path inside the frozen `conv_engine`: `u_conv/fm_rd_addr3`
     (DSP) -> 2x DSP48E1 + LUT5 -> `u_ram_a` BRAM address, 13.834 ns (70%
     logic). Standalone synthesis had shown +0.085 ns at 75 MHz, but placing
     80 BRAM36 next to the PS adds route delay. That bitstream was not used.
     It is kept in `verilog/build_hw_log/try1_71MHz/` with its reports.
   - **Try 2, 66.666672 MHz** (the next achievable frequency below): WNS
     **+0.206 ns**, met. This is 1 of the 2 rebuilds the rules allow. Frozen
     RTL was not touched.
   - The FCLK0 request is set to **exactly** 66.666672, so that PYNQ, which
     re-derives the divisors from the requested value in the .hwh, programs
     the same clock.
9. **`layer_table.vh` added to the project as a global include.** The module
   reference failed without it (`[filemgmt 56-591] ... needs to be added to
   the project`). A global include is needed because `top_v1.v` uses the
   `LT_*` macros without its own `` `include``. In the new project the include
   path is v1_2 only. The v1_1 header defines the same macros; only comments
   and `FLASH_IMG_*` differ.
10. **Archive moves (`docs/archive/`, with README):** the two superseded v1_2
    synthesis reports (they loaded v1_1 `.mem` files). The untracked root
    `timing_v1_2.rpt` was a byte-identical copy and went to the gitignored
    `verilog/stray/root_timing_v1_2.rpt`, so git has no second copy.
11. **Not archived because they were not there:** no older
    `HANDOFF_v1_impl.md` exists in the repo. The `.docx` brief that was at the
    repo root on the previous session was **no longer on disk** at the start
    of this run. I did not delete it, so it was probably moved by you. Kept in
    `docs/`: V0 summary and changelog, V1 audits, V1 synth/impl results and
    `.rpt` files, `V1_CHANGELOG`, `PROJECT_NARRATIVE`, the brief `.md`,
    `HANDOFF_v1_impl_v2.md`, `V1_board_results_v1_2.md`, this file.
12. **`.gitignore` additions:** `board_bundle/`, `!docs/archive/*.rpt`,
    `/NA/`, `!v1/board/flash.bit` (removed on 2026-10-09 with the file). `*.vvp`, `*.jou`, `*.log`, `*.str`,
    `.Xil/` and `xsim.dir/` were already covered. No build artifacts were
    tracked. `/NA/` is there because Vivado's PS7 IP writes
    `NA/ps7_summary.html` into the batch working directory (moved to
    `verilog/build_hw_log/NA_ps7_summary/`).
13. **`flash.bit` is committed** (4,045,676 bytes, under the 10 MB limit),
    together with `flash.hwh`. *(2026-10-09: renamed `flash_hp32.bit/.hwh`;
    the byte-identical `flash.bit/.hwh` were removed.)*
14. **Testbench fix during Phase 4.** First xsim run: timeout with no image
    finished. Cause: a bug in my testbench. `send_stream` waited one extra
    negedge after raising `tvalid`, so a beat whose `tready` was already high
    was taken twice. The DUT saw doubled beats, closed the stream after
    N_PIXELS, and the TB then waited forever. The wrapper was correct and was
    not changed. Second run: PASS.

---

## Key numbers

### Phase 2 — standalone synthesis of `top_v1`, V1.2 files, 75 MHz (13.333 ns)

Log: `Synth 8-3876` for `../mem/v1_2/flash_v1_2/{weights,bias,layer_table}.mem`, no `8-4445`.

| | Current (v1_2 files) | Superseded `78d9e58` (v1_1 files) |
|---|---|---|
| WNS / WHS | +0.085 / +0.079 ns | +0.085 / +0.079 ns |
| Failing endpoints | 0 of 9,477 | 0 of 9,439 |
| LUT / FF | 2,675 / 2,845 | 2,006 / 2,840 |
| DSP | 14 | 14 |
| BRAM36 / BRAM18 | 80 / 1 | 80 / 1 |

LUT +669: the weight ROM's logic depends on its contents.

### Phase 4 — wrapper simulation (`v1/scripts/sim_tb_v1_axi.bat`, Vivado 2022.2 xsim)

```
  run 1 image 0 thr=-646: logit0=-82 logit1=-75 margin=7 decision=1 CYCLES=12196126
  run 2 image 1 thr=-646: logit0=-163 logit1=369 margin=532 decision=1 CYCLES=12196126
  run 3 image 0 thr=2147483647: logit0=-82 logit1=-75 margin=7 decision=0 CYCLES=12196126
  checks: 33, failures: 0
RESULT: PASS
```

The checks also cover: VERSION = F1A50102, THRESHOLD resets to -646,
unmapped read = 0, `STATUS.err` = 0 on good runs, `done` clears on the next
start, `irq_done` follows `done`, early `tlast` sets `err` and clears on the
next start, soft reset returns STATUS to 0. AXI-Lite writes use aw-first,
w-first and simultaneous orders. The stream has LFSR `tvalid` gaps.

**CYCLES = 12,196,126 per image**, which is 182.9 ms at 66.666672 MHz,
or 5.47 images/s (compute only).

### Phase 5 — implementation (`flash_bd_wrapper`, xc7z020clg400-1)

| | Value |
|---|---|
| FCLK0 actual | **66.666672 MHz** (15.0 ns) |
| Post-route WNS / WHS | **+0.206 ns / +0.024 ns** (0 failing of 15,320 endpoints) |
| Critical path | `u_conv/y_reg[3]` -> `u_ram_a/mem_reg_0_2/ADDRBWRADDR[15]`, 14.069 ns, 10 levels (CARRY4=6, DSP48E1=1, LUT2=1, LUT5=2) |
| LUT | 3,818 / 53,200 (7.2%), of which `top_v1_axi_0` 2,759 |
| FF | 4,745 / 106,400 (4.5%), of which `top_v1_axi_0` 3,206 |
| BRAM | 81 RAMB36 + 1 RAMB18 = 81.5 / 140 tiles (58.2%); accelerator 80 + 1, DMA 1 |
| DSP | 14 / 220 (6.4%) |
| Power (**estimate**, `report_power`, confidence Medium) | 1.492 W total: PS7 1.256 W, PL dynamic 0.092 W (BRAM 0.060), static 0.144 W; junction 42.2 °C |

`.mem` files loaded (all `runme.log` files under `ProjectFlashV1_hw.runs/`;
they appear in `flash_bd_top_v1_axi_0_0_synth_1`), no `8-4445`:

```
INFO: [Synth 8-3876] $readmem data file 'c:/KarDRIVE/Projects/ProjectFlash/v1/mem/v1_2/flash_v1_2/weights.mem' is read successfully [C:/KarDRIVE/Projects/ProjectFlash/v1/rtl/top_v1.v:110]
INFO: [Synth 8-3876] $readmem data file 'c:/KarDRIVE/Projects/ProjectFlash/v1/mem/v1_2/flash_v1_2/bias.mem' is read successfully [C:/KarDRIVE/Projects/ProjectFlash/v1/rtl/top_v1.v:111]
INFO: [Synth 8-3876] $readmem data file 'c:/KarDRIVE/Projects/ProjectFlash/v1/mem/v1_2/flash_v1_2/layer_table.mem' is read successfully [C:/KarDRIVE/Projects/ProjectFlash/v1/rtl/layer_seq.v:48]
```

Reports: `docs/reports/impl/V1_impl_timing_v1_2.rpt`, `V1_impl_util_v1_2.rpt`,
`V1_impl_power_v1_2.rpt`.

### Address map (PS `M_AXI_GP0`)

| Block | Base | Range |
|---|---|---|
| `top_v1_axi_0` (`s_axi`) | `0x4000_0000` | 4 KB |
| `axi_dma_0` (`S_AXI_LITE`) | `0x4040_0000` | 64 KB |
| DMA `M_AXI_MM2S` -> HP0 -> DDR | `0x0000_0000` | 512 MB |

Interrupts: `IRQ_F2P[0]` = `irq_done`, `IRQ_F2P[1]` = `mm2s_introut`.

### Bitstream

- `v1/board/flash.bit` (now `v1/board/flash_hp32.bit`): 4,045,676 bytes, SHA-256 prefix `396a219b10690f26`.
  Source: `verilog/ProjectFlashV1_hw/ProjectFlashV1_hw.runs/impl_1/flash_bd_wrapper.bit`.
- `v1/board/flash.hwh` (now `flash_hp32.hwh`): from `ProjectFlashV1_hw.gen/sources_1/bd/flash_bd/hw_handoff/flash_bd.hwh`.
  It shows `PCW_FPGA0_PERIPHERAL_FREQMHZ = 66.666672`.
- XSA: `verilog/ProjectFlashV1_hw/flash_bd_wrapper.xsa` (gitignored).

### Board package

`v1/board/make_board_bundle.ps1` builds `board_bundle/` (gitignored, 253
files, 50.9 MB): `flash.bit`, `flash.hwh` (now `flash_hp32.*`), `flash_v1_2_board.ipynb`,
`tools/flash_preprocess.py`, `vectors/` (244 `img_*.mem`, `exp_logit0/1`,
`exp_margin`, `exp_decision`, `gt_label`). The bundle has already been built
once and is in place now.

For the board run, the golden model's decisions on these 244 images give
117/122 true positives and 57/122 true negatives (sensitivity 0.959,
specificity 0.467). The board should reproduce exactly these numbers.

---

## Open issues / things I was unsure about (2026-10-07; outcome added 2026-10-09)

*Outcome:* the 66.67 MHz clock was kept for V1 (pipelining the conv address
path is V2 work); the notebook's FCLK0 check read 66.666667 MHz on the
board; `BD 41-702` turned out not to be fixable in one line (the parameters
are read-only, `[BD 41-737]`). The one issue nobody listed here, the HP0 AFI
width, is the one that broke the first board run.

- **Latency is ~183 ms/image, not the ~165 ms in the handoff,** because FCLK0
  is 66.67 MHz instead of 75 MHz. The 75 MHz standalone synthesis slack
  (+0.085 ns) did not survive placement next to the PS. Getting back to
  ≥71.4 MHz needs a pipeline register on `conv_engine`'s feature-map address
  path. That is an RTL change to a frozen module, so it is left for you (or V2).
- **Margin at 66.67 MHz is +0.206 ns.** That is met at sign-off, but small.
  The board runs at nominal voltage and room temperature, and the timing
  analysis is worst-case, so this is fine. Do not overclock FCLK0 from PYNQ.
- The notebook checks `pynq.Clocks.fclk0_mhz` against 66.666672 and warns on
  a mismatch. It has not run on hardware yet. The vector-file helpers were
  checked on the PC against the real files.
- **PS7 `BD 41-702` warnings** (`PCW_M_AXI_GP0_FREQMHZ`/`PCW_S_AXI_HP0_FREQMHZ`
  user value 10 vs propagated 71/66). These are bookkeeping parameters. The
  interface clocks are driven by FCLK0, and timing is analysed on
  `clk_fpga_0`. Harmless, but a clean-up candidate.
- **`tb_v1` in `ProjectFlashV1_hw`** (sim top, as asked) uses relative
  `../mem/...` paths. Run inside the project's xsim it needs the `.mem` files
  next to the run directory, as before. `tb_v1_axi` uses absolute paths and
  runs anywhere.
- **`create_bd.tcl` in a re-run** logs `ERROR: [BD 41-71] Exec TCL: Cannot
  find design` once (try 2). It came from a `catch`-ed `close_bd_design` on a
  design that was not open. Harmless, and the committed script now checks
  first. The try-2 build used the old line.
- **`.docx` brief:** it was missing from disk at the start of the run (see
  Decision 11). If you still want it in `docs/archive/`, put it back and
  `git add` it.
