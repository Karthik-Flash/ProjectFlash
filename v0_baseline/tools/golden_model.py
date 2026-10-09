import numpy as np, sys

def rd(f, signed=True, n=None):
    v = [int(l.strip(), 16) for l in open(f) if l.strip()]
    if signed: v = [x - 256 if x > 127 else x for x in v]
    return np.array(v, dtype=np.int64)

cw = rd('conv1_weights.mem'); cb = rd('conv1_bias.mem')
w1 = rd('fc1_weights.mem');  b1 = rd('fc1_bias.mem')
w2 = rd('fc2_weights.mem');  b2 = rd('fc2_bias.mem')

def infer(imgfile, verbose=False):
    img = rd(imgfile, signed=False).reshape(28, 28)
    pad = np.zeros((30, 30), dtype=np.int64); pad[1:29, 1:29] = img

    # conv 4x3x3 pad=1, + bias, relu
    fm = np.zeros((4, 28, 28), dtype=np.int64)
    for f in range(4):
        k = cw[f*9:(f+1)*9].reshape(3, 3)
        for r in range(28):
            for c in range(28):
                fm[f, r, c] = int((pad[r:r+3, c:c+3] * k).sum()) + int(cb[f])
    fm = np.maximum(fm, 0)

    # maxpool 2x2 s2 -> 14x14, then >> 8 (truncating)
    pool = fm.reshape(4, 14, 2, 14, 2).max(axis=(2, 4)) >> 8

    flat = pool.reshape(-1)                       # ch-major: ch*196 + r*14 + c
    h1 = np.maximum(w1.reshape(16, 784) @ flat + b1, 0)
    logits = w2.reshape(2, 16) @ h1 + b2
    return flat, h1, logits

if __name__ == '__main__':
    names = [f'image_pneumonia{i}.mem' for i in (1,2,3,4)] + \
            [f'image_normal{i}.mem'    for i in (1,2,3,4)]
    exp   = [1,1,1,1,0,0,0,0]
    ok = 0
    for n, e in zip(names, exp):
        flat, h1, lg = infer(n)
        d = int(lg[1] > lg[0])
        ok += (d == e)
        print(f'{n:26s} logit0={lg[0]:>16d} logit1={lg[1]:>16d} '
              f'pred={d} exp={e} {"OK" if d==e else "MISMATCH"}  '
              f'|max h1|={h1.max():d}  needs {int(max(abs(lg)) ).bit_length()+1} bits')
    print(f'\ngolden model: {ok}/8 correct')
