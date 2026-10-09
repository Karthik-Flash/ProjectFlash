# Board session 2026-10-09 — V1.2.1 verified (244/244), root cause confirmed, LED demo

Raw evidence from the PYNQ-Z2 (PYNQ 3.1.1). Files are stored byte for byte
(`.gitattributes`: `docs/board_runs/** -text`); never edit them. Results and
interpretation: [`docs/V1_board_results_v1_2.md`](../../V1_board_results_v1_2.md).

**Date.** The session took place on **2026-10-09**. The `date` fields in the
three `summary_*.json` files read **2025-05-04 09:28–09:45** because the board
has no battery-backed clock and no network time; its clock was never set. The
real order of the runs is run 1 → run 2 → run 3 → demo, all on one boot except
the demo (see below).

| File | SHA-256 prefix | Bytes | What it is |
|---|---|---|---|
| `run1_hp64.ipynb` | `b1461899c01c0623` | 21,313 | Run 1. `flash_hp64.bit` (V1.2.1, HP0 64-bit), fresh boot, AFI check OK, `AFI_FORCE = False`. 244/244 bit-exact. Executed board notebook with outputs. |
| `run2_hp32.ipynb` | `014f70c7e85ff250` | 37,145 | Run 2, same boot. `flash_hp32.bit` (V1.2, HP0 32-bit), AFI check MISMATCH, `AFI_FORCE = False`. 0/244 bit-exact (the 2026-10-08 failure, reproduced). |
| `run3_hp32_afiforce.ipynb` | `db759e7d8c0c89c4` | 21,392 | Run 3, same boot. `flash_hp32.bit` with `AFI_FORCE = True` (AFI0 RDCHAN_CTRL bit 0: 0 → 1). 244/244 bit-exact. |
| `results_flash_hp64.csv` | `fa595037550af8d7` | 11,969 | Run 1, one row per image: board and expected logit0/logit1/margin/decision, cycles, ground truth, exact. CRLF line endings, as written on the board. |
| `results_flash_hp32.csv` | `c68d7994bb229de5` | 11,982 | Run 2, same columns. |
| `results_flash_hp32_afiforce.csv` | `fa595037550af8d7` | 11,969 | Run 3, same columns. **Byte-identical to `results_flash_hp64.csv`.** |
| `summary_flash_hp64.json` | `a35f15045b49002e` | 635 | Run 1 summary: SHAs, PYNQ version, FCLK0, AFI bit 0, counts, TP/FN/TN/FP, throughput, ARM baseline. |
| `summary_flash_hp32.json` | `939fc8ab9b0ce6d0` | 626 | Run 2 summary. |
| `summary_flash_hp32_afiforce.json` | `5a592e7b154f9b8b` | 635 | Run 3 summary. |
| `demo_flash_hp64_led_executed.ipynb` | `038a3a5bb2fe36d4` | 618,857 | Live demo, `flash_hp64_led.bit` (`7e0c3394fac1b57d`): LED self-test, 12-image gallery (12/12 bit-exact, ARM mean 706.6 ms, 3.8×), 244-image sweep (244/244), slider, limitations. Executed `v1/board/flash_v1_2_demo.ipynb`; it has one extra empty cell added on the board. |

Notes:

- `flash_hp32` in runs 2 and 3 is byte-identical to the bitstream that was
  called `flash.bit` on 2026-10-08 (SHA-256 `396a219b10690f26`).
- The demo was run after the three verification runs, with the LED
  bitstream loaded. Its AFI check read bit 0 = 0 (OK for a 64-bit build),
  which is consistent with the reboot that the lab order prescribes after
  run 3's `AFI_FORCE` write. The files do not record the reboot itself.
