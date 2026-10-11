# export_bd.tcl -- Project FLASH: block design picture and address map of a project.
#
# Opens the project, opens flash_bd, writes (nothing in the project is saved):
#   docs/figures/bd_layout_<tag>.pdf and .svg   (write_bd_layout)
#   docs/reports/impl/V1_bd_addrmap_<tag>.csv   (every address segment)
#
# write_bd_layout only works in GUI mode ([BD 5-349] in batch mode), so run it
# as a GUI session that exits by itself, from the repo root, with the project
# closed in any other Vivado:
#   C:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode gui -nojournal ^
#       -source v1/scripts/export_bd.tcl -tclargs <project.xpr> <tag> exit
# In batch mode the address map is still written and the layout is skipped.

set repo [file normalize [file dirname [info script]]/../..]
set xpr  [file normalize [lindex $argv 0]]
set tag  [lindex $argv 1]

open_project $xpr
open_bd_design [get_files flash_bd.bd]

# ---- address map ------------------------------------------------------------
set csv $repo/docs/reports/impl/V1_bd_addrmap_$tag.csv
set fh [open $csv w]
puts $fh "master_address_space,slave_segment,offset,range_bytes,high_address"
foreach space [lsort [get_bd_addr_spaces]] {
    foreach seg [lsort [get_bd_addr_segs -quiet -of $space]] {
        set off [get_property OFFSET $seg]
        set rng [get_property RANGE $seg]
        if {$off eq "" || $rng eq ""} { continue }
        set hi [format 0x%08X [expr {$off + $rng - 1}]]
        puts $fh "[get_property PATH $space],[get_property NAME $seg],$off,$rng,$hi"
    }
}
close $fh
puts "FLASH_ADDRMAP: $csv"

# ---- layout ------------------------------------------------------------------
foreach fmt {pdf svg} {
    set f $repo/docs/figures/bd_layout_$tag.$fmt
    file delete -force $f
    catch {write_bd_layout -force -format $fmt -orientation landscape -scope all $f}
    puts [expr {[file exists $f] ? "FLASH_LAYOUT: $f" : "FLASH_LAYOUT_FAILED: $fmt (needs -mode gui)"}]
}

close_project
puts "FLASH_EXPORT_DONE"
if {[lindex $argv 2] eq "exit"} { exit }
