# ProjectFlash v0 -- Vivado batch simulation
#   vivado -mode batch -source v0_baseline/sim/run_sim.tcl -tclargs 244
# Run from the repository root. The tclarg is N_IMAGES (default 8).

set N 8
if {[llength $argv] > 0} { set N [lindex $argv 0] }

set root [pwd]
set proj flash_v0
set pdir $root/vivado_v0

create_project -force $proj $pdir -part xc7z020clg400-1

add_files [glob $root/v0_baseline/rtl/*.v]
add_files -fileset constrs_1 $root/v0_baseline/constraints/pynq_z2.xdc
add_files -fileset sim_1 $root/v0_baseline/sim/tb_top.v

set_property top top_accelerator [get_filesets sources_1]
set_property top tb_top          [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# N_IMAGES is a parameter on tb_top, overridden at elaboration.
set_property -name {xsim.elaborate.xelab.more_options} \
             -value "-generic_top \"N_IMAGES=$N\"" -objects [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# xsim resolves bare $readmemh paths against its own run directory, so the .mem
# files have to physically live there. This is the step everyone forgets.
set simdir $pdir/$proj.sim/sim_1/behav/xsim
file mkdir $simdir
foreach f [glob $root/v0_baseline/mem/*.mem] { file copy -force $f $simdir }
puts "INFO: copied [llength [glob $root/v0_baseline/mem/*.mem]] .mem files to $simdir"

launch_simulation
puts "INFO: simulation finished"
