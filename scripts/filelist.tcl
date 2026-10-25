# filelist.tcl - read a SPECTRA file list (sourced by sim.tcl and build.tcl).
#
# File list format (sim/*.f), one entry per line, paths relative to the repo root:
#     # comment
#     -i rtl/core          include directory
#     -d SIM               Verilog define (NAME or NAME=VALUE)
#     -l unisims_ver       simulation library for Xilinx primitives (xsim: -L, plus glbl)
#     -t scripts/x.tcl     Tcl script build.tcl sources before reading the RTL (IP generation)
#     rtl/core/pipe.v      source file (.v = Verilog 2001, .sv = SystemVerilog)

proc read_filelist {root path} {
    set files {}
    set incs {}
    set defs {}
    set libs {}
    set tcls {}
    set f [open [file join $root $path] r]
    foreach line [split [read $f] "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        if {[string match "-i *" $line]} {
            lappend incs [file normalize [file join $root [string trim [string range $line 3 end]]]]
        } elseif {[string match "-d *" $line]} {
            lappend defs [string trim [string range $line 3 end]]
        } elseif {[string match "-l *" $line]} {
            lappend libs [string trim [string range $line 3 end]]
        } elseif {[string match "-t *" $line]} {
            lappend tcls [file normalize [file join $root [string trim [string range $line 3 end]]]]
        } else {
            set p [file normalize [file join $root $line]]
            if {![file exists $p]} { close $f; error "file list $path: $line not found" }
            lappend files $p
        }
    }
    close $f
    return [list $files $incs $defs $libs $tcls]
}

# build/<short commit>[-dirty]: run directories are never reused across commits.
proc commit_dir {root} {
    if {[catch {exec git -C $root rev-parse --short HEAD} c]} { set c nogit }
    if {![catch {exec git -C $root status --porcelain --untracked-files=no} s] && $s ne ""} {
        append c -dirty
    }
    return [file join $root build $c]
}
