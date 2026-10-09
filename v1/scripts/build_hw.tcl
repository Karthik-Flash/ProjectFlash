# build_hw.tcl -- Project FLASH V1.2: block design -> implementation -> bitstream.
#
# Run from the repo root (batch):
#   C:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -notrace ^
#       -source v1/scripts/build_hw.tcl -tclargs <project.xpr> [fclk_max_mhz] [board_name] [led]
#
# <project.xpr> : the main project is verilog/ProjectFlashV1_hw/ProjectFlashV1_hw.xpr.
#                 If the file does not exist, a project is created there with
#                 the PYNQ-Z2 part/board and the v1 sources. Close the project in
#                 the GUI first: the GUI overwrites changes made behind its back.
# fclk_max_mhz  : FCLK0 ceiling, default 75.0 (see create_bd.tcl).
# board_name    : basename of the copies in v1/board/, default flash
#                 (V1.2.1 builds use flash_hp64).
# led           : 1 adds axi_gpio_led (board LEDs), default 0.
#
# Steps: add top_v1_axi.v (sources_1) and tb_v1_axi.v (sim_1, tb_v1 stays the
# sim top); disable v1.xdc; source create_bd.tcl; synth + impl + bitstream;
# write impl reports into docs/; copy .bit/.hwh to v1/board/<board_name>.{bit,hwh};
# close the project. Check the $readmem lines in every runme.log afterwards.

set repo  [file normalize [file dirname [info script]]/../..]
set xpr   [file normalize [lindex $argv 0]]
set ::flash_fclk_max [expr {[llength $argv] > 1 ? [lindex $argv 1] : 75.0}]
set board_name [expr {[llength $argv] > 2 ? [lindex $argv 2] : "flash"}]
set ::flash_led [expr {[llength $argv] > 3 ? [lindex $argv 3] : 0}]
# Report tag: docs/V1_impl_*_v1_2.rpt for the default build, *_v1_2_hp64.rpt etc. otherwise.
set rpt_tag [expr {$board_name eq "flash" ? "v1_2" : "v1_2_[string map {flash_ {}} $board_name]"}]
set inc   $repo/v1/mem/v1_2/flash_v1_2
set rtl   $repo/v1/rtl
set rtl_files [list $rtl/conv_engine.v $rtl/fmap_ram.v $rtl/gap_unit.v $rtl/fc_unit.v \
                    $rtl/decision.v $rtl/layer_seq.v $rtl/top_v1.v $rtl/top_v1_axi.v]

if {[file exists $xpr]} {
    open_project $xpr
} else {
    puts "FLASH_PROJECT: $xpr not found -- creating it"
    create_project [file rootname [file tail $xpr]] [file dirname $xpr] -part xc7z020clg400-1
    set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]
    set_property target_language Verilog [current_project]
    add_files -fileset constrs_1 -norecurse $repo/v1/constr/v1.xdc
    add_files -fileset sim_1 -norecurse $repo/v1/sim/tb_v1.v
}

# ---- sources -----------------------------------------------------------
foreach f $rtl_files {
    if {[llength [get_files -quiet $f]] == 0} { add_files -norecurse -fileset sources_1 $f }
}
if {[llength [get_files -quiet $repo/v1/sim/tb_v1_axi.v]] == 0} {
    add_files -fileset sim_1 -norecurse $repo/v1/sim/tb_v1_axi.v
}
# v1_2 header only: v1_1's layer_table.vh defines the same macros.
set_property include_dirs [list $inc] [get_filesets sources_1]
# The module reference needs the header as a project file. Global include:
# top_v1.v uses the LT_* macros without its own `include.
if {[llength [get_files -quiet $inc/layer_table.vh]] == 0} {
    add_files -norecurse -fileset sources_1 $inc/layer_table.vh
}
set_property file_type {Verilog Header} [get_files $inc/layer_table.vh]
set_property is_global_include true [get_files $inc/layer_table.vh]
set_property include_dirs [list $inc] [get_filesets sim_1]
set_property -name {xsim.compile.xvlog.more_options} -value "-i $inc" -objects [get_filesets sim_1]
set_property top tb_v1 [get_filesets sim_1]
set_property is_enabled false [get_files $repo/v1/constr/v1.xdc]
update_compile_order -fileset sources_1

# ---- block design ------------------------------------------------------
source $repo/v1/scripts/create_bd.tcl

# ---- build -------------------------------------------------------------
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "FLASH_RUN: synth_1 [get_property STATUS [get_runs synth_1]]"
puts "FLASH_RUN: impl_1 [get_property STATUS [get_runs impl_1]]"
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "FLASH_BUILD_FAILED: impl_1 did not complete"
}

# ---- reports -----------------------------------------------------------
open_run impl_1
report_timing_summary -max_paths 10 -file $repo/docs/V1_impl_timing_$rpt_tag.rpt
report_utilization -hierarchical -file $repo/docs/V1_impl_util_$rpt_tag.rpt
report_power -file $repo/docs/V1_impl_power_$rpt_tag.rpt
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts "FLASH_TIMING: WNS $wns ns WHS $whs ns at FCLK0 $::flash_fclk_actual MHz"

# ---- board files ---------------------------------------------------------
set proj_dir [get_property DIRECTORY [current_project]]
set bit [glob $proj_dir/*.runs/impl_1/flash_bd_wrapper.bit]
set hwh [glob $proj_dir/*.gen/sources_1/bd/flash_bd/hw_handoff/flash_bd.hwh]
file mkdir $repo/v1/board
file copy -force $bit $repo/v1/board/$board_name.bit
file copy -force $hwh $repo/v1/board/$board_name.hwh
write_hw_platform -fixed -include_bit -force $proj_dir/flash_bd_wrapper.xsa
puts "FLASH_BIT: $bit ([file size $bit] bytes)"
puts "FLASH_HWH: $hwh"

close_project
puts "FLASH_BUILD_DONE"
