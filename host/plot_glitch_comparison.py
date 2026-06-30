#!/usr/bin/env python3
"""
plot_glitch_comparison.py — Compare ADC data with/without glitch filter

Simulates the AD9648 0x0C98 artifact (glitch every 256 samples) on a
realistic ADC trace (baseline + pulse), runs it through a Python
implementation of the 3-stage up-down glitch filter, and plots
before/after comparison.

Usage:
  python host/plot_glitch_comparison.py [--threshold 500]

Architecture reference: Architecture.md §3, §3a
"""

import argparse
import numpy as np
import matplotlib.pyplot as plt


def glitch_filter(samples, threshold=500):
    """
    Software model of the 3-stage up-down glitch filter.
    Matches the RTL in rtl/signal_processing/glitch_filter.sv.
    """
    n = len(samples)
    filtered = samples.copy()
    glitch_count = 0
    max_delta = 0

    for i in range(2, n):  # Need 3 samples for window
        s3 = samples[i - 2]  # oldest
        s2 = samples[i - 1]  # middle
        s1 = samples[i]      # newest

        d1 = int(s2) - int(s3)  # s2 - s3
        d2 = int(s1) - int(s2)  # s1 - s2

        abs_d1 = abs(d1)
        abs_d2 = abs(d2)

        # Track max delta
        max_delta = max(max_delta, abs_d1, abs_d2)

        # Detect UP-then-DOWN or DOWN-then-UP pattern
        signs_opposite = (d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)

        if signs_opposite and abs_d1 > threshold and abs_d2 > threshold:
            # Replace the middle sample (s2) with linear interpolation
            filtered[i - 1] = (samples[i - 2] + samples[i]) // 2
            glitch_count += 1

    return np.array(filtered, dtype=np.uint16), glitch_count, max_delta


def generate_adc_trace(num_samples=4096, baseline=0x2000, pulse_amp=4000,
                       pulse_start=800, pulse_width=600, glitch_val=0x0C98,
                       glitch_period=256):
    """
    Generate a realistic ADC trace:
      - baseline (mid-code ~0x2000 for 14-bit ADC with 16-bit container)
      - triangular pulse (rise, flat top, fall)
      - 0x0C98 glitch injected every `glitch_period` samples
    """
    t = np.arange(num_samples, dtype=np.int32)
    samples = np.full(num_samples, baseline, dtype=np.int32)

    # Pulse
    rise_end = pulse_start + pulse_width // 3
    flat_end = pulse_start + 2 * pulse_width // 3
    fall_end = pulse_start + pulse_width

    mask_rise = (t >= pulse_start) & (t < rise_end)
    mask_flat = (t >= rise_end) & (t < flat_end)
    mask_fall = (t >= flat_end) & (t < fall_end)

    samples[mask_rise] = baseline + (t[mask_rise] - pulse_start) * pulse_amp // (pulse_width // 3)
    samples[mask_flat] = baseline + pulse_amp
    samples[mask_fall] = baseline + pulse_amp - (t[mask_fall] - flat_end) * pulse_amp // (pulse_width // 3)

    # Inject glitches (skip t=0)
    glitch_mask = (t > 0) & (t % glitch_period == 0)
    samples[glitch_mask] = glitch_val

    return t, samples, pulse_start, pulse_width


def plot_comparison(t, raw, filtered, glitch_mask, glitch_count, max_delta,
                    threshold, pulse_start=800, pulse_width=600,
                    output_path="build/plots/glitch_comparison.png"):
    """Plot raw vs filtered data with glitch markers."""
    fig, axes = plt.subplots(3, 1, figsize=(14, 10), sharex=True)

    # --- Top: Full trace overlay ---
    ax = axes[0]
    ax.plot(t, raw, alpha=0.5, linewidth=0.5, label='Raw (with glitches)', color='#888888')
    ax.plot(t, filtered, alpha=0.8, linewidth=0.5, label='Filtered', color='#1f77b4')
    # Mark glitch locations
    glitch_idx = np.where(glitch_mask)[0]
    if len(glitch_idx) > 0:
        ax.scatter(t[glitch_mask], raw[glitch_mask],
                   color='red', s=8, alpha=0.7, zorder=5,
                   label=f'Glitches (n={len(glitch_idx)})')
    ax.set_ylabel('Sample Value (16-bit)')
    ax.set_title(f'Glitch Filter Comparison — Threshold={threshold}, '
                  f'Glitches removed={glitch_count}')
    ax.legend(loc='upper right', fontsize=9)
    ax.grid(True, alpha=0.3)

    # --- Middle: zoom on one glitch region ---
    ax = axes[1]
    # Find first glitch region (somewhere around 256-280)
    zoom_start = max(0, 256 - 20)
    zoom_end = min(len(t), 256 + 60)
    ax.plot(t[zoom_start:zoom_end], raw[zoom_start:zoom_end],
            'o-', markersize=3, alpha=0.7, label='Raw', color='#888888')
    ax.plot(t[zoom_start:zoom_end], filtered[zoom_start:zoom_end],
            's-', markersize=3, alpha=0.9, label='Filtered', color='#1f77b4')
    # Mark the glitch at sample 256
    glitch_local = (zoom_start <= 256 < zoom_end)
    if glitch_local and glitch_val_valid(raw, 256):
        ax.axvline(x=256, color='red', linestyle='--', alpha=0.5,
                   label='0x0C98 glitch')
    ax.set_ylabel('Sample Value')
    ax.set_title('Zoom: Glitch at sample 256 (UP-then-DOWN pattern)')
    ax.legend(loc='upper right', fontsize=9)
    ax.grid(True, alpha=0.3)

    # --- Bottom: zoom on pulse region ---
    ax = axes[2]
    pulse_zoom_start = max(0, pulse_start - 50)
    pulse_zoom_end = min(len(t), pulse_start + pulse_width + 50)
    ax.plot(t[pulse_zoom_start:pulse_zoom_end],
            raw[pulse_zoom_start:pulse_zoom_end],
            alpha=0.5, linewidth=0.8, label='Raw', color='#888888')
    ax.plot(t[pulse_zoom_start:pulse_zoom_end],
            filtered[pulse_zoom_start:pulse_zoom_end],
            alpha=0.9, linewidth=0.8, label='Filtered', color='#1f77b4')
    ax.set_xlabel('Sample Index (@ 100 MHz → 10 ns/sample)')
    ax.set_ylabel('Sample Value')
    ax.set_title(f'Zoom: Pulse region (start={pulse_start}, '
                  f'width={pulse_width} samples)')
    ax.legend(loc='upper right', fontsize=9)
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    print(f"Saved: {output_path}")
    plt.close()


def glitch_val_valid(raw, idx):
    """Check if index is in valid range."""
    return 0 <= idx < len(raw)


def print_stats(raw, filtered, glitch_count, max_delta, threshold):
    """Print comparison statistics."""
    diff_mask = raw != filtered
    n_replaced = np.sum(diff_mask)

    print()
    print("=" * 55)
    print("  Glitch Filter Comparison — Summary")
    print("=" * 55)
    print(f"  Samples analysed:     {len(raw)}")
    print(f"  Threshold:            {threshold}")
    print(f"  Glitches detected:    {glitch_count}")
    print(f"  Samples replaced:     {n_replaced}")
    print(f"  Max |delta| observed: {max_delta}")
    print()

    # Check if any glitches remain in filtered output
    glitch_val = 0x0C98
    glitches_raw = np.sum(raw == glitch_val)
    glitches_filt = np.sum(filtered == glitch_val)
    print(f"  0x0C98 values in raw:      {glitches_raw}")
    print(f"  0x0C98 values in filtered: {glitches_filt}")
    removal_pct = 100.0 * (glitches_raw - glitches_filt) / max(glitches_raw, 1)
    print(f"  Removal efficiency:       {removal_pct:.1f}%")
    print()

    # Check false positives (changes at non-glitch locations)
    glitch_val = 0x0C98
    fp_mask = diff_mask & (raw != glitch_val)
    fp_count = np.sum(fp_mask)
    if fp_count > 0:
        fp_indices = np.where(fp_mask)[0]
        print(f"  ⚠  {fp_count} false positive(s) at indices: {fp_indices[:10]}")
        for idx in fp_indices:
            print(f"      Sample {idx}: raw={raw[idx]}, filtered={filtered[idx]}")
    else:
        print(f"  ✓  Zero false positives (all changes are 0x0C98 glitches)")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Plot ADC data with/without glitch filter")
    parser.add_argument("--threshold", type=int, default=500,
                        help="Glitch detection threshold (default: 500)")
    parser.add_argument("--samples", type=int, default=4096,
                        help="Number of samples to simulate (default: 4096)")
    parser.add_argument("--output", type=str,
                        default="build/plots/glitch_comparison.png",
                        help="Output plot path")
    args = parser.parse_args()

    import os
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)

    # Generate ADC trace with 0x0C98 glitches
    t, raw, pulse_start, pulse_width = generate_adc_trace(num_samples=args.samples)

    # Apply glitch filter
    filtered, glitch_count, max_delta = glitch_filter(
        raw, threshold=args.threshold)

    # Find glitch locations
    glitch_val = 0x0C98
    glitch_mask = (raw == glitch_val)

    # Print stats
    print_stats(raw, filtered, glitch_count, max_delta, args.threshold)

    # Plot
    plot_comparison(t, raw, filtered, glitch_mask, glitch_count, max_delta,
                    args.threshold, pulse_start=pulse_start,
                    pulse_width=pulse_width, output_path=args.output)

    print(f"To view: open {args.output}")


if __name__ == "__main__":
    main()
