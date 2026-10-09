# synth_top_v1.tcl -- non-project out-of-context synthesis of top_v1 (V1.2).
#
# Run from the repo root:
#   C:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -notrace ^
#       -source v1/scripts/synth_top_v1.tcl -log verilog/synth_v1_2/vivado.log
#
# Output (gitignored scratch): verilog/synth_v1_2/. Reports are copied to
# docs/reports/synth/ by hand after checking the $readmem lines in the log.

set repo   [file normalize [file dirname [info script]]/../..]
set out    $repo/verilog/synth_v1_2
file mkdir $out

# layer_seq.v includes layer_table.vh; top_v1.v uses its macros without its
# own `include, so layer_seq.v must be read before top_v1.v.
read_verilog [list \
    $repo/v1/rtl/conv_engine.v \
    $repo/v1/rtl/fmap_ram.v \
    $repo/v1/rtl/gap_unit.v \
    $repo/v1/rtl/fc_unit.v \
    $repo/v1/rtl/decision.v \
    $repo/v1/rtl/layer_seq.v \
    $repo/v1/rtl/top_v1.v]
read_xdc $repo/v1/constr/v1.xdc

synth_design -top top_v1 -part xc7z020clg400-1 \
    -include_dirs $repo/v1/mem/v1_2/flash_v1_2

write_checkpoint -force $out/top_v1_synth.dcp
report_timing_summary -max_paths 10 -file $out/V1_synth_timing_v1_2.rpt
report_utilization -file $out/V1_synth_util_v1_2.rpt
puts "SYNTH_TOP_V1_DONE"
