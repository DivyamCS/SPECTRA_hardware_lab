################ CLOCK ################
set_property PACKAGE_PIN E3 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 [get_ports clk]

################ RESET (BTNC Center Pushbutton, active-high) ################
set_property PACKAGE_PIN N17 [get_ports reset]
set_property IOSTANDARD LVCMOS33 [get_ports reset]

################ LEDS LD0-LD15 ################
set_property PACKAGE_PIN H17 [get_ports {led[0]}]
set_property PACKAGE_PIN K15 [get_ports {led[1]}]
set_property PACKAGE_PIN J13 [get_ports {led[2]}]
set_property PACKAGE_PIN N14 [get_ports {led[3]}]
set_property PACKAGE_PIN R18 [get_ports {led[4]}]
set_property PACKAGE_PIN V17 [get_ports {led[5]}]
set_property PACKAGE_PIN U17 [get_ports {led[6]}]
set_property PACKAGE_PIN U16 [get_ports {led[7]}]
set_property PACKAGE_PIN V16 [get_ports {led[8]}]
set_property PACKAGE_PIN T15 [get_ports {led[9]}]
set_property PACKAGE_PIN U14 [get_ports {led[10]}]
set_property PACKAGE_PIN T16 [get_ports {led[11]}]
set_property PACKAGE_PIN V15 [get_ports {led[12]}]
set_property PACKAGE_PIN V14 [get_ports {led[13]}]
set_property PACKAGE_PIN V12 [get_ports {led[14]}]
set_property PACKAGE_PIN V11 [get_ports {led[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

################ UART (USB-UART bridge on Nexys A7) ################
# uart_tx → D4  (FPGA TXD pin on USB-UART, connects to host RX)
set_property PACKAGE_PIN D4  [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

################ 7-SEGMENT DISPLAY ################
# Segments (active-low, common-anode)
set_property PACKAGE_PIN T10 [get_ports {seg[0]}]  ;# CA
set_property PACKAGE_PIN R10 [get_ports {seg[1]}]  ;# CB
set_property PACKAGE_PIN K16 [get_ports {seg[2]}]  ;# CC
set_property PACKAGE_PIN K13 [get_ports {seg[3]}]  ;# CD
set_property PACKAGE_PIN P15 [get_ports {seg[4]}]  ;# CE
set_property PACKAGE_PIN T11 [get_ports {seg[5]}]  ;# CF
set_property PACKAGE_PIN L18 [get_ports {seg[6]}]  ;# CG
set_property IOSTANDARD LVCMOS33 [get_ports {seg[*]}]

# Decimal point (active-low)
set_property PACKAGE_PIN H15 [get_ports dp]
set_property IOSTANDARD LVCMOS33 [get_ports dp]

# Anodes AN0-AN5 (active-low, 6 digits on Nexys A7)
set_property PACKAGE_PIN J17 [get_ports {an[0]}]
set_property PACKAGE_PIN J18 [get_ports {an[1]}]
set_property PACKAGE_PIN T9  [get_ports {an[2]}]
set_property PACKAGE_PIN J14 [get_ports {an[3]}]
set_property PACKAGE_PIN P14 [get_ports {an[4]}]
set_property PACKAGE_PIN T14 [get_ports {an[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {an[*]}]

################ SLIDE SWITCHES SW0-SW3 ################
set_property PACKAGE_PIN J15 [get_ports {sw[0]}]
set_property PACKAGE_PIN L16 [get_ports {sw[1]}]
set_property PACKAGE_PIN M13 [get_ports {sw[2]}]
set_property PACKAGE_PIN R15 [get_ports {sw[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw[*]}]
