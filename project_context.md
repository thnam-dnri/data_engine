# data_engine — HPGe Waveform Acquisition Platform

**Path**: `/Users/namtran/Library/CloudStorage/Dropbox/FPGA/data_engine/`
**Board**: Digilent USB104 A7 Rev. B.2 (XC7A100T-1CSG324I) + Zmod ADC 1410-105 (AD9648)
**Last updated**: 2026-06-30

> **Architecture update (2026-06-30):** §12 Debug & Validation Architecture added to Architecture.md.
> Every pipeline block now has a standard `dbg_if` port, an Audit Aggregator collects all debug
> signals onto a DPTI-accessible register map, and BIST mode validates the full pipeline without
> external equipment. This is a clean-slate document for data_engine — not a copy of sig_recorder.

## Project Goal

Open, low-cost, pure-RTL FPGA waveform acquisition platform for High-Purity Germanium (HPGe) detectors. Captures raw preamplifier waveforms with full metadata provenance for ML research, at ~10× lower cost than commercial digitizers.

## Key Design Parameters

| Parameter | Value |
|-----------|-------|
| ADC | AD9648, dual 14-bit, 105 MSPS, interleaved CMOS |
| FPGA | XC7A100T-1CSG324I (~101K LUTs, 4,860 Kb BRAM) |
| Host link | FT232H DPTI sync FIFO, ~7 MB/s emp. @ 1 kHz pulse gen, theor. 30 MB/s |
| Event window | 1800 samples (600 pre + 1200 post) = **17.14 µs @ 105 MSPS** |
| Circular buffer | 8192 × 16 (Issue 001 2-level buffering architecture) |
| Descriptor FIFO | 64 × 160 bit |
| TX waveform FIFO | 4096 × 16 |
| Max event rate | ~1,900 evt/s @ 7 MB/s or ~8,300 evt/s @ 30 MB/s (3600 B/evt, 1800 samp) |

## Architecture

```
ADC → IDDR deinterleaver → async FIFO (CDC) → glitch filter → 
circular buffer → descriptor FIFO → waveform reader → TX FIFO → 
DPTI (FT232H) → PC
```

- **2-level buffering** (Issue 001): capture memory (circular buffer) separated from transport memory (TX FIFO). DPTI backpressure never reaches ADC.
- **Pure RTL**: no soft-core CPU in the real-time path.
- **Trigger-optional**: continuous capture preserves all baseline/pile-up information; trigger is a downstream software choice.

## Implementation Status

| Component | Status | Notes |
|-----------|--------|-------|
| ADC CMOS interface (IDDR) | ✅ Complete | SAME_EDGE_PIPELINED mode |
| ADC SPI init (AD9648) | ✅ Complete | 20-step sequence, CDCE I²C dependency |
| CDCE6214 I²C init | ✅ Complete | 22 reg writes, powers analog front-end |
| Clock domains (3: adc_dco/sys_clk/ft_clk) | ✅ Verified | Async FIFO CDC, timing MET |
| DPTI host interface | ✅ Verified | ~7 MB/s emp. @ 1 kHz pulse gen, theor. 30 MB/s, round-robin arbitration |
| Glitch filter (0x0C98 artifact) | ✅ Complete | 3-stage up-down pattern detector, 100% effective |
| Trigger logic | ✅ Complete | Neg-edge, programmable threshold/hysteresis |
| Circular buffer (8192×16) | ✅ Complete | Port A: continuous write, Port B: registered read |
| Descriptor FIFO (64×106) | ✅ Complete | FWFT, per-trigger descriptor push |
| Waveform reader | ✅ Complete | Burst read BRAM → TX FIFO, handles wrap |
| TX waveform FIFO (4096×16) | ✅ Complete | Single-clock @ 100 MHz |
| Event pipeline FSM | ✅ Complete | Pipelined push, drain, lost_event_counter |
| Host software (Python DAQ) | ✅ Complete | Streaming + event mode, ROOT collection |
| Bitstream (Issue 001) | ✅ Generated | Timing MET, 6,387 LUTs (10%), 1 BRAM |

## Key Technical Findings

### AD9648 0x0C98 Glitch
- Deterministic single-sample artifact appearing every **256 DCO cycles** (2.56 µs)
- Value: `0x0C98` (3224 decimal), replaces any signal value
- **HW solution**: 3-stage up-down pattern detector — threshold 500, 100% effective
- **Root cause**: under investigation. Period = 2⁸ suggests internal ADC digital counter/pipeline wrapping.
- **Pending**: DCO invert (reg 0x16), clock divide (reg 0x0B), test pattern (reg 0x0D) experiments to confirm origin

### Event Window Physics
- HPGe rising edge: **100–1000 ns** (10–105 samples @ 105 MSPS) — contains position-dependent interaction information
- 1800-sample event window (600 pre + 1200 post) = **17.14 µs** — fully captures rise + tail
- Pre-trigger baseline (600 samples = 5.7 µs) provides >10× the rising edge width for noise characterisation

### Throughput Constraints
- ADC raw: 184 MB/s (1 ch) → FT232H: ~7 MB/s emp. (tested @ 1 kHz pulse gen) **or** theor. 30 MB/s
- Event mode at 1800 samples/event: **~1,900 evt/s @ 7 MB/s** or **~8,300 evt/s @ 30 MB/s**
- Window size can be reduced for higher-rate operation (e.g. 512 samples → ~6,700 evt/s @ 7 MB/s or ~28,800 evt/s @ 30 MB/s)
- **⚠️ Upper bound not yet characterized**: 7 MB/s was measured at 1 kHz pulse gen; the DPTI link has never been stressed beyond that. Real maximum depends on USB OS scheduling, FT232H buffer sizing, and Python DAQ overhead.

## Open Questions

1. **Glitch root cause**: sync mismatch (coworker theory) vs. ADC-internal artifact. Experiments via existing SPI register writes on current bitstream can resolve.
2. **Baseline estimator**: <100 LUTs, add to signal processing pipeline for enriched metadata.
3. **Issue 001 burst capacity**: 2 consecutive events before buffer wrap — acceptable for HPGe rates but should be validated in hardware.
4. **Configurable event window**: runtime-tunable `cfg_post` via DPTI command deferred to Phase 2.

## Novelty & Feasibility Assessment (2026-06-30)

### Verdict: STRONG NOVELTY — HIGH FEASIBILITY

The project addresses a genuine, well-documented research gap. Academic searches across arXiv, Semantic Scholar, and PubMed confirm that **no open-source, purpose-built FPGA waveform streaming platform exists for HPGe detectors** that combines:
- Pure RTL (zero soft-core CPU in real-time path)
- Continuous circular buffer capture (trigger-optional)
- 2-level buffering with DPTI backpressure isolation
- Fully open acquisition chain (HDL + software + documentation)
- Purpose-built for raw preamplifier waveform dataset generation for ML

### Novelty Assessment

| Dimension | Finding |
|-----------|---------|
| **vs. Commercial (CAEN DT5780 ~$5k)** | Waveform mode is a "debugging feature" per CAEN's own DPP-PHA manual, with documented data-loss risk. Our platform makes waveform capture the *primary operating mode*. |
| **vs. PandaX digitizer [He+21]** | Closest academic work — but PandaX is specific to LXe TPC, uses high-end FPGAs (not COTS), not open-source. Our design targets HPGe at ~$300. |
| **vs. Pavel Demin's MCPHA** | Pulse-height analyzer (histogram only) for shaped Gaussian pulses — cannot output raw preamplifier waveforms. Complementary, not competitive. |
| **vs. Digilent Zmod Scope Demo** | Uses MicroBlaze CPU — single-shot capture only. Our pure-RTL pipeline is fundamentally different. |
| **vs. CAEN Open FPGA (VX2745)** | Proprietary Sci-Compiler toolchain — not truly open. Our HDL is open for academic/research use (see `LICENSE`), bit-for-bit reproducible. |
| **vs. GELATIO (Gerda)** | Offline PC software analysis — not an acquisition platform. |

### Key Literature Gaps Confirmed

1. **Fan et al. (NIM A, 2024)**: 1D/2D-CNN HPGe discrimination — digitizer not stated, acquisition pipeline unpublished
2. **Yu et al. (NIM A, 2025)**: CNN PSD for ICPC HPGe — digitizer not stated, uses transfer function from "tens of waveforms"
3. **Lennon (UKAEA, 2024)**: ML Compton suppression — acquisition details unpublished
4. **Babicz et al. (arXiv:2603.06192, Mar 2026)**: Transformer PSD — uses public data release (Majorana), not open acquisition
5. **Holl et al. (EPJC, 2019)**: Autoencoder PSD — CAEN digitizer implied, chain unpublished

**All published ML-on-HPGe-waveform papers use closed acquisition chains.** None open-source their digitizer firmware or describe the pipeline in sufficient detail for reproducibility.

### Feasibility Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| **FT232H throughput (7–30 MB/s)** | Low-Medium | 7 MB/s measured @ 1 kHz pulse gen — **upper bound untested**. Theoretical 30 MB/s gives ~8,300 evt/s @ 1800 samp, sufficient for all but the highest HPGe rates. Phase 2 Ethernet for full ADC streaming. |
| **AD9648 0x0C98 glitch root cause** | Low-Medium | HW filter is 100% effective. Root-cause experiments via SPI registers planned (non-destructive). |
| **HPGe preamplifier compatibility** | Low | Input range, impedance, bandwidth all verified compatible. |
| **FPGA resource headroom** | Low | 10% LUTs, 5% BRAM used — ample room for DSP blocks. |
| **Vivado toolchain dependency** | Low | Free WebPACK sufficient. Yosys/nextpnr experimental for Artix-7. |
| **Competitive preemption** | Low | No evidence of similar open-source platform emerging. |

### Recommended Publication Path

1. **Short-term**: JINST (technical paper on architecture + throughput benchmarks)
2. **Medium-term**: NIM A (full instrumentation paper with HPGe validation data)
3. **Long-term**: IEEE TNS (if on-chip DSP/pulse-processing implemented)

### Updated Literature References (from 2026-06-30 search)

| Paper | Relevance |
|-------|-----------|
| Babicz et al., "Transformer-Based PSD in HPGe Detectors", arXiv:2603.06192 (2026) | Latest ML-on-HPGe paper; uses public Majorana data, not open acquisition |
| Wang et al., "Dataset for neutron/gamma PSD", arXiv:2305.18242 (2023) | Related open dataset for scintillator PSD — confirms demand for open waveform data |
| He et al., "500 MS/s waveform digitizer for PandaX", arXiv:2108.11804 (2021) | Closest architectural reference; triggerless readout with circular buffer |

## Related Projects

- **sig_recorder** (`/home/adminministrator/Dropbox/FPGA/DIGILENT/sig_recorder/`): implementation repository with full RTL, testbenches, host software, and build scripts. Working, hardware-verified reference for all Phase 1-2 modules — port from here, don't rebuild from scratch.
- **DIGILENT/project_context.md**: tracks sig_recorder implementation details, build status, bug fixes, and MCP server setup.

## Documents

| File | Description |
|------|-------------|
| `data_engine.md` | Research direction, core innovations, literature review, specifications |
| `Architecture.md` | Detailed architecture, module descriptions, throughput budget, packet format, debug architecture §12 |
| `implementation_strategy.md` | Phased build plan, file creation schedule, test coverage matrix |
| `hardware_spec/USB104_A7_SYZYGY_Channel_Map.md` | Verified SYZYGY→FPGA pin mapping |
| `hardware_spec/USB104_A7_Zmod_ADC1410.xdc` | Timing and pin constraints (from Digilent official repo) |
