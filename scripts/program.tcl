# program.tcl - program the FPGA on the board over JTAG with a bitstream (volatile: lost at
# power-off), then verify that the DONE pin is high.
#
#   vivado -mode batch -nojournal -nolog -notrace -source scripts/program.tcl -tclargs <file.bit>
#
# The bitstream path may be absolute or relative to the repo root. Exit status 0 = programmed
# and DONE high, 1 = no board / no device / programming failed.

set root [file normalize [file join [file dirname [info script]] ..]]
if {[llength $argv] != 1} { puts "usage: program.tcl <file.bit>"; exit 1 }
set bit [lindex $argv 0]
if {[file pathtype $bit] ne "absolute"} { set bit [file join $root $bit] }
if {![file exists $bit]} { puts "PROGRAM FAIL: $bit not found"; exit 1 }

if {[catch {
    open_hw_manager
    connect_hw_server -allow_non_jtag
    set targets [get_hw_targets]
    if {[llength $targets] == 0} { error "no JTAG target (board off, JP1 not on JTAG, or no cable driver)" }
    open_hw_target [lindex $targets 0]
    set dev [lindex [get_hw_devices xc7a100t*] 0]
    if {$dev eq ""} { error "no xc7a100t on the JTAG chain: [get_hw_devices]" }
    current_hw_device $dev
    set_property PROGRAM.FILE $bit $dev
    program_hw_devices $dev
    refresh_hw_device $dev
    set done [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]
    puts "device $dev, DONE pin = $done"
    if {$done ne "1"} { error "DONE pin low after programming" }
} err]} {
    puts "PROGRAM FAIL: $err"
    catch { close_hw_manager }
    exit 1
}
puts "PROGRAM OK: [file tail $bit]"
close_hw_manager
exit 0
