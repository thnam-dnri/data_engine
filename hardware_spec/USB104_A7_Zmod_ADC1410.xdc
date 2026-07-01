#=============================================================================
# USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105 Constraints
#=============================================================================
# Source: Digilent official USB104A7-ZmodADC reference design
#   https://github.com/Digilent/USB104A7-ZmodADC
#
# ADC: Analog Devices AD9648 (dual 14-bit, 105 MSPS)
# Interface mode: Interleaved CMOS — single 14-bit data bus,
#   Channel A on rising edge of DCO, Channel B on falling edge.
#   All SYZYGY signals used as single-ended LVCMOS18 (NOT differential).
#
# Usage:
#   1. Copy this file into your Vivado project
#   2. Define ports matching the names below in your top-level HDL
#   3. Uncomment sections as needed
#
# Pinout verified against:
#   - USB104A7_A.xdc (carrier board, Digilent official)
#   - ZmodADC_0_ZmodADC.xdc (ADC module, Digilent official)
#=============================================================================

#---------------------------------------------------------------------------
# ADC 14-BIT DATA BUS — single-ended CMOS (interleaved Ch A / Ch B)
#---------------------------------------------------------------------------
set_property PACKAGE_PIN H14 [get_ports {adc_data[0]}]
set_property PACKAGE_PIN K15 [get_ports {adc_data[1]}]
set_property PACKAGE_PIN E16 [get_ports {adc_data[2]}]
set_property PACKAGE_PIN C16 [get_ports {adc_data[3]}]
set_property PACKAGE_PIN C17 [get_ports {adc_data[4]}]
set_property PACKAGE_PIN J14 [get_ports {adc_data[5]}]
set_property PACKAGE_PIN G18 [get_ports {adc_data[6]}]
set_property PACKAGE_PIN J17 [get_ports {adc_data[7]}]
set_property PACKAGE_PIN H15 [get_ports {adc_data[8]}]
set_property PACKAGE_PIN E15 [get_ports {adc_data[9]}]
set_property PACKAGE_PIN F18 [get_ports {adc_data[10]}]
set_property PACKAGE_PIN J18 [get_ports {adc_data[11]}]
set_property PACKAGE_PIN J15 [get_ports {adc_data[12]}]
set_property PACKAGE_PIN G14 [get_ports {adc_data[13]}]

set_property IOSTANDARD LVCMOS18 [get_ports {adc_data[*]}]

#---------------------------------------------------------------------------
# ADC DATA CLOCK (DCO) — from AD9648 to FPGA
#---------------------------------------------------------------------------
# This is the data output clock. All ADC data is synchronous to this clock.
# Use IBUFG or simple input buffer.
set_property PACKAGE_PIN H16 [get_ports {adc_dco}]
set_property IOSTANDARD LVCMOS18 [get_ports {adc_dco}]

create_clock -period 10.000 -name adc_dco -waveform {0.000 5.000} [get_ports {adc_dco}]

# Timing constraints (from Digilent reference: DCO-to-data skew)
set_input_delay -clock [get_clocks adc_dco] -clock_fall -min -add_delay 3.240 \
  [get_ports {adc_data[*]}]
set_input_delay -clock [get_clocks adc_dco] -clock_fall -max -add_delay 5.440 \
  [get_ports {adc_data[*]}]
set_input_delay -clock [get_clocks adc_dco] -min -add_delay 3.240 \
  [get_ports {adc_data[*]}]
set_input_delay -clock [get_clocks adc_dco] -max -add_delay 5.440 \
  [get_ports {adc_data[*]}]

#---------------------------------------------------------------------------
# ADC SAMPLE CLOCK — from FPGA to AD9648 (differential, SSTL)
#---------------------------------------------------------------------------
# Use ODDR + OBUFDS in HDL to generate this clock.
set_property PACKAGE_PIN F15 [get_ports {adc_clk_p}]
set_property PACKAGE_PIN F16 [get_ports {adc_clk_n}]
set_property IOSTANDARD DIFF_SSTL18_I [get_ports {adc_clk_p}]
set_property IOSTANDARD DIFF_SSTL18_I [get_ports {adc_clk_n}]
set_property SLEW SLOW [get_ports {adc_clk_p}]
set_property SLEW SLOW [get_ports {adc_clk_n}]

#---------------------------------------------------------------------------
# ANALOG FRONT-END CONTROLS — gain and coupling
#---------------------------------------------------------------------------
# Channel 1 AC coupling control (active low)
set_property PACKAGE_PIN A13 [get_ports {ch1_ac_h}]
set_property PACKAGE_PIN A14 [get_ports {ch1_ac_l}]
set_property IOSTANDARD LVCMOS18 [get_ports {ch1_ac_*}]

# Channel 2 AC coupling control
set_property PACKAGE_PIN B16 [get_ports {ch2_ac_h}]
set_property PACKAGE_PIN B17 [get_ports {ch2_ac_l}]
set_property IOSTANDARD LVCMOS18 [get_ports {ch2_ac_*}]

# Channel 1 Gain control (high/low)
set_property PACKAGE_PIN D15 [get_ports {ch1_gain_h}]
set_property PACKAGE_PIN C15 [get_ports {ch1_gain_l}]
set_property IOSTANDARD LVCMOS18 [get_ports {ch1_gain_*}]

# Channel 2 Gain control
set_property PACKAGE_PIN B18 [get_ports {ch2_gain_h}]
set_property PACKAGE_PIN A18 [get_ports {ch2_gain_l}]
set_property IOSTANDARD LVCMOS18 [get_ports {ch2_gain_*}]

# Common coupling control
set_property PACKAGE_PIN E18 [get_ports {com_couple_h}]
set_property PACKAGE_PIN D18 [get_ports {com_couple_l}]
set_property IOSTANDARD LVCMOS18 [get_ports {com_couple_*}]

#---------------------------------------------------------------------------
# SPI CONFIGURATION INTERFACE
#---------------------------------------------------------------------------
set_property PACKAGE_PIN A15 [get_ports {adc_spi_sdio}]
set_property PACKAGE_PIN A16 [get_ports {adc_spi_sclk}]
set_property PACKAGE_PIN E17 [get_ports {adc_spi_cs}]
set_property IOSTANDARD LVCMOS18 [get_ports {adc_spi_*}]
set_property DRIVE 4 [get_ports {adc_spi_sdio}]
set_property DRIVE 4 [get_ports {adc_spi_sclk}]
set_property DRIVE 4 [get_ports {adc_spi_cs}]

# ADC SYNC — unused in Phase 1 streaming mode
# set_property PACKAGE_PIN D17 [get_ports {adc_sync}]

#---------------------------------------------------------------------------
# I²C CONFIGURATION (Bank 14, 3.3V)
#---------------------------------------------------------------------------
set_property PACKAGE_PIN U16 [get_ports {adc_scl}]
set_property PACKAGE_PIN V17 [get_ports {adc_sda}]
set_property IOSTANDARD LVCMOS33 [get_ports {adc_scl}]
set_property IOSTANDARD LVCMOS33 [get_ports {adc_sda}]
# ADC detect — unused in Phase 1 streaming mode
# set_property PACKAGE_PIN T11 [get_ports {adc_det}]
# set_property IOSTANDARD LVCMOS33 [get_ports {adc_det}]
set_property PULLUP TRUE [get_ports {adc_scl}]
set_property PULLUP TRUE [get_ports {adc_sda}]

#---------------------------------------------------------------------------
# BITSTREAM SETTINGS
#---------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]

#---------------------------------------------------------------------------
# REFERENCE
#---------------------------------------------------------------------------
# Full documentation: USB104_A7_SYZYGY_Channel_Map.md
# Official source:
#   https://github.com/Digilent/USB104A7-ZmodADC
#   https://github.com/Digilent/digilent-xdc
#---------------------------------------------------------------------------
