#==============================================================================
# ProjectFlash v0 -- timing constraints for top_accelerator
#
# 75 MHz. The design closes at ~83.7 MHz (measured: WNS -1.940 ns against a
# 10 ns target), so 13.333 ns leaves roughly 1.4 ns of margin. Inference takes
# 231 us; nothing about this workload needs 100 MHz.
#==============================================================================

create_clock -period 13.333 -name sys_clk [get_ports clk]

set_false_path -from [get_ports rst]

set_input_delay  -clock sys_clk 2.000 [get_ports {start pixel_valid}]
set_input_delay  -clock sys_clk 2.000 [get_ports {pixel_in[*]}]
set_output_delay -clock sys_clk 2.000 [get_ports {cancer_detected result_valid}]

# Sanity check: catches a top-module swap silently dropping every constraint,
# which is exactly what pynq_z2_demo.xdc did.
if {[llength [get_ports -quiet clk]] == 0} {
    error "XDC: port 'clk' not found -- constraints would be silently ignored"
}