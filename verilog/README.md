# verilog/ — local Vivado projects (not in git)

Everything in this folder except this README is gitignored. The projects are
built from the sources in `v1/` and `v0_baseline/` by the scripts in
`v1/scripts/`, and can be deleted and regenerated at any time.

| Folder | Status | What it is |
|---|---|---|
| `ProjectFlashV1_hw/` | **Main V1 project** | Block design `flash_bd` (Zynq PS7, AXI DMA, `top_v1_axi`, optional `axi_gpio_led`), top `flash_bd_wrapper`, FCLK0 66.666672 MHz. Built by `v1/scripts/build_hw.tcl`. Its last build is the **LED variant** (`flash_hp64_led`). |
| `ProjectFlashV1/` | **Legacy** — do not use for hardware | The first V1 project: bare `top_v1` as the top level with `v1/constr/v1.xdc`. It only synthesizes (98 data ports cannot be placed on pins). Kept because its xsim set-up produced the 16/16 + 12/12 `tb_v1` result. Superseded by `ProjectFlashV1_hw/` on 2026-10-07. |
| `ProjectFlashV0/` | Legacy (v0) | The 28×28 v0 baseline project (`top_accelerator`, `tb_top`). |
| `synth_v1_2/` | Scratch | Non-project synthesis of `top_v1` by `v1/scripts/synth_top_v1.tcl` (source of `docs/reports/synth/V1_synth_*_v1_2.rpt`). |
| `sim_tb_v1_axi/` | Scratch | xsim run directory of `v1/scripts/sim_tb_v1_axi.bat`. |
| `build_hw_log/` | Scratch | Vivado logs of every `build_hw.tcl` run, including the failed 71.43 MHz attempt (`try1_71MHz/`). |
| `bd_dryrun*/`, `stray/` | Scratch | Block-design dry runs and a stray duplicate report; safe to delete. |

Rebuild the board overlays (close the project in the GUI first; from the repo
root):

```
C:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source v1/scripts/build_hw.tcl -tclargs verilog/ProjectFlashV1_hw/ProjectFlashV1_hw.xpr 70.0 flash_hp64       # V1.2.1
C:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source v1/scripts/build_hw.tcl -tclargs verilog/ProjectFlashV1_hw/ProjectFlashV1_hw.xpr 70.0 flash_hp64_led 1 # V1.2.1-led
```
