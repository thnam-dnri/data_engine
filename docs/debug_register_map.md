# Debug Register Map — data_engine

**Date:** 2026-06-30
**Architecture reference:** `Architecture.md` §12.4
**Authority:** This document is the contract between RTL (`register_map_pkg.sv`), Audit Aggregator (`audit_aggregator.sv`), and host software (`dbg_client.py`). All three must match this file exactly.

---

## Address Space

- **16-bit address** (0x0000-0xFFFF), **32-bit data** per register
- **0x20 spacing per block** = 8 registers per block (4 common + 4 block-specific)
- Common registers (+0x00..+0x0C) map directly to `dbg_info_t` (128-bit packed struct, see `Architecture.md` §12.1)
- Block-specific registers (+0x10..+0x1C) are per-block (defined below)

---

## Common Register Layout (all blocks, +0x00..+0x0C)

These 4 registers are identical for every pipeline block. They map to `dbg_info_t`.

| Offset | Reg Name | Bits | Field | R/W | Reset | Description |
|:------:|----------|:----:|-------|:---:|:-----:|-------------|
| +0x00 | COMMON_0 | [31:28] | state | R | 0 | FSM state (0 = IDLE, block-specific encoding) |
|        |          | [27:12] | cycle_count | R | 0 | Cycles since reset (16-bit, wraps every 65536 cycles) |
|        |          | [11:4]  | stall_cycles | R | 0 | Cycles spent waiting on backpressure (8-bit, saturating) |
|        |          | [3:0]   | reserved | R | 0 | Zero |
| +0x04 | COMMON_1 | [31]    | error | R/W | 0 | Sticky error flag (write 1 to clear) |
|        |          | [30:23] | error_id | R | 0 | Which error fired (block-specific, 0 = no error) |
|        |          | [22]    | bypass_mode | R/W | 0 | 1 = block bypassed (pass-through) |
|        |          | [21:0]  | reserved | R | 0 | Zero |
| +0x08 | COMMON_2 | [31:16] | event_count | R/W | 0 | Events processed by this block (write 1 to clear to 0) |
|        |          | [15:0]  | reserved | R | 0 | Zero |
| +0x0C | COMMON_3 | [31:16] | word_count | R/W | 0 | Words consumed/produced (write 1 to clear to 0) |
|        |          | [15:0]  | reserved | R | 0 | Zero |

---

## Block Register Maps

### System (0x000-0x01F)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x000 | firmware_version | [31:0] | R | hardcoded | Bitfile version: [31:24] major, [23:16] minor, [15:8] patch, [7:0] build |
| 0x004 | board_id | [15:0] | R | hardcoded | Unique board identifier |
| 0x008 | run_timestamp_lo | [31:0] | R | 0 | Run time counter, low 32 bits (nanoseconds since run start) |
| 0x00C | run_timestamp_hi | [31:0] | R | 0 | Run time counter, high 32 bits |
| 0x010 | reset_cause | [3:0] | R | 0 | 0=power-on, 1=external, 2=watchdog, 3=host cmd |
| 0x014 | sys_ctrl | [0] | R/W | 0 | bit 0: global reset (self-clearing) |
| 0x018 | reserved | | | | |
| 0x01C | reserved | | | | |

### ADC Interface (0x020-0x03F)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x020 | COMMON_0 | | R | | state, cycle_count, stall_cycles (see common layout) |
| 0x024 | COMMON_1 | | R/W | | error, error_id, bypass_mode |
| 0x028 | COMMON_2 | | R/W | | event_count (samples captured) |
| 0x02C | COMMON_3 | | R/W | | word_count |
| 0x030 | iddr_cal_state | [3:0] | R | 0 | IDDR calibration state |
| 0x034 | cha_sync_count | [15:0] | R | 0 | Channel A sample continuity count |
| 0x038 | chb_sync_count | [15:0] | R | 0 | Channel B sample continuity count |
| 0x03C | reserved | | | | |

**State encoding:** 0=IDLE, 1=DCO_LOCKED, 2=DEINTERLEAVE_ACTIVE, 3=DCO_LOST
**Error IDs:** 0=none, 1=DCO_lost, 2=bit_error_detected

### CDC FIFO (0x040-0x05F)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x040 | COMMON_0 | | R | | state, cycle_count, stall_cycles |
| 0x044 | COMMON_1 | | R/W | | error, error_id, bypass_mode |
| 0x048 | COMMON_2 | | R/W | | event_count (words crossed CDC) |
| 0x04C | COMMON_3 | | R/W | | word_count |
| 0x050 | fill_level | [5:0] | R | 0 | Instantaneous FIFO fill level (0-63) |
| 0x054 | watermark | [5:0] | R | 0 | Max fill level observed since reset |
| 0x058 | reserved | | | | |
| 0x05C | reserved | | | | |

**State encoding:** 0=IDLE, 1=STREAMING
**Error IDs:** 0=none, 1=overflow, 2=underflow

### Glitch Filter (0x060-0x07F)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x060 | COMMON_0 | | R | | state, cycle_count, stall_cycles |
| 0x064 | COMMON_1 | | R/W | | error, error_id, bypass_mode |
| 0x068 | COMMON_2 | | R/W | | event_count (glitches removed) |
| 0x06C | COMMON_3 | | R/W | | word_count (samples processed) |
| 0x070 | max_delta | [15:0] | R | 0 | Max sample-to-sample jump observed |
| 0x074 | threshold | [15:0] | R/W | 500 | Glitch detection threshold (default 500 counts) |
| 0x078 | reserved | | | | |
| 0x07C | reserved | | | | |

**State encoding:** 0=BYPASS, 1=ACTIVE
**Error IDs:** 0=none, 1=filter_saturation

### Circular Buffer (0x080-0x09F)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x080 | COMMON_0 | | R | | state, cycle_count, stall_cycles |
| 0x084 | COMMON_1 | | R/W | | error, error_id, bypass_mode |
| 0x088 | COMMON_2 | | R/W | | event_count (wrap_around count) |
| 0x08C | COMMON_3 | | R/W | | word_count (samples written) |
| 0x090 | wr_ptr | [12:0] | R | 0 | Live write pointer (0-8191) |
| 0x094 | rd_ptr | [12:0] | R | 0 | Live burst-read pointer |
| 0x098 | collision_flag | [0] | R/W | 0 | wr_ptr == rd_addr during active burst (write 1 to clear) |
| 0x09C | watermark | [12:0] | R | 0 | Max fill level observed |

**State encoding:** 0=WRITE, 1=BURST_READ
**Error IDs:** 0=none, 1=collision (wr overtook rd during burst)

### Trigger (0x0A0-0x0BF)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x0A0 | COMMON_0 | | R | | state, cycle_count, stall_cycles |
| 0x0A4 | COMMON_1 | | R/W | | error, error_id, bypass_mode |
| 0x0A8 | COMMON_2 | | R/W | | event_count (triggers fired) |
| 0x0AC | COMMON_3 | | R/W | | word_count (samples evaluated) |
| 0x0B0 | threshold | [15:0] | R/W | configurable | Trigger threshold (ADC counts) |
| 0x0B4 | threshold_cross_rate | [15:0] | R | 0 | Threshold crossing rate (Hz, updated every 1s) |
| 0x0B8 | holdoff_remaining | [15:0] | R | 0 | Remaining holdoff cycles (live) |
| 0x0BC | armed | [0] | R/W | 1 | 1=trigger armed, 0=disarmed |

**State encoding:** 0=IDLE, 1=DETECT, 2=HOLDOFF
**Error IDs:** 0=none, 1=threshold_saturation

### Continuous Capture (0x0C0-0x0DF) — *deferred, not in initial release*

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x0C0 | COMMON_0 | | R | | state, cycle_count, stall_cycles |
| 0x0C4 | COMMON_1 | | R/W | | error, error_id, bypass_mode |
| 0x0C8 | COMMON_2 | | R/W | | event_count (blocks sent) |
| 0x0CC | COMMON_3 | | R/W | | word_count (bytes sent) |
| 0x0D0 | active | [0] | R/W | 0 | 1=continuous capture active |
| 0x0D4 | dropped_block_count | [15:0] | R | 0 | Blocks dropped due to TX FIFO full |
| 0x0D8 | reserved | | | | |
| 0x0DC | reserved | | | | |

**State encoding:** 0=IDLE, 1=STREAM
**Error IDs:** 0=none, 1=overflow (TX FIFO full)

### Descriptor FIFO (0x0E0-0x0FF)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x0E0 | COMMON_0 | | R | | state, cycle_count, stall_cycles |
| 0x0E4 | COMMON_1 | | R/W | | error, error_id, bypass_mode |
| 0x0E8 | COMMON_2 | | R/W | | event_count (descriptors pushed) |
| 0x0EC | COMMON_3 | | R/W | | word_count (descriptors popped) |
| 0x0F0 | fill_level | [5:0] | R | 0 | Instantaneous FIFO fill level (0-63) |
| 0x0F4 | watermark | [5:0] | R | 0 | Max fill level observed |
| 0x0F8 | lost_event_count | [15:0] | R/W | 0 | Events lost due to FIFO overflow (write 1 to clear) |
| 0x0FC | reserved | | | | |

**State encoding:** 0=IDLE, 1=PUSH, 2=POP
**Error IDs:** 0=none, 1=overflow, 2=seq_gap

### Waveform Reader (0x100-0x11F)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x100 | COMMON_0 | | R | | state, cycle_count, stall_cycles |
| 0x104 | COMMON_1 | | R/W | | error, error_id, bypass_mode |
| 0x108 | COMMON_2 | | R/W | | event_count (events read) |
| 0x10C | COMMON_3 | | R/W | | word_count (samples read) |
| 0x110 | remaining | [15:0] | R | 0 | Remaining samples in current burst (live) |
| 0x114 | wrap_handled | [15:0] | R | 0 | Count of buffer wrap-arounds handled during burst read |
| 0x118 | reserved | | | | |
| 0x11C | reserved | | | | |

**State encoding:** 0=IDLE, 1=BURST, 2=DONE
**Error IDs:** 0=none, 1=length_mismatch, 2=wrap_error

### TX FIFO (0x120-0x13F)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x120 | COMMON_0 | | R | | state, cycle_count, stall_cycles |
| 0x124 | COMMON_1 | | R/W | | error, error_id, bypass_mode |
| 0x128 | COMMON_2 | | R/W | | event_count (words drained) |
| 0x12C | COMMON_3 | | R/W | | word_count |
| 0x130 | fill_level | [11:0] | R | 0 | Instantaneous FIFO fill level (0-4095) |
| 0x134 | watermark | [11:0] | R | 0 | Max fill level observed |
| 0x138 | dpti_stall | [15:0] | R | 0 | DPTI TXE# high cycle count (stall cycles) |
| 0x13C | reserved | | | | |

**State encoding:** 0=IDLE, 1=STREAMING
**Error IDs:** 0=none, 1=overflow, 2=underflow

### DPTI Bridge (0x140-0x15F)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x140 | COMMON_0 | | R | | state, cycle_count, stall_cycles |
| 0x144 | COMMON_1 | | R/W | | error, error_id, bypass_mode |
| 0x148 | COMMON_2 | | R/W | | event_count (bytes sent) |
| 0x14C | COMMON_3 | | R/W | | word_count (bytes received from host) |
| 0x150 | rx_cmd_count | [15:0] | R | 0 | Host commands received |
| 0x154 | bus_turnarounds | [15:0] | R | 0 | Bus direction change count |
| 0x158 | reserved | | | | |
| 0x15C | reserved | | | | |

**State encoding:** 0=IDLE, 1=SEND, 2=RECV
**Error IDs:** 0=none, 1=protocol_error, 2=timeout

### BIST Control (0x1E0-0x1FF)

| Address | Name | Bits | R/W | Reset | Description |
|:-------:|------|:----:|:---:|:-----:|-------------|
| 0x1E0 | bist_mode | [0] | R/W | 0 | 1=BIST active (replaces ADC data with pattern gen) |
| 0x1E4 | bist_pattern | [2:0] | R/W | 0 | Pattern ID: 0=ramp, 1=alt_max_min, 2=pulse, 3=prbs, 4=glitch_injected |
| 0x1E8 | bist_error_mask | [9:0] | R | 0 | Bitmask: bit N=1 means block N detected error |
| 0x1EC | bist_result | [0] | R | 0 | 1=all blocks PASS, 0=at least one FAIL |
| 0x1F0 | bist_cycle_count | [31:0] | R/W | 0 | Number of pattern cycles run (write to reset) |
| 0x1F4 | reserved | | | | |
| 0x1F8 | reserved | | | | |
| 0x1FC | reserved | | | | |

---

## DPTI Command Protocol

| CMD Byte | Direction | Effect |
|:--------:|:---------:|--------|
| `0x10` | Host→FPGA | Set register address high byte (next byte = addr_hi) |
| `0x11` | Host→FPGA | Set register address low byte (next byte = addr_lo) |
| `0x12` | Host→FPGA | Write data high byte (next byte = data_hi) |
| `0x13` | Host→FPGA | Write data low byte (next byte = data_lo) |
| `0x14` | Host→FPGA | Read request — FPGA replies with 4 data bytes |
| `0x15` | FPGA→Host | Read response (4 data bytes: data[31:24], data[23:16], data[15:8], data[7:0]) |

**Address width:** 16-bit (addr_hi + addr_lo). All block base addresses fit in 9 bits (max 0x1FF).

---

## register_map_pkg.sv Constants

The following constants should be defined in `rtl/pkg/register_map_pkg.sv`:

```systemverilog
// Block base addresses (0x20 spacing)
localparam logic [15:0] SYS_BASE          = 16'h000;
localparam logic [15:0] ADC_IF_BASE       = 16'h020;
localparam logic [15:0] CDC_FIFO_BASE     = 16'h040;
localparam logic [15:0] GLITCH_FILTER_BASE = 16'h060;
localparam logic [15:0] CIRC_BUF_BASE     = 16'h080;
localparam logic [15:0] TRIGGER_BASE      = 16'h0A0;
localparam logic [15:0] CONT_CAP_BASE     = 16'h0C0;
localparam logic [15:0] DESC_FIFO_BASE    = 16'h0E0;
localparam logic [15:0] WF_READER_BASE    = 16'h100;
localparam logic [15:0] TX_FIFO_BASE      = 16'h120;
localparam logic [15:0] DPTI_BASE         = 16'h140;
localparam logic [15:0] BIST_BASE         = 16'h1E0;

// Common register offsets (within each block)
localparam logic [15:0] DBG_COMMON_0      = 16'h00; // state, cycle_count, stall_cycles
localparam logic [15:0] DBG_COMMON_1      = 16'h04; // error, error_id, bypass_mode
localparam logic [15:0] DBG_COMMON_2      = 16'h08; // event_count
localparam logic [15:0] DBG_COMMON_3      = 16'h0C; // word_count
localparam logic [15:0] DBG_SPECIFIC_0    = 16'h10; // block-specific
localparam logic [15:0] DBG_SPECIFIC_1    = 16'h14;
localparam logic [15:0] DBG_SPECIFIC_2    = 16'h18;
localparam logic [15:0] DBG_SPECIFIC_3    = 16'h1C;
```
