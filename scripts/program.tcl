# program.tcl — Program data_engine bitstream to FPGA via hw_server
#
# Called by: make program [TOP=<name>]
# Pre-req:  hw_server running (Makefile starts it if not)
# Bitstream: build/synth/<top>.bit (defaults to top_pipeline, override with TOP env)
#
# Uses the on-board FT232H USB-JTAG channel (Digilent USB104 A7).

# --- Resolve top name (env TOP > argv > default) ---
if {[info exists ::env(TOP)] && $::env(TOP) ne ""} {
    set top_name $::env(TOP)
} elseif {[llength $argv] > 0} {
    set top_name [lindex $argv 0]
} else {
    set top_name top_pipeline
}
set bit_file [file normalize [file dirname [info script]]/../build/synth/${top_name}.bit]

# --- Open hardware manager ---
open_hw
connect_hw_server

# --- Discover targets ---
open_hw_target

# --- Refresh and detect devices ---
refresh_hw_server

# --- Get the FPGA device on the chain ---
set devs [get_hw_devices]
if {[llength $devs] == 0} {
    puts "ERROR: No hardware devices found on JTAG chain"
    puts "  Check USB cable and that hw_server is running"
    exit 1
}

# Prefer the xc7a100t device
set fpga ""
foreach d $devs {
    set name [get_property NAME $d]
    puts "  Found: $name"
    if {[string match "*xc7a100t*" $name] || [string match "*100t*" $name]} {
        set fpga $d
    }
}
if {$fpga eq ""} {
    set fpga [lindex $devs 0]
}
puts "  Using: $fpga"

# --- Set bitstream property and program ---
set_property PROGRAM.FILE $bit_file $fpga
program_hw_devices $fpga

puts ""
puts "============================================================"
puts " Programmed: $bit_file"
puts " Device:     $fpga"
puts " Top:        $top_name"
puts "============================================================"
puts " The FPGA is now running ${top_name}.bit."
puts " Use host/stream_receiver.py to read ADC data over DPTI/USB."
puts "============================================================"

disconnect_hw_server
close_hw
exit
