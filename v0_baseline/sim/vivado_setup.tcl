#==============================================================================
# ProjectFlash v0 -- set up an EXISTING Vivado project
#
# Use this when you have already created ProjectFlashV0 (pynq-z2) yourself.
# In the Vivado Tcl Console, with the project open:
#
#     cd C:/KarDRIVE/Projects/ProjectFlash
#     source v0_baseline/sim/vivado_setup.tcl
#
# Then, every time you regenerate the .mem files from Colab:
#
#     flash_copy_mem
#
# Then Flow Navigator -> Run Simulation -> Run Behavioral Simulation.
#==============================================================================

set REPO_ROOT "C:/KarDRIVE/Projects/ProjectFlash"

if {![file isdirectory $REPO_ROOT/v0_baseline/rtl]} {
    error "REPO_ROOT is wrong. Edit the top of this script. Looked in: $REPO_ROOT"
}

# ---- design sources -------------------------------------------------------
set rtl [glob $REPO_ROOT/v0_baseline/rtl/*.v]
add_files -norecurse -force $rtl
set_property top top_accelerator [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "INFO: added [llength $rtl] RTL files"

# ---- constraints ----------------------------------------------------------
if {[llength [get_files -quiet */pynq_z2.xdc]] == 0} {
    add_files -fileset constrs_1 -norecurse -force \
        $REPO_ROOT/v0_baseline/constraints/pynq_z2.xdc
}

# ---- testbench ------------------------------------------------------------
add_files -fileset sim_1 -norecurse -force $REPO_ROOT/v0_baseline/sim/tb_top.v
set_property top tb_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sim_1

# Let the simulation run to $finish instead of stopping at 1000ns.
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# ---- .mem files -----------------------------------------------------------
# xsim resolves bare $readmemh paths against its own run directory, so the .mem
# files have to physically sit there. Vivado does not do this for you.
proc flash_copy_mem {} {
    global REPO_ROOT
    set pdir   [get_property directory [current_project]]
    set pname  [get_property name      [current_project]]
    set simdir [file join $pdir "$pname.sim" sim_1 behav xsim]
    file mkdir $simdir
    set n 0
    foreach f [glob -nocomplain $REPO_ROOT/v0_baseline/mem/*.mem] {
        file copy -force $f $simdir
        incr n
    }
    puts "INFO: copied $n .mem files -> $simdir"
    if {$n == 0} { puts "WARNING: v0_baseline/mem/ is empty. Unzip flash_v0_mem.zip into it." }
    return $simdir
}

# Set the number of images the testbench sweeps. Must match manifest.json.
proc flash_set_n {n} {
    set_property -name {xsim.elaborate.xelab.more_options} \
                 -value "-generic_top \"N_IMAGES=$n\"" -objects [get_filesets sim_1]
    puts "INFO: N_IMAGES = $n"
}

flash_copy_mem
flash_set_n 8
puts ""
puts "READY. Run Simulation -> Run Behavioral Simulation."
puts "After the Colab run: unzip into v0_baseline/mem/, then  flash_copy_mem ; flash_set_n 244"
