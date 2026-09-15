# ==============================================================================
# pynq_z2_demo.xdc  -- Pin constraints for demo_top.v on PYNQ-Z2
# Device: xc7z020clg400-1
# ==============================================================================

# ------------------------------------------------------------------------------
# Clock: 125 MHz on-board oscillator -> H16  (MRCC-capable pin)
# The demo_top divides this to 62.5 MHz internally for safe timing margin.
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN H16     [get_ports clk_125]
set_property IOSTANDARD  LVCMOS33 [get_ports clk_125]
create_clock -period 8.000 -name clk_125 [get_ports clk_125]

# ------------------------------------------------------------------------------
# Push buttons (active HIGH on PYNQ-Z2)
#   BTN0 (D19) = rst      : hold to reset, release to start inference
#   BTN1 (D20) = retrig   : pulse to re-run inference
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN D19     [get_ports btn0_rst]
set_property IOSTANDARD  LVCMOS33 [get_ports btn0_rst]

set_property PACKAGE_PIN D20     [get_ports btn1_retrig]
set_property IOSTANDARD  LVCMOS33 [get_ports btn1_retrig]

# ------------------------------------------------------------------------------
# LEDs (active HIGH on PYNQ-Z2)
#   LD0 (R14) = cancer_detected  -> ON = Pneumonia, OFF = Normal
#   LD1 (P14) = result_valid     -> 1-second blink when inference completes
#   LD2 (N16) = running          -> ON during pixel streaming (fast, ~12 us)
#   LD3 (M14) = done_latch       -> stays ON after first completed inference
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN R14     [get_ports ld0_pneumonia]
set_property IOSTANDARD  LVCMOS33 [get_ports ld0_pneumonia]

set_property PACKAGE_PIN P14     [get_ports ld1_valid]
set_property IOSTANDARD  LVCMOS33 [get_ports ld1_valid]

set_property PACKAGE_PIN N16     [get_ports ld2_running]
set_property IOSTANDARD  LVCMOS33 [get_ports ld2_running]

set_property PACKAGE_PIN M14     [get_ports ld3_done]
set_property IOSTANDARD  LVCMOS33 [get_ports ld3_done]

# ------------------------------------------------------------------------------
# False paths: button inputs are asynchronous
# ------------------------------------------------------------------------------
set_false_path -from [get_ports btn0_rst]
set_false_path -from [get_ports btn1_retrig]
