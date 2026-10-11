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
    class3_median_margin={c: float(np.median(m[cls3 == c]))
                          for c in ('Normal', 'No Lung Opacity / Not Normal', 'Lung Opacity')},
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
p = D['impl']['v1_2_hp64']['power']
D['impl']['v1_2_hp64']['power']['pl_w'] = round(p['total_w'] - p['ps7_w'], 3)            # PL dynamic + device static
D['impl']['v1_2_hp64']['power']['pl_dynamic_w'] = round(p['dynamic_w'] - p['ps7_w'], 3)

# ---------------------------------------------------------------- accelerator metrics (industry terms)
lat = D['latency']
ops = 2 * lat['total_macs']                                  # 1 MAC = 1 multiply + 1 add
t_c, t_e = lat['cycles'] / (fclk * 1e6), lat['end_to_end_ms'] / 1e3
u64 = D['impl']['v1_2_hp64']
D['accel'] = dict(
    ops_per_image=ops,
    gops_compute=round(ops / t_c / 1e9, 5), gops_end_to_end=round(ops / t_e / 1e9, 5),
    gops_peak_1mac=round(2 * fclk * 1e6 / 1e9, 5),
    mac_cycle_efficiency=round(lat['total_macs'] / lat['cycles'], 5),
    dsp=u64['util']['flash_bd_wrapper']['dsp'], bram_tiles=u64['bram_tiles'], lut=u64['util']['flash_bd_wrapper']['lut'],
    accel_only=u64['util']['top_v1_axi_0'],
    energy_mj_total=round(p['total_w'] * t_c * 1e3, 1), energy_mj_pl=round(D['impl']['v1_2_hp64']['power']['pl_w'] * t_c * 1e3, 1),
    gops_per_w_total=round(ops / t_c / 1e9 / p['total_w'], 4),
    gops_per_w_pl=round(ops / t_c / 1e9 / D['impl']['v1_2_hp64']['power']['pl_w'], 3),
    power_label='Derived from the Vivado vector-less estimate (Synthesis estimate), compute latency',
    pc_ms=lat.get('pc_golden', {}).get('ms_per_image'), arm_ms_range=[min(arm), max(arm)],
    arm_demo_mean_ms=D['demo']['mean_arm_ms'], fpga_demo_mean_ms=D['demo']['mean_fpga_ms'])

# ---------------------------------------------------------------- test-set subgroups (manifest), CIs
def hanley_mcneil(a, npos, nneg, z=1.96):
    q1, q2 = a / (2 - a), 2 * a * a / (1 + a)
    se = math.sqrt((a * (1 - a) + (npos - 1) * (q1 - a * a) + (nneg - 1) * (q2 - a * a)) / (npos * nneg))
    return [round(a - z * se, 4), round(a + z * se, 4)]

summ_m = manifest['summary']
boot_test = [float(v) for v in re.findall(r'[\d.]+', summ_m['TEST AUROC'])]
n_pos_test = next(s['positives'] for s in manifest['subgroups'] if s['subgroup'] == 'all test')
sg = []
for s in manifest['subgroups']:
    a, npos, nneg = float(s['AUROC']), s['positives'], s['n'] - s['positives']
    sg.append(dict(subgroup=s['subgroup'], n=s['n'], positives=npos, auroc=a, ci_hanley_mcneil=hanley_mcneil(a, npos, nneg)))
view_only = float(summ_m['view-only AUROC (shortcut floor)'])
D['subgroups'] = dict(
    rows=sg, test_auroc_bootstrap=boot_test, view_only_auroc=view_only,
    view_only_ci_hanley_mcneil=hanley_mcneil(view_only, n_pos_test, n_test - n_pos_test),
    note='Measured AUROC from manifest.json; CI is the manifest bootstrap for all test, '
         'otherwise Derived with Hanley & McNeil (1982), which is slightly wider than the bootstrap overall')

# ---------------------------------------------------------------- PPV / NPV vs prevalence (test operating point)
aud = (R / 'docs/audits/V1_audit_v1_2.md').read_text(encoding='utf-8')
tn_, fp_, tp_, fn_ = map(int, re.search(r'TN (\d+), FP (\d+), TP (\d+), FN (\d+)', aud).groups())
sens_t, spec_t = tp_ / (tp_ + fn_), tn_ / (tn_ + fp_)
def ppv_npv(prev):
    ppv = sens_t * prev / (sens_t * prev + (1 - spec_t) * (1 - prev))
    npv = spec_t * (1 - prev) / (spec_t * (1 - prev) + (1 - sens_t) * prev)
    return round(ppv, 4), round(npv, 4)
prev_test = (tp_ + fn_) / (tp_ + fn_ + tn_ + fp_)
D['prevalence'] = dict(test_counts=dict(tp=tp_, fn=fn_, tn=tn_, fp=fp_), sens=round(sens_t, 4), spec=round(spec_t, 4),
                       test_prevalence=round(prev_test, 4),
                       ppv_npv={f'{q:g}': ppv_npv(q) for q in (0.01, 0.05, 0.10, round(prev_test, 4), 0.50)})

# ---------------------------------------------------------------- V2 projection (Derived, ideal scaling)
non_mac = lat['cycles'] - lat['total_macs']
D['projection'] = dict(
    assumption='cycles(k) = total MACs / k + the measured non-MAC cycles (GAP stream, sequencing); '
               'ideal scaling, memory bandwidth permitting; compute only',
    non_mac_cycles=non_mac,
    ms={f'{f:g}MHz': {k: round((lat['total_macs'] / k + non_mac) / (f * 1e3), 2) for k in (1, 2, 4, 8, 16)}
        for f in (fclk, 75.0)})
D['projection']['ms'] = {('66.67MHz' if k.startswith('66') else k): v for k, v in D['projection']['ms'].items()}

# ---------------------------------------------------------------- 28x28 -> 224x224 (layer tables)
def table_macs(path):
    t = json.loads(path.read_text())
    return t, sum(L['out_c'] * L['out_h'] * L['out_w'] * L['in_c'] * 9 if L['op'] == 'CONV3X3' else
                  L['out_c'] * L['in_c'] if L['op'] == 'FC' else 0 for L in t['layers'])
t11, macs11 = table_macs(R / 'v1/mem/v1_1/flash_v1_1/layer_table.json')
t12, macs12 = table_macs(EXP / 'layer_table.json')
s11 = (R / 'docs/reports/synth/V1_synth_results_v1_1.md').read_text(encoding='utf-8')
c1 = t12['layers'][0]
D['scaling'] = dict(
    macs_v1_1=macs11, macs_v1_2=macs12, macs_ratio=round(macs12 / macs11, 2), pixel_ratio=(224 // 28) ** 2,
    descriptor_bits=t12['word_width'], descriptor_fields=t12['fields'],
    descriptor_used_bits=sum(w for _, w in t12['fields']),
    conv1_output_bytes_224=c1['out_c'] * c1['out_h'] * c1['out_w'],
    bram36_v1_1_synth=int(re.search(r'\| BRAM36 \| (\d+) \|', s11).group(1)),
    bram18_v1_1_synth=int(re.search(r'\| BRAM18 \| (\d+) \|', s11).group(1)),
    bram_tiles_v1_2_synth=D['synth_v1_2']['bram_tiles'],
    same_fields_both_stages=t11['fields'] == t12['fields'])
# v0's parameters, from the layer table in v0_baseline/README.md (conv 4x3x3, FC1 784->16, FC2 16->2)
v0 = dict(conv=4 * 9 + 4, fc1=784 * 16 + 16, fc2=16 * 2 + 2)
D['scaling']['v0_params'] = dict(v0, total=sum(v0.values()), flatten_fc_share=round((v0['fc1'] + v0['fc2']) / sum(v0.values()), 4),
                                 fc1_weights_if_224=4 * 112 * 112 * 16)

(OUT / 'derived_numbers.json').write_text(json.dumps(D, indent=1) + '\n')

# ================================================================ figures
# Sized for an IEEE column (3.5 in) or page (7.16 in), serif text, no in-plot titles: the captions in
# the report and the paper carry the title and the label (Measured, Derived, Derived projection). The
# same run writes the report's PNGs and the paper's vector PDFs (paper/figures/).
INK, INK2, MUTED, GRID, BASE, SURF = '#0b0b0b', '#52514e', '#898781', '#e1e0d9', '#c3c2b7', '#ffffff'
BLUE, ORANGE, AQUA = '#2a78d6', '#eb6834', '#1baf7a'
W1, W2 = 3.5, 7.16
plt.rcParams.update({
    'font.family': 'serif', 'font.serif': ['STIXGeneral', 'DejaVu Serif'], 'mathtext.fontset': 'stix',
    'font.size': 8, 'text.color': INK, 'axes.edgecolor': BASE, 'axes.labelcolor': INK, 'axes.labelsize': 8,
    'axes.facecolor': SURF, 'figure.facecolor': SURF,
    'xtick.color': INK2, 'ytick.color': INK2, 'xtick.labelsize': 7.5, 'ytick.labelsize': 7.5,
    'axes.grid': True, 'grid.color': GRID, 'grid.linewidth': 0.5, 'axes.spines.top': False,
    'axes.spines.right': False, 'legend.frameon': False, 'legend.fontsize': 7.2, 'savefig.dpi': 220,
    'savefig.bbox': 'tight', 'savefig.pad_inches': 0.03, 'savefig.facecolor': SURF, 'pdf.fonttype': 42})
PAPER = R / 'paper/figures'
PAPER.mkdir(parents=True, exist_ok=True)

def save(fig, name, width=W1):
    # Fit the saved width (tight box, labels outside the axes included) to the column or page, so
    # the paper includes it at 100% and the font sizes are the real ones.
    for _ in range(4):
        bb = fig.get_tightbbox(fig.canvas.get_renderer())
        fig.set_size_inches(fig.get_figwidth() + width - 2 * 0.03 - bb.width, fig.get_figheight())
    fig.savefig(OUT / f'{name}.png')
    fig.savefig(PAPER / f'{name}.pdf', metadata={'CreationDate': None})
    plt.close(fig)

# F1: MACs per layer (Derived)
fig, ax = plt.subplots(figsize=(W1, 2.0))
names = list(macs)
vals = [macs[n] / 1e6 for n in names]
ax.bar(names, vals, color=BLUE, width=0.62, zorder=3)
for x, v, n in zip(range(len(names)), vals, names):
    ax.text(x, v + 0.07, f'{macs[n]:,}', ha='center', va='bottom', fontsize=5.8, color=INK2)
ax.set_ylim(0, 4.3)
ax.set_ylabel('MACs per image (millions)')
ax.grid(axis='x', visible=False)
save(fig, 'fig_layer_macs')

# Fa: operating characteristic on the 244 board margins (Derived), test-set point (Measured, manifest)
fig, ax = plt.subplots(figsize=(W1, 2.35))
ths = np.arange(int(m.min()) - 100, int(m.max()) + 101)
sens_c = ((m[None, :] > ths[:, None]) & (gt == 1)).sum(1) / gt.sum()
spec_c = ((m[None, :] <= ths[:, None]) & (gt == 0)).sum(1) / (gt == 0).sum()
ax.plot(ths, sens_c, color=BLUE, lw=1.6, zorder=3)
ax.plot(ths, spec_c, color=ORANGE, lw=1.6, zorder=3)
ax.axvline(T, color=INK2, lw=0.8, ls='--', zorder=2)
b_s, b_p = D['cls']['sensitivity_wilson'][0], D['cls']['specificity_wilson'][0]
ax.scatter([T, T], [b_s, b_p], s=22, color=[BLUE, ORANGE], zorder=5, edgecolor=SURF, lw=1,
           label=f'board, 244: {b_s:.3f} / {b_p:.3f}')
ax.scatter([T, T], [sens_t, spec_t], s=26, marker='D', facecolor=SURF, edgecolor=[BLUE, ORANGE], lw=1.3, zorder=5,
           label=f'test set, 4,003: {sens_t:.3f} / {spec_t:.3f}')
ax.text(1150, 0.83, 'specificity', color=INK2, fontsize=7)
ax.text(1150, 0.47, 'sensitivity', color=INK2, fontsize=7)
ax.text(T + 60, 0.03, 'T = −646', fontsize=6.8, color=INK2)
ax.set_xlabel('threshold on margin (flag if margin > threshold)')
ax.set_ylim(-0.02, 1.08)
ax.legend(loc='upper center', bbox_to_anchor=(0.5, -0.24), ncol=2, handletextpad=0.2, columnspacing=1.0)
save(fig, 'fig_operating_characteristic')

# Fb: board margins by RSNA three-way class (Measured)
fig, ax = plt.subplots(figsize=(W1, 2.15))
classes = [('Normal', 'Normal', AQUA), ('No Lung Opacity / Not Normal', 'Not Normal', ORANGE),
           ('Lung Opacity', 'Lung Opacity', BLUE)]
jr = np.random.default_rng(1)
for yy, (c, lab, col) in enumerate(classes):
    mc = m[cls3 == c]
    ax.scatter(mc, yy + jr.uniform(-0.2, 0.2, len(mc)), s=6, color=col, lw=0, alpha=0.9, zorder=3)
    ax.boxplot(mc, positions=[yy], vert=False, widths=0.55, showfliers=False, zorder=4, manage_ticks=False,
               medianprops=dict(color=INK, lw=1.2), boxprops=dict(color=INK, lw=0.8),
               whiskerprops=dict(color=INK, lw=0.8), capprops=dict(color=INK, lw=0.8))
    ax.text(1.01, yy, f'{int((mc > T).sum())}/{len(mc)}\nflagged', transform=ax.get_yaxis_transform(),
            va='center', fontsize=6.5, color=INK, clip_on=False)
ax.axvline(T, color=INK2, lw=0.9, ls='--', zorder=2)
ax.text(T - 40, 2.62, 'T', ha='right', fontsize=7, color=INK2)
ax.set_yticks(range(3)); ax.set_yticklabels([c[1] for c in classes], fontsize=7)
ax.set_ylim(-0.6, 2.75)
ax.set_xlabel('board margin = logit1 − logit0')
ax.grid(axis='y', visible=False)
save(fig, 'fig_margins_by_class')

# Fc: subgroup AUROC, test set (Measured AUROC; CIs bootstrap or Derived Hanley–McNeil)
nice = {'all test': 'All test', 'Opacity vs Normal': 'vs Normal only',
        'Opacity vs No Lung Opacity / Not Normal': 'vs Not Normal only', 'view AP': 'AP films',
        'view PA': 'PA films', 'sex M': 'Male', 'sex F': 'Female'}
rows = [(f"{nice[s['subgroup']]} ({s['n']:,})", s['auroc'],
         boot_test[1:] if s['subgroup'] == 'all test' else s['ci_hanley_mcneil'], BLUE) for s in sg]
rows.append(('Board, 244 images', D['cls']['auroc'], D['cls']['auroc_boot_ci'], AQUA))
fig, ax = plt.subplots(figsize=(W1, 2.55))
ys = list(range(len(rows) - 1, 0, -1)) + [-0.5]
for yy, (lab, a, ci, col) in zip(ys, rows):
    ax.plot(ci, [yy, yy], color=col, lw=1.6, zorder=3, solid_capstyle='round')
    ax.scatter([a], [yy], s=20, color=col, zorder=4, edgecolor=SURF, lw=0.8)
    ax.text(1.01, yy, f'{a:.3f} ({ci[0]:.3f}–{ci[1]:.3f})', transform=ax.get_yaxis_transform(), va='center',
            fontsize=6.3, color=INK, clip_on=False)
ax.axvline(view_only, color=INK2, lw=0.8, ls='--', zorder=2)
ax.text(view_only + 0.004, 7.55, f'AP/PA view alone {view_only:.3f}', fontsize=6.5, color=INK2)
ax.set_yticks(ys); ax.set_yticklabels([r[0] for r in rows], fontsize=6.6)
ax.set_xlim(0.66, 1.0); ax.set_ylim(-1.1, 8.0)
ax.set_xlabel('AUROC (95% CI)')
ax.grid(axis='y', visible=False)
save(fig, 'fig_subgroup_auroc')

# Fd: PPV / NPV vs prevalence at the test operating point (Derived)
fig, ax = plt.subplots(figsize=(W1, 2.3))
pv = np.linspace(0.01, 0.50, 197)
pp = np.array([ppv_npv(q) for q in pv])
ax.plot(pv * 100, pp[:, 0] * 100, color=BLUE, lw=1.6, zorder=3)
ax.plot(pv * 100, pp[:, 1] * 100, color=ORANGE, lw=1.6, zorder=3)
for q, lab in ((prev_test, f'test set\n{prev_test * 100:.1f}%'), (0.5, '244 subset\n50%')):
    ax.axvline(q * 100, color=INK2, lw=0.7, ls='--', zorder=2)
    a_, b_ = ppv_npv(q)
    ax.scatter([q * 100] * 2, [a_ * 100, b_ * 100], s=16, color=[BLUE, ORANGE], zorder=4, edgecolor=SURF, lw=0.8)
    ax.text(q * 100 - 0.8, a_ * 100 + 3, f'{a_ * 100:.1f}%', ha='right', fontsize=6.5, color=INK)
    ax.text(q * 100 - 0.8, b_ * 100 - 9, f'{b_ * 100:.1f}%', ha='right', fontsize=6.5, color=INK)
    ax.text(q * 100 - 0.8, 12, lab, ha='right', va='center', fontsize=6.3, color=INK2)
a5 = ppv_npv(0.05)[0]
ax.scatter([5], [a5 * 100], s=16, color=BLUE, zorder=4, edgecolor=SURF, lw=0.8)
ax.text(6, a5 * 100 - 2, f'{a5 * 100:.1f}% at 5%', fontsize=6.5, color=INK, va='top')
ax.text(24, 99.5, 'NPV: P(no pneumonia | cleared)', fontsize=6.5, color=INK2, va='bottom')
ax.text(37, 27, 'PPV: P(pneumonia | flagged)', fontsize=6.5, color=INK2, ha='center')
ax.set_xlim(0, 52); ax.set_ylim(0, 106)
ax.set_xlabel('prevalence of pneumonia (%)'); ax.set_ylabel('%')
save(fig, 'fig_ppv_npv_prevalence')

# Fe: AFI case study: the corrupted run (Measured) next to what the PL received (Derived)
fig = plt.figure(figsize=(W2, 2.75))
gs = fig.add_gridspec(3, 2, width_ratios=[1, 1.35], wspace=0.18, hspace=0.75)
ax = fig.add_subplot(gs[:, 0])
ok = h32['decision'] == exp['exp_decision']
lo = min(exp['exp_margin'].min(), h32['margin'].min()) - 150
hi = max(exp['exp_margin'].max(), h32['margin'].max()) + 150
ax.plot([lo, hi], [lo, hi], color=MUTED, lw=0.8, zorder=2)
ax.scatter(exp['exp_margin'][ok], h32['margin'][ok], s=7, color=BLUE, zorder=3, lw=0,
           label=f'decision agrees ({ok.sum()})')
ax.scatter(exp['exp_margin'][~ok], h32['margin'][~ok], s=18, color=ORANGE, zorder=4, lw=0.6, edgecolor=SURF,
           label=f'decision flips ({(~ok).sum()})')
ax.axhline(T, color=INK2, lw=0.6, ls='--', zorder=2); ax.axvline(T, color=INK2, lw=0.6, ls='--', zorder=2)
ax.set_xlim(lo, hi); ax.set_ylim(lo, hi)
ax.set_xlabel('expected margin (golden model)'); ax.set_ylabel('board margin, flash_hp32')
ax.text(0.03, 0.97, f'r = {D["afi"]["corr_all_logits"]:.2f} (logits)\nbit-exact 0/244\n'
        f'decisions agree {D["afi"]["decision_agreement"]}/244', transform=ax.transAxes, va='top', fontsize=6.8,
        color=INK)
ax.legend(loc='lower right')
im0 = i0.reshape(224, 224).astype(int)
seen = dup_even(i0).reshape(224, 224).astype(int)
y0, x0 = 96, 40
crop = (slice(y0, y0 + 24), slice(x0, x0 + 128))
panels = (im0[crop], seen[crop], np.abs(im0[crop] - seen[crop]))
titles = ('image 0 as sent (rows 96–119, columns 40–167)', 'as received: odd 32-bit words replaced by even ones',
          '|difference|; orange lines mark 8-pixel (64-bit) groups')
for j, (a, t_) in enumerate(zip(panels, titles)):
    axc = fig.add_subplot(gs[j, 1])
    axc.imshow(a, cmap='gray', vmin=0, vmax=255 if j < 2 else max(1, int(a.max())), interpolation='nearest',
               aspect='equal')
    axc.set_xlabel(t_, fontsize=6.4, labelpad=2); axc.set_xticks([]); axc.set_yticks([]); axc.grid(False)
    for xx in range(0, 129, 8):
        axc.axvline(xx - 0.5, color=ORANGE, lw=0.5, alpha=0.8)
save(fig, 'fig_afi_case', W2)

# Ff: V2 projection, latency vs MACs per clock (Derived projection)
fig, ax = plt.subplots(figsize=(W1, 2.45))
ks = [1, 2, 4, 8, 16]
for f, key, col in ((fclk, '66.67MHz', BLUE), (75.0, '75MHz', ORANGE)):
    yv = [D['projection']['ms'][key][k] for k in ks]
    ax.plot(ks, yv, color=col, lw=1.5, marker='o', ms=3.2, zorder=3)
    ax.text(2.15, yv[1] * (1.3 if col == BLUE else 0.56), f'{key[:-3]} MHz', fontsize=6.5, color=INK2, va='center')
    ax.text(17.5, yv[-1] * (1.12 if col == BLUE else 0.89), f'{yv[-1]:.1f} ms', va='center', fontsize=6.3, color=INK)
ax.scatter([1], [lat['compute_ms']], s=46, facecolor='none', edgecolor=INK, lw=1.1, zorder=5)
ax.text(1.12, lat['compute_ms'] * 1.32, f'measured {lat["compute_ms"]:.2f} ms', fontsize=6.5, color=INK)
pcm = D['accel']['pc_ms']
for yv, lab in ((D['demo']['mean_arm_ms'], f'board ARM, NumPy golden ({D["demo"]["mean_arm_ms"]:.0f} ms)'),
                (pcm, f'desktop PC, NumPy golden ({pcm:.1f} ms)')):
    ax.axhline(yv, color=MUTED, lw=0.8, ls=':', zorder=2)
    ax.text(1.0, yv * 1.08, lab, fontsize=6.2, color=INK2)
ax.set_xscale('log', base=2); ax.set_yscale('log')
ax.set_xticks(ks); ax.set_xticklabels([str(k) for k in ks])
ax.set_yticks([10, 30, 100, 300, 1000]); ax.set_yticklabels(['10', '30', '100', '300', '1000'])
ax.set_xlim(0.85, 16.5); ax.set_ylim(6, 1300)
ax.set_xlabel('MACs per clock (V1 = 1)'); ax.set_ylabel('compute latency (ms, log)')
ax.text(0.98, 0.83, 'ideal scaling, memory bandwidth permitting;\n75 MHz needs the address path pipelined',
        transform=ax.transAxes, ha='right', va='top', fontsize=5.9, color=INK2)
save(fig, 'fig_v2_projection')

print(json.dumps({k: D[k] for k in ('checks', 'accel', 'prevalence', 'projection', 'scaling')}, indent=1)[:4000])
print('figures:', sorted(p_.name for p_ in OUT.glob('*.png')))
