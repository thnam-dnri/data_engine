# synth.tcl — Vivado batch synthesis for data_engine
#
# Called by: make synth
# Sources: hw_spec pin XDC + constraints/timing.xdc
# Top: top_stream (Phase 1)
#
# Outputs under build/synth/:
#   synth.tcl/         — synthesis checkpoint + reports
#   top_stream.runs/   — impl runs (place, route, timing)
#   top_stream.bit     — final bitstream
#   timing_summary.rpt — post-route timing
#   utilization.rpt    — LUT/FF/BRAM utilization
#   drc.rpt            — DRC violations

# --- Project settings ---
set top_name   top_stream
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
    read_verilog [file extension $f] $f
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
puts " Bitstream: [file join $output_dir ${top_name}.bit]"
puts " Reports:   $output_dir/"
puts "============================================================"

exit
