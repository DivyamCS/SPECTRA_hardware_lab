# sim.tcl - compile, elaborate and run one testbench in xsim (batch), then report PASS or FAIL.
#
#   vivado -mode batch -nojournal -nolog -notrace -source scripts/sim.tcl -tclargs \
#       -f <file list> -top <testbench> [-hex <dir>] [-run <dir>] [-expect pass|finish] \
#
#   -f        file list (format in scripts/filelist.tcl), paths relative to the repo root
#   -top      testbench module
#   -hex      directory whose *.hex / *.mem files are copied into the run directory, where
#             $readmemh("imem.hex") etc. find them
#   -run      run directory (default build/<commit>/sim/<top>)
#   -expect   pass (default): the testbench prints exactly one "PASS <name>" line and no
#             "FAIL" line; finish: the run only has to reach $finish without errors (for
#             testbenches without a checker, such as the lab's tb_pipeline)
#
# No plusargs: xsim.bat (a Windows batch file) splits every argument at "=", so a testbench
# writes its output files into the run directory under fixed names instead.
#
# Logs: xvlog.log, xelab.log and xsim.log in the run directory. The last line printed is
# "SIM PASS <top>" or "SIM FAIL <top>: <reason>"; exit status 0 or 1.

set root [file normalize [file join [file dirname [info script]] ..]]
source [file join $root scripts filelist.tcl]

array set opt {-f "" -top "" -hex "" -run "" -expect pass}
foreach {k v} $argv {
    if {[info exists opt($k)]} {
        set opt($k) $v
    } else {
        puts "sim.tcl: unknown option $k"
        exit 2
    }
}
if {$opt(-f) eq "" || $opt(-top) eq ""} {
    puts "sim.tcl: -f <file list> and -top <testbench> are required"
    exit 2
}
set top $opt(-top)

proc fail {why} {
    global top
    puts "SIM FAIL $top: $why"
    exit 1
}

# Run one tool, keep its full output in <tool>.log, return the output.
proc tool {name args} {
    set cmd [concat [auto_execok $name] $args]
    set rc [catch {exec {*}$cmd 2>@1} out]
    set f [open $name.log w]
    puts $f $out
    close $f
    if {$rc} { fail "$name failed (see [file normalize $name.log])" }
    return $out
}

if {[catch {read_filelist $root $opt(-f)} fl]} { fail $fl }
lassign $fl files incs defs libs

set run $opt(-run)
if {$run eq ""} { set run [file join [commit_dir $root] sim $top] }
file mkdir $run
cd $run
if {$opt(-hex) ne ""} {
    foreach h [glob -nocomplain -directory [file join $root $opt(-hex)] *.hex *.mem] {
        file copy -force $h .
    }
}

set common {}
foreach i $incs { lappend common -i $i }
foreach d $defs { lappend common -d $d }
set v  [lsearch -all -inline -glob $files *.v]
set sv [lsearch -all -inline -glob $files *.sv]
if {[llength $v]}  { tool xvlog {*}$common {*}$v }
if {[llength $sv]} { file rename -force xvlog.log xvlog_v.log; tool xvlog -sv {*}$common {*}$sv }
# Xilinx primitives (file list -l): compile glbl and link the named libraries
set tops [list $top]
set lflags {}
if {[llength $libs]} {
    tool xvlog [file join $::env(XILINX_VIVADO) data verilog src glbl.v]
    lappend tops glbl
    foreach l $libs { lappend lflags -L $l }
}
tool xelab {*}$tops {*}$lflags -s ${top}_snap -timescale 1ns/1ps -debug off
set out [tool xsim ${top}_snap -R]

if {[regexp -line {^(ERROR|FATAL).*$} $out m]} { fail $m }
set passes [regexp -all -line -inline {^PASS \S+} $out]
set fails  [regexp -all -line -inline {^FAIL.*$} $out]
if {[llength $fails]} { fail [lindex $fails 0] }
if {$opt(-expect) eq "finish"} {
    if {![regexp {\$finish called} $out]} { fail "\$finish not reached" }
} elseif {[llength $passes] != 1} {
    fail "expected exactly one PASS line, got [llength $passes]"
}
puts "SIM PASS $top  (run directory [file normalize $run])"
exit 0
