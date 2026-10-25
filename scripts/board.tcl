# board.tcl - drive the board over JTAG through the VIO hook (PROTOCOL.md section 10).
#
#   vivado -mode batch -nojournal -nolog -notrace -source scripts/board.tcl -tclargs CMD ...
#
# Commands (several may follow each other in one call; each prints one line):
#   program FILE.bit         program the FPGA (volatile), with FILE.ltx for the VIO probes
#   probes FILE.ltx          use the probes of an FPGA programmed earlier (no reprogramming)
#   sw HEX                   ovr_en = 1 and the switches = HEX (16 bits)
#   pins                     ovr_en = 0: back to the physical switches and buttons
#   reset                    pulse BTNC through the VIO (ovr_btn bit 0) for ~1 ms
#   press NAME               pulse BTNL / BTNR / BTNU / BTND through the VIO
#   read                     print LEDS, SEG7, SEG7_DP, uart_busy and SEG7_TXT (with the display text)
#   wait MS                  sleep MS milliseconds
# The VIO must already be programmed (program first, or a bitstream with the hook loaded earlier).
# Exit status 0 = every command done, 1 = no board / no VIO / bad command.

set root [file normalize [file join [file dirname [info script]] ..]]

proc die {msg} { puts "BOARD FAIL: $msg"; catch { close_hw_manager }; exit 1 }

proc connect {} {
    open_hw_manager
    connect_hw_server -allow_non_jtag
    set t [get_hw_targets]
    if {[llength $t] == 0} { die "no JTAG target" }
    open_hw_target [lindex $t 0]
    set d [lindex [get_hw_devices xc7a100t*] 0]
    if {$d eq ""} { die "no xc7a100t on the chain" }
    current_hw_device $d
    return $d
}

proc vio {} {
    set v [get_hw_vios -of_objects [current_hw_device]]
    if {[llength $v] == 0} { die "no VIO in the loaded design (program a bitstream with vio_hook)" }
    return [lindex $v 0]
}

# Probes by VIO port. Vivado names probes after the nets that survive optimisation and splits a
# port into pieces where bits are constant, so a port's value is rebuilt from its pieces: each
# has TYPE vio_input / vio_output, PROBE_PORT (the port number), PROBE_PORT_BITS (its lowest bit)
# and WIDTH. Ports: out0 ovr_en, out1 ovr_sw, out2 ovr_btn; in0 leds, in1 seg7_val, in2 seg7_dp,
# in3 uart_busy, in4 seg7_txt.
set PORT {ovr_en {vio_output 0} ovr_sw {vio_output 1} ovr_btn {vio_output 2} \
          leds {vio_input 0} seg7_val {vio_input 1} seg7_dp {vio_input 2} uart_busy {vio_input 3} seg7_txt {vio_input 4}}
proc pieces {name} {
    global PORT
    lassign [dict get $PORT $name] type port
    set out {}
    foreach p [get_hw_probes -of_objects [vio]] {
        if {[get_property TYPE $p] eq $type && [get_property PROBE_PORT $p] == $port} { lappend out $p }
    }
    if {[llength $out] == 0} { die "no VIO probe on $type port $port ($name)" }
    return $out
}
proc bin2int {b} { set v 0; foreach c [split $b ""] { set v [expr {($v << 1) | $c}] }; return $v }
proc get_in {name} {
    set v 0
    foreach p [pieces $name] {
        set_property INPUT_VALUE_RADIX BINARY $p
        set v [expr {$v | ([bin2int [get_property INPUT_VALUE $p]] << [get_property PROBE_PORT_BITS $p])}]
    }
    return $v
}
proc set_out {name hexval} {
    set v [expr {"0x$hexval"}]
    foreach p [pieces $name] {
        set w [get_property WIDTH $p]
        set slice [expr {($v >> [get_property PROBE_PORT_BITS $p]) & ((1 << $w) - 1)}]
        set b ""
        for {set k [expr {$w - 1}]} {$k >= 0} {incr k -1} { append b [expr {($slice >> $k) & 1}] }
        set_property OUTPUT_VALUE_RADIX BINARY $p
        set_property OUTPUT_VALUE $b $p
    }
}

set dev [connect]
set args $argv
while {[llength $args]} {
    set cmd [lindex $args 0]; set args [lrange $args 1 end]
    switch -- $cmd {
        program {
            set bit [lindex $args 0]; set args [lrange $args 1 end]
            if {[file pathtype $bit] ne "absolute"} { set bit [file join $root $bit] }
            set ltx [file rootname $bit].ltx
            set_property PROGRAM.FILE $bit $dev
            if {[file exists $ltx]} { set_property PROBES.FILE $ltx $dev }
            program_hw_devices $dev
            refresh_hw_device $dev
            puts "BOARD programmed [file tail $bit], DONE = [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
        }
        probes {
            set ltx [lindex $args 0]; set args [lrange $args 1 end]
            if {[file pathtype $ltx] ne "absolute"} { set ltx [file join $root $ltx] }
            set_property PROBES.FILE $ltx $dev
            refresh_hw_device $dev
            puts "BOARD probes [file tail $ltx]"
        }
        sw {
            set v [lindex $args 0]; set args [lrange $args 1 end]
            set_out ovr_sw $v; set_out ovr_btn 00; set_out ovr_en 1
            commit_hw_vio [vio]
            puts "BOARD switches = 0x$v (VIO)"
        }
        pins {
            set_out ovr_en 0; commit_hw_vio [vio]
            puts "BOARD switches and buttons from the pins"
        }
        reset - press {
            set bit 1
            if {$cmd eq "press"} {
                set name [lindex $args 0]; set args [lrange $args 1 end]
                set bit [dict get {BTNL 2 BTNR 4 BTNU 8 BTND 16} $name]
            }
            set_out ovr_en 1
            set_out ovr_btn [format %02X $bit]; commit_hw_vio [vio]
            after 2
            set_out ovr_btn 00; commit_hw_vio [vio]
            puts "BOARD [expr {$cmd eq "reset" ? "reset pulsed" : "pressed $name"}]"
        }
        read {
            refresh_hw_vio [vio]
            puts [format "BOARD leds=0x%04X seg7=%d seg7_dp=0x%02X uart_busy=%d seg7_txt=0x%08X" [get_in leds] \
                      [get_in seg7_val] [get_in seg7_dp] [get_in uart_busy] [get_in seg7_txt]]
        }
        wait {
            set ms [lindex $args 0]; set args [lrange $args 1 end]
            after $ms
        }
        default { die "unknown command $cmd" }
    }
}
close_hw_manager
exit 0
