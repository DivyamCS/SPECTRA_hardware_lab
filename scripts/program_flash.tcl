# program_flash.tcl - write the demo into the Nexys A7's QSPI flash, so the board starts the demo
# at power-on with no laptop (docs/fallback.md). This CHANGES what is stored on the board: run it
# only on purpose.
#
#   vivado -mode batch -nojournal -nolog -notrace -source scripts/program_flash.tcl -tclargs \
#       build/releases/fpga-v1/flash/top_fpga.mcs --yes-program-the-flash
#
# The image comes from `python scripts/updatemem.py swap DCP fw/build/demo OUT --flash` (SPI x4,
# 33 MHz, compressed; checked on the board over JTAG). Steps: connect over JTAG, attach the flash
# part s25fl128sxxxxxx0-spi-x1_x2_x4 (Spansion S25FL128S, 16 MB), erase the image's address range,
# program and verify it, then reboot the FPGA from the flash (boot_hw_device). For power-on boot
# the board's mode jumper JP1 must be on QSPI. To undo: program another image the same way; JTAG
# programming (scripts/program.tcl) always works regardless of the flash.
# Exit status 0 = programmed and verified, 1 = refused or failed.

set args $argv
if {[llength $args] != 2 || [lindex $args 1] ne "--yes-program-the-flash"} {
    puts "program_flash.tcl: refusing. Give the .mcs file and --yes-program-the-flash (this changes the board's flash)."
    exit 1
}
set mcs [file normalize [lindex $args 0]]
set prm [file rootname $mcs].prm
if {![file exists $mcs] || ![file exists $prm]} { puts "program_flash.tcl: $mcs or $prm missing"; exit 1 }

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xc7a100t_0] 0]
if {$dev eq ""} { puts "program_flash.tcl: no xc7a100t on the JTAG chain"; exit 1 }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {s25fl128sxxxxxx0-spi-x1_x2_x4}] 0]
set mem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.ADDRESS_RANGE {use_file} $mem
set_property PROGRAM.FILES [list $mcs] $mem
set_property PROGRAM.PRM_FILE $prm $mem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $mem
set_property PROGRAM.BLANK_CHECK 0 $mem
set_property PROGRAM.ERASE 1 $mem
set_property PROGRAM.CFG_PROGRAM 1 $mem
set_property PROGRAM.VERIFY 1 $mem
set_property PROGRAM.CHECKSUM 0 $mem
# the FPGA first gets Vivado's flash-loader bitstream (volatile), which writes the flash
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
if {[catch {program_hw_cfgmem -hw_cfgmem $mem} err]} { puts "program_flash.tcl: programming failed: $err"; exit 1 }
puts "FLASH programmed and verified: $mcs"
# reboot from the flash: the board now runs the demo exactly as after a power-on. This needs the
# mode jumper JP1 on QSPI; with JP1 on JTAG the FPGA stays blank until the next JTAG programming.
if {[catch {boot_hw_device $dev}]} {
    puts "FLASH the flash is programmed, but the FPGA did not boot from it: set JP1 to QSPI and switch the board off and on"
    exit 0
}
puts "FLASH the FPGA rebooted from the flash"
exit 0
