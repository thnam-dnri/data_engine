# synth.tcl — Vivado batch synthesis for data_engine
#
# Called by: make synth
# Sources: hw_spec pin XDC + constraints/timing.xdc
# Top: defaults to top_pipeline (Phase 2.7+); override with `make synth TOP=top_stream`
#      (Makefile exports TOP as env var; synth.tcl picks it up via $::env(TOP)).
#      Also accepts positional argv: `vivado -source synth.tcl -- top_stream`.
#
# Outputs under build/synth/:
#   synth.dcp          — synthesis checkpoint
#   routed.dcp         — post-route checkpoint
#   <top>.bit          — final bitstream
#   timing_summary.rpt — post-route timing
#   utilization.rpt    — LUT/FF/BRAM utilization
#   drc.rpt            — DRC violations

# --- Project settings ---
# Top name resolution order:
#   1. $::env(TOP)  — set by `make synth TOP=<name>`
#   2. $argv        — `vivado -source synth.tcl -- <name>` (after `--`)
#   3. default      — top_pipeline
if {[info exists ::env(TOP)] && $::env(TOP) ne ""} {
    set top_name $::env(TOP)
} elseif {[llength $argv] > 0} {
    set top_name [lindex $argv 0]
} else {
    set top_name top_pipeline
}
set part       xc7a100tcsg324-1
set src_dir    [file normalize [file dirname [info script]]/../rtl]
set spec_dir   [file normalize [file dirname [info script]]/../hardware_spec]
set constr_dir [file normalize [file dirname [info script]]/../constraints]
set output_dir [file normalize [file dirname [info script]]/../build/synth]

# --- Create output directory ---
file mkdir $output_dir

# --- Create in-memory project ---
create_project -in_memory -part $part

# --- Read RTL sources ---
# Packages first (required for import resolution)
read_verilog -sv [glob -nocomplain $src_dir/pkg/*.sv]

# Other RTL: .sv and .v files
foreach f [concat \
    [glob -nocomplain $src_dir/*/*.sv] \
    [glob -nocomplain $src_dir/*/*.v]  \
    [glob -nocomplain $src_dir/top_*.sv] \
] {
    if {[file extension $f] eq ".sv"} {
        read_verilog -sv $f
    } else {
        read_verilog $f
    }
}

# --- Read constraint files ---
read_xdc [file join $spec_dir USB104_A7_Zmod_ADC1410.xdc]
read_xdc [file join $constr_dir timing.xdc]

# --- Set top module ---
set_property top $top_name [current_fileset]

# --- Launch synthesis ---
synth_design -top $top_name -part $part
write_checkpoint -force [file join $output_dir synth.dcp]

# --- Timing report after synthesis ---
report_timing_summary -file [file join $output_dir timing_post_synth.rpt]

# --- Utilization report after synthesis ---
report_utilization -file [file join $output_dir utilization_post_synth.rpt]

# --- Launch implementation (place & route) ---
opt_design
place_design
phys_opt_design
route_design
phys_opt_design -hold_fix
write_checkpoint -force [file join $output_dir routed.dcp]

# --- Reports after implementation ---
report_timing_summary -file [file join $output_dir timing_summary.rpt]
report_utilization    -file [file join $output_dir utilization.rpt]
report_drc            -file [file join $output_dir drc.rpt]

# --- Generate bitstream ---
write_bitstream -force -file [file join $output_dir ${top_name}.bit]

puts ""
puts "============================================================"
puts " Synthesis + Implementation complete."
puts " Top:       $top_name"
puts " Bitstream: [file join $output_dir ${top_name}.bit]"
puts " Reports:   $output_dir/"
puts "============================================================"

exit
