"""Time the NumPy golden model on this PC (context for the board's ARM baseline).

Runs v1/mem/v1_2/flash_v1_2/tools/golden_model_v1.py on verification image 0,
checks the result against exp_*[0], and writes the median of repeated runs to
docs/figures/pc_golden_timing.json together with the CPU and library versions.

    python tools/time_golden_pc.py
"""
import datetime, json, platform, sys, time
from pathlib import Path

import numpy as np

R = Path(__file__).resolve().parents[1]
EXP = R / 'v1/mem/v1_2/flash_v1_2'
sys.path.insert(0, str(EXP / 'tools'))
from golden_model_v1 import GoldenModel  # noqa: E402


def cpu_name():
    try:
        import winreg
        k = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'HARDWARE\DESCRIPTION\System\CentralProcessor\0')
        return winreg.QueryValueEx(k, 'ProcessorNameString')[0].strip()
    except Exception:
        return platform.processor() or platform.machine()


def s32(x):
    return x - (1 << 32) if x & 0x80000000 else x


x = np.array([int(t, 16) for t in (EXP / 'vectors/img_0.mem').read_text().split()], np.uint8).reshape(1, 1, 224, 224)
e0 = s32(int((EXP / 'vectors/exp_logit0.mem').read_text().split()[0], 16))
e1 = s32(int((EXP / 'vectors/exp_logit1.mem').read_text().split()[0], 16))
t = time.perf_counter(); g = GoldenModel(EXP); load_s = time.perf_counter() - t
g.run(x)                                                     # warm-up
ts = []
for _ in range(21):
    t = time.perf_counter(); lg, _ = g.run(x); ts.append(time.perf_counter() - t)
assert (int(lg[0, 0]), int(lg[0, 1])) == (e0, e1), 'golden model != exp_*[0]'
out = dict(ms_per_image=round(float(np.median(ts)) * 1e3, 1), runs=len(ts),
           min_ms=round(min(ts) * 1e3, 1), max_ms=round(max(ts) * 1e3, 1), model_load_s=round(load_s, 3),
           image=0, result=[e0, e1], cpu=cpu_name(), python=platform.python_version(), numpy=np.__version__,
           os=platform.platform(), date=datetime.date.today().isoformat(),
           note='single process, NumPy int64, same golden model the board ARM baseline runs')
(R / 'docs/figures').mkdir(parents=True, exist_ok=True)
(R / 'docs/figures/pc_golden_timing.json').write_text(json.dumps(out, indent=1) + '\n')
print(json.dumps(out, indent=1))
