"""Project FLASH V1 -- standalone golden model.

Pure NumPy int64. Reads ONLY exported files (layer_table.json, weights.mem, bias.mem),
so agreement with the training framework proves the export as well as the arithmetic.
This is the reference the RTL must match bit for bit.

    from golden_model_v1 import GoldenModel
    g = GoldenModel('export/v1_2')
    logits, trace = g.run(images_uint8_N1HW, keep=True)
"""
import json
from pathlib import Path
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view


def read_hex(path, bits, signed):
    v = np.array([int(t, 16) for t in Path(path).read_text().split()], dtype=np.int64)
    if signed:
        v = np.where(v >= (1 << (bits - 1)), v - (1 << bits), v)
    return v


class GoldenModel:
    def __init__(self, export_dir):
        d = Path(export_dir)
        spec = json.loads((d / 'layer_table.json').read_text())
        self.layers, self.img = spec['layers'], spec['img']
        w = read_hex(d / 'weights.mem', 8, True)
        b = read_hex(d / 'bias.mem', 32, True)
        for L in self.layers:
            if L['op'] == 'CONV3X3':
                L['W'] = w[L['w_base']:L['w_base'] + L['n_w']].reshape(L['out_c'], L['in_c'], 3, 3)
                L['B'] = b[L['b_base']:L['b_base'] + L['n_b']]
            elif L['op'] == 'FC':
                L['W'] = w[L['w_base']:L['w_base'] + L['n_w']].reshape(L['out_c'], L['in_c'])
                L['B'] = b[L['b_base']:L['b_base'] + L['n_b']]

    @staticmethod
    def conv3x3_acc(x, W, B, stride, pad):
        """acc[n,o,y,x] = B[o] + sum_{c,i,j} W[o,c,i,j] * xpad[n,c,stride*y+i,stride*x+j]"""
        n, c, h, w = x.shape
        xp = np.zeros((n, c, h + 2 * pad, w + 2 * pad), dtype=np.int64)
        xp[:, :, pad:pad + h, pad:pad + w] = x
        ho, wo = (h + 2 * pad - 3) // stride + 1, (w + 2 * pad - 3) // stride + 1
        win = sliding_window_view(xp, (3, 3), axis=(2, 3))[:, :, ::stride, ::stride][:, :, :ho, :wo]
        return np.einsum('nchwij,ocij->nohw', win, W, optimize=True) + B[None, :, None, None]

    def run(self, x_u8, keep=False, acc_stats=None):
        """x_u8: (N,1,H,W) uint8. Returns (logits (N,2) int64, trace dict)."""
        a = np.asarray(x_u8).astype(np.int64)
        assert a.shape[1:] == (1, self.img, self.img), f'expected (N,1,{self.img},{self.img})'
        trace = {}

        def stat(name, v):
            if acc_stats is not None:
                lo, hi = int(v.min()), int(v.max())
                o = acc_stats.get(name, (lo, hi))
                acc_stats[name] = (min(o[0], lo), max(o[1], hi))

        for L in self.layers:
            nm = L['name']
            if L['op'] == 'CONV3X3':
                acc = self.conv3x3_acc(a, L['W'], L['B'], L['stride'], L['pad'])
                a = np.clip(acc >> L['shift'], 0, 255)          # >> on int64 = arithmetic = floor
                stat(nm + '_acc', acc)
                if keep: trace[nm + '_acc'], trace[nm] = acc, a
            elif L['op'] == 'GAP':
                s = a.sum(axis=(2, 3))
                a = s >> L['shift']
                stat('gap_sum', s)
                if keep: trace['gap_sum'], trace['gap'] = s, a
            elif L['op'] == 'FC':
                a = a @ L['W'].T + L['B'][None, :]
                stat('logits', a); stat('margin', a[:, 1] - a[:, 0])
                if keep: trace['logits'] = a
        return a, trace


def decide(logits, threshold):
    """POSITIVE iff logit1 - logit0 > threshold."""
    return ((logits[:, 1] - logits[:, 0]) > threshold).astype(np.int64)
