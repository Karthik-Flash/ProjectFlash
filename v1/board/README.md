# PYNQ-Z2 board run — Project FLASH V1.2.1

**Tested on PYNQ 3.1.1** (PYNQ-Z2 image), 2026-10-09: `flash_hp64` and
`flash_hp64_led` are bit-exact on all 244 verification images. Results:
[`docs/V1_board_results_v1_2.md`](../../docs/V1_board_results_v1_2.md).
Research prototype, not a medical device.

Files here:

| File | What |
|---|---|
| `flash_hp64.bit`, `.hwh` | **V1.2.1 overlay (verification default).** HP0 and DMA memory side 64-bit. SHA-256 `0ee58d6c924cd162` / `7011237c69968c86`. |
| `flash_hp64_led.bit`, `.hwh` | **V1.2.1-led overlay (demo default).** `flash_hp64` plus `axi_gpio_led` at 0x41200000 driving LD0–LD3 and the two RGB LEDs; same accelerator netlist. SHA-256 `7e0c3394fac1b57d` / `2b37db60135ed638`. |
| `flash_hp32.bit`, `.hwh` | V1.2 overlay, HP0 32-bit (called `flash.bit` on 2026-10-08). Kept only for the AFI confirmation test; it gives 0/244 unless the AFI is forced. SHA-256 `396a219b10690f26` / `5f8c18af7bdf3650`. |
| `flash_v1_2_board.ipynb` | Verification notebook. `BIT` selects the overlay; it runs a read-only AFI-vs-`.hwh` check, an optional `AFI_FORCE` cell (off), the VERSION check, the 244-image bit-exact sweep, saved evidence files, latency, throughput, the threshold demo, sens/spec and the ARM baseline. |
| `flash_v1_2_demo.ipynb` | Live demo notebook: disclaimer, LED self-test, a 12-image gallery (FPGA vs ARM), a live 244-image sweep, a slider with LED output, and limitations. It refuses to run on an AFI mismatch and never writes the AFI. |
| `make_notebook.py`, `make_demo_notebook.py` | Generate the two notebooks. Edit cells there, not in the `.ipynb`; usage is in their docstrings. |
| `make_board_bundle.ps1` | Builds `board_bundle/` (gitignored, 263 files) with everything the board needs. |

PYNQ needs each `.bit` next to its `.hwh` with the same basename.

## 1. SD card (once)

1. Download the official **PYNQ-Z2** image from <http://www.pynq.io/boards.html>.
   The runs used **PYNQ 3.1.1**.
2. Flash it to a ≥16 GB micro-SD card with balenaEtcher.

## 2. Board setup

1. Boot jumper (JP4) → **SD**.
2. Power jumper (J9) → **USB**. This design is small, so USB power is enough.
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

Fallback if SMB does not work: zip the bundle on the PC with forward-slash
paths (Windows `Compress-Archive` writes backslashes, which Linux extracts as
literal file names):

```powershell
python -c "import zipfile,pathlib;r=pathlib.Path('board_bundle');z=zipfile.ZipFile('board_bundle.zip','w',zipfile.ZIP_DEFLATED);[z.write(p,p.relative_to(r).as_posix()) for p in sorted(r.rglob('*')) if p.is_file()];z.close()"
```

Upload `board_bundle.zip` in JupyterLab into `jupyter_notebooks/`, then in a
JupyterLab terminal run (Python's built-in zip module, no `unzip` needed):

```bash
cd ~/jupyter_notebooks && python3 -m zipfile -t board_bundle.zip && python3 -m zipfile -e board_bundle.zip flash_v1_2/ && ls flash_v1_2 && ls flash_v1_2/vectors | wc -l
```

`-t` checks every file's CRC first (catches a truncated upload); nothing is
extracted if it fails. Expect the six overlay files, both notebooks, `model`,
`tools`, `vectors`, and a count of `249` (244 images + 5 expectation/label
files).

## 5. Verification run — lab order

Browser → <http://192.168.2.99:9090>, password `xilinx`, open
`flash_v1_2/flash_v1_2_board.ipynb`. Each run saves
`results_<basename>.csv` and `summary_<basename>.json` next to the notebook.

**Run 1 — `flash_hp64` on a freshly booted board (the result that counts).**

1. Power-cycle or reboot the board, so the AFI is in its boot state.
2. Leave `BIT = 'flash_hp64.bit'` and `AFI_FORCE = False`. Run all cells.
3. Expect (as measured on 2026-10-09):
   - AFI check `OK` (bit 0 = 0, `.hwh` HP0 = 64)
   - `VERSION OK`
   - `BOARD: 244/244 bit-exact`
   - CYCLES = 12,196,126, i.e. 182.94 ms/image compute at 66.666667 MHz;
     about 184.7 ms/image end to end
   - TP 117 / FN 5 / TN 57 / FP 65
   - the ARM baseline assert passes (about 0.7 s per image)
4. Files: `results_flash_hp64.csv`, `summary_flash_hp64.json`.

**Run 2 — `flash_hp32` root-cause confirmation (same boot, optional).**

1. *Kernel → Restart*. Set `BIT = 'flash_hp32.bit'`, keep `AFI_FORCE = False`,
   run all cells. Expect AFI check `MISMATCH` and the old result: 0/244,
   image 0 margin 125. Files: `results_flash_hp32.csv`, `summary_flash_hp32.json`.
2. *Kernel → Restart*. Same `BIT`, set `AFI_FORCE = True`, run all cells.
   Expect RDCHAN_CTRL `0x0 -> 0x1` and 244/244. Files:
   `results_flash_hp32_afiforce.csv`, `summary_flash_hp32_afiforce.json`.

**Then reboot the board.** `AFI_FORCE` changes a PS register that stays set
until reboot. Any later 64-bit overlay on the same boot would show
`MISMATCH` and get corrupted input.

Download the result files (Jupyter file browser → right-click → Download) and
put them in `docs/board_runs/<date>/` with a `README.md` listing their
SHA-256 prefixes. The board clock is not set, so the JSON dates are wrong;
write the real date in the README.

## 6. Live demo

Open `flash_v1_2/flash_v1_2_demo.ipynb` on a booted board (after a reboot if
`AFI_FORCE` was used) and run all cells. It loads `flash_hp64_led.bit` if it
is present, otherwise `flash_hp64.bit`; the LED code is then a no-op.

- **Load cell:** SHA-256, VERSION, FCLK0, AFI check. It raises "reboot the
  board and re-run" on a mismatch.
- **LED self-test:** LD0–LD3 on for 1 s, then both RGB LEDs red, green and
  blue (0.5 s each), then off.
- **Gallery:** the first 6 true positives and first 6 true negatives by index
  (a fixed rule, not cherry-picked), each run live on the FPGA and on the ARM
  golden model. Measured: 12/12 bit-exact, FPGA 185.0 ms vs ARM 706.6 ms
  mean, 3.8×.
- **Sweep:** all 244 live, about 57 s. Measured: 244/244, sensitivity 0.959,
  specificity 0.467, AUROC 0.8367.
- **Slider:** runs any image live. Pneumonia: LD0–LD3 blink at 4 Hz for
  2.5 s with the RGB LEDs red. Negative: RGB green for 1.5 s.
- **Limitations:** the first false positive (image 1) and false negative
  (image 61), shown with their images.
- The last cell turns the LEDs off and frees the DMA buffer.

## 7. If image 0 mismatches

1. Confirm VERSION (0xF1A50102) and the bitstream SHA.
2. Check the AFI line: a `MISMATCH` means the AFI width does not match the
   overlay (see `docs/V1_board_debug_log.md`); reboot.
3. Check which `.mem` files synthesis loaded (`docs/BRINGUP_STATUS.md`,
   Phase 5).

The RTL is proven bit-exact on the board, so check the memory path and the
weights first.
