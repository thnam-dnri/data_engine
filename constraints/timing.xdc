#=============================================================================
# timing.xdc — data_engine Phase 1 Streaming Top
# Board:  Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105
# Source: Derived from Digilent official USB104A7-ZmodADC + sig_recorder
#
# Usage: read_xdc this file (not the official XDC directly) because port
# names differ from the official Digilent XDC.
#=============================================================================

#---------------------------------------------------------------------------
# 100 MHz SYSTEM CLOCK
#---------------------------------------------------------------------------
set_property PACKAGE_PIN E3 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports clk]

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
set_property PACKAGE_PIN H16 [get_ports adc_dco]
set_property IOSTANDARD LVCMOS18 [get_ports adc_dco]

#---------------------------------------------------------------------------
# ADC SAMPLE CLOCK — from FPGA to AD9648 (differential, SSTL)
# Driven by OBUFDS in top_stream.sv
#---------------------------------------------------------------------------
set_property PACKAGE_PIN F15 [get_ports adc_clk_p]
set_property PACKAGE_PIN F16 [get_ports adc_clk_n]
set_property IOSTANDARD DIFF_SSTL18_I [get_ports adc_clk_p]
set_property IOSTANDARD DIFF_SSTL18_I [get_ports adc_clk_n]
set_property SLEW SLOW [get_ports adc_clk_p]
set_property SLEW SLOW [get_ports adc_clk_n]

#---------------------------------------------------------------------------
# ANALOG FRONT-END CONTROLS — gain and coupling (LVCMOS18)
#---------------------------------------------------------------------------
set_property PACKAGE_PIN A13 [get_ports ch1_ac_h]
set_property PACKAGE_PIN A14 [get_ports ch1_ac_l]
set_property PACKAGE_PIN B16 [get_ports ch2_ac_h]
set_property PACKAGE_PIN B17 [get_ports ch2_ac_l]
set_property PACKAGE_PIN D15 [get_ports ch1_gain_h]
set_property PACKAGE_PIN C15 [get_ports ch1_gain_l]
set_property PACKAGE_PIN B18 [get_ports ch2_gain_h]
set_property PACKAGE_PIN A18 [get_ports ch2_gain_l]
set_property PACKAGE_PIN E18 [get_ports com_couple_h]
set_property PACKAGE_PIN D18 [get_ports com_couple_l]
set_property IOSTANDARD LVCMOS18 [get_ports {ch*_*}]
set_property IOSTANDARD LVCMOS18 [get_ports com_couple_h]
set_property IOSTANDARD LVCMOS18 [get_ports com_couple_l]

#---------------------------------------------------------------------------
# SPI INTERFACE (LVCMOS18) — ADC internal register configuration
#---------------------------------------------------------------------------
set_property PACKAGE_PIN A15 [get_ports adc_spi_sdio]
set_property PACKAGE_PIN A16 [get_ports adc_spi_sclk]
set_property PACKAGE_PIN E17 [get_ports adc_spi_cs]
set_property IOSTANDARD LVCMOS18 [get_ports {adc_spi_*}]

#---------------------------------------------------------------------------
# I2C — 3.3V with pull-up (CDCE6214 clock generator)
#---------------------------------------------------------------------------
set_property PACKAGE_PIN U16 [get_ports adc_scl]
set_property PACKAGE_PIN V17 [get_ports adc_sda]
set_property IOSTANDARD LVCMOS33 [get_ports adc_scl]
set_property IOSTANDARD LVCMOS33 [get_ports adc_sda]
set_property PULLUP TRUE [get_ports adc_scl]
set_property PULLUP TRUE [get_ports adc_sda]

#---------------------------------------------------------------------------
# LEDs (Bank 14, 3.3V)
#---------------------------------------------------------------------------
set_property PACKAGE_PIN R17 [get_ports {led[0]}]
set_property PACKAGE_PIN P15 [get_ports {led[1]}]
set_property PACKAGE_PIN R15 [get_ports {led[2]}]
set_property PACKAGE_PIN T14 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

#---------------------------------------------------------------------------
# DPTI (FT232H synchronous FIFO, Bank 14, 3.3V)
#---------------------------------------------------------------------------
set_property PACKAGE_PIN P17 [get_ports dpti_clk]
set_property IOSTANDARD LVCMOS33 [get_ports dpti_clk]
create_clock -period 16.666 -name dpti_clk -waveform {0.000 8.333} [get_ports dpti_clk]

set_property PACKAGE_PIN M18 [get_ports {dpti_data[0]}]
set_property PACKAGE_PIN R12 [get_ports {dpti_data[1]}]
set_property PACKAGE_PIN R13 [get_ports {dpti_data[2]}]
set_property PACKAGE_PIN M13 [get_ports {dpti_data[3]}]
set_property PACKAGE_PIN R18 [get_ports {dpti_data[4]}]
set_property PACKAGE_PIN T18 [get_ports {dpti_data[5]}]
set_property PACKAGE_PIN N14 [get_ports {dpti_data[6]}]
set_property PACKAGE_PIN P14 [get_ports {dpti_data[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {dpti_data[*]}]

set_property PACKAGE_PIN N17 [get_ports dpti_oen]
set_property PACKAGE_PIN N15 [get_ports dpti_rdn]
set_property PACKAGE_PIN M16 [get_ports dpti_rxen]
set_property PACKAGE_PIN P18 [get_ports dpti_siwun]
set_property PACKAGE_PIN L18 [get_ports dpti_spien]
set_property PACKAGE_PIN M17 [get_ports dpti_txen]
set_property PACKAGE_PIN N16 [get_ports dpti_wrn]
set_property IOSTANDARD LVCMOS33 [get_ports {dpti_*}]

#---------------------------------------------------------------------------
# ADC DATA CLOCK (DCO) — define as clock for timing closure
#---------------------------------------------------------------------------
create_clock -period 9.524 -name adc_dco_clk -waveform {0.000 4.762} [get_ports adc_dco]

#---------------------------------------------------------------------------
# ADC DATA INPUT DELAY (IDDR-mode timing, both DCO edges)
# Values from AD9648 datasheet + sig_recorder verified constraints
#---------------------------------------------------------------------------
set_input_delay -clock [get_clocks adc_dco_clk]        -min -add_delay 4.500 [get_ports {adc_data[*]}]
set_input_delay -clock [get_clocks adc_dco_clk]        -max -add_delay 5.440 [get_ports {adc_data[*]}]
set_input_delay -clock [get_clocks adc_dco_clk] -clock_fall -min -add_delay 4.500 [get_ports {adc_data[*]}]
set_input_delay -clock [get_clocks adc_dco_clk] -clock_fall -max -add_delay 5.440 [get_ports {adc_data[*]}]

#---------------------------------------------------------------------------
# ASYNCHRONOUS CLOCK DOMAIN CROSSINGS
#
# Three clock domains:
#   adc_dco_clk — ADC data capture (IDDR, CDC FIFO write side)
#   sys_clk     — system logic (CDC FIFO read side, decimator, DPTI bridge sys side)
#   dpti_clk    — FT232H interface (DPTI bridge PHY)
#
# All cross-domain paths are handled by explicit synchronizers:
#   - CDC FIFO (xpm_fifo_async) for adc_dco_clk ↔ sys_clk
#   - Toggle-handshake CDC in comm_dpti for sys_clk ↔ dpti_clk
#---------------------------------------------------------------------------
set_clock_groups -asynchronous \
  -group [get_clocks adc_dco_clk] \
  -group [get_clocks sys_clk] \
  -group [get_clocks dpti_clk]

#---------------------------------------------------------------------------
# ASYNC_REG — Mark synchronizer registers for relaxed hold timing
#---------------------------------------------------------------------------
set_property ASYNC_REG TRUE [get_cells -hierarchical -filter {NAME =~ *rx_buf_s1_reg* || NAME =~ *rx_buf_s2_reg*}]

#---------------------------------------------------------------------------
# FALSE PATHS — Debug interface signals (dbg_if) are not timing-critical
#---------------------------------------------------------------------------
set_false_path -through [get_nets -hierarchical -filter {NAME =~ *dbg*}]

#---------------------------------------------------------------------------
# BITSTREAM SETTINGS
#---------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
