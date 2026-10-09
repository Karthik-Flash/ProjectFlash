# Project FLASH V1.2 — Hardware Bring-up Handoff (v2, Oct 2026)

Supersedes `HANDOFF_v1_impl.md`. Paste/upload this as the first message of the new chat.

**Rules (non-negotiable):** author `Karthik-Flash`; **no `Co-Authored-By` trailers** (Claude Code slipped once and had to amend + force-push — watch for it); work on `main`, no branches; Windows, repo at `C:\KarDRIVE\Projects\ProjectFlash`; Vivado 2022.2; iverilog 0.9.7 needs `-g2005`; Vivado TCL console ≠ PowerShell.

---

## 1. Where we are

**Done and on `main`:**
- V1.1 (RSNA 28×28) and V1.2 (RSNA 224×224) trained in Colab, exported as int8/int32 `.mem` files. Each stage trained separately. Test AUROC 0.8143 (V1.1), 0.8229 (V1.2), overlapping CIs.
- Golden model (NumPy int64) independently audited: 244/244 verification vectors + 60/60 trace files exact, both stages. PyTorch float64 vs golden exact on the full test split.
- RTL (7 modules, `v1/rtl/`). Only RTL change for 224×224: `fmap_ram` 64 KB → 128 KB.
- xsim V1.2: **16/16** logit0/logit1/margin/decision exact, **12/12** layer traces exact. 1.96 s sim time ≈ 196 M cycles for 16 images ≈ **12.2 M cycles/image** (matches the 12.2 M MACs/image: the conv engine does 1 MAC/cycle).
- Synthesis V1.2 @ 75 MHz: WNS +0.085 ns, WHS +0.079 ns, 0/9439 failing. 2006 LUT, 2840 FF, 14 DSP, 80 BRAM36 (57%), 1 BRAM18. Docs: `docs/V1_synth_results_v1_2.md` + `.rpt` files.

**Not done:**
- `v1/sim/tb_v1.v` — the cycle-counted timeout (`while (to_cycles < 1_024_000_000)`) that produced the PASS is **uncommitted** in the working tree.
- Implementation fails at IO placement (98 pins > 75 sites). Expected: `top_v1` exposes logits as pins. Fix = AXI wrapper + Zynq block design.
- No wrapper, no bitstream, no board run, no power number, no `V1_CHANGELOG.md`.

**Expected board performance (set expectations now):** ~12.2 M cycles/image at 75 MHz ≈ **~165 ms/image, ~6 images/s**. The design is a single-MAC sequential engine; parallel MACs are a V2 optimisation, not a bug.

---

## 2. Corrections to the previous handoff (read these)

1. **`$readmemh` paths in synthesis.** `top_v1`'s parameter defaults point at **v1_1** files with **relative** paths (`../mem/v1_1/...`). Only `tb_v1` overrides them. So the synthesis run may have baked in v1_1 weights/layer table — or none, if the relative path didn't resolve. For a bitstream this is fatal: wrong weights = wrong answers on the board with no error. Fix: the wrapper passes **absolute v1_2 paths**, and after every synthesis we grep the log for `readmem` warnings (Synth 8-4445 "could not open"). The committed V1.2 timing/util numbers are still structurally valid (same RTL, same RAM sizes) but the doc should note which files were loaded.
2. **The wrapper must mirror `tb_v1`'s exact drive sequence** (reset length, threshold write, start pulse(s) — `layer_seq` needed a double start pulse during bring-up — pixel timing). The old Step A prompt didn't say this.
3. **FCLK_CLK0 "75 MHz" may not be exact.** The PS PLL can only hit certain frequencies; if Vivado's *actual* FCLK0 is above 75.0 MHz (e.g. 76.9), our +0.085 ns slack is gone. Pick the nearest actual frequency **≤ 75 MHz** and record it.
4. **Disable `v1/constr/v1.xdc`** for the block-design flow (clk/rst come from the PS; those ports won't exist).
5. **PYNQ MMIO writes take unsigned values**: write `-646 & 0xFFFFFFFF`, and sign-convert reads.
6. The preprocessing function name in the old driver (`preprocess_dicom_224`) was invented — check `tools/flash_preprocess.py` for the real one.
7. `PROJECT_NARRATIVE.md` overstated RTL verification (said 244, actually 16), called the 244 vectors the whole test split (it's a seeded subset), and said V1.2 reused V1.1 weights (it didn't). Corrected version is in `docs/`.

---

## 3. Plan

**Today (PC only):** Claude Code prompts 1 → 2 → 3, then Vivado block design → implementation → bitstream → export. Also flash the SD card.
**Tomorrow (board):** boot, copy files, run the 244-image bit-exact sweep on silicon, measure latency, write results doc.

Success = **244/244 exact on the board** (logit0, logit1, margin, decision) + post-route timing met + measured latency. That's V1 closed.

---

## 4. Claude Code prompt 1 — housekeeping (run first, fresh session)

```
Housekeeping on main before hardware work. Author Karthik-Flash. NO
Co-Authored-By trailers -- check `git log -1 --format=%B` after every
commit and amend if one slipped in. Do each step, report, stop at the end.

1. Report `git status` and `ls v1/rtl`. If top_v1_axi.v already exists,
   tell me and stop.

2. v1/sim/tb_v1.v has an uncommitted cycle-counted timeout
   (while (to_cycles < 1_024_000_000)). This is the exact version that
   produced the V1.2 xsim PASS (16/16 + 12/12). Commit it alone:
     git add v1/sim/tb_v1.v
     git commit -m "tb_v1: cycle-counted 1.024e9-cycle timeout for v1_2 sweep

     Replaces # delay timeouts, which were timescale-dependent. The
     v1_2 16-image sweep needs ~196M cycles (~12.2M per image, one MAC
     per cycle); this is the version that produced RESULT: PASS."

3. Docs: I have placed PROJECT_NARRATIVE.md and HANDOFF_v1_impl_v2.md
   in docs/. Also move the untracked "Project FLASH - Project Brief,
   Technical Framework & Research Roadmap.md" from the repo root into
   docs/ (git mv not needed, it's untracked). Commit all three:
     "docs: project narrative, brief, and hardware bring-up handoff"

4. Write docs/V1_CHANGELOG.md in the same shape as docs/V0_CHANGELOG.md,
   built ONLY from `git log` on main (v1 notebook -> audits -> RTL
   bring-up -> v1_1 synth -> fmap_ram 128KB -> tb retarget -> v1_2 synth).
   Cite short commit hashes. Do not invent anything not in the log.
   Commit: "docs: V1 changelog (v1_0 -> v1_2)"

5. Evidence checks, report results, change nothing:
   a. Get-FileHash on v1/mem/v1_1/flash_v1_1/weights.mem and
      v1/mem/v1_2/flash_v1_2/weights.mem -- same or different?
   b. In verilog/ProjectFlashV1/ProjectFlashV1.runs/synth_1/runme.log
      (or *.vds), search for: readmem, 8-4445, weights.mem, bias.mem,
      layer_table.mem. Report every matching line verbatim. I need to
      know which .mem files the V1.2 synthesis actually loaded.
   c. `git log --format=%B main | Select-String -Pattern "Co-Authored"`
      -- report any hits (don't rewrite history, just report).

6. git push origin main. Report `git log --oneline -6` and stop.
```

**Send the step-5 output to the new chat before running prompt 2.**

---

## 5. Claude Code prompt 2 — AXI wrapper (corrected)

```
Create v1/rtl/top_v1_axi.v: a Verilog-2001 wrapper (no SystemVerilog --
it must work as a Vivado block-design "module reference" and compile on
iverilog 0.9.7 -g2005) that puts top_v1 behind AXI so the Zynq PS can
drive it. Work on main, author Karthik-Flash, no trailers.

FIRST read v1/rtl/top_v1.v, v1/rtl/layer_seq.v and v1/sim/tb_v1.v.
The wrapper's control FSM must reproduce EXACTLY the sequence tb_v1
uses to drive top_v1 for one image: reset, threshold_wr/threshold_wr_en,
start pulse(s) (layer_seq needed a double start pulse during bring-up
-- copy whatever tb_v1 does), pixel_in/pixel_valid timing, and how it
waits for result_valid. Write a comment block in the wrapper quoting the
tb_v1 lines you mirrored. If anything in tb_v1's sequence is ambiguous,
stop and ask rather than guess.

Parameters (pass straight through to top_v1), defaults ABSOLUTE v1_2:
  WEIGHTS_FILE     = "C:/KarDRIVE/Projects/ProjectFlash/v1/mem/v1_2/flash_v1_2/weights.mem"
  BIAS_FILE        = ".../flash_v1_2/bias.mem"
  LAYER_TABLE_FILE = ".../flash_v1_2/layer_table.mem"
  N_PIXELS         = 50176
  DEFAULT_THRESHOLD = -646
Absolute paths are deliberate: relative $readmemh paths resolve
differently in synthesis vs xsim, and a silent miss bakes zeros into
the bitstream.

Ports:
- aclk, aresetn (active low). Core clk = aclk, core rst = ~aresetn
  OR soft_reset.
- AXI4-Stream slave s_axis_*: tdata[31:0], tvalid, tready, tlast.
  4 pixels/beat, byte 0 = first pixel. 12544 beats per v1_2 image.
  tready low whenever the core isn't accepting pixels (before start,
  after N_PIXELS, or skid FIFO full). Feed top_v1 one pixel per cycle.
  Count pixels; if tlast arrives early or late, set STATUS.err.
- AXI4-Lite slave s_axi_*: awaddr[5:0], awvalid, awready, wdata[31:0],
  wstrb[3:0], wvalid, wready, bresp[1:0], bvalid, bready, araddr[5:0],
  arvalid, arready, rdata[31:0], rresp[1:0], rvalid, rready. Correct
  AXI-Lite handshakes (aw and w may arrive in either order).
- irq_done: level-high while STATUS.done is set (PS interrupts on
  Zynq are level-sensitive by default).
Add X_INTERFACE_INFO / X_INTERFACE_PARAMETER attributes so Vivado
infers: aclk as a clock with ASSOCIATED_BUSIF s_axi:s_axis and
ASSOCIATED_RESET aresetn; aresetn as an active-low reset; irq_done as
an interrupt (SENSITIVITY LEVEL_HIGH).

Register map (32-bit):
  0x00 CTRL      RW  bit0 start (self-clearing), bit1 soft_reset
  0x04 STATUS    RO  bit0 busy, bit1 done, bit2 ready_for_pixels, bit3 err
                     (done and err clear on write-1 to CTRL bit0 of the
                     next start; NOT on read -- read-to-clear is fragile)
  0x08 THRESHOLD RW  signed 32, reset value DEFAULT_THRESHOLD; applied to
                     top_v1 via threshold_wr/threshold_wr_en
  0x0C LOGIT0    RO  signed 32, latched on result_valid
  0x10 LOGIT1    RO
  0x14 MARGIN    RO
  0x18 DECISION  RO  bit0 positive
  0x1C VERSION   RO  constant 32'hF1A5_0102  (lets the board confirm
                     the right bitstream loaded)
  0x20 CYCLES    RO  core clock cycles from start to result_valid
                     (measured latency for the paper)

Compile check only (do not run):
  cd v1/rtl
  iverilog -g2005 -I../mem/v1_2/flash_v1_2 -o axi.vvp conv_engine.v fmap_ram.v gap_unit.v fc_unit.v decision.v layer_seq.v top_v1.v top_v1_axi.v
Don't commit axi.vvp.

Commit: git add v1/rtl/top_v1_axi.v
  "top_v1_axi: AXI4-Stream + AXI4-Lite wrapper for Zynq PS
   Mirrors tb_v1's drive sequence. Absolute v1_2 .mem paths. Registers
   0x00-0x20 incl. VERSION and CYCLES. Removes the 98 top-level data
   pins that blocked placement."
Push. Report git show --stat HEAD and the tb_v1 lines you mirrored.
```

---

## 6. Claude Code prompt 3 — wrapper testbench

Never put an unsimulated wrapper on the board: a board failure can't show you which layer broke.

```
Create v1/sim/tb_v1_axi.v (Verilog-2001, iverilog -g2005 compatible) to
verify top_v1_axi end to end. Author Karthik-Flash, no trailers.

- 100 MHz-style #5 clock, cycle-counted timeout (no raw # delays):
  budget 4 images x 12.2M cycles x 2 = 100,000,000 cycles.
- AXI-Lite master tasks axil_write(addr,data) and axil_read(addr,data),
  with aw/w issued in different orders across calls.
- AXI-Stream master task that sends one image from img_k.mem (absolute
  v1_2 vectors path), 4 pixels/beat, tlast on beat 12543, with
  pseudo-random tvalid gaps (LFSR) so tready backpressure is exercised.
- Per image (k = 0..3): write THRESHOLD = -646, write CTRL.start, stream
  image, poll STATUS.done, read LOGIT0/LOGIT1/MARGIN/DECISION/CYCLES,
  compare against exp_logit0/exp_logit1/exp_margin/exp_decision.mem.
- Extra checks: VERSION == F1A50102; STATUS.err == 0; CYCLES nonzero
  and printed; on image 0, re-run with THRESHOLD = 32'h7FFFFFFF and
  check DECISION == 0 (threshold register actually reaches decision);
  done clears on next start.
- Print a summary block and RESULT: PASS/FAIL like tb_v1.

Compile with iverilog to check syntax only; do NOT run (slow). The user
runs it in Vivado xsim: add as simulation source, set as sim top.
Commit "tb_v1_axi: end-to-end AXI wrapper testbench (4 images)". Push.
```

**In Vivado:** add `top_v1_axi.v` (design) and `tb_v1_axi.v` (simulation), set `tb_v1_axi` as simulation top, Run Behavioral Simulation, `run all`. ~4 images × ~1.3 min wall ≈ 5–8 min. Must print PASS before continuing.

---

## 7. Vivado block design → bitstream (GUI)

Keep the same project (`ProjectFlashV1`).

1. Sources → `v1.xdc` → right-click → **Disable File**.
2. **Create Block Design** → name `flash_bd`.
3. Add **ZYNQ7 Processing System** → **Run Block Automation** (applies PYNQ-Z2 DDR/MIO presets; if PYNQ-Z2 board files are installed, select the board preset — otherwise the part default works but double-check DDR is `MT41K256M16 RE-125`, 16-bit).
4. Double-click PS7:
   - Clock Configuration → PL Fabric Clocks → FCLK_CLK0 requested **75**. Read **Actual Frequency**. If > 75.0, lower the request until actual ≤ 75.0. Write the actual number down.
   - PS-PL Configuration → HP Slave AXI → enable **S AXI HP0** (32-bit).
   - Interrupts → enable **Fabric Interrupts → IRQ_F2P**.
5. Add **AXI Direct Memory Access**: Scatter-Gather **off**, Read channel (MM2S) **on**, Write channel **off**, buffer length register width **26**, MM2S stream width **32**.
6. Right-click canvas → **Add Module** → `top_v1_axi`. Check its parameters show the absolute v1_2 paths.
7. **Run Connection Automation** (select all). Then by hand: DMA `M_AXIS_MM2S` → `top_v1_axi/s_axis`; add a **Concat** (2 inputs): `top_v1_axi/irq_done` → In0, DMA `mm2s_introut` → In1, Concat out → PS7 `IRQ_F2P`.
8. **Validate Design** (F6) — fix until clean. **Address Editor**: note the base addresses of `top_v1_axi` and the DMA.
9. Sources → `flash_bd` → **Create HDL Wrapper** (let Vivado manage) → **Set as Top**.
10. **Run Synthesis.** Then check the log:
    PowerShell: `Select-String -Path verilog\ProjectFlashV1\ProjectFlashV1.runs\*\runme.log -Pattern "readmem|8-4445"` → must show the v1_2 files opened, no "could not open".
11. **Run Implementation** → **Generate Bitstream**. Then in TCL console (implemented design open):
    ```tcl
    report_timing_summary -max_paths 10 -file C:/KarDRIVE/Projects/ProjectFlash/docs/V1_impl_timing_v1_2.rpt
    report_utilization -hierarchical -file C:/KarDRIVE/Projects/ProjectFlash/docs/V1_impl_util_v1_2.rpt
    report_power -file C:/KarDRIVE/Projects/ProjectFlash/docs/V1_impl_power_v1_2.rpt
    ```
    Post-route WNS must be ≥ 0. If negative, stop and bring the report to the chat (fix is a pipeline register on `u_conv`'s address path, or a lower FCLK).
12. **File → Export → Export Hardware → Include bitstream** → `flash_bd_wrapper.xsa`. Rename to `.zip`, extract. Rename the `.bit` and `.hwh` to the same basename: `flash.bit`, `flash.hwh`.

---

## 8. Board day prep (do tonight)

- **SD card (≥16 GB):** download the official PYNQ image for **PYNQ-Z2** (v3.0.1) from pynq.io, flash with balenaEtcher.
- **Jumpers:** boot mode → **SD**; power → **USB** (fine for this design) or REG with a 12 V adapter.
- **Cables:** micro-USB (power + UART), Ethernet direct to PC.
- **PC network:** set the Ethernet adapter to static `192.168.2.1 / 255.255.255.0`. Board default is `192.168.2.99`.
- **Jupyter:** browser → `http://192.168.2.99:9090`, password `xilinx`. Files can also go via SMB `\\192.168.2.99\xilinx` (user/pass `xilinx`).
- **Files to copy into one folder on the board:** `flash.bit`, `flash.hwh`, all 244 `img_*.mem` + `exp_logit0/1.mem`, `exp_margin.mem`, `exp_decision.mem`, `gt_label.mem` from `v1/mem/v1_2/flash_v1_2/vectors/` (~37 MB), and `tools/flash_preprocess.py` + 1–2 test DICOMs.

---

## 9. Board notebook (tomorrow)

```python
from pynq import Overlay, allocate
import numpy as np, time

ol   = Overlay('flash.bit')
dma  = ol.axi_dma_0
acc  = ol.top_v1_axi_0          # check ol.ip_dict if the name differs

def s32(x): return x - (1 << 32) if x & 0x80000000 else x
def readmem(path, signed32=False):
    v = [int(l.split('//')[0], 16) for l in open(path)
         if l.strip() and not l.startswith(('//', '@'))]
    return [s32(x) for x in v] if signed32 else v

assert acc.read(0x1C) == 0xF1A50102, "wrong bitstream"

N = 50176
buf = allocate(shape=(N,), dtype=np.uint8)

def run(img, thr=-646):
    buf[:] = img; buf.flush()
    acc.write(0x08, thr & 0xFFFFFFFF)
    acc.write(0x00, 1)                       # start
    dma.sendchannel.transfer(buf); dma.sendchannel.wait()
    while not (acc.read(0x04) & 0x2): pass   # done
    assert not (acc.read(0x04) & 0x8), "stream length error"
    return (s32(acc.read(0x0C)), s32(acc.read(0x10)),
            s32(acc.read(0x14)), acc.read(0x18) & 1, acc.read(0x20))

V = 'vectors/'
e0, e1 = readmem(V+'exp_logit0.mem', True), readmem(V+'exp_logit1.mem', True)
em, ed = readmem(V+'exp_margin.mem', True), readmem(V+'exp_decision.mem')
ok, cyc, t0 = 0, [], time.time()
for k in range(244):
    img = np.array(readmem(f'{V}img_{k}.mem'), dtype=np.uint8)
    l0, l1, m, d, c = run(img)
    match = (l0, l1, m, d) == (e0[k], e1[k], em[k], ed[k])
    ok += match; cyc.append(c)
    if not match: print(k, (l0, l1, m, d), (e0[k], e1[k], em[k], ed[k]))
wall = time.time() - t0
print(f"BOARD: {ok}/244 bit-exact")
print(f"cycles/image: {min(cyc)}..{max(cyc)}  latency @ FCLK: compute from actual MHz")
print(f"wall: {wall:.1f}s total, {wall/244*1000:.0f} ms/image incl. file parsing")
```

If image 0 mismatches: first confirm `VERSION`, then check which `.mem` files synthesis loaded (step 7.10). Weights are the #1 suspect, not the RTL — the RTL is already proven in xsim.

---

## 10. Results to write up (`docs/V1_board_results_v1_2.md`)

- Board: **N/244 bit-exact** (logit0, logit1, margin, decision).
- Post-route: WNS/WHS at actual FCLK0, utilization incl. PS/DMA, `report_power` estimate (label it an estimate).
- Latency: CYCLES register (exact cycles) → ms at actual FCLK0; throughput images/s.
- Threshold demo: same image at two thresholds flips the decision.
- Optional: sensitivity/specificity on the 244 using `gt_label.mem` (small sample — headline accuracy stays the notebook's test AUROC with CI).
- One DICOM end-to-end through `flash_preprocess.py` → board, compared to the golden model on the PC.

Then tag: `git tag v1.2-hw` and push tags.
