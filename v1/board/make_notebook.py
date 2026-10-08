"""Generate the PYNQ-Z2 board notebook v1/board/flash_v1_2_board.ipynb.

Edit the cells here, not in the .ipynb, then regenerate from the repo root:

    python v1/board/make_notebook.py v1/board/flash_v1_2_board.ipynb 66.666672 top_v1_axi_0 axi_dma_0

Arguments: output path, FCLK0 actual in MHz (from Vivado / the .hwh), and the
accelerator and DMA instance names from the .hwh. Then rebuild the bundle with
v1/board/make_board_bundle.ps1.
"""
import json, sys
out, fclk, acc_name, dma_name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def md(s):   return {"cell_type": "markdown", "metadata": {}, "source": s.strip("\n").splitlines(True)}
def code(s): return {"cell_type": "code", "metadata": {}, "execution_count": None, "outputs": [], "source": s.strip("\n").splitlines(True)}

cells = [
md(f"""
# Project FLASH V1.2 — PYNQ-Z2 board run

Runs the V1.2 (224x224) pneumonia classifier on the FPGA and checks it
bit-exact against the golden model on the 244 exported verification images.

Folder layout (made by `v1/board/make_board_bundle.ps1`): `flash_hp64.bit/.hwh`,
`flash_hp32.bit/.hwh`, this notebook, `tools/` (preprocessing, golden model),
`model/` (v1_2 weights for the ARM baseline), `vectors/`.

Build-side FCLK0 (actual, from Vivado): **{fclk} MHz**.

Bitstreams: `flash_hp64.bit` (V1.2.1, HP0 64-bit, the default) and
`flash_hp32.bit` (V1.2, HP0 32-bit, kept for the AFI confirmation test).
Choose with `BIT` in the first code cell. Each sweep saves
`results_<basename>.csv` and `summary_<basename>.json` next to this notebook.

Register map (`top_v1_axi`): 0x00 CTRL (bit0 start, bit1 soft reset),
0x04 STATUS (bit0 busy, bit1 done, bit2 ready_for_pixels, bit3 err),
0x08 THRESHOLD, 0x0C LOGIT0, 0x10 LOGIT1, 0x14 MARGIN, 0x18 DECISION,
0x1C VERSION, 0x20 CYCLES.
"""),
code(f"""
from pynq import Overlay, allocate, Clocks
import numpy as np, time, hashlib

BIT = 'flash_hp64.bit'           # or 'flash_hp32.bit' for the AFI confirmation test
HWH = BIT[:-4] + '.hwh'
FCLK_BUILD_MHZ = {fclk}          # Vivado's actual FCLK0 for this bitstream

ol  = Overlay(BIT)
sha16 = lambda path: hashlib.sha256(open(path, 'rb').read()).hexdigest()[:16]
SHA_BIT, SHA_HWH = sha16(BIT), sha16(HWH)
print(f'bitstream: {{BIT}}  sha256 {{SHA_BIT}}   ({{HWH}} sha256 {{SHA_HWH}})')
print('IP blocks:', list(ol.ip_dict.keys()))
dma = ol.{dma_name}
acc = ol.{acc_name}

version = acc.read(0x1C)
assert version == 0xF1A50102, f'wrong bitstream: VERSION = {{version:#010x}}'
print(f'VERSION OK ({{version:#010x}})')

fclk = Clocks.fclk0_mhz
print(f'FCLK0 now: {{fclk:.6f}} MHz (build: {{FCLK_BUILD_MHZ}} MHz)')
if abs(fclk - FCLK_BUILD_MHZ) > 0.01:
    print('WARNING: FCLK0 differs from the build value; timing was closed at the build value')
"""),
md("""
## HP0 AFI width check

The Zynq HP0 port bridge (AFI) has its own data-width setting (RDCHAN_CTRL
bit 0, `32BitEn`). It must match the HP0 width the bitstream was built with.
PYNQ does not run this design's `ps7_init`, so the AFI keeps whatever mode
the PS booted with. On 2026-10-08 a 32-bit HP0 build against a 64-bit AFI
returned every even 32-bit word twice (`docs/V1_board_debug_log.md`).
This cell only reads the register.
"""),
code(r"""
import re
from pynq import MMIO

AFI0 = MMIO(0xF8008000, 0x1000)          # HP0 AFI: RDCHAN_CTRL @ 0x00
hwh_hp0 = int(re.search(r'NAME="PCW_S_AXI_HP0_DATA_WIDTH" VALUE="(\d+)"',
                        open(HWH).read()).group(1))
rdctrl = AFI0.read(0x00)
afi_bit0 = rdctrl & 1
print(f'AFI0 RDCHAN_CTRL = {rdctrl:#010x}; bit 0 = {afi_bit0} '
      f'({"32-bit" if afi_bit0 else "64-bit"} mode)')
print(f'.hwh HP0 data width = {hwh_hp0}')
afi_ok = (afi_bit0 == 1) == (hwh_hp0 == 32)
print('AFI vs .hwh:', 'OK' if afi_ok else 'MISMATCH -- input words will be corrupted (see AFI_FORCE)')
"""),
md("""
## AFI_FORCE (confirmation test only, off by default)

Set `AFI_FORCE = True` to write RDCHAN_CTRL bit 0 so the AFI matches the
`.hwh` (1 for a 32-bit HP0 build, 0 for 64-bit). Use it with
`BIT = 'flash_hp32.bit'` to confirm the root cause: the sweep should go from
0/244 to 244/244. Reboot the board afterwards (the write persists until then).
"""),
code("""
AFI_FORCE = False
if AFI_FORCE:
    want = 1 if hwh_hp0 == 32 else 0
    v = AFI0.read(0x00)
    AFI0.write(0x00, (v & ~1) | want)
    print(f'AFI0 RDCHAN_CTRL {v:#010x} -> {AFI0.read(0x00):#010x}')
else:
    print('AFI_FORCE off: AFI left as booted')
"""),
code("""
def s32(x):
    return x - (1 << 32) if x & 0x80000000 else x

def readmem(path, signed32=False):
    v = [int(l.split('//')[0], 16) for l in open(path)
         if l.strip() and not l.startswith(('//', '@'))]
    return [s32(x) for x in v] if signed32 else v

N   = 50176                          # 224 x 224 uint8 pixels, row-major
buf = allocate(shape=(N,), dtype=np.uint8)

def run(img, thr=-646):
    \"\"\"One image through the accelerator. Returns (logit0, logit1, margin, decision, cycles).\"\"\"
    buf[:] = img
    buf.flush()
    acc.write(0x08, thr & 0xFFFFFFFF)          # MMIO takes unsigned values
    acc.write(0x00, 1)                         # arm the run; pixels go in before compute starts
    dma.sendchannel.transfer(buf)
    dma.sendchannel.wait()
    while not (acc.read(0x04) & 0x2):          # STATUS.done
        pass
    assert not (acc.read(0x04) & 0x8), 'STATUS.err: stream length error'
    return (s32(acc.read(0x0C)), s32(acc.read(0x10)), s32(acc.read(0x14)),
            acc.read(0x18) & 1, acc.read(0x20))
"""),
md("## 244-image bit-exact sweep"),
code("""
V  = 'vectors/'
e0 = readmem(V + 'exp_logit0.mem', True)
e1 = readmem(V + 'exp_logit1.mem', True)
em = readmem(V + 'exp_margin.mem', True)
ed = readmem(V + 'exp_decision.mem')
gt = readmem(V + 'gt_label.mem')

ok = {'logit0': 0, 'logit1': 0, 'margin': 0, 'decision': 0}
n_exact, cyc, dec, bad = 0, [], [], []
t0 = time.time()
for k in range(244):
    img = np.array(readmem(f'{V}img_{k}.mem'), dtype=np.uint8)
    l0, l1, m, d, c = run(img)
    got, exp = (l0, l1, m, d), (e0[k], e1[k], em[k], ed[k])
    for name, g, e in zip(ok, got, exp):
        ok[name] += (g == e)
    n_exact += (got == exp)
    cyc.append(c); dec.append(d)
    if got != exp:
        bad.append((k, got, exp))
        print('MISMATCH', k, got, exp)
wall = time.time() - t0

print(f'BOARD: {n_exact}/244 bit-exact')
for name, n in ok.items():
    print(f'  {name:9s} {n}/244')
"""),
md("""
## Save evidence

Writes `results_<BIT basename>.csv` (one row per image) and
`summary_<BIT basename>.json` next to this notebook. With `AFI_FORCE = True`
the basename gets `_afiforce`, so the forced and unforced runs of the same
bitstream do not overwrite each other. Download both files after the run.
"""),
code("""
import csv, json, datetime, pynq

TAG = BIT[:-4] + ('_afiforce' if AFI_FORCE else '')
# The sweep keeps board values only for mismatches; an image not in `bad`
# matched exactly, so its board values equal the expected ones.
got_by_k = {k: got for k, got, exp in bad}
with open(f'results_{TAG}.csv', 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['k', 'logit0', 'logit1', 'margin', 'decision', 'cycles',
                'exp_logit0', 'exp_logit1', 'exp_margin', 'exp_decision', 'gt', 'exact'])
    for k in range(244):
        exp_k = (e0[k], e1[k], em[k], ed[k])
        got_k = got_by_k.get(k, exp_k)
        w.writerow([k, *got_k, cyc[k], *exp_k, gt[k], int(got_k == exp_k)])

TP = sum(d == 1 and g == 1 for d, g in zip(dec, gt)); FN = sum(d == 0 and g == 1 for d, g in zip(dec, gt))
TN = sum(d == 0 and g == 0 for d, g in zip(dec, gt)); FP = sum(d == 1 and g == 0 for d, g in zip(dec, gt))
summary = dict(
    bit=BIT, sha_bit=SHA_BIT, sha_hwh=SHA_HWH, pynq_version=pynq.__version__,
    fclk0_mhz=round(fclk, 6), hwh_hp0_width=hwh_hp0,
    afi_bit0_at_load=afi_bit0, afi_bit0_now=AFI0.read(0x00) & 1, afi_force=AFI_FORCE,
    n_exact=int(n_exact), exact_per_field={k: int(v) for k, v in ok.items()},
    tp=int(TP), fn=int(FN), tn=int(TN), fp=int(FP),
    cycles_min=int(min(cyc)), cycles_max=int(max(cyc)), wall_s=round(wall, 1),
    date=datetime.datetime.now().isoformat(timespec='seconds'))
with open(f'summary_{TAG}.json', 'w') as f:
    json.dump(summary, f, indent=1)
print(f'wrote results_{TAG}.csv and summary_{TAG}.json')
print(json.dumps(summary, indent=1))
"""),
md("## Latency"),
code("""
cmin, cmax = min(cyc), max(cyc)
ms = lambda c: c / (fclk * 1e3)
print(f'CYCLES/image: {cmin} .. {cmax}')
print(f'compute latency @ {fclk:.6f} MHz: {ms(cmin):.2f} .. {ms(cmax):.2f} ms '
      f'-> {1000 / ms(cmax):.2f} images/s (compute only)')
print(f'wall: {wall:.1f} s total, {wall / 244 * 1000:.0f} ms/image incl. DMA and .mem parsing')
"""),
md("""
## Throughput — 244 back-to-back runs, images already in memory

All 244 images are parsed into one array first, so the timing below covers
only `run()`: buffer copy and cache flush, register writes, DMA, compute and
polling. Compare with the compute-only CYCLES figure above.
"""),
code("""
imgs = np.stack([np.array(readmem(f'{V}img_{k}.mem'), dtype=np.uint8) for k in range(244)])
t0 = time.perf_counter()
res = [run(imgs[k]) for k in range(244)]
dt = time.perf_counter() - t0
n_ok = sum(r[:4] == (e0[k], e1[k], em[k], ed[k]) for k, r in enumerate(res))
ms_img, ms_compute = dt / 244 * 1e3, ms(cmax)
print(f'{n_ok}/244 exact in this pass')
print(f'end to end: {ms_img:.2f} ms/image -> {1000 / ms_img:.2f} images/s (DMA + registers + compute)')
print(f'compute only (CYCLES): {ms_compute:.2f} ms/image; overhead {ms_img - ms_compute:.2f} ms/image')
summary.update(throughput_ms_per_image=round(ms_img, 3), throughput_images_per_s=round(1000 / ms_img, 3),
               throughput_exact=int(n_ok))
with open(f'summary_{TAG}.json', 'w') as f:
    json.dump(summary, f, indent=1)
"""),
md("## Threshold demo — same image, two thresholds"),
code("""
img0 = np.array(readmem(V + 'img_0.mem'), dtype=np.uint8)
for thr in (-646, 0x7FFFFFFF):
    l0, l1, m, d, c = run(img0, thr)
    print(f'image 0, threshold {thr:>11d}: margin {m}, decision {d}')
"""),
md("""
## Sensitivity / specificity vs `gt_label.mem`

Small-sample check on the 244 seeded verification images only. The headline
accuracy stays the notebook's test AUROC (V1.2: 0.8229) with its CI.
"""),
code("""
tp = sum(1 for d, g in zip(dec, gt) if d == 1 and g == 1)
fn = sum(1 for d, g in zip(dec, gt) if d == 0 and g == 1)
tn = sum(1 for d, g in zip(dec, gt) if d == 0 and g == 0)
fp = sum(1 for d, g in zip(dec, gt) if d == 1 and g == 0)
print(f'TP {tp}  FN {fn}  TN {tn}  FP {fp}')
print(f'sensitivity {tp / max(tp + fn, 1):.3f}   specificity {tn / max(tn + fp, 1):.3f}   (n = 244, small sample)')
"""),
md("""
## Optional: ARM baseline — golden model on the Cortex-A9

Runs `tools/golden_model_v1.py` (NumPy int64) on the board's CPU for image 0
and checks it against `exp_*[0]`. Reads `model/` (weights.mem, bias.mem,
layer_table.json; layer_table.mem is there for reference). Needs NumPy >= 1.20.
"""),
code("""
# Expected run time: ~0.5-2 s for the inference plus ~0.5 s to load the model
# (9 ms per image on a desktop PC; the A9 is roughly 50-200x slower).
# If it is still running after a few minutes, interrupt the kernel and skip it.
ARM_BASELINE = True
if ARM_BASELINE:
    import sys
    sys.path.insert(0, 'tools')
    from golden_model_v1 import GoldenModel
    t = time.perf_counter(); gm = GoldenModel('model'); t_load = time.perf_counter() - t
    x0 = np.array(readmem(V + 'img_0.mem'), dtype=np.uint8).reshape(1, 1, 224, 224)
    t = time.perf_counter(); lg, _ = gm.run(x0); t_arm = time.perf_counter() - t
    l0, l1 = int(lg[0, 0]), int(lg[0, 1])
    arm = (l0, l1, l1 - l0, int(l1 - l0 > -646))
    assert arm == (e0[0], e1[0], em[0], ed[0]), f'ARM golden {arm} != expected {(e0[0], e1[0], em[0], ed[0])}'
    print(f'ARM golden, image 0: {arm} == expected')
    print(f'ARM: {t_arm * 1e3:.0f} ms/image (model load {t_load:.2f} s) vs FPGA compute {ms(cmax):.1f} ms/image')
    summary.update(arm_ms_image0=round(t_arm * 1e3, 1), arm_model_load_s=round(t_load, 2))
    with open(f'summary_{TAG}.json', 'w') as f:
        json.dump(summary, f, indent=1)
"""),
md("""
## Optional: one DICOM end to end

Needs `pydicom` and `opencv` on the board (`pip install pydicom` if missing).
Compare the logits with the golden model run on the PC for the same file.
"""),
code("""
# import sys; sys.path.insert(0, 'tools')
# from flash_preprocess import preprocess_file
# arrays, info = preprocess_file('test.dcm', sizes=(224,))
# print(info)
# print(run(arrays[224].reshape(-1)))
"""),
code("buf.freebuffer()"),
]

nb = {"cells": cells, "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
      "language_info": {"name": "python"}}, "nbformat": 4, "nbformat_minor": 5}
json.dump(nb, open(out, "w", newline="\n"), indent=1)
print("wrote", out)
