# v0 baseline — what changed and why

Three genuine datapath bugs were carried from `PneumoniaFPGA/V3`. Each was found by
dumping an intermediate tensor out of the simulator and diffing it against the
NumPy golden model, not by reading the code.

---

## Bug 1 — `line_buffer.v`: the 3×3 window was misaligned

Two faults in one module.

The window's bottom-right tap read `row2[col_wr+1]`. That location had not yet been
written for the current row, so it still held the pixel from the **previous** row.
Every one of the 784 windows therefore had one corrupt tap.

Separately, the window was emitted centred on `(row_wr-1, col_wr)`. Streaming 784
pixels produces centres for image rows −1 through 26. Image row 27 was never
convolved, and an all-padding row was written into feature-map row 0. The whole
feature map was shifted up by one.

**Fix.** Padding is no longer built from comparators inside the module. The caller
streams a **30×30 zero-padded frame** and the line buffer became a plain valid-window
generator: two line stores, three column taps, `window_valid = (row>=2 && col>=2)`.
That yields exactly 784 windows and is bit-identical to
`torch.nn.Conv2d(padding=1)`. It also removes the entire class of border bugs and
scales to any resolution by changing one parameter.

## Bug 2 — `top_accelerator.v`: max-pool read pipeline off by two

`fm_rd_addr` is a register and the BRAM output is a register, so address-to-data is
two cycles. The pool FSM captured after one. The four values landing in
`pool_buffer` were shifted by one address, the fourth 2×2 element was never read at
all, and `pool_result` was sampled in the same cycle `pool_buffer[3]` was being
written — so the comparator tree saw the *previous* window's value.

**Fix.** Rewrote the sequencer as an explicit 8-state walk: issue the four addresses,
capture with correct latency, and only then let the combinational `max_pool` output
settle before writing.

## Bug 3 — `fc_layer.v`: FC1 read pointer off by one

`READ_PREFETCH` issued address 1, and the first `COMPUTE` cycle re-issued address 1.
That burned a slot. The input sequence became `pm[0], pm[1], pm[1], pm[2], …`, so
`pm[783]` was never read and `pm[1]` was multiplied by two different weights.

**Fix.** Dropped the `input_value` staging register and made the invariant explicit:
`bram_rd_data == mem[input_idx]` during every `COMPUTE` cycle, held by issuing
`input_idx + 2` one cycle ahead. Also stopped `DONE_STATE` returning to `IDLE` while
the FSM still had `start` asserted, which was silently re-triggering a full
12,544-cycle pass.

## Bug 4 — `tb_top.v`: two testbench faults masking the above

Stimulus was driven on `posedge`, the same edge the DUT samples, which is a race.
The first image after reset intermittently missed `start` entirely. All stimulus now
moves on `negedge`.

`cancer_flag` is registered *on* `output_valid`, so the decision pin settles one
clock after `result_valid` rises. The old testbench sampled immediately and was
reading the **previous** image's decision. This alone accounts for part of the
original 5/8.

---

## Result

| | V3 | v0 baseline |
|---|---|---|
| Label agreement | 4/8 (all four normals were false positives) | 8/8 |
| Bit-exact logit match vs golden | not measured | 8/8 |
| Conv feature map vs golden | corrupted every window | 0 mismatches / 3,136 |
| Pooled tensor vs golden | off by one address | 0 mismatches / 784 |

The claim to make from here is *"RTL logits equal the quantised reference model on
every image tested"*, not *"8/8 tests pass"*. A decision bit can be right by
accident. A matching 32-bit logit cannot.
