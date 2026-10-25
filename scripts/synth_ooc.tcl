# synth_ooc.tcl - synthesise and place-and-route ONE module out of context (no pins, no
# bitstream), to check its resources and timing alone.
#
#   vivado -mode batch -nojournal -nolog -notrace -source scripts/synth_ooc.tcl -tclargs \
#       -f <file list> -top <module> [-period 20.0] [-out <dir>] [-part xc7a100tcsg324-1]
#
# The clock port must be called `clk`; it is constrained to -period ns (default 20 = 50 MHz).
# Inputs and outputs get 30 % of the period as external delay, so paths through the ports are
# timed too. Output directory (default build/<commit>/ooc/<top>): utilization.rpt,
# timing_summary.rpt, summary.txt (WNS, WHS, LUT, FF, BRAM, DSP, latches). Exit status 0 if
# WNS >= 0, WHS >= 0 and no latch; 3 otherwise; 1 on error.

set root [file normalize [file join [file dirname [info script]] ..]]
source [file join $root scripts filelist.tcl]

array set opt {-f "" -top "" -period 20.0 -out "" -part xc7a100tcsg324-1}
foreach {k v} $argv {
    if {![info exists opt($k)]} { puts "synth_ooc.tcl: unknown option $k"; exit 2 }
    set opt($k) $v
}
if {$opt(-f) eq "" || $opt(-top) eq ""} { puts "synth_ooc.tcl: -f and -top are required"; exit 2 }
set top $opt(-top)
lassign [read_filelist $root $opt(-f)] files incs defs
set out $opt(-out)
if {$out eq ""} { set out [file join [commit_dir $root] ooc $top] }
file mkdir $out
cd $out

foreach f $files {
    if {[string match *.sv $f]} { read_verilog -sv $f } else { read_verilog $f }
}
synth_design -top $top -part $opt(-part) -mode out_of_context -include_dirs $incs -verilog_define $defs
set p $opt(-period)
create_clock -name clk -period $p [get_ports clk]
set io [expr {0.3 * $p}]
set ins [get_ports -filter {DIRECTION == IN && NAME != clk}]
set outs [get_ports -filter {DIRECTION == OUT}]
if {[llength $ins]}  { set_input_delay  -clock clk $io $ins }
if {[llength $outs]} { set_output_delay -clock clk $io $outs }
opt_design
place_design
route_design
report_utilization -file utilization.rpt
report_timing_summary -max_paths 5 -report_unconstrained -file timing_summary.rpt

proc slack {type} {
    set p [get_timing_paths -delay_type $type -max_paths 1 -nworst 1]
    if {[llength $p] == 0} { return "none" }
    return [get_property SLACK $p]
}
set wns [slack max]
set whs [slack min]
set u [report_utilization -return_string]
proc used {u label} {
    if {[regexp -line "^\\|\\s*$label\\s*\\|\\s*(\[0-9.\]+)" $u m n]} { return $n }
    return "?"
}
set latches [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ REGISTER.LATCH.*}]]
set met [expr {($wns eq "none" || $wns >= 0) && ($whs eq "none" || $whs >= 0) && $latches == 0}]
set f [open summary.txt w]
foreach {k v} [list top $top period_ns $p WNS $wns WHS $whs LUT [used $u {Slice LUTs\*?}] \
               FF [used $u {Slice Registers}] BRAM [used $u {Block RAM Tile}] DSP [used $u {DSPs}] \
               latches $latches result [expr {$met ? "met" : "FAILED"}]] {
    puts $f "$k=$v"
    puts "OOC $k=$v"
}
close $f
exit [expr {$met ? 0 : 3}]
