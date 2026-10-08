# PYNQ-Z2 board run — Project FLASH V1.2

Files here:

| File | What |
|---|---|
| `flash_hp64.bit`, `.hwh` | **V1.2.1 overlay (default).** HP0 and DMA memory side 64-bit. Built by `v1/scripts/build_hw.tcl`. |
| `flash_hp32.bit`, `.hwh` | V1.2 overlay, HP0 32-bit. Kept for the AFI confirmation test (see `docs/V1_board_debug_log.md`). |
| `flash.bit`, `flash.hwh` | Legacy name of the V1.2 overlay, byte-identical to `flash_hp32.*`. Not in the bundle. |
| `flash_v1_2_board.ipynb` | Board notebook: `BIT` selects the overlay, HP0 AFI width check (read only), optional `AFI_FORCE` cell (off), VERSION check, 244-image bit-exact sweep, latency, threshold demo, small-sample sens/spec. PYNQ needs each `.bit` with its `.hwh` of the same basename. |
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
extracted if it fails. Expect `flash.bit flash.hwh flash_v1_2_board.ipynb
tools vectors` and a count of `249` (244 images + 5 expectation/label files).

## 5. Run

1. Browser → <http://192.168.2.99:9090>, password `xilinx`.
2. Open `flash_v1_2/flash_v1_2_board.ipynb`, run all cells.
3. Expected: `VERSION OK`, `BOARD: 244/244 bit-exact`, CYCLES = 12,196,126 per image
   (xsim value), i.e. ~183 ms/image at FCLK0 = 66.666672 MHz.

## 6. Record

Fill in `docs/V1_board_results_v1_2.md` with the notebook's output.

If image 0 mismatches: confirm VERSION first, then check which `.mem` files
synthesis loaded (`docs/BRINGUP_STATUS.md`, Phase 5). Weights are the first
suspect, not the RTL: the RTL is proven bit-exact in xsim.
