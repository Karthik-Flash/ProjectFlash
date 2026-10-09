# PYNQ-Z2 board run — Project FLASH V1.2

Files here:

| File | What |
|---|---|
| `flash_hp64.bit`, `.hwh` | **V1.2.1 overlay (default).** HP0 and DMA memory side 64-bit. Built by `v1/scripts/build_hw.tcl`. |
| `flash_hp32.bit`, `.hwh` | V1.2 overlay, HP0 32-bit. Kept for the AFI confirmation test (see `docs/V1_board_debug_log.md`). |
| `flash_v1_2_board.ipynb` | Board notebook: `BIT` selects the overlay, HP0 AFI width check (read only), optional `AFI_FORCE` cell (off), VERSION check, 244-image bit-exact sweep, latency, threshold demo, small-sample sens/spec. PYNQ needs each `.bit` with its `.hwh` of the same basename. |
| `make_notebook.py` | Generates `flash_v1_2_board.ipynb`. Edit cells there, not in the `.ipynb`; usage in its docstring. |
| `make_board_bundle.ps1` | Builds `board_bundle/` (gitignored) with everything the board needs. |

## 1. SD card (once)

1. Download the official **PYNQ-Z2** image (v3.0.1) from <http://www.pynq.io/boards.html>.
2. Flash it to a ≥16 GB micro-SD card with balenaEtcher.

## 2. Board setup

1. Boot jumper (JP4) → **SD**.
2. Power jumper (J9) → **USB**. This design is small, USB power is enough.
3. Micro-USB cable to the PC (power + UART). Ethernet cable directly to the PC.
4. Switch on. Wait for the LEDs to settle (~1 min).

## 3. PC network

Set the PC's Ethernet adapter to a static address:

- IP `192.168.2.1`, mask `255.255.255.0` (`/24`), no gateway.

The board's default address is `192.168.2.99`.

## 4. Copy the files

On the PC, from the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File v1\board\make_board_bundle.ps1
```

Then copy the `board_bundle` folder to the board over SMB:

- Explorer → `\\192.168.2.99\xilinx` (user `xilinx`, password `xilinx`)
- Copy the contents of `board_bundle\` into
  `\\192.168.2.99\xilinx\jupyter_notebooks\flash_v1_2\` (create the folder).

Fallback if SMB does not work: in JupyterLab, upload `board_bundle.zip` (repo
root) into `jupyter_notebooks/`, then in a JupyterLab terminal run (Python's
built-in zip module, no `unzip` needed):

```bash
cd ~/jupyter_notebooks && python3 -m zipfile -t board_bundle.zip && python3 -m zipfile -e board_bundle.zip flash_v1_2/ && ls flash_v1_2 && ls flash_v1_2/vectors | wc -l
```

`-t` checks every file's CRC first (catches a truncated upload); nothing is
extracted if it fails. Expect `flash_hp32.bit flash_hp32.hwh flash_hp64.bit
flash_hp64.hwh flash_v1_2_board.ipynb model tools vectors` and a count of `249`
(244 images + 5 expectation/label files).

## 5. Run — lab order

Browser → <http://192.168.2.99:9090>, password `xilinx`, open
`flash_v1_2/flash_v1_2_board.ipynb`. Each run saves
`results_<basename>.csv` and `summary_<basename>.json` next to the notebook.

**Run 1 — `flash_hp64` on a freshly booted board (the result that counts).**

1. Power-cycle or reboot the board, so the AFI is in its boot state.
2. Leave `BIT = 'flash_hp64.bit'` and `AFI_FORCE = False`. Run all cells.
3. Expect:
   - AFI check `OK` (bit 0 = 0, `.hwh` HP0 = 64)
   - `VERSION OK`
   - `BOARD: 244/244 bit-exact`
   - CYCLES = 12,196,126, i.e. 182.9 ms/image compute at 66.666672 MHz
   - TP 117 / FN 5 / TN 57 / FP 65
   - ARM baseline assert passes
4. Files: `results_flash_hp64.csv`, `summary_flash_hp64.json`.

**Run 2 — `flash_hp32` root-cause confirmation (same boot).**

1. *Kernel → Restart*. Set `BIT = 'flash_hp32.bit'`, keep `AFI_FORCE = False`,
   run all cells. Expect AFI check `MISMATCH` and the old result: 0/244,
   image 0 margin 125. Files: `results_flash_hp32.csv`, `summary_flash_hp32.json`.
2. *Kernel → Restart*. Same `BIT`, set `AFI_FORCE = True`, run all cells.
   Expect RDCHAN_CTRL `0x0 -> 0x1` and 244/244. Files:
   `results_flash_hp32_afiforce.csv`, `summary_flash_hp32_afiforce.json`.

**Then reboot the board.** `AFI_FORCE` changes a PS register that stays set
until reboot. Any later `flash_hp64` run on the same boot would show
`MISMATCH` and corrupted input.

Download the six result files (Jupyter file browser → right-click →
Download) and put them in `docs/board_runs/<date>/`.

## 6. Record

Fill in `docs/V1_board_results_v1_2.md` with the notebook's output.

If image 0 mismatches: confirm VERSION first, then check which `.mem` files
synthesis loaded (`docs/BRINGUP_STATUS.md`, Phase 5). Weights are the first
suspect, not the RTL: the RTL is proven bit-exact in xsim.
