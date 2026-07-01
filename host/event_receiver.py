#!/usr/bin/env python3
"""
event_receiver.py — Phase 2.7 hardware smoke test

Opens the FT232H DPTI interface, arms the event pipeline (sends 0x02),
reads event packets, and validates them.

Packet format (per rtl/top_pipeline.sv, drain FSM):
  byte 0:        0xA5  (sync high)
  byte 1:        0x5A  (sync low)
  bytes 2-3:     event_id[15:8] event_id[7:0]
  bytes 4-3603:  1800 samples, each 2 bytes MSB-first then LSB
  Total:         3604 bytes per event

Usage:
  # 1. Program the FPGA (one-time)
  make program TOP=top_pipeline

  # 2. Capture events with optional plotting
  python host/event_receiver.py --duration 10 --plot waveform 1
"""

import argparse
import os
import struct
import sys
import time

import numpy as np

try:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    HAS_MPL = True
except ImportError:
    HAS_MPL = False

try:
    from pyftdi.ftdi import Ftdi
    HAS_PYFTDI = True
except ImportError:
    HAS_PYFTDI = False


# ==============================================================================
# Constants
# ==============================================================================
SAMPLES_PER_EVT = 1800
PACKET_SIZE     = 4 + SAMPLES_PER_EVT * 2  # 3604
PRE_SAMPLES     = 600
POST_SAMPLES    = SAMPLES_PER_EVT - PRE_SAMPLES  # 1200
SYNC_HI         = 0xA5
SYNC_LO         = 0x5A
RATE_MSPS       = 105.0   # raw ADC rate (events are full-rate, not decimated)

# Commands (matches top_pipeline.sv command decoder)
CMD_STOP       = 0x00
CMD_STREAM     = 0x01
CMD_ARM_EVENTS = 0x02
CMD_GLITCH_OFF = 0x07
CMD_GLITCH_ON  = 0x08


# ==============================================================================
# FT232H helpers
# ==============================================================================
def find_ft232h():
    if not HAS_PYFTDI:
        raise RuntimeError("pyftdi not installed. Install with: pip install pyftdi")
    for desc in Ftdi().find_all([(0x0403, 0x6014)]):
        dev_desc = desc[0]
        ftdi = Ftdi()
        ftdi.open(dev_desc.vid, dev_desc.pid, dev_desc.bus, dev_desc.address)
        return ftdi
    raise RuntimeError("No FT232H/FT2232H found. Check USB connection.")


def send_cmd(ftdi, cmd_byte):
    ftdi.write_data(bytes([cmd_byte]))


# ==============================================================================
# Packet parser
# ==============================================================================
class EventStreamParser:
    def __init__(self):
        self.events = []
        self.errors = {
            "bad_sync": 0,
            "bad_length": 0,
            "out_of_order_id": 0,
            "gap": 0,
        }
        self.bytes_received = 0
        self.expected_id = 0
        self.last_consumed = 0

    def parse_buffer(self, buf):
        """
        Parse a complete byte buffer. Returns list of (event_id, samples) tuples
        and updates self.errors / self.expected_id.
        """
        results = []
        i = 0
        while i + PACKET_SIZE <= len(buf):
            # Look for A5 5A sync
            if buf[i] == SYNC_HI and buf[i + 1] == SYNC_LO:
                event_id = (buf[i + 2] << 8) | buf[i + 3]

                # Extract 1800 samples
                samples_bytes = buf[i + 4 : i + PACKET_SIZE]
                # MSB then LSB per sample (16-bit big-endian, 14-bit right-aligned)
                samples_hi = np.frombuffer(
                    samples_bytes[0::2].tobytes(), dtype=np.uint8
                ).astype(np.uint16)
                samples_lo = np.frombuffer(
                    samples_bytes[1::2].tobytes(), dtype=np.uint8
                ).astype(np.uint16)
                samples = (samples_hi << 8) | samples_lo

                # Validate event_id ordering
                event_id = int(event_id)
                if event_id != self.expected_id and (self.bytes_received > 0 or results):
                    if event_id > self.expected_id:
                        gap = event_id - self.expected_id
                        self.errors["gap"] += gap
                        self.errors["out_of_order_id"] += 1
                    else:
                        self.errors["out_of_order_id"] += 1
                self.expected_id = (event_id + 1) & 0xFFFF

                results.append((event_id, samples))
                i += PACKET_SIZE
            else:
                i += 1

        self.last_consumed = i
        self.bytes_received += i
        self.events.extend(results)
        return results

    def summary(self):
        return {
            "events":      len(self.events),
            "bytes":       self.bytes_received,
            "errors":      dict(self.errors),
            "expected_id": self.expected_id,
        }


# ==============================================================================
# Main capture
# ==============================================================================
def capture_events(duration_s, plot_waveform_idx=None, plot_path=None,
                   do_arm=True, do_stop=True, verbose=True):
    ftdi = find_ft232h()
    print(f"FT232H connected: VID={ftdi.usb_dev.idVendor:04x} "
          f"PID={ftdi.usb_dev.idProduct:04x}")
    ftdi.set_bitmode(0xFF, Ftdi.BitMode.SYNCFF)
    ftdi.write_data_set_chunksize(64 * 1024)

    # Stop anything in progress, then arm
    send_cmd(ftdi, CMD_STOP)
    time.sleep(0.05)
    if do_arm:
        send_cmd(ftdi, CMD_ARM_EVENTS)
        time.sleep(0.05)
        if verbose:
            print("Sent ARM command (0x02). Waiting for events...")

    parser = EventStreamParser()
    all_events = []
    buf = bytearray()
    start = time.time()
    last_print = start

    try:
        while time.time() - start < duration_s:
            chunk = ftdi.read_data(65536)
            if chunk:
                buf.extend(chunk)
                if len(buf) >= PACKET_SIZE:
                    events = parser.parse_buffer(
                        np.frombuffer(bytes(buf), dtype=np.uint8)
                    )
                    all_events.extend(events)
                    buf = bytearray(buf[parser.last_consumed:])

            # Status every second
            now = time.time()
            if verbose and (now - last_print) > 1.0:
                elapsed = now - start
                n_evts = len(all_events)
                rate = n_evts / max(elapsed, 0.001)
                print(f"\r  {elapsed:5.1f}s  events={n_evts:5d}  "
                      f"rate={rate:6.1f} evt/s  "
                      f"buf={len(buf):5d}  "
                      f"errs={sum(parser.errors.values()):3d}  ",
                      end="", flush=True)
                last_print = now
    finally:
        if do_stop:
            send_cmd(ftdi, CMD_STOP)
            if verbose:
                print("\n  Sent STOP command (0x00).")
        ftdi.close()

    if verbose:
        print()
        print()
        print("=" * 60)
        print("  Capture Summary")
        print("=" * 60)
        print(f"  Duration:     {time.time() - start:.2f} s")
        print(f"  Events:       {len(all_events)}")
        print(f"  Total bytes:  {parser.bytes_received}")
        print(f"  Errors:       {parser.errors}")
        if all_events:
            last_id = all_events[-1][0]
            first_id = all_events[0][0]
            print(f"  Event IDs:    {first_id} → {last_id}  "
                  f"(delta = {last_id - first_id})")

    # Optional plot
    if plot_waveform_idx is not None and plot_waveform_idx <= len(all_events):
        if not HAS_MPL:
            print("WARNING: matplotlib not installed; cannot plot.")
        else:
            plot_waveform(
                all_events[plot_waveform_idx - 1],
                idx=plot_waveform_idx,
                outpath=plot_path or "build/plots/event_waveform.png",
            )
            if verbose:
                print(f"  Plot saved.")

    return all_events, parser


def plot_waveform(event_tuple, idx, outpath):
    event_id, samples = event_tuple
    t_us = np.arange(-PRE_SAMPLES, POST_SAMPLES) / RATE_MSPS  # µs
    fig, ax = plt.subplots(figsize=(12, 6))
    ax.plot(t_us, samples, linewidth=1.0, color="#1f77b4",
            label=f"event_id={event_id}")
    ax.axvline(0, color="red", linestyle="--", alpha=0.5, label="Trigger (t=0)")
    ax.axvline(-PRE_SAMPLES / RATE_MSPS, color="blue", linestyle=":",
               alpha=0.4, label=f"Pre-trigger (-{PRE_SAMPLES} samp)")
    ax.axvline(POST_SAMPLES / RATE_MSPS, color="blue", linestyle=":",
               alpha=0.4, label=f"Post-trigger (+{POST_SAMPLES} samp)")
    ax.set_xlabel("Time (µs @ 105 MSPS, 9.52 ns/sample)")
    ax.set_ylabel("ADC code (14-bit, right-aligned)")
    ax.set_title(f"Event #{idx} — {len(samples)} samples, "
                 f"min={samples.min()}, max={samples.max()}, "
                 f"mean={samples.mean():.0f}")
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=9, loc="upper right")
    os.makedirs(os.path.dirname(outpath) or ".", exist_ok=True)
    plt.tight_layout()
    plt.savefig(outpath, dpi=150)
    plt.close()


def main():
    parser = argparse.ArgumentParser(
        description="data_engine Phase 2.7 Event Receiver")
    parser.add_argument("--duration", type=float, default=5.0,
                        help="Capture duration (s, default 5)")
    parser.add_argument("--no-arm", action="store_true",
                        help="Don't send ARM command (use 0x01 stream instead)")
    parser.add_argument("--plot", type=int, default=None, metavar="N",
                        help="Plot the Nth captured event (1-indexed)")
    parser.add_argument("--plot-path", default=None,
                        help="Output PNG path (default "
                             "build/plots/event_waveform_NNNN.png)")
    args = parser.parse_args()

    plot_path = args.plot_path
    if args.plot is not None and plot_path is None:
        plot_path = f"build/plots/event_waveform_{args.plot:04d}.png"

    events, sp = capture_events(
        duration_s=args.duration,
        plot_waveform_idx=args.plot,
        plot_path=plot_path,
        do_arm=not args.no_arm,
    )


if __name__ == "__main__":
    main()
