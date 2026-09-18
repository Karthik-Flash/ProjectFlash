# Project FLASH V1 -- PYNQ-Z2 constraints
# Zynq-7000: xc7z020clg400-1, 125 MHz sysclk on H16, target 75 MHz internal (13.333 ns)

# ---- system clock (bank 13, LVCMOS33) ----
set_property PACKAGE_PIN H16 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 13.333 -name sys_clk [get_ports clk]

# ---- reset ----
set_property PACKAGE_PIN D19 [get_ports rst]
set_property IOSTANDARD LVCMOS33 [get_ports rst]

# ---- guard: fail loudly if a rename silently orphans the constraints (handoff 3.1) ----
if {[llength [get_ports -quiet clk]] == 0} {
    error "XDC: port 'clk' not found -- constraints would be silently ignored"
}