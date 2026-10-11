# report_hw.tcl -- Project FLASH: hardware evidence reports for one routed build.
#
# Opens a routed checkpoint read-only (the project is not touched) and writes
# into docs/reports/impl/:
#   V1_impl_paths_<tag>.rpt      10 worst setup paths, then 10 worst hold paths
#   V1_impl_design_<tag>.rpt     report_design_analysis -timing (10 worst paths)
#   V1_impl_utilsum_<tag>.rpt    flat utilisation summary (site types); the hierarchical
#                                one is V1_impl_util_<tag>.rpt, written by build_hw.tcl
#   V1_impl_clocks_<tag>.rpt     report_clocks
#   V1_impl_clockutil_<tag>.rpt  report_clock_utilization
#   V1_impl_io_<tag>.rpt         report_io
#   V1_impl_drc_<tag>.rpt        report_drc
#   V1_impl_methodology_<tag>.rpt report_methodology
#
# Run from the repo root:
#   C:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -notrace ^
#       -source v1/scripts/report_hw.tcl -tclargs <routed.dcp> <tag>
# <routed.dcp> : <project>.runs/impl_1/flash_bd_wrapper_routed.dcp of the build
# <tag>        : v1_2_hp64 or v1_2_hp64_led (matches the existing report names)

set repo [file normalize [file dirname [info script]]/../..]
set dcp  [file normalize [lindex $argv 0]]
set tag  [lindex $argv 1]
set out  $repo/docs/reports/impl
file mkdir $out

open_checkpoint $dcp
puts "FLASH_REPORT: $dcp -> $tag"

report_timing -delay_type max -max_paths 10 -nworst 1 -sort_by slack -input_pins \
    -name worst_setup -file $out/V1_impl_paths_$tag.rpt
report_timing -delay_type min -max_paths 10 -nworst 1 -sort_by slack -input_pins \
    -name worst_hold -file $out/V1_impl_paths_$tag.rpt -append
report_design_analysis -timing -max_paths 10 -file $out/V1_impl_design_$tag.rpt
report_utilization -file $out/V1_impl_utilsum_$tag.rpt
report_clocks -file $out/V1_impl_clocks_$tag.rpt
report_clock_utilization -file $out/V1_impl_clockutil_$tag.rpt
report_io -file $out/V1_impl_io_$tag.rpt
report_drc -file $out/V1_impl_drc_$tag.rpt
report_methodology -file $out/V1_impl_methodology_$tag.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts "FLASH_REPORT_TIMING: $tag WNS $wns ns WHS $whs ns"
puts "FLASH_REPORT_GPIO: [llength [get_cells -quiet -hierarchical -filter {NAME =~ *axi_gpio_led*}]] cells named axi_gpio_led"
close_design
puts "FLASH_REPORT_DONE"
