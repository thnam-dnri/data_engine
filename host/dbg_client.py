#!/usr/bin/env python3
"""
dbg_client.py — Phase 3A Debug Client for data_engine Audit Aggregator

Opens the FT232H DPTI interface, sends register-read protocol commands
(0x10/0x11/0x14), and parses the 0x15 response.

CLI usage:
    python3 host/dbg_client.py --read 0x000          # Read a single register
    python3 host/dbg_client.py --poll-block 0x0A0    # Read a full block (8 regs)
    python3 host/dbg_client.py --poll-all            # Read all implemented blocks

Requires pyftdi (pip install pyftdi).

Register map: docs/debug_register_map.md
Constants: rtl/pkg/register_map_pkg.sv
"""

import argparse
import sys
import time

try:
    from pyftdi.ftdi import Ftdi
    HAS_PYFTDI = True
except ImportError:
    HAS_PYFTDI = False


# ==============================================================================
# Register Map Constants (mirrors rtl/pkg/register_map_pkg.sv)
# ==============================================================================

# Block base addresses
SYS_BASE          = 0x000
ADC_IF_BASE       = 0x020
CDC_FIFO_BASE     = 0x040
GLITCH_FILTER_BASE = 0x060
CIRC_BUF_BASE     = 0x080
TRIGGER_BASE      = 0x0A0
CONT_CAP_BASE     = 0x0C0  # deferred
DESC_FIFO_BASE    = 0x0E0
WF_READER_BASE    = 0x100
TX_FIFO_BASE      = 0x120
DPTI_BASE         = 0x140
BIST_BASE         = 0x1E0  # deferred

# Common offsets
DBG_COMMON_0      = 0x00
DBG_COMMON_1      = 0x04
DBG_COMMON_2      = 0x08
DBG_COMMON_3      = 0x0C
DBG_SPECIFIC_0    = 0x10
DBG_SPECIFIC_1    = 0x14
DBG_SPECIFIC_2    = 0x18
DBG_SPECIFIC_3    = 0x1C

# System registers
SYS_FIRMWARE_VERSION = 0x000
SYS_BOARD_ID         = 0x004
SYS_RUN_TIMESTAMP_LO = 0x008
SYS_RUN_TIMESTAMP_HI = 0x00C
SYS_RESET_CAUSE      = 0x010
SYS_CTRL             = 0x014

# Glitch Filter specific
GLT_MAX_DELTA   = 0x070
GLT_THRESHOLD   = 0x074

# Circular Buffer specific
BUF_WR_PTR      = 0x090
BUF_RD_PTR      = 0x094
BUF_COLLISION   = 0x098
BUF_WATERMARK   = 0x09C

# Trigger specific
TRIG_THRESHOLD           = 0x0B0
TRIG_THRESHOLD_CROSS_RATE = 0x0B4
TRIG_HOLDOFF_REMAINING   = 0x0B8
TRIG_ARMED               = 0x0BC

# Descriptor FIFO specific
DESC_FILL_LEVEL      = 0x0F0
DESC_WATERMARK       = 0x0F4
DESC_LOST_EVENT_CNT  = 0x0F8

# Waveform Reader specific
WFR_REMAINING     = 0x110
WFR_WRAP_HANDLED  = 0x114

# TX FIFO specific
TX_FILL_LEVEL  = 0x130
TX_WATERMARK   = 0x134
TX_DPTI_STALL  = 0x138

# DPTI Bridge specific
DPTI_RX_CMD_CNT      = 0x150
DPTI_BUS_TURNAROUNDS = 0x154


# ==============================================================================
# Block names and register descriptions
# ==============================================================================

REGISTER_NAMES = {
    SYS_FIRMWARE_VERSION:   "firmware_version",
    SYS_BOARD_ID:           "board_id",
    SYS_RUN_TIMESTAMP_LO:   "run_timestamp_lo",
    SYS_RUN_TIMESTAMP_HI:   "run_timestamp_hi",
    SYS_RESET_CAUSE:        "reset_cause",
    SYS_CTRL:               "sys_ctrl",

    0x020: "ADC_IF COMMON_0",
    0x024: "ADC_IF COMMON_1",
    0x028: "ADC_IF COMMON_2",
    0x02C: "ADC_IF COMMON_3",

    0x040: "CDC_FIFO COMMON_0",
    0x044: "CDC_FIFO COMMON_1",
    0x048: "CDC_FIFO COMMON_2",
    0x04C: "CDC_FIFO COMMON_3",
    0x050: "CDC fill_level",
    0x054: "CDC watermark",

    0x060: "GLITCH COMMON_0",
    0x064: "GLITCH COMMON_1",
    0x068: "GLITCH COMMON_2",
    0x06C: "GLITCH COMMON_3",
    GLT_MAX_DELTA: "glitch_max_delta",
    GLT_THRESHOLD: "glitch_threshold",

    0x080: "CBUF COMMON_0",
    0x084: "CBUF COMMON_1",
    0x088: "CBUF COMMON_2",
    0x08C: "CBUF COMMON_3",
    BUF_WR_PTR:    "cbuf_wr_ptr",
    BUF_RD_PTR:    "cbuf_rd_ptr",
    BUF_COLLISION: "cbuf_collision",
    BUF_WATERMARK: "cbuf_watermark",

    0x0A0: "TRIGGER COMMON_0",
    0x0A4: "TRIGGER COMMON_1",
    0x0A8: "TRIGGER COMMON_2",
    0x0AC: "TRIGGER COMMON_3",
    TRIG_THRESHOLD:            "trigger_threshold",
    TRIG_THRESHOLD_CROSS_RATE: "trigger_cross_rate",
    TRIG_HOLDOFF_REMAINING:    "trigger_holdoff_remaining",
    TRIG_ARMED:                "trigger_armed",

    0x0E0: "DESC_FIFO COMMON_0",
    0x0E4: "DESC_FIFO COMMON_1",
    0x0E8: "DESC_FIFO COMMON_2",
    0x0EC: "DESC_FIFO COMMON_3",
    DESC_FILL_LEVEL:     "desc_fill_level",
    DESC_WATERMARK:      "desc_watermark",
    DESC_LOST_EVENT_CNT: "desc_lost_event_count",

    0x100: "READER COMMON_0",
    0x104: "READER COMMON_1",
    0x108: "READER COMMON_2",
    0x10C: "READER COMMON_3",
    WFR_REMAINING:    "reader_remaining",
    WFR_WRAP_HANDLED: "reader_wrap_handled",

    0x120: "TX_FIFO COMMON_0",
    0x124: "TX_FIFO COMMON_1",
    0x128: "TX_FIFO COMMON_2",
    0x12C: "TX_FIFO COMMON_3",
    TX_FILL_LEVEL: "tx_fill_level",
    TX_WATERMARK:  "tx_watermark",
    TX_DPTI_STALL: "tx_dpti_stall",

    0x140: "DPTI COMMON_0",
    0x144: "DPTI COMMON_1",
    0x148: "DPTI COMMON_2",
    0x14C: "DPTI COMMON_3",
    DPTI_RX_CMD_CNT:      "dpti_rx_cmd_count",
    DPTI_BUS_TURNAROUNDS: "dpti_bus_turnarounds",
}

BLOCK_NAMES = {
    SYS_BASE:          "System",
    ADC_IF_BASE:       "ADC Interface",
    CDC_FIFO_BASE:     "CDC FIFO",
    GLITCH_FILTER_BASE: "Glitch Filter",
    CIRC_BUF_BASE:     "Circular Buffer",
    TRIGGER_BASE:      "Trigger",
    CONT_CAP_BASE:     "Continuous Capture (deferred)",
    DESC_FIFO_BASE:    "Descriptor FIFO",
    WF_READER_BASE:    "Waveform Reader",
    TX_FIFO_BASE:      "TX FIFO",
    DPTI_BASE:         "DPTI Bridge",
    BIST_BASE:         "BIST (deferred)",
}

# Blocks ordered for --poll-all
ALL_BLOCK_BASES = [
    SYS_BASE, ADC_IF_BASE, CDC_FIFO_BASE, GLITCH_FILTER_BASE,
    CIRC_BUF_BASE, TRIGGER_BASE, CONT_CAP_BASE, DESC_FIFO_BASE,
    WF_READER_BASE, TX_FIFO_BASE, DPTI_BASE, BIST_BASE,
]


# ==============================================================================
# FT232H / DPTI helpers
# ==============================================================================

def find_ft232h():
    if not HAS_PYFTDI:
        raise RuntimeError(
            "pyftdi not installed. Install with: pip install pyftdi"
        )
    for desc in Ftdi().find_all([(0x0403, 0x6014)]):
        dev_desc = desc[0]
        ftdi = Ftdi()
        ftdi.open(dev_desc.vid, dev_desc.pid, dev_desc.bus, dev_desc.address)
        return ftdi
    raise RuntimeError("No FT232H/FT2232H found. Check USB connection.")


def configure_ft232h(ftdi):
    """Configure an open FT232H handle for DPTI sync FIFO transfers."""
    ftdi.set_bitmode(0xFF, Ftdi.BitMode.SYNCFF)
    ftdi.write_data_set_chunksize(64 * 1024)


def open_ft232h():
    """Open and configure the default FT232H DPTI device."""
    ftdi = find_ft232h()
    configure_ft232h(ftdi)
    return ftdi


# ==============================================================================
# Register Read Protocol
#
# Host → FPGA:
#   0x10 <addr_hi>       — set register address high byte
#   0x11 <addr_lo>       — set register address low byte
#   0x14                 — read request
#
# FPGA → Host:
#   0x15 <addr_hi> <addr_lo> <data[31:24]> <data[23:16]> <data[15:8]> <data[7:0]>
# ==============================================================================

CMD_SET_ADDR_HI  = 0x10
CMD_SET_ADDR_LO  = 0x11
CMD_READ_REG     = 0x14
CMD_RESP_TAG     = 0x15

# Timeout for reading back the response (seconds)
READ_TIMEOUT = 1.0


def read_reg(addr, timeout_s=READ_TIMEOUT, ftdi=None):
    """
    Read a single 32-bit register at the given 16-bit address.

    Returns the 32-bit integer value, or raises TimeoutError / RuntimeError.

    Steps:
      1. Send 0x10 <addr_hi> to set the high byte.
      2. Send 0x11 <addr_lo> to set the low byte.
      3. Send 0x14 to trigger a read.
      4. Search the incoming byte stream for 0x15 tag byte.
      5. Validate the echoed address.
      6. Decode the 4 big-endian data bytes.
    """
    addr_hi = (addr >> 8) & 0xFF
    addr_lo = addr & 0xFF

    close_when_done = False
    if ftdi is None:
        ftdi = open_ft232h()
        close_when_done = True

    try:
        # Build command bytes
        cmd = bytes([CMD_SET_ADDR_HI, addr_hi, CMD_SET_ADDR_LO, addr_lo, CMD_READ_REG])

        # Flush any stale data from previous commands
        stale = ftdi.read_data(4096)
        _ = stale  # discard

        # Send the command sequence
        ftdi.write_data(cmd)

        # Poll for the 0x15 response
        deadline = time.time() + timeout_s
        buf = bytearray()
        while time.time() < deadline:
            chunk = ftdi.read_data(1024)
            if chunk:
                buf.extend(chunk)
                # Look for 0x15 tag
                idx = bytes(buf).find(bytes([CMD_RESP_TAG]))
                if idx >= 0 and len(buf) - idx >= 7:
                    # Found the response: 0x15 addr_hi addr_lo data[3] data[2] data[1] data[0]
                    resp_addr_hi = buf[idx + 1]
                    resp_addr_lo = buf[idx + 2]
                    resp_addr = (resp_addr_hi << 8) | resp_addr_lo
                    if resp_addr != addr:
                        raise RuntimeError(
                            f"Address mismatch: requested 0x{addr:04X}, "
                            f"got 0x{resp_addr:04X}"
                        )
                    data = (
                        (buf[idx + 3] << 24) |
                        (buf[idx + 4] << 16) |
                        (buf[idx + 5] << 8) |
                        buf[idx + 6]
                    )
                    return data
            time.sleep(0.001)

        raise TimeoutError(
            f"No register read response for address 0x{addr:04X} "
            f"within {timeout_s:.1f}s"
        )
    finally:
        if close_when_done:
            ftdi.close()


def poll_block(base_addr, timeout_s=READ_TIMEOUT, ftdi=None):
    """
    Read all 8 registers in a block (addresses base .. base+0x1C, stride 4).

    Returns a dict {offset: value}.
    """
    close_when_done = False
    if ftdi is None:
        ftdi = open_ft232h()
        close_when_done = True

    try:
        result = {}
        for offset in range(0, 0x20, 4):
            addr = base_addr + offset
            try:
                val = read_reg(addr, timeout_s=timeout_s, ftdi=ftdi)
                result[offset] = val
            except (TimeoutError, RuntimeError) as e:
                result[offset] = f"ERR: {e}"
        return result
    finally:
        if close_when_done:
            ftdi.close()


def poll_all(timeout_s=READ_TIMEOUT, ftdi=None):
    """
    Read all known blocks.

    Returns dict {base_addr: {offset: value}}.
    """
    close_when_done = False
    if ftdi is None:
        ftdi = open_ft232h()
        close_when_done = True

    try:
        result = {}
        for base in ALL_BLOCK_BASES:
            result[base] = poll_block(base, timeout_s=timeout_s, ftdi=ftdi)
        return result
    finally:
        if close_when_done:
            ftdi.close()


def print_reg_value(addr, value, indent=""):
    """Print a register address, its name, and its value in hex + decimal."""
    name = REGISTER_NAMES.get(addr, f"unknown_0x{addr:04X}")
    if isinstance(value, str):
        print(f"{indent}0x{addr:04X}  {name:30s}  {value}")
    else:
        print(f"{indent}0x{addr:04X}  {name:30s}  0x{value:08X}  ({value})")


def print_block(block_base, values, indent=""):
    """Print a full block's register values."""
    name = BLOCK_NAMES.get(block_base, f"Block 0x{block_base:04X}")
    print(f"\n{indent}--- {name} (0x{block_base:04X}) ---")
    for offset in sorted(values.keys()):
        addr = block_base + offset
        print_reg_value(addr, values[offset], indent=indent)


# ==============================================================================
# CLI
# ==============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="data_engine Phase 3A Debug Client — Audit Aggregator Register Read"
    )
    parser.add_argument("--read", type=lambda x: int(x, 0), metavar="ADDR",
                        help="Read a single 32-bit register at ADDR (hex or dec)")
    parser.add_argument("--poll-block", type=lambda x: int(x, 0), metavar="BASE",
                        help="Read all 8 registers in a block at BASE")
    parser.add_argument("--poll-all", action="store_true",
                        help="Read all implemented blocks")
    parser.add_argument("--timeout", type=float, default=READ_TIMEOUT,
                        help=f"Read timeout in seconds (default {READ_TIMEOUT})")
    args = parser.parse_args()

    if not (args.read is not None or args.poll_block is not None or args.poll_all):
        parser.print_help()
        print()
        print("ERROR: specify at least one of --read, --poll-block, or --poll-all")
        sys.exit(1)

    if not HAS_PYFTDI:
        print("ERROR: pyftdi not installed. Install with: pip install pyftdi")
        sys.exit(1)

    try:
        ftdi = open_ft232h()
    except RuntimeError as e:
        print(f"ERROR: {e}")
        sys.exit(1)

    print(f"FT232H connected: VID={ftdi.usb_dev.idVendor:04x} "
          f"PID={ftdi.usb_dev.idProduct:04x}")

    try:
        if args.read is not None:
            addr = args.read
            print(f"\nReading register 0x{addr:04X}...")
            val = read_reg(addr, timeout_s=args.timeout, ftdi=ftdi)
            print_reg_value(addr, val)

        if args.poll_block is not None:
            base = args.poll_block
            print(f"\nPolling block at 0x{base:04X}...")
            values = poll_block(base, timeout_s=args.timeout, ftdi=ftdi)
            print_block(base, values)

        if args.poll_all:
            print("\nPolling all blocks...")
            all_values = poll_all(timeout_s=args.timeout, ftdi=ftdi)
            for base in ALL_BLOCK_BASES:
                if base in all_values:
                    print_block(base, all_values[base])
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)
    finally:
        ftdi.close()

    print("\nDone.")


if __name__ == "__main__":
    main()
