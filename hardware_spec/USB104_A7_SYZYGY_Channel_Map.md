# USB104 A7 — SYZYGY Connector → FPGA Pin Mapping (Officially Verified)

> **Source**: [Digilent official USB104A7-ZmodADC reference design](https://github.com/Digilent/USB104A7-ZmodADC)
>   - `FPGA/src/constraints/USB104A7_A.xdc` (carrier)
>   - `FPGA/src/constraints/ZmodADC_0_ZmodADC.xdc` (ADC module)
> **FPGA**: Xilinx Artix-7 XC7A100T-1CSG324I (CSG324 package)
> **Board**: Digilent USB104 A7 Rev. B.2
> **Zmod**: ADC 1410-105 (AD9648 dual 14-bit ADC, 105 MSPS)
> **Verification**: 2026-06-24 — internet-verified against official Digilent repos

---

## ⚠️ Critical: The ADC interface is NOT differential DDR

The Zmod ADC 1410 uses the SYZYGY pins as **single-ended LVCMOS18 signals**, not differential pairs. The D_P/N pairs are not used as differential data lanes — each P or N pin is an independent signal.

---

## 1. ADC Channel Assignment

The AD9648 operates in **interleaved CMOS mode**: both channels share one 14-bit data bus (`ADC_DATA_0[13:0]`). Channel A is sampled on the **rising edge** of DCO, Channel B on the **falling edge**.

### ADC_DATA_0[13:0] — 14-bit data bus (single-ended, LVCMOS18)

| ADC_DATA_0 Bit | SYZYGY Signal | FPGA Pin | IOSTANDARD |
|:--------------:|:-------------:|:--------:|:----------:|
| 0 | S24 | H14 | LVCMOS18 |
| 1 | S22 | K15 | LVCMOS18 |
| 2 | D4_N | E16 | LVCMOS18 |
| 3 | D6_P | C16 | LVCMOS18 |
| 4 | D6_N | C17 | LVCMOS18 |
| 5 | S16 | J14 | LVCMOS18 |
| 6 | S18 | G18 | LVCMOS18 |
| 7 | S20 | J17 | LVCMOS18 |
| 8 | S17 | H15 | LVCMOS18 |
| 9 | D4_P | E15 | LVCMOS18 |
| 10 | S19 | F18 | LVCMOS18 |
| 11 | S21 | J18 | LVCMOS18 |
| 12 | S23 | J15 | LVCMOS18 |
| 13 | S25 | G14 | LVCMOS18 |

**Result**: The 14-bit ADC data bus uses:
- 4 pins from SYZYGY D-port: D4_P, D4_N, D6_P, D6_N
- 10 pins from SYZYGY S-port: S16, S17, S18, S19, S20, S21, S22, S23, S24, S25

---

## 2. Control Signals

These signals configure the Zmod ADC 1410's analog front-end (gain, coupling).

| Function | Port Name | SYZYGY Signal | FPGA Pin | IOSTANDARD | Direction |
|----------|-----------|:-------------:|:--------:|:----------:|:---------:|
| Ch1 AC coupling High | SC1_AC_H | D0_P | A13 | LVCMOS18 | FPGA→Zmod |
| Ch1 AC coupling Low | SC1_AC_L | D0_N | A14 | LVCMOS18 | FPGA→Zmod |
| Ch2 AC coupling High | SC2_AC_H | D1_P | B16 | LVCMOS18 | FPGA→Zmod |
| Ch2 AC coupling Low | SC2_AC_L | D1_N | B17 | LVCMOS18 | FPGA→Zmod |
| Ch1 Gain High | SC1_GAIN_H | D5_P | D15 | LVCMOS18 | FPGA→Zmod |
| Ch1 Gain Low | SC1_GAIN_L | D5_N | C15 | LVCMOS18 | FPGA→Zmod |
| Ch2 Gain High | SC2_GAIN_H | D3_P | B18 | LVCMOS18 | FPGA→Zmod |
| Ch2 Gain Low | SC2_GAIN_L | D3_N | A18 | LVCMOS18 | FPGA→Zmod |
| Common coupling High | SC_COM_H | D7_P | E18 | LVCMOS18 | FPGA→Zmod |
| Common coupling Low | SC_COM_L | D7_N | D18 | LVCMOS18 | FPGA→Zmod |

| Function | Port Name | SYZYGY Signal | FPGA Pin | IOSTANDARD | Notes |
|----------|-----------|:-------------:|:--------:|:----------:|:-----:|
| SPI data | sdio_sc | D2_P | A15 | LVCMOS18, DRIVE=4 | Bidir |
| SPI clock | sclk_sc | D2_N | A16 | LVCMOS18, DRIVE=4 | FPGA→Zmod |
| SPI chip select | cs_sc1 | S26 | E17 | LVCMOS18, DRIVE=4 | FPGA→Zmod |
| ADC sync | ADC_SYNC | S27 | D17 | LVCMOS18, SLEW=SLOW | FPGA→Zmod |

---

## 3. Clock Signals

| Function | Port Name | SYZYGY Signal | FPGA Pin | IOSTANDARD | Notes |
|----------|-----------|:-------------:|:--------:|:----------:|:-----:|
| ADC data clock out | ADC_DCO | P2C_CLK_P | H16 | LVCMOS18 | From AD9648 to FPGA |
| ADC sample clock P | CLKIN_ADC_P | C2P_CLK_P | F15 | **DIFF_SSTL18_I** | From FPGA to AD9648 |
| ADC sample clock N | CLKIN_ADC_N | C2P_CLK_N | F16 | **DIFF_SSTL18_I** | From FPGA to AD9648 |

### Clock Setup
```tcl
create_clock -period 10.000 -name ZmodADC_0_ADC_DCO_0 \
  -waveform {0.000 5.000} [get_ports {ZmodADC_0_ADC_DCO_0}]
create_generated_clock -name ZmodADC_0_CLKIN_ADC_P_0 \
  -source [get_pins .../InstADC_ClkODDR/C] -divide_by 1 \
  [get_ports ZmodADC_0_CLKIN_ADC_P_0]
```

**Input delay constraints** (from Digilent reference):
```tcl
set_input_delay -clock [get_clocks ZmodADC_0_ADC_DCO_0] \
  -clock_fall -min -add_delay 3.240 [get_ports {ZmodADC_0_ADC_DATA_0[*]}]
set_input_delay -clock [get_clocks ZmodADC_0_ADC_DCO_0] \
  -clock_fall -max -add_delay 5.440 [get_ports {ZmodADC_0_ADC_DATA_0[*]}]
set_input_delay -clock [get_clocks ZmodADC_0_ADC_DCO_0] \
  -min -add_delay 3.240 [get_ports {ZmodADC_0_ADC_DATA_0[*]}]
set_input_delay -clock [get_clocks ZmodADC_0_ADC_DCO_0] \
  -max -add_delay 5.440 [get_ports {ZmodADC_0_ADC_DATA_0[*]}]
```

---

## 4. I²C Configuration Interface — Bank 14 (3.3V)

| Function | Port Name | Signal | FPGA Pin | IOSTANDARD |
|----------|-----------|:------:|:--------:|:----------:|
| I²C Clock | Zmod_IIC_scl_io | SCL | U16 | LVCMOS33, PULLUP |
| I²C Data | Zmod_IIC_sda_io | SDA | V17 | LVCMOS33, PULLUP |
| Module Detect | syzygy_det | DET | T11 | LVCMOS33 |

---

## 5. Complete SYZYGY → FPGA Pin Cross-Reference

| SYZYGY Signal | FPGA Pin | ADC Function | IOSTANDARD |
|:-------------:|:--------:|:------------:|:----------:|
| D0_P | A13 | SC1_AC_H | LVCMOS18 |
| D0_N | A14 | SC1_AC_L | LVCMOS18 |
| D1_P | B16 | SC2_AC_H | LVCMOS18 |
| D1_N | B17 | SC2_AC_L | LVCMOS18 |
| D2_P | A15 | sdio_sc (SPI) | LVCMOS18 |
| D2_N | A16 | sclk_sc (SPI) | LVCMOS18 |
| D3_P | B18 | SC2_GAIN_H | LVCMOS18 |
| D3_N | A18 | SC2_GAIN_L | LVCMOS18 |
| D4_P | E15 | ADC_DATA_0[9] | LVCMOS18 |
| D4_N | E16 | ADC_DATA_0[2] | LVCMOS18 |
| D5_P | D15 | SC1_GAIN_H | LVCMOS18 |
| D5_N | C15 | SC1_GAIN_L | LVCMOS18 |
| D6_P | C16 | ADC_DATA_0[3] | LVCMOS18 |
| D6_N | C17 | ADC_DATA_0[4] | LVCMOS18 |
| D7_P | E18 | SC_COM_H | LVCMOS18 |
| D7_N | D18 | SC_COM_L | LVCMOS18 |
| P2C_CLK_P | H16 | ADC_DCO | LVCMOS18 |
| P2C_CLK_N | G16 | (unused?) | LVCMOS18 |
| C2P_CLK_P | F15 | CLKIN_ADC_P | DIFF_SSTL18_I |
| C2P_CLK_N | F16 | CLKIN_ADC_N | DIFF_SSTL18_I |
| S16 | J14 | ADC_DATA_0[5] | LVCMOS18 |
| S17 | H15 | ADC_DATA_0[8] | LVCMOS18 |
| S18 | G18 | ADC_DATA_0[6] | LVCMOS18 |
| S19 | F18 | ADC_DATA_0[10] | LVCMOS18 |
| S20 | J17 | ADC_DATA_0[7] | LVCMOS18 |
| S21 | J18 | ADC_DATA_0[11] | LVCMOS18 |
| S22 | K15 | ADC_DATA_0[1] | LVCMOS18 |
| S23 | J15 | ADC_DATA_0[12] | LVCMOS18 |
| S24 | H14 | ADC_DATA_0[0] | LVCMOS18 |
| S25 | G14 | ADC_DATA_0[13] | LVCMOS18 |
| S26 | E17 | cs_sc1 (SPI CS) | LVCMOS18 |
| S27 | D17 | ADC_SYNC | LVCMOS18 |
| SCL | U16 | Zmod_IIC_scl_io | LVCMOS33 |
| SDA | V17 | Zmod_IIC_sda_io | LVCMOS33 |
| DET | T11 | syzygy_det | LVCMOS33 |

Note: P2C_CLK_N (G16) and some S-signals not listed above are unused in the Zmod ADC reference design.

---

## 6. FT232H DPTI Interface (on-board, NOT via SYZYGY)

The USB104 A7 has an on-board FT232H (`0403:6014`, `Usb104A7_DPTI`) connected directly to the FPGA for high-speed data transfer via Digilent Parallel Transfer Interface (DPTI). This is a synchronous FIFO interface at up to ~30 MB/s.

> **Source**: Digilent official master XDC `USB104-A7-100T-Master.xdc` — `set_property` entries for `prog_*` signals.

| Signal | FPGA Pin | Direction | IOSTANDARD | Description |
|--------|:--------:|:---------:|:----------:|-------------|
| `prog_clko` | P17 | FT232H → FPGA | LVCMOS33 | 60 MHz clock from FT232H |
| `prog_d[0]` | M18 | Bidir | LVCMOS33 | Data bus bit 0 |
| `prog_d[1]` | R12 | Bidir | LVCMOS33 | Data bus bit 1 |
| `prog_d[2]` | R13 | Bidir | LVCMOS33 | Data bus bit 2 |
| `prog_d[3]` | M13 | Bidir | LVCMOS33 | Data bus bit 3 |
| `prog_d[4]` | R18 | Bidir | LVCMOS33 | Data bus bit 4 |
| `prog_d[5]` | T18 | Bidir | LVCMOS33 | Data bus bit 5 |
| `prog_d[6]` | N14 | Bidir | LVCMOS33 | Data bus bit 6 |
| `prog_d[7]` | P14 | Bidir | LVCMOS33 | Data bus bit 7 |
| `prog_oen` | N17 | FPGA → FT232H | LVCMOS33 | Output enable (active low) |
| `prog_rdn` | N15 | FPGA → FT232H | LVCMOS33 | Read strobe (active low) |
| `prog_rxen` | M16 | FT232H → FPGA | LVCMOS33 | Receive enable flag (active low) |
| `prog_siwun` | P18 | FPGA → FT232H | LVCMOS33 | Serial interface wake-up (active low) |
| `prog_spien` | L18 | FPGA → FT232H | LVCMOS33 | SPI enable (active low, unused in FIFO mode) |
| `prog_txen` | M17 | FT232H → FPGA | LVCMOS33 | Transmit enable flag (active low) |
| `prog_wrn` | N16 | FPGA → FT232H | LVCMOS33 | Write strobe (active low) |

### DPTI Synchronous FIFO Protocol (FT232H → FPGA)

The FT232H acts as the FIFO master, providing `prog_clko` (60 MHz). Data transfer uses:

**Write (PC ← FPGA):**
1. FPGA checks `prog_txen` is low (FT232H TX FIFO not full)
2. FPGA drives `prog_d[7:0]` with data, asserts `prog_wrn` low for one clock cycle
3. FT232H samples data on rising edge of `prog_clko`

**Read (PC → FPGA):**
1. FPGA checks `prog_rxen` is low (FT232H RX FIFO has data)
2. FPGA asserts `prog_rdn` low for one clock cycle
3. FT232H drives `prog_d[7:0]` with next byte — FPGA samples on rising edge

**Bidirectional bus control:** `prog_oen` must be low when FPGA drives the data bus; high otherwise (FT232H drives during reads).

---

## 7. Summary of IOSTANDARDs

| Signal Group | Voltage | IOSTANDARD |
|:------------|:-------:|:----------:|
| All SYZYGY D[0:7], S[16:27], P2C_CLK | 1.8V | LVCMOS18 |
| C2P_CLK (ADC sample clock output) | 1.8V | **DIFF_SSTL18_I** |
| I²C (SCL, SDA), DET | 3.3V | LVCMOS33 |
| On-board LEDs, buttons, prog signals | 3.3V | LVCMOS33 |
| Pmod headers JA, JB, JC | 3.3V | LVCMOS33 |

---

## 7. Verification Sources

1. **Digilent official master XDC**: `USB104-A7-100T-Master.xdc` (carrier pinout)
2. **Digilent reference design**: `USB104A7-ZmodADC` repo → `ZmodADC_0_ZmodADC.xdc` (ADC module pinout)
3. **JTAG detection**: XC7A100T confirmed on the board (IDCODE 0x13631093)
