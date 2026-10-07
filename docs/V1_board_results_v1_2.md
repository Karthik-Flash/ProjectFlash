# V1.2 Board Results (PYNQ-Z2, 224x224)

Template. Fill in from `v1/board/flash_v1_2_board.ipynb` after the board run.
Build-side numbers (timing, utilization, power estimate, FCLK0) are in
`docs/BRINGUP_STATUS.md` and the `docs/V1_impl_*_v1_2.rpt` files.

## Setup

| Item | Value |
|---|---|
| Date | |
| PYNQ image version | |
| Bitstream (`flash.bit`) commit | |
| VERSION register | (expect `0xF1A50102`) |
| FCLK0 reported by `pynq.Clocks.fclk0_mhz` | |

## Bit-exactness (244 verification images)

| Field | Exact / 244 |
|---|---|
| logit0 | |
| logit1 | |
| margin | |
| decision | |
| STATUS.err set on any image | |

Mismatches (image, got, expected):

```
```

## Latency and throughput

| Metric | Value |
|---|---|
| CYCLES register, min..max | |
| Compute latency @ FCLK0 (CYCLES / FCLK0) | |
| Wall time per image incl. DMA + file parsing | |
| Throughput (images/s, compute only) | |

## Threshold demo

| Image | Threshold | Decision |
|---|---|---|
| | -646 (default) | |
| | 0x7FFFFFFF | |

## Small-sample sensitivity / specificity (244 images vs `gt_label.mem`)

Small, seeded subset. The headline accuracy stays the notebook's test AUROC
(V1.2: 0.8229) with its confidence interval.

| Metric | Value |
|---|---|
| TP / FN / TN / FP | |
| Sensitivity | |
| Specificity | |

## DICOM end to end (optional)

| DICOM | Board logits | Golden model logits (PC) | Match |
|---|---|---|---|
| | | | |

## Notes
