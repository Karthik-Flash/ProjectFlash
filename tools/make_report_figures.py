"""Regenerate the figures and derived numbers of PROJECT_FLASH_REPORT.md.

Reads only repository files: the board evidence in docs/board_runs/, the V1.2
export in v1/mem/v1_2/flash_v1_2/, and the Vivado reports in docs/reports/.
Writes docs/figures/*.png and docs/figures/derived_numbers.json. The output is
deterministic (fixed bootstrap seed); re-running it reproduces every derived
number in the report.

    python tools/make_report_figures.py

Needs numpy and matplotlib. The golden model (NumPy int64) is the one shipped
with the export, v1/mem/v1_2/flash_v1_2/tools/golden_model_v1.py.
"""
import base64, csv, json, math, re, sys
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

R = Path(__file__).resolve().parents[1]
EXP = R / 'v1/mem/v1_2/flash_v1_2'
RUN8, RUN9 = R / 'docs/board_runs/2026-10-08', R / 'docs/board_runs/2026-10-09'
OUT = R / 'docs/figures'
OUT.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(EXP / 'tools'))
from golden_model_v1 import GoldenModel  # noqa: E402

T = -646
D = {}                                   # everything derived goes in here

# ---------------------------------------------------------------- helpers
def s32(x):
    return x - (1 << 32) if x & 0x80000000 else x

def read_hex(p):
    return [int(t, 16) for t in Path(p).read_text().split()]

def img(k):
    return np.array(read_hex(EXP / f'vectors/img_{k}.mem'), dtype=np.uint8)

def read_csv(p):
    with open(p, newline='') as f:
        rows = list(csv.DictReader(f))
    return {c: np.array([int(r[c]) for r in rows]) for c in rows[0]}

def wilson(k, n, z=1.96):
    p = k / n; d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [round(p, 4), round(c - h, 4), round(c + h, 4)]

def auroc(y, m):
    pos, neg = m[y == 1], m[y == 0]
    return float(((pos[:, None] > neg[None, :]).sum() + 0.5 * (pos[:, None] == neg[None, :]).sum())
                 / (len(pos) * len(neg)))

def dup_even(x):
    b = np.asarray(x).reshape(-1, 2, 4).copy()
    b[:, 1, :] = b[:, 0, :]
    return b.ravel()

G = GoldenModel(EXP)
def golden(x):
    lg, _ = G.run(np.asarray(x, dtype=np.uint8).reshape(1, 1, 224, 224))
    l0, l1 = int(lg[0, 0]), int(lg[0, 1])
    return (l0, l1, l1 - l0)

# ---------------------------------------------------------------- board runs
runs = {name: read_csv(RUN9 / f'results_{name}.csv')
        for name in ('flash_hp64', 'flash_hp32', 'flash_hp32_afiforce')}
summ = {name: json.loads((RUN9 / f'summary_{name}.json').read_text())
        for name in runs}
exp = runs['flash_hp64']
EXPCOLS = ('exp_logit0', 'exp_logit1', 'exp_margin', 'exp_decision')
BOARDCOLS = ('logit0', 'logit1', 'margin', 'decision')

D['runs'] = {}
for name, r in runs.items():
    fields = {b: int((r[b] == r[e]).sum()) for b, e in zip(BOARDCOLS, EXPCOLS)}
    D['runs'][name] = dict(
        bit_exact=int(r['exact'].sum()), per_field=fields,
        cycles=sorted(set(r['cycles'].tolist())),
        summary_n_exact=summ[name]['n_exact'], afi_bit0_at_load=summ[name]['afi_bit0_at_load'],
        afi_bit0_now=summ[name]['afi_bit0_now'], afi_force=summ[name]['afi_force'],
        hwh_hp0_width=summ[name]['hwh_hp0_width'], sha_bit=summ[name]['sha_bit'], sha_hwh=summ[name]['sha_hwh'],
        throughput_ms=summ[name]['throughput_ms_per_image'], throughput_ips=summ[name]['throughput_images_per_s'],
        arm_ms_image0=summ[name]['arm_ms_image0'], arm_load_s=summ[name]['arm_model_load_s'],
        wall_s=summ[name]['wall_s'], fclk0_mhz=summ[name]['fclk0_mhz'], pynq=summ[name]['pynq_version'],
        json_date=summ[name]['date'],
        tp_fn_tn_fp=[summ[name][k] for k in ('tp', 'fn', 'tn', 'fp')])

# identical CSVs, and run 2 == the 2026-10-08 sweep image by image
D['checks'] = {}
D['checks']['hp64_csv_bytes_equal_afiforce_csv'] = (
    (RUN9 / 'results_flash_hp64.csv').read_bytes() == (RUN9 / 'results_flash_hp32_afiforce.csv').read_bytes())
nb8 = json.loads((RUN8 / 'flash_v1_2_board.ipynb').read_text(encoding='utf-8'))
txt8 = ''.join(''.join(o.get('text', '')) for c in nb8['cells'] for o in c.get('outputs', []))
mm = re.findall(r'MISMATCH (\d+) \((-?\d+), (-?\d+), (-?\d+), (\d)\)', txt8)
b8 = {int(a[0]): tuple(map(int, a[1:])) for a in mm}
h32 = runs['flash_hp32']
D['checks']['oct08_mismatch_lines'] = len(b8)
D['checks']['hp32_run2_equals_oct08_board'] = all(
    b8[k] == tuple(int(h32[c][k]) for c in BOARDCOLS) for k in range(244))

# the corrupted run: how plausible it looked
D['afi'] = dict(
    decision_agreement=int((h32['decision'] == exp['exp_decision']).sum()),
    margin_exact=int((h32['margin'] == exp['exp_margin']).sum()),
    corr_logit0=round(float(np.corrcoef(h32['logit0'], exp['exp_logit0'])[0, 1]), 4),
    corr_logit1=round(float(np.corrcoef(h32['logit1'], exp['exp_logit1'])[0, 1]), 4),
    corr_margin=round(float(np.corrcoef(h32['margin'], exp['exp_margin'])[0, 1]), 4),
    corr_all_logits=round(float(np.corrcoef(np.r_[h32['logit0'], h32['logit1']],
                                            np.r_[exp['exp_logit0'], exp['exp_logit1']])[0, 1]), 4))

# the dup_even model on all 244 images and every probe
X = [img(k) for k in range(244)]
gold = [golden(x) for x in X]
model = [golden(dup_even(x)) for x in X]
D['afi']['golden_equals_expected'] = sum(
    g == (int(exp['exp_logit0'][k]), int(exp['exp_logit1'][k]), int(exp['exp_margin'][k])) for k, g in enumerate(gold))
D['afi']['dup_even_model_equals_corrupted_run'] = sum(
    m == (int(h32['logit0'][k]), int(h32['logit1'][k]), int(h32['margin'][k])) for k, m in enumerate(model))

r_, c_ = np.mgrid[0:224, 0:224]
i0 = X[0]
probes = {
    'const 0': np.zeros(50176), 'const 128': np.full(50176, 128), 'const 255': np.full(50176, 255),
    'row ramp': r_.ravel(), 'col ramp': c_.ravel(),
    'img0 @ 66.667 MHz': i0, 'img0 @ 50.000 MHz': i0, 'img0 @ 25.000 MHz': i0,
    'img0 roll 1': np.roll(i0, 1), 'img0 roll -1': np.roll(i0, -1),
    'img0 roll 4': np.roll(i0, 4), 'img0 roll -4': np.roll(i0, -4),
    'img0 roll 224': np.roll(i0, 224), 'img0 roll -224': np.roll(i0, -224),
    'top half 255': ((r_ < 112) * 255).ravel(), 'left half 255': ((c_ < 112) * 255).ravel(),
    'checker 1px': (((r_ + c_) % 2) * 255).ravel()}
for (y, x) in [(0, 0), (0, 1), (0, 2), (0, 3), (1, 0), (112, 112), (223, 223)]:
    z = np.zeros((224, 224)); z[y, x] = 255; probes[f'px({y},{x})=255'] = z.ravel()
diag = {**json.loads((RUN8 / 'diag_1.json').read_text()), **json.loads((RUN8 / 'diag_2.json').read_text())}
ptab = []
for name, x in probes.items():
    b = tuple(diag[name][:3]); g = golden(x); m = golden(dup_even(x))
    ptab.append(dict(probe=name, board=list(b), golden=list(g), model=list(m),
                     board_eq_model=b == m, board_eq_golden=b == g))
D['afi']['probes_total'] = len(ptab)
D['afi']['probes_board_eq_model'] = sum(p['board_eq_model'] for p in ptab)
D['afi']['probes_board_eq_golden'] = sum(p['board_eq_golden'] for p in ptab)
D['afi']['probes_discriminating'] = [p['probe'] for p in ptab if p['model'] != p['golden']]
D['afi']['probe_table'] = ptab

# ---------------------------------------------------------------- classification (run 1)
gt, m, d = exp['gt'], exp['margin'], exp['decision']
TP = int(((d == 1) & (gt == 1)).sum()); FN = int(((d == 0) & (gt == 1)).sum())
TN = int(((d == 0) & (gt == 0)).sum()); FP = int(((d == 1) & (gt == 0)).sum())
rng = np.random.default_rng(0)
boots = []
for _ in range(2000):
    i = rng.integers(0, 244, 244)
    if gt[i].min() != gt[i].max():
        boots.append(auroc(gt[i], m[i]))
fn_m = sorted(m[(d == 0) & (gt == 1)].tolist())
fp_m = m[(d == 1) & (gt == 0)]
manifest = json.loads((EXP / 'manifest.json').read_text())
cls3 = np.array(manifest['verification']['class3'])
assert (np.array(manifest['verification']['ground_truth']) == gt).all()
def by_class(mask):
    return {c: int(((cls3 == c) & mask).sum()) for c in ('Normal', 'No Lung Opacity / Not Normal', 'Lung Opacity')}
neg = gt == 0
D['cls'] = dict(
    n=244, positives=int(gt.sum()), negatives=int(neg.sum()), threshold=T,
    ties_at_T=int((m == T).sum()), tp=TP, fn=FN, tn=TN, fp=FP,
    sensitivity_wilson=wilson(TP, TP + FN), specificity_wilson=wilson(TN, TN + FP),
    ppv=round(TP / (TP + FP), 4), npv=round(TN / (TN + FN), 4),
    accuracy=round((TP + TN) / 244, 4), correct=TP + TN, errors=FP + FN,
    auroc=round(auroc(gt, m), 4),
    auroc_boot_ci=[round(float(np.percentile(boots, 2.5)), 4), round(float(np.percentile(boots, 97.5)), 4)],
    bootstrap=dict(resamples=2000, seed=0, method='non-stratified resampling of the 244, percentile CI'),
    fn_margins=fn_m,
    fp_margin_min_q1_median_q3_max=[int(fp_m.min()), float(np.percentile(fp_m, 25)), float(np.median(fp_m)),
                                     float(np.percentile(fp_m, 75)), int(fp_m.max())],
    median_margin_pos=float(np.median(m[gt == 1])), median_margin_neg=float(np.median(m[neg])),
    negatives_above_T=int((m[neg] > T).sum()),
    threshold_table={str(t): dict(sens=round(float(((m > t) & (gt == 1)).sum() / gt.sum()), 3),
                                  spec=round(float(((m <= t) & neg).sum() / neg.sum()), 3))
                     for t in (-646, -400, -200, 0, 200)},
    class3_counts=by_class(np.ones(244, bool)),
    class3_fp=by_class((d == 1) & neg), class3_tn=by_class((d == 0) & neg),
    class3_fp_rate={c: round(by_class((d == 1) & neg)[c] / max(by_class(neg)[c], 1), 3)
                    for c in ('Normal', 'No Lung Opacity / Not Normal')},
    auroc_pneumonia_vs_normal_244=round(auroc(gt[cls3 != 'No Lung Opacity / Not Normal'],
                                              m[cls3 != 'No Lung Opacity / Not Normal']), 4),
    auroc_pneumonia_vs_notnormal_244=round(auroc(gt[cls3 != 'Normal'], m[cls3 != 'Normal']), 4))

# ---------------------------------------------------------------- demo notebook
demo = json.loads((RUN9 / 'demo_flash_hp64_led_executed.ipynb').read_text(encoding='utf-8'))
dtxt, pngs = '', []
for c in demo['cells']:
    for o in c.get('outputs', []):
        dtxt += ''.join(o.get('text', ''))
        if 'image/png' in o.get('data', {}):
            pngs.append(o['data']['image/png'])
gal = re.findall(r'^\s+(\d+)\s+(pneumonia|negative)\s+(pneumonia|negative)\s+(-?\d+)\s+(yes|NO)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)x',
                 dtxt, re.M)
mean = re.search(r'mean: FPGA ([\d.]+) ms, ARM ([\d.]+) ms, speedup ([\d.]+)x;\s+FPGA bit-exact (\d+)/12, ARM golden == expected (\d+)/12', dtxt)
sweep = re.search(r'BIT-EXACT: (\d+)/244', dtxt)
D['demo'] = dict(
    sha_bit=re.search(r'flash_hp64_led\.bit\s+sha256 (\w+)', dtxt).group(1),
    gallery_images=[int(g[0]) for g in gal], gallery_exact=sum(g[4] == 'yes' for g in gal),
    gallery_fpga_ms=[float(g[5]) for g in gal], gallery_arm_ms=[float(g[6]) for g in gal],
    mean_fpga_ms=float(mean.group(1)), mean_arm_ms=float(mean.group(2)), mean_speedup=float(mean.group(3)),
    sweep_bit_exact=int(sweep.group(1)),
    sweep_wall_s=float(re.search(r'time: ([\d.]+) s total', dtxt).group(1)),
    image_load_ms=float(re.search(r'image load: (\d+) ms', dtxt).group(1)),
    auroc_printed=float(re.search(r'AUROC ([\d.]+)', dtxt).group(1)))
(OUT / 'fig_demo_gallery_board.png').write_bytes(base64.b64decode(pngs[0]))
(OUT / 'fig_demo_errors_board.png').write_bytes(base64.b64decode(pngs[1]))

# ---------------------------------------------------------------- latency (derived)
fclk = summ['flash_hp64']['fclk0_mhz']
cyc = int(exp['cycles'][0])
arm = [summ[n]['arm_ms_image0'] for n in ('flash_hp64', 'flash_hp32', 'flash_hp32_afiforce')]
layers = json.loads((EXP / 'layer_table.json').read_text())['layers']
macs = {}
for L in layers:
    if L['op'] == 'CONV3X3':
        macs[L['name']] = L['out_c'] * L['out_h'] * L['out_w'] * L['in_c'] * 9
    elif L['op'] == 'FC':
        macs[L['name']] = L['out_c'] * L['in_c']
D['latency'] = dict(
    cycles=cyc, fclk0_mhz=fclk, compute_ms=round(cyc / (fclk * 1e3), 2),
    compute_ips=round(fclk * 1e6 / cyc, 2),
    end_to_end_ms=summ['flash_hp64']['throughput_ms_per_image'],
    host_overhead_ms=round(summ['flash_hp64']['throughput_ms_per_image'] - cyc / (fclk * 1e3), 2),
    end_to_end_runs_ms=[summ[n]['throughput_ms_per_image'] for n in runs],
    arm_ms=arm, speedup_vs_arm=[round(a / (cyc / (fclk * 1e3)), 2) for a in (min(arm), max(arm))],
    conv_macs=sum(v for k, v in macs.items() if k != 'fc'), total_macs=sum(macs.values()), macs_per_layer=macs,
    cycles_minus_macs=cyc - sum(macs.values()),
    ms_at_75mhz_derived=round(cyc / 75e3, 2))
D['latency']['overhead_pct'] = round(100 * D['latency']['host_overhead_ms'] / D['latency']['end_to_end_ms'], 2)
gapL = next(L for L in layers if L['op'] == 'GAP')
D['latency']['gap_stream_cycles'] = gapL['in_c'] * gapL['in_h'] * gapL['in_w']
D['latency']['sequencing_and_drain_cycles'] = D['latency']['cycles_minus_macs'] - D['latency']['gap_stream_cycles']
n_test = int(json.loads((EXP / 'manifest.json').read_text())['summary']['patients train/val/test'].split('/')[2])
D['latency']['full_test_set_images'] = n_test
D['latency']['full_test_set_compute_min'] = round(n_test * D['latency']['compute_ms'] / 60000, 1)
pc = R / 'docs/figures/pc_golden_timing.json'
if pc.exists():
    D['latency']['pc_golden'] = json.loads(pc.read_text())

# ---------------------------------------------------------------- Vivado reports
def timing(p):
    t = p.read_text()
    i = t.index('Design Timing Summary')
    nums = re.search(r'\n\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)', t[i:])
    path = re.search(r'Max Delay Paths.*?Slack \((\w+)\) :\s+(-?[\d.]+)ns.*?Source:\s+(\S+).*?Destination:\s+(\S+)'
                     r'.*?Requirement:\s+([\d.]+)ns.*?Data Path Delay:\s+([\d.]+)ns\s+\(logic ([\d.]+)ns.*?route ([\d.]+)ns'
                     r'.*?Logic Levels:\s+(\d+)\s+\(([^)]*)\)', t, re.S)
    return dict(wns=float(nums.group(1)), failing_setup=int(nums.group(3)), endpoints=int(nums.group(4)),
                whs=float(nums.group(5)), failing_hold=int(nums.group(7)),
                critical=dict(source=path.group(3), dest=path.group(4), requirement_ns=float(path.group(5)),
                              data_path_ns=float(path.group(6)), logic_ns=float(path.group(7)),
                              route_ns=float(path.group(8)), levels=int(path.group(9)), cells=path.group(10)))

def util(p):
    out = {}
    for line in p.read_text().splitlines():
        mm_ = re.match(r'\|\s{0,5}(flash_bd_wrapper|top_v1_axi_0|axi_dma_0|axi_gpio_led|axi_mem_intercon|ps7_0_axi_periph)\s+\|'
                       r'.*?\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|\s+(\d+)\s+\|', line)
        if mm_ and mm_.group(1) not in out:
            v = list(map(int, mm_.groups()[1:]))
            out[mm_.group(1)] = dict(lut=v[0], ff=v[4], ramb36=v[5], ramb18=v[6], dsp=v[7])
    return out

def power(p):
    t = p.read_text()
    g = lambda k: float(re.search(r'\|\s*' + re.escape(k) + r'\s*\|\s*([\d.]+)', t).group(1))
    return dict(total_w=g('Total On-Chip Power (W)'), dynamic_w=g('Dynamic (W)'), static_w=g('Device Static (W)'),
                ps7_w=g('PS7'), bram_w=g('Block RAM'), junction_c=g('Junction Temperature (C)'),
                confidence=re.search(r'\|\s*Confidence Level\s*\|\s*(\w+)', t).group(1))

su = (R / 'docs/reports/synth/V1_synth_util_v1_2.rpt').read_text()
avail = dict(lut=int(re.search(r'\| Slice LUTs\*?\s*\|.*?\|.*?\|.*?\|\s*(\d+)', su).group(1)),
             ff=int(re.search(r'\| Slice Registers\s*\|.*?\|.*?\|.*?\|\s*(\d+)', su).group(1)),
             bram=int(re.search(r'\| Block RAM Tile\s*\|.*?\|.*?\|.*?\|\s*(\d+)', su).group(1)),
             dsp=int(re.search(r'\| DSPs\s*\|.*?\|.*?\|.*?\|\s*(\d+)', su).group(1)))
D['impl'] = {'available': avail}
for tag in ('v1_2', 'v1_2_hp64', 'v1_2_hp64_led'):
    u = util(R / f'docs/reports/impl/V1_impl_util_{tag}.rpt')
    top = u['flash_bd_wrapper']
    tiles = top['ramb36'] + top['ramb18'] / 2
    D['impl'][tag] = dict(timing=timing(R / f'docs/reports/impl/V1_impl_timing_{tag}.rpt'),
                          util=u, power=power(R / f'docs/reports/impl/V1_impl_power_{tag}.rpt'),
                          pct=dict(lut=round(100 * top['lut'] / avail['lut'], 2), ff=round(100 * top['ff'] / avail['ff'], 2),
                                   bram=round(100 * tiles / avail['bram'], 2), dsp=round(100 * top['dsp'] / avail['dsp'], 2)),
                          bram_tiles=tiles)
st = (R / 'docs/reports/synth/V1_synth_timing_v1_2.rpt').read_text()
i = st.index('Design Timing Summary')
nums = re.search(r'\n\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s+(-?[\d.]+)', st[i:])
D['synth_v1_2'] = dict(wns=float(nums.group(1)), endpoints=int(nums.group(4)), whs=float(nums.group(5)),
                       lut=int(re.search(r'\| Slice LUTs\*?\s*\|\s*(\d+)', su).group(1)),
                       ff=int(re.search(r'\| Slice Registers\s*\|\s*(\d+)', su).group(1)),
                       bram_tiles=float(re.search(r'\| Block RAM Tile\s*\|\s*([\d.]+)', su).group(1)),
                       dsp=int(re.search(r'\| DSPs\s*\|\s*(\d+)', su).group(1)))

(OUT / 'derived_numbers.json').write_text(json.dumps(D, indent=1) + '\n')

# ================================================================ figures
INK, INK2, MUTED, GRID, BASE, SURF = '#0b0b0b', '#52514e', '#898781', '#e1e0d9', '#c3c2b7', '#fcfcfb'
BLUE, ORANGE, AQUA = '#2a78d6', '#eb6834', '#1baf7a'
GOOD, CRIT = '#0ca30c', '#d03b3b'
plt.rcParams.update({
    'font.family': ['Segoe UI', 'DejaVu Sans'], 'font.size': 10, 'text.color': INK,
    'axes.edgecolor': BASE, 'axes.labelcolor': INK2, 'axes.titlesize': 11, 'axes.titleweight': 'bold',
    'axes.titlelocation': 'left', 'axes.facecolor': SURF, 'figure.facecolor': SURF,
    'xtick.color': MUTED, 'ytick.color': MUTED, 'axes.grid': True, 'grid.color': GRID, 'grid.linewidth': 0.6,
    'axes.spines.top': False, 'axes.spines.right': False, 'legend.frameon': False, 'savefig.dpi': 170,
    'savefig.bbox': 'tight', 'savefig.facecolor': SURF})

def tag(ax, text):
    ax.text(1.0, 1.02, text, transform=ax.transAxes, ha='right', va='bottom', fontsize=8.5, color=INK2,
            bbox=dict(boxstyle='round,pad=0.25', fc='#f0efec', ec='none'))

# F1: MACs per layer (Derived)
fig, ax = plt.subplots(figsize=(7.2, 3.0))
names = list(macs)
vals = [macs[n] / 1e6 for n in names]
ax.bar(names, vals, color=BLUE, width=0.6, zorder=3)
for x, v, n in zip(range(len(names)), vals, names):
    ax.text(x, v + 0.06, f'{macs[n]:,}', ha='center', va='bottom', fontsize=8.5, color=INK2)
ax.set_ylabel('MACs per image (millions)')
ax.set_title('Multiply-accumulates per layer, 224×224 input')
ax.grid(axis='x', visible=False)
tag(ax, 'Derived (layer_table.json)')
fig.savefig(OUT / 'fig_layer_macs.png'); plt.close(fig)

# F2: the corrupted run vs the expected logits (Measured)
fig, axes = plt.subplots(1, 2, figsize=(9.2, 3.9))
ax = axes[0]
ok = h32['decision'] == exp['exp_decision']
lo = min(exp['exp_margin'].min(), h32['margin'].min()) - 150
hi = max(exp['exp_margin'].max(), h32['margin'].max()) + 150
ax.plot([lo, hi], [lo, hi], color=MUTED, lw=1, zorder=2)
ax.scatter(exp['exp_margin'][ok], h32['margin'][ok], s=14, color=BLUE, zorder=3, lw=0, label=f'decision agrees ({ok.sum()})')
ax.scatter(exp['exp_margin'][~ok], h32['margin'][~ok], s=34, color=ORANGE, zorder=4, lw=0.8, edgecolor=SURF,
           label=f'decision flips ({(~ok).sum()})')
ax.axhline(T, color=INK2, lw=0.8, ls='--', zorder=2); ax.axvline(T, color=INK2, lw=0.8, ls='--', zorder=2)
ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
ax.set_xlabel('expected margin (golden model)'); ax.set_ylabel('board margin, flash_hp32')
ax.set_title('2026-10-08: plausible but wrong')
ax.text(0.03, 0.97, f'r = {D["afi"]["corr_all_logits"]:.2f} (logits), {D["afi"]["corr_margin"]:.2f} (margin)\n'
        f'bit-exact 0/244, decisions agree {D["afi"]["decision_agreement"]}/244',
        transform=ax.transAxes, va='top', fontsize=8.5, color=INK2)
ax.text(hi - 60, T + 60, 'T = -646', ha='right', fontsize=8, color=INK2)
ax.legend(loc='lower right', fontsize=8.5)
tag(ax, 'Measured (board)')
ax = axes[1]
labels = ['run 1\nflash_hp64', 'run 2\nflash_hp32', 'run 3\nflash_hp32\n+ AFI_FORCE', 'demo\nflash_hp64_led']
vals = [D['runs']['flash_hp64']['bit_exact'], D['runs']['flash_hp32']['bit_exact'],
        D['runs']['flash_hp32_afiforce']['bit_exact'], D['demo']['sweep_bit_exact']]
cols = [GOOD if v == 244 else CRIT for v in vals]
ax.bar(range(4), vals, color=cols, width=0.6, zorder=3)
for x, v in enumerate(vals):
    ax.text(x, v + 4, f'{v}/244', ha='center', va='bottom', fontsize=9, color=INK if v else CRIT, weight='bold')
ax.set_xticks(range(4)); ax.set_xticklabels(labels, fontsize=8.5); ax.set_ylim(0, 270)
ax.set_ylabel('images bit-exact (logits, margin, decision)')
ax.set_title('2026-10-09: one bit decides')
ax.grid(axis='x', visible=False)
tag(ax, 'Measured (board)')
fig.tight_layout(); fig.savefig(OUT / 'fig_afi_runs.png'); plt.close(fig)

# F3: what the PL saw (Derived illustration)
im0 = i0.reshape(224, 224).astype(int)
seen = dup_even(i0).reshape(224, 224).astype(int)
y0, x0 = 96, 40
crop = (slice(y0, y0 + 24), slice(x0, x0 + 48))
fig, axes = plt.subplots(1, 3, figsize=(9.2, 2.0))
for ax, a, t_ in zip(axes, (im0[crop], seen[crop], np.abs(im0[crop] - seen[crop])),
                     ('image 0 as sent', 'as received by the PL\n(odd 32-bit words replaced)', '|difference|')):
    ax.imshow(a, cmap='gray', vmin=0, vmax=255 if t_ != '|difference|' else max(1, int(a.max())), interpolation='nearest')
    ax.set_title(t_, fontsize=9.5, weight='normal'); ax.set_xticks([]); ax.set_yticks([]); ax.grid(False)
    for xx in range(0, 49, 8):
        ax.axvline(xx - 0.5, color=ORANGE, lw=0.6, alpha=0.7)
axes[0].set_ylabel(f'rows {y0}-{y0 + 23}\ncols {x0}-{x0 + 47}', fontsize=8, color=INK2)
tag(axes[2], 'Derived (dup_even model)')
fig.text(0.01, 0.04, 'Orange lines mark 8-pixel (64-bit) boundaries: each group keeps its first 4 pixels and repeats them.',
         fontsize=8.5, color=INK2)
fig.savefig(OUT / 'fig_dup_even.png'); plt.close(fig)

# F4: latency (Measured, one Derived)
fig, ax = plt.subplots(figsize=(7.6, 2.9))
pcms = D['latency'].get('pc_golden', {}).get('ms_per_image')
rows = [('FPGA, compute only (CYCLES)', D['latency']['compute_ms'], BLUE, None),
        ('FPGA, end to end (run(), 244 images)', D['latency']['end_to_end_ms'], BLUE, None),
        ('ARM Cortex-A9, NumPy int64 golden', float(np.mean(arm)), ORANGE, (min(arm), max(arm)))]
if pcms:
    rows.append(('Desktop PC, NumPy int64 golden', pcms, AQUA, None))
for yy, (lab, v, col, rngv) in enumerate(rows):
    ax.barh(yy, v, color=col, height=0.55, zorder=3)
    if rngv:
        ax.plot(rngv, [yy, yy], color=INK, lw=1.4, zorder=4)
        ax.plot([rngv[0]] * 2, [yy - .12, yy + .12], color=INK, lw=1.4, zorder=4)
        ax.plot([rngv[1]] * 2, [yy - .12, yy + .12], color=INK, lw=1.4, zorder=4)
        txt = f'{rngv[0]:.0f}-{rngv[1]:.0f} ms (3 runs)'
        xpos = rngv[1]
    else:
        txt = f'{v:.2f} ms' if v > 50 else f'{v:.1f} ms'
        xpos = v
    ax.text(xpos + 12, yy, txt, va='center', fontsize=9, color=INK)
ax.set_yticks(range(len(rows))); ax.set_yticklabels([r[0] for r in rows], fontsize=9)
ax.invert_yaxis(); ax.set_xlim(0, 900); ax.set_xlabel('milliseconds per 224×224 image')
ax.set_title('Latency per image')
ax.grid(axis='y', visible=False)
tag(ax, 'Measured')
fig.savefig(OUT / 'fig_latency.png'); plt.close(fig)

# F5: margins by ground truth (Measured)
fig, ax = plt.subplots(figsize=(7.6, 3.2))
bins = np.arange(-2400, 2600, 100)
ax.hist(m[gt == 1], bins=bins, color=BLUE, alpha=0.85, label='pneumonia (ground truth, n=122)', zorder=3,
        edgecolor=SURF, linewidth=0.8)
ax.hist(m[gt == 0], bins=bins, color=ORANGE, alpha=0.75, label='no pneumonia (ground truth, n=122)', zorder=3,
        edgecolor=SURF, linewidth=0.8)
ax.axvline(T, color=INK, lw=1.2, zorder=4)
ax.set_ylim(0, 16.5)
ax.text(T - 40, 16.2, 'T = -646\nflag if margin > T', ha='right', va='top', fontsize=8.5, color=INK)
ax.set_xlabel('board margin = logit1 - logit0'); ax.set_ylabel('images')
ax.set_title('Board margins on the 244 verification images')
ax.legend(loc='upper right', fontsize=8.5, bbox_to_anchor=(1.0, 0.95))
tag(ax, 'Measured (board, run 1)')
fig.savefig(OUT / 'fig_margins.png'); plt.close(fig)

# F6: ROC (Derived from measured margins)
fig, ax = plt.subplots(figsize=(4.4, 4.2))
ths = np.r_[np.inf, np.sort(np.unique(m))[::-1], -np.inf]
tpr = [((m > t) & (gt == 1)).sum() / gt.sum() for t in ths]
fpr = [((m > t) & (gt == 0)).sum() / (gt == 0).sum() for t in ths]
ax.plot([0, 1], [0, 1], color=MUTED, lw=1, ls='--', zorder=2)
ax.plot(fpr, tpr, color=BLUE, lw=2, zorder=3)
op = (FP / (FP + TN), TP / (TP + FN))
ax.scatter([op[0]], [op[1]], s=60, color=ORANGE, zorder=4, edgecolor=SURF, lw=1.5)
ax.annotate(f'T = -646\nsens {op[1]:.3f}, spec {1 - op[0]:.3f}', op, xytext=(0.55, 0.62), fontsize=8.5,
            color=INK, arrowprops=dict(arrowstyle='-', color=INK2, lw=0.8))
ax.text(0.97, 0.06, f'AUROC {D["cls"]["auroc"]:.3f}\n95% CI {D["cls"]["auroc_boot_ci"][0]:.3f}-{D["cls"]["auroc_boot_ci"][1]:.3f}',
        ha='right', fontsize=9, color=INK)
ax.set_xlim(0, 1); ax.set_ylim(0, 1.02); ax.set_aspect('equal')
ax.set_xlabel('1 - specificity'); ax.set_ylabel('sensitivity'); ax.set_title('ROC, 244 images')
tag(ax, 'Derived (board margins)')
fig.savefig(OUT / 'fig_roc.png'); plt.close(fig)

# F7: utilisation (Measured, post-route)
fig, ax = plt.subplots(figsize=(7.6, 3.0))
res = ['lut', 'ff', 'bram', 'dsp']
reslab = ['LUT', 'Flip-flops', 'Block RAM tiles', 'DSP slices']
x = np.arange(4); w = 0.36
for j, (tg, lab, col) in enumerate((('v1_2_hp64', 'flash_hp64 (V1.2.1)', BLUE),
                                    ('v1_2_hp64_led', 'flash_hp64_led (V1.2.1-led)', AQUA))):
    pv = [D['impl'][tg]['pct'][r] for r in res]
    ax.bar(x + (j - 0.5) * w, pv, w * 0.92, color=col, label=lab, zorder=3)
    for xx, v in zip(x + (j - 0.5) * w, pv):
        ax.text(xx, v + 1, f'{v:.1f}%', ha='center', fontsize=8, color=INK2)
ax.set_xticks(x); ax.set_xticklabels(reslab); ax.set_ylim(0, 70)
ax.set_ylabel('% of xc7z020'); ax.set_title('Post-route utilisation')
ax.legend(loc='upper left', fontsize=8.5); ax.grid(axis='x', visible=False)
tag(ax, 'Measured (post-route reports)')
fig.savefig(OUT / 'fig_utilisation.png'); plt.close(fig)

print(json.dumps({k: D[k] for k in ('checks', 'runs')}, indent=1)[:3000])
print('figures:', sorted(p.name for p in OUT.glob('*.png')))
