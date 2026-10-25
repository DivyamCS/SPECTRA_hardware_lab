# build.tcl - synthesis, implementation, bitstream and reports in Vivado non-project mode.
#
#   vivado -mode batch -nojournal -nolog -notrace -source scripts/build.tcl -tclargs \
#       -f <file list> -top <top module> -xdc <constraints> [-hex <dir>] [-out <dir>] \
#       [-part xc7a100tcsg324-1]
#
#   -f     file list (format in scripts/filelist.tcl)
#   -xdc   constraints file, relative to the repo root
#   -hex   directory whose *.hex / *.mem files are copied into the output directory, where
#          $readmemh finds them during synthesis
#   -out   output directory (default build/<commit>/impl/<top>)
#   -part  default xc7a100tcsg324-1 (Nexys A7-100T)
#   -generic  top-level parameters, e.g. "HAS_DCACHE:0" (area variants)
#
# Output directory: post_synth.dcp, post_route.dcp, <top>.bit, timing_summary.rpt,
# utilization.rpt, utilization_hier.rpt, drc.rpt, methodology.rpt, cdc.rpt and summary.txt
# (WNS, WHS, LUT, FF, BRAM, DSP). Exit status: 0 timing met, 3 timing failed
# (WNS < 0 or WHS < 0; the bitstream is still written), 1 error.

set root [file normalize [file join [file dirname [info script]] ..]]
source [file join $root scripts filelist.tcl]

array set opt {-f "" -top "" -xdc "" -hex "" -out "" -part xc7a100tcsg324-1 -generic ""}
foreach {k v} $argv {
    if {![info exists opt($k)]} { puts "build.tcl: unknown option $k"; exit 2 }
    set opt($k) $v
}
foreach k {-f -top -xdc} {
    if {$opt($k) eq ""} { puts "build.tcl: $k is required"; exit 2 }
}
set top $opt(-top)
lassign [read_filelist $root $opt(-f)] files incs defs libs tcls

set out $opt(-out)
if {$out ne ""} { set out [file normalize [file join $root $out]] }
if {$out eq ""} { set out [file join [commit_dir $root] impl $top] }
file mkdir $out
cd $out
if {$opt(-hex) ne ""} {
    foreach h [glob -nocomplain -directory [file join $root $opt(-hex)] *.hex *.mem] {
        file copy -force $h .
    }
}

# IP generation scripts (file list -t), run in the output directory
foreach t $tcls { source $t }

foreach f $files {
    if {[string match *.sv $f]} { read_verilog -sv $f } else { read_verilog $f }
}
read_xdc [file join $root $opt(-xdc)]

set t0 [clock seconds]
# -generic "NAME:VALUE NAME:VALUE": top-level parameters (area variants)
set gen {}
# NAME:VALUE on the command line (vivado.bat, a batch file, splits arguments at "=")
foreach g $opt(-generic) { lappend gen -generic [string map {: =} $g] }
synth_design -top $top -part $opt(-part) -include_dirs $incs -verilog_define $defs {*}$gen
write_checkpoint -force post_synth.dcp
report_utilization -file util_synth.rpt
opt_design
# The JTAG debug hub (inserted by opt_design for the VIO) starts paths at its BSCANE2 primitive's
# data outputs (RESET, SEL, SHIFT, ...), which have no clock: declare paths through them false here (the cell does not exist when the XDC is
# read). Builds without debug cores are not touched.
set bscan [get_cells -quiet -hier -filter {REF_NAME == BSCANE2}]
if {[llength $bscan]} {
    set bpins [get_pins -of_objects $bscan -filter {DIRECTION == OUT && REF_PIN_NAME != TCK}]
    if {[llength $bpins]} { set_false_path -through $bpins }
}
place_design
phys_opt_design
route_design
write_checkpoint -force post_route.dcp

report_timing_summary -max_paths 10 -report_unconstrained -file timing_summary.rpt
report_utilization -file utilization.rpt
report_utilization -hierarchical -file utilization_hier.rpt
report_drc -file drc.rpt
report_methodology -file methodology.rpt
report_cdc -details -file cdc.rpt
write_bitstream -force $top.bit
# probes file for the VIO / ILA (scripts/board.tcl finds probes by name); none without debug cores
catch { write_debug_probes -force $top.ltx }

# ---- summary ----
proc slack {type} {
    set p [get_timing_paths -delay_type $type -max_paths 1 -nworst 1]
    if {[llength $p] == 0} { return "none" }
    set s [get_property SLACK $p]
    if {$s eq ""} { return "none" }
    return $s
}
set wns [slack max]
set whs [slack min]
set u [report_utilization -return_string]
proc used {u label} {
    if {[regexp -line "^\\|\\s*$label\\s*\\|\\s*(\[0-9.\]+)" $u m n]} { return $n }
    return "?"
}
set lut  [used $u {Slice LUTs\*?}]
set ff   [used $u {Slice Registers}]
set bram [used $u {Block RAM Tile}]
set dsp  [used $u {DSPs}]
set met [expr {($wns eq "none" || $wns >= 0) && ($whs eq "none" || $whs >= 0)}]
set f [open summary.txt w]
foreach {k v} [list top $top part $opt(-part) WNS $wns WHS $whs LUT $lut FF $ff BRAM $bram DSP $dsp \
               timing [expr {$met ? "met" : "FAILED"}] minutes [expr {([clock seconds] - $t0) / 60.0}]] {
    puts $f "$k=$v"
    puts "BUILD $k=$v"
}
close $f
puts "BUILD done: [file normalize $out]"
exit [expr {$met ? 0 : 3}]
