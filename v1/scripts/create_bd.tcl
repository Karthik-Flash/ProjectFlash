# create_bd.tcl -- Project FLASH V1.2 block design "flash_bd" (PYNQ-Z2).
#
# Sourced by build_hw.tcl with a project already open whose sources_1 holds
# v1/rtl (incl. top_v1_axi.v). Can also be sourced from the Vivado Tcl console
# of such a project. Replaces any existing flash_bd.
#
#   PS7 (board preset) -- FCLK_CLK0 <= ::flash_fclk_max, S_AXI_HP0 64-bit, IRQ_F2P
#   axi_dma_0          -- no SG, MM2S only, 26-bit length, 64-bit memory side,
#                         32-bit stream
#   top_v1_axi_0       -- module reference; s_axis <- DMA M_AXIS_MM2S
#   M_AXI_GP0 -> {DMA S_AXI_LITE, top_v1_axi_0 s_axi}; DMA M_AXI_MM2S -> HP0 (AXI4->AXI3 interconnect)
#   xlconcat {irq_done, mm2s_introut} -> IRQ_F2P
#
# V1.2.1: HP0 and the DMA memory side are 64-bit. With HP0 at 32-bit the board
# returned every even 32-bit word twice (w0,w0,w2,w2,...): PYNQ leaves the HP0
# AFI in 64-bit mode and does not re-run this design's ps7_init. 64-bit matches
# the AFI's PYNQ default. See docs/V1_board_debug_log.md.
#
# Optional input:  ::flash_fclk_max  (MHz, default 70.0). FCLK0 is lowered
# until the PS's ACTUAL frequency is <= this value. 70.0 gives 66.666672 MHz
# (IO PLL 1000/15), the verified clock; 75.0 gives 71.428566 MHz, which failed
# post-route timing (WNS -0.925 ns) on 2026-10-07.
# Optional input:  ::flash_led (0/1, default 0): add axi_gpio_led for the board LEDs.
# Output:          ::flash_fclk_actual (MHz, string as Vivado reports it)

if {![info exists ::flash_fclk_max]} { set ::flash_fclk_max 70.0 }

# ---- start clean -------------------------------------------------------
if {[llength [get_files -quiet flash_bd.bd]] > 0} {
    set old_bd [get_files flash_bd.bd]
    if {[llength [get_bd_designs -quiet flash_bd]] > 0} { close_bd_design [get_bd_designs flash_bd] }
    set old_wrap [get_files -quiet flash_bd_wrapper.v]
    if {[llength $old_wrap] > 0} { remove_files $old_wrap }
    remove_files $old_bd
    file delete -force [file dirname $old_bd]
}

create_bd_design flash_bd

# ---- Zynq PS -----------------------------------------------------------
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps

set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {75} \
] $ps

# Lower the FCLK0 request in 0.5 MHz steps until the actual is <= max.
set req 75.0
while {1} {
    set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $req $ps
    set act [get_property CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ $ps]
    puts "FLASH_FCLK: requested $req MHz -> actual $act MHz"
    if {$act <= $::flash_fclk_max + 1e-6} { break }
    set req [expr {$req - 0.5}]
    if {$req < 10.0} { error "FLASH_FCLK: no FCLK0 <= $::flash_fclk_max MHz found" }
}
# Request exactly the achievable value so PYNQ (which re-derives the divisors
# from the requested frequency in the .hwh) programs the same clock.
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $act $ps
set ::flash_fclk_actual [get_property CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ $ps]
puts "FLASH_FCLK_FINAL: requested $act MHz -> actual $::flash_fclk_actual MHz"

# ---- DMA ---------------------------------------------------------------
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
] $dma

# ---- Accelerator (module reference) ------------------------------------
set acc [create_bd_cell -type module -reference top_v1_axi top_v1_axi_0]
foreach p {WEIGHTS_FILE BIAS_FILE LAYER_TABLE_FILE N_PIXELS DEFAULT_THRESHOLD} {
    puts "FLASH_PARAM: $p = [get_property CONFIG.$p $acc]"
}

# ---- Connections -------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_pins top_v1_axi_0/s_axis]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { \
    Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/processing_system7_0/M_AXI_GP0} Slave {/axi_dma_0/S_AXI_LITE} \
    ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { \
    Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/processing_system7_0/M_AXI_GP0} Slave {/top_v1_axi_0/s_axi} \
    ddr_seg {Auto} intc_ip {Auto} master_apm {0}} \
    [get_bd_intf_pins top_v1_axi_0/s_axi]
# DMA (AXI4) -> HP0 (AXI3). A direct connect_bd_intf_net is refused
# ([BD 41-1285] protocols incompatible), so automation inserts an interconnect
# whose only job is the AXI4->AXI3 protocol conversion (both sides 64-bit).
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { \
    Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/axi_dma_0/M_AXI_MM2S} Slave {/processing_system7_0/S_AXI_HP0} \
    ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
    [get_bd_intf_pins processing_system7_0/S_AXI_HP0]

# Anything automation left unclocked/unreset goes to FCLK0 / its reset block.
set fclk [get_bd_pins processing_system7_0/FCLK_CLK0]
set rstn [get_bd_pins -of [get_bd_cells -filter {VLNV =~ "*proc_sys_reset*"}] -filter {NAME == peripheral_aresetn}]
foreach pin [list top_v1_axi_0/aclk axi_dma_0/m_axi_mm2s_aclk axi_dma_0/s_axi_lite_aclk processing_system7_0/S_AXI_HP0_ACLK] {
    set p [get_bd_pins $pin]
    if {[llength [get_bd_nets -quiet -of $p]] == 0} { connect_bd_net $fclk $p }
}
foreach pin [list top_v1_axi_0/aresetn axi_dma_0/axi_resetn] {
    set p [get_bd_pins $pin]
    if {[llength [get_bd_nets -quiet -of $p]] == 0} { connect_bd_net $rstn $p }
}

# ---- Interrupts --------------------------------------------------------
set cc [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0]
set_property CONFIG.NUM_PORTS {2} $cc
connect_bd_net [get_bd_pins top_v1_axi_0/irq_done]    [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut]   [get_bd_pins xlconcat_0/In1]
connect_bd_net [get_bd_pins xlconcat_0/dout]          [get_bd_pins processing_system7_0/IRQ_F2P]

# ---- Optional board LEDs (::flash_led = 1; flash_hp64_led build) ----------
# axi_gpio_led on the GP0 AXI-Lite interconnect, both channels outputs only,
# pins from the PYNQ-Z2 board files via board automation (none typed here):
#   GPIO  (ch1, 0x00) = leds_4bits  LD0..LD3, bit n = LDn
#   GPIO2 (ch2, 0x08) = rgb_led     6 bits "RGBRGB": bit0/1/2 = LD4 B/G/R,
#                                   bit3/4/5 = LD5 B/G/R
if {[info exists ::flash_led] && $::flash_led} {
    set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_led]
    set_property -dict [list CONFIG.C_IS_DUAL {1}         CONFIG.GPIO_BOARD_INTERFACE {leds_4bits} CONFIG.GPIO2_BOARD_INTERFACE {rgb_led}] $gpio
    apply_bd_automation -rule xilinx.com:bd_rule:board -config {Board_Interface {leds_4bits} Manual_Source {Auto}}         [get_bd_intf_pins axi_gpio_led/GPIO]
    apply_bd_automation -rule xilinx.com:bd_rule:board -config {Board_Interface {rgb_led} Manual_Source {Auto}}         [get_bd_intf_pins axi_gpio_led/GPIO2]
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {         Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto}         Master {/processing_system7_0/M_AXI_GP0} Slave {/axi_gpio_led/S_AXI}         ddr_seg {Auto} intc_ip {/ps7_0_axi_periph} master_apm {0}}         [get_bd_intf_pins axi_gpio_led/S_AXI]
    # The board interface owns C_ALL_OUTPUTS (stays 0: ports are tri_io), so
    # software must write GPIO_TRI = 0 (0x04 ch1, 0x0C ch2) before GPIO_DATA.
    foreach p {C_IS_DUAL C_ALL_OUTPUTS C_GPIO_WIDTH C_ALL_OUTPUTS_2 C_GPIO2_WIDTH GPIO_BOARD_INTERFACE GPIO2_BOARD_INTERFACE} {
        puts "FLASH_LED: $p = [get_property CONFIG.$p $gpio]"
    }
}

# ---- Addresses, validate, save -----------------------------------------
assign_bd_address
validate_bd_design
foreach seg [get_bd_addr_segs -of [get_bd_addr_spaces processing_system7_0/Data]] {
    puts "FLASH_ADDR: [get_property NAME $seg] offset [get_property OFFSET $seg] range [get_property RANGE $seg]"
}
foreach seg [get_bd_addr_segs -of [get_bd_addr_spaces axi_dma_0/Data_MM2S]] {
    puts "FLASH_ADDR_DMA: [get_property NAME $seg] offset [get_property OFFSET $seg] range [get_property RANGE $seg]"
}
save_bd_design

set wrapper [make_wrapper -files [get_files flash_bd.bd] -top]
add_files -norecurse $wrapper
set_property top flash_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "FLASH_BD_DONE"
