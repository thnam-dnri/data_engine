#!/usr/bin/env python3
"""
capture_waveforms.py — Capture 1000 ADC waveforms and plot the 100th (before filter)

Usage:
  # 1. Build and program the FPGA
  make synth && make program

  # 2. Capture (requires 1 kHz pulser on CH-A or CH-B)
  python host/capture_waveforms.py --capture --output capture_raw.bin

  # 3. Process and plot the 100th waveform
  python host/capture_waveforms.py --plot --input capture_raw.bin --which 100

  # Or both in one shot:
  python host/capture_waveforms.py --duration 2  --n-waveforms 1000
"""

import argparse
import os
import sys
import struct
import time
import numpy as np
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))

try:
    from pyftdi.ftdi import Ftdi as FtdiDev
    HAS_PYFTDI = True
except ImportError:
    HAS_PYFTDI = False
    print("pyftdi not available. Install: pip install pyftdi")
    sys.exit(1)


# ==============================================================================
# Data format (matches top_stream.sv TX byte sequencer)
# ==============================================================================
# After 1:32 decimation, each event is 4 bytes:
#   byte 0: ch_a[7:0]   (LSB)
#   byte 1: ch_a[15:8]  (MSB)
#   byte 2: ch_b[7:0]   (LSB)
#   byte 3: ch_b[15:8]  (MSB)
#
# Samples per second per channel (after FPGA 1:32 decimation in top_stream.sv):
#   ADC rate 105 MSPS / 32 decimation = 3.28 MSPS theoretical
#   Measured: 5.6 MB/s ÷ 4 bytes/pair = 1.4 MSPS effective (DPTI bottleneck)
# Override via --rate-msps if conditions change.

DEFAULT_RATE_MSPS = 1.4
SAMPLES_PER_MS   = int(DEFAULT_RATE_MSPS * 1000)  # 1400 samples/ms @ 1.4 MSPS

# Waveform parameters per Architecture.md
WAVEFORM_PRE  = 600   # pre-trigger samples
WAVEFORM_POST = 1200  # post-trigger samples
WAVEFORM_LEN  = 1800  # total samples per waveform


def find_ft232h():
    """Find the FT232H DPTI device."""
    for desc in FtdiDev().find_all([(0x0403, 0x6014)]):
        # desc is (UsbDeviceDescriptor, interface)
        dev_desc = desc[0]
        port = FtdiDev()
        port.open(dev_desc.vid, dev_desc.pid, dev_desc.bus, dev_desc.address)
        return port
    raise RuntimeError("No FT232H found. Check USB connection.")


def parse_pairs(data_bytes):
    """
    Parse raw bytes into (ch_a, ch_b) sample pairs.
    Returns numpy array of shape (N, 2): column 0 = ch_a, column 1 = ch_b.
    """
    n_bytes = len(data_bytes)
    n_pairs = n_bytes // 4
    # Trim to aligned 4-byte boundary
    data_bytes = data_bytes[:n_pairs * 4]

    pairs = np.frombuffer(data_bytes, dtype=np.uint8).reshape(-1, 4)
    ch_a = pairs[:, 0].astype(np.uint16) | (pairs[:, 1].astype(np.uint16) << 8)
    ch_b = pairs[:, 2].astype(np.uint16) | (pairs[:, 3].astype(np.uint16) << 8)

    return np.column_stack([ch_a, ch_b])


def detect_pulse_starts(samples, channel=0, threshold=500,
                        min_distance=500, pre_samples=600, post_samples=1200,
                        n_waveforms=1000):
    """
    Find rising-edge pulse triggers in a channel.
    
    Args:
        samples: 1D array of sample values
        channel: which channel (0=ch_a, 1=ch_b)
        threshold: threshold above baseline for trigger
        min_distance: minimum samples between triggers
        pre_samples: samples before trigger to include
        post_samples: samples after trigger to include
    
    Returns:
        list of (trigger_index, waveform_array) tuples
    """
    baseline = np.median(samples[:2000])  # first 2000 samples as baseline
    print(f"  Baseline (median of first 2000 samples): {baseline}")

    above = samples > (baseline + threshold)
    triggers = []

    i = 0
    while i < len(above) - 1 and len(triggers) < n_waveforms:
        # Find rising edge
        if not above[i] and above[i + 1]:
            trigger_idx = i + 1

            # Check we have enough pre/post samples
            if trigger_idx >= pre_samples and trigger_idx + post_samples <= len(samples):
                start = trigger_idx - pre_samples
                end = trigger_idx + post_samples
                waveform = samples[start:end]
                triggers.append((trigger_idx, waveform))

                # Skip ahead to avoid re-triggering on same pulse
                i += min_distance
                continue

        i += 1

    print(f"  Found {len(triggers)} pulse starts (threshold above baseline + {threshold})")
    return triggers


def capture(duration_s=2):
    """
    Capture raw data from the FT232H and return bytes.
    
    Args:
        duration_s: capture duration in seconds
    
    Returns:
        raw_bytes: bytes captured from the FPGA
    """
    ftdi = find_ft232h()
    print(f"Found FT232H: VID={ftdi.usb_dev.idVendor:04x} PID={ftdi.usb_dev.idProduct:04x}")

    # Configure for sync FIFO mode
    ftdi.set_bitmode(0xFF, FtdiDev.BitMode.SYNCFF)
    ftdi.write_data_set_chunksize(64 * 1024)

    print(f"Capturing for {duration_s} seconds...")
    all_data = bytearray()
    start = time.time()
    while time.time() - start < duration_s:
        data = ftdi.read_data(65536)
        if data:
            all_data.extend(data)
        elapsed = time.time() - start
        if int(elapsed) > int(elapsed - 0.1):
            rate = len(all_data) / max(elapsed, 0.001)
            print(f"\r  {elapsed:.1f}s  {len(all_data)/1e6:.2f} MB  "
                  f"{rate/1e6:.2f} MB/s", end="", flush=True)

    elapsed = time.time() - start
    rate = len(all_data) / max(elapsed, 0.001)
    print(f"\n  Done. {len(all_data)/1e6:.2f} MB captured at {rate/1e6:.2f} MB/s")
    ftdi.close()
    return bytes(all_data)


def extract_waveforms(raw_bytes, channel=0, threshold=500,
                      n_waveforms=1000, pre=600, post=1200,
                      rate_msps=DEFAULT_RATE_MSPS):
    """
    Parse raw bytes and extract individual waveforms.
    
    Returns:
        triggers: list of (trigger_idx, waveform) tuples
        pairs: full (N, 2) samples array for plotting context
    """
    print("Parsing sample pairs...")
    pairs = parse_pairs(raw_bytes)
    print(f"  Total pairs: {len(pairs)} ({pairs.shape[0]/rate_msps/1000:.1f} ms @ {rate_msps} MSPS)")

    ch = pairs[:, channel]
    ch_label = f"CH-{'A' if channel == 0 else 'B'}"

    print(f"Detecting pulses on {ch_label}...")
    triggers = detect_pulse_starts(
        ch, channel=channel, threshold=threshold,
        min_distance=pre + post - 200,  # prevent overlap
        pre_samples=pre, post_samples=post,
        n_waveforms=n_waveforms
    )

    return triggers, pairs


def plot_waveform(waveform_idx, triggers, pairs, channel=0,
                  pre=600, post=1200, rate_msps=DEFAULT_RATE_MSPS):
    """
    Plot a specific waveform with context.
    
    Args:
        waveform_idx: 1-based index of the waveform to plot (1 = first)
    """
    if waveform_idx < 1 or waveform_idx > len(triggers):
        print(f"ERROR: waveform index {waveform_idx} out of range "
              f"(1–{len(triggers)})")
        return

    trigger_idx, wf = triggers[waveform_idx - 1]
    ch_label = f"CH-{'A' if channel == 0 else 'B'}"

    # Time axis for waveform (in µs)
    t_wf = np.arange(-pre, post) / rate_msps  # samples / MSPS = µs

    fig, axes = plt.subplots(2, 1, figsize=(14, 8), gridspec_kw={'height_ratios': [1, 2]})

    # --- Top: context — 5 ms around the trigger ---
    ax = axes[0]
    half_ctx = int(2.5 * SAMPLES_PER_MS)
    context_start = max(0, trigger_idx - half_ctx)
    context_end = min(len(pairs), trigger_idx + half_ctx)
    ctx_t = np.arange(context_start, context_end) / rate_msps
    ax.plot(ctx_t - trigger_idx / rate_msps, pairs[context_start:context_end, channel],
            color='#888888', linewidth=0.6, alpha=0.7)
    ax.axvline(x=0, color='red', linestyle='--', alpha=0.5, label='Trigger')
    ax.axvline(x=-pre / rate_msps, color='blue', linestyle=':', alpha=0.4,
               label=f'Pre-trigger (-{pre} samples)')
    ax.axvline(x=post / rate_msps, color='blue', linestyle=':', alpha=0.4,
               label=f'Post-trigger (+{post} samples)')
    ax.set_ylabel('Sample Value (16-bit)')
    ax.set_title(f'Context: ±2.5 ms around waveform #{waveform_idx}')
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    # --- Bottom: extracted waveform ---
    ax = axes[1]
    ax.plot(t_wf, wf, linewidth=1.2, color='#1f77b4')
    ax.axvline(x=0, color='red', linestyle='--', alpha=0.5, label='Trigger')
    ax.axvline(x=-pre / rate_msps, color='blue', linestyle=':', alpha=0.4)
    ax.axvline(x=post / rate_msps, color='blue', linestyle=':', alpha=0.4)
    ax.fill_between(t_wf, 0, wf, where=(t_wf >= 0), alpha=0.1, color='#1f77b4')
    ax.set_xlabel(f'Time (µs @ {rate_msps} MSPS, {1000/rate_msps:.0f} ns/sample)')
    ax.set_ylabel('Sample Value (16-bit)')
    ax.set_title(f'Waveform #{waveform_idx} — {ch_label}, '
                  f'{len(wf)} samples (pre={pre}, post={post})')
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    outpath = f"build/plots/waveform_{waveform_idx:04d}.png"
    os.makedirs(os.path.dirname(outpath) or ".", exist_ok=True)
    plt.savefig(outpath, dpi=150)
    print(f"Saved: {outpath}")
    plt.close()


def save_raw(raw_bytes, path="capture_raw.bin"):
    """Save raw captured bytes to file."""
    with open(path, "wb") as f:
        f.write(raw_bytes)
    print(f"Saved {len(raw_bytes)} bytes to {path}")


def load_raw(path="capture_raw.bin"):
    """Load raw captured bytes from file."""
    with open(path, "rb") as f:
        data = f.read()
    print(f"Loaded {len(data)} bytes from {path}")
    return data


def main():
    parser = argparse.ArgumentParser(
        description="Capture ADC waveforms and plot the Nth (before filter)")
    
    # Capture options
    parser.add_argument("--capture", action="store_true",
                       help="Capture data from FPGA")
    parser.add_argument("--input", "-i", default="capture_raw.bin",
                       help="Raw data file (default: capture_raw.bin)")
    parser.add_argument("--output", "-o", default="capture_raw.bin",
                       help="Output file for captured data")

    # Duration
    parser.add_argument("--duration", type=float, default=2.0,
                       help="Capture duration in seconds (default: 2)")

    # Waveform extraction
    parser.add_argument("--channel", type=int, choices=[0, 1], default=0,
                       help="Channel to analyse (0=CH-A, 1=CH-B, default: 0)")
    parser.add_argument("--threshold", type=int, default=500,
                       help="Rising-edge threshold above baseline (default: 500)")
    parser.add_argument("--n-waveforms", type=int, default=1000,
                       help="Number of waveforms to collect (default: 1000)")
    parser.add_argument("--rate-msps", type=float, default=DEFAULT_RATE_MSPS,
                       help=f"Effective sample rate per channel in MSPS "
                            f"(default: {DEFAULT_RATE_MSPS}, measured from DPTI "
                            f"throughput; 3.28 = theoretical 105/32 decimation)")

    # Plot
    parser.add_argument("--plot", action="store_true",
                       help="Extract waveforms from captured data and plot Nth")
    parser.add_argument("--which", type=int, default=100,
                       help="Which waveform to plot (1-indexed, default: 100)")

    # Shortcut: do both capture + plot
    parser.add_argument("--auto", action="store_true",
                       help="Capture, extract, and plot the Nth waveform in one run")

    args = parser.parse_args()

    # Default: show help
    if not any([args.capture, args.plot, args.auto]):
        parser.print_help()
        print()
        print("Example: python capture_waveforms.py --auto --duration 2 --n-waveforms 1000")
        return

    # --- Caputure mode ---
    if args.capture or args.auto:
        print("=" * 60)
        print("  Phase 2 — Waveform Capture")
        print("=" * 60)
        print(f"  Channel:    CH-{'A' if args.channel == 0 else 'B'}")
        print(f"  Duration:   {args.duration}s")
        print(f"  Threshold:  {args.threshold}")
        print(f"  Waveforms:  {args.n_waveforms}")
        print()

        raw_bytes = capture(duration_s=args.duration)
        save_raw(raw_bytes, args.output)

    # --- Plot mode ---
    if args.plot or args.auto:
        print("=" * 60)
        print("  Waveform Extraction & Plot")
        print("=" * 60)

        raw_bytes = load_raw(args.output)
        triggers, pairs = extract_waveforms(
            raw_bytes, channel=args.channel, threshold=args.threshold,
            n_waveforms=args.n_waveforms,
            pre=WAVEFORM_PRE, post=WAVEFORM_POST,
            rate_msps=args.rate_msps
        )

        print(f"  Extracted {len(triggers)} / {args.n_waveforms} requested waveforms")
        print()

        if len(triggers) < args.which:
            print(f"ERROR: Only {len(triggers)} waveforms found, "
                  f"cannot plot #{args.which}")
            sys.exit(1)

        plot_waveform(args.which, triggers, pairs,
                      channel=args.channel,
                      pre=WAVEFORM_PRE, post=WAVEFORM_POST,
                      rate_msps=args.rate_msps)

        print()
        print(f"  ✓  Waveform #{args.which} plotted.")
        print(f"     (Total: {len(triggers)} waveforms extracted from "
              f"{len(pairs)} total samples)")
        print(f"  Open build/plots/waveform_{args.which:04d}.png to view")


if __name__ == "__main__":
    main()
