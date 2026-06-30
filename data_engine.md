# Data Engine Research Direction

## Open FPGA‑Based High‑Rate HPGe Waveform Acquisition Platform

**Last updated:** 2026-06-30

---

- [1. Research Goal](#1-research-goal)
- [2. Core Innovations](#2-core-innovations)
- [3. Problem Analysis & Community Bottlenecks](#3-problem-analysis--community-bottlenecks)
- [4. Proposed Architecture](#4-proposed-architecture)
- [5. Key Design Decisions](#5-key-design-decisions)
- [6. Observability and Self‑Diagnosis](#6-observability-and-self-diagnosis)
- [7. Literature Review & Related Work](#7-literature-review--related-work)
  - [7.1 FPGA Waveform Digitizers for Nuclear & Particle Physics](#71-fpga-waveform-digitizers-for-nuclear--particle-physics)
  - [7.2 HPGe Digitizer Performance Studies](#72-hpge-digitizer-performance-studies)
  - [7.3 FPGA DAQ Infrastructure & Tools](#73-fpga-daq-infrastructure--tools)
  - [7.4 Gap Analysis](#74-gap-analysis)
- [8. Expected Contributions](#8-expected-contributions)
- [9. Prospective Technical Specifications](#9-prospective-technical-specifications)
- [10. Research Plan & Milestones](#10-research-plan--milestones)
- [References](#references)

---

## 1. Research Goal

We aim to develop an **open, low‑cost, and fully reproducible FPGA‑based waveform acquisition platform** tailored for High‑Purity Germanium (HPGe) detector research.

Unlike commercial digitizers, which function as opaque black boxes, our platform is designed as a **transparent data engine** that generates high‑quality, continuous waveform datasets. Such datasets are essential for modern analysis methods—particularly machine learning (ML)—but are currently scarce and non‑reproducible.

The platform directly addresses three persistent community bottlenecks:

- the lack of openly available, timestamped HPGe waveform data,
- the high cost and closed‑firmware nature of commercial digitizers,
- the poor reproducibility of ML experiments due to proprietary acquisition chains.

Our architecture bridges the gap between the analogue front‑end and advanced digital processing:

```
HPGe preamplifier → FPGA waveform DAQ → Raw waveform database → ML / advanced signal processing
```

---

## 2. Core Innovations

### 2.1 Low‑cost, open waveform acquisition

We implement a pure RTL (Register‑Transfer Level) FPGA architecture using:

- commercial off‑the‑shelf (COTS) FPGA boards,
- high‑speed ADCs,
- no embedded processor dependency,
- a fully open acquisition chain (HDL sources, scripts, and documentation).

This design ensures affordability and complete reproducibility—enabling other labs to replicate and build upon the system without expensive proprietary tools.

### 2.2 Continuous waveform preservation

Traditional digitizers operate in a **trigger‑then‑capture** mode: upon a trigger, a short window is recorded, and the rest is discarded. This approach loses valuable baseline, noise, and pile‑up information.

Our paradigm is:

> **Continuous capture → circular buffering → event selection → waveform extraction**

By preserving the raw detector information *before* any interpretative step, we provide data scientists with the full signal context needed for advanced ML and physics analysis, including:

- **Inter-event baseline** for noise characterisation and drift correction.
- **Pile‑up events** for training recovery algorithms.
- **Rare/abnormal pulses** discarded by conventional triggers.

**Event window sizing:** A typical HPGe event window of 1800 samples (600 pre-trigger + 1200 post-trigger) spans **17.14 µs @ 105 MSPS**. The physics-critical **rising edge (~100–1000 ns = 10–105 samples)** — which carries position-dependent interaction information for pulse-shape discrimination — is fully captured with >10× headroom in the pre-trigger baseline. The window size is configurable: a 512-sample window (51.2 µs) suffices for most ML applications while tripling the sustainable event rate over the host-link bottleneck.

### 2.3 Built‑in dataset provenance

Every captured waveform is accompanied by metadata (timestamp, trigger status, FIFO health counters, ADC status), creating a fully traceable dataset ideal for reproducible ML pipelines.

---

## 3. Problem Analysis & Community Bottlenecks

| Bottleneck | Consequence | Our Approach |
|---|---|---|
| **Closed firmware** | Results cannot be verified or extended | Pure RTL, fully open‑source (HDL + tooling) |
| **Trigger‑only capture** | Baseline, pre‑trigger noise, pile‑up context lost | Continuous circular buffer with event extraction |
| **High cost** (€5k–€20k per channel) | Not accessible to small labs or educational use | COTS FPGA + ADC, no proprietary backplane |
| **No standard dataset format** | ML studies on HPGe are ad‑hoc, not comparable | Metadata‑rich HDF5 / ROOT output with self‑diagnostics |
| **Poor reproducibility** | ML results cannot be reproduced across labs | Full acquisition chain open + characterised instrument |

---

## 4. Proposed Architecture

```
                  ┌───────────┐
                  │  AD9648  │  Dual 14-bit ADC @ 105 MSPS (Zmod ADC 1410-105)
                  └─────┬─────┘
                        │ LVDS / serial
                  ┌─────▼──────┐
                  │    ADC     │  Serialisation / deserialisation, bit alignment
                  │ Interface  │
                  └─────┬──────┘
                        │ parallel sample bus
                  ┌─────▼──────┐
                  │   CDC      │  Clock domain crossing (ADC clk → sys clk)
                  │   FIFO     │
                  └─────┬──────┘
                        │
                  ┌─────▼──────────┐
                  │   Signal       │  Glitch filter (HW up-down pattern detector),
                  │   Processing   │  baseline estimator (EWMA), FIR, pole-zero
                  └─────┬──────────┘
                        │
                  ┌─────▼──────────────┐
                  │   Circular         │  Dual‑port BRAM buffer (XC7A100T: 4,860 Kb total).
                  │   Waveform Buffer  │  Continuous write, random read. ~300K samples max.
                  └─────┬──────────────┘
                        │
           ┌────────────┼────────────┐
           │            │            │
  ┌────────▼─────┐ ┌───▼────┐ ┌─────▼───────┐
  │   Trigger    │ │Monitor │ │ Continuous  │ Trigger: leading‑edge, CFD,
  │   Logic      │ │ & Stat │ │ Capture     │ or ML‑based
  └────────┬─────┘ └───┬────┘ └──────┬──────┘
           │           │             │
  ┌────────▼─────┐     │    ┌────────▼───────┐
  │  Descriptor  │     │    │  Waveform      │ Descriptor: timestamp, amplitude,
  │  FIFO        │     │    │  Reader        │ energy, trigger type
  └────────┬─────┘     │    └────────┬───────┘
           │           │             │
           └───────────┼─────────────┘
                       │
                ┌──────▼───────┐
                │   TX FIFO    │  Elastic buffer for USB/ETH bridge
                └──────┬───────┘
                       │
                ┌──────▼──────┐
                │  FT232H    │  On-board FT232H DPTI (sync FIFO, 60 MHz, ~30 MB/s)
                │   DPTI     │
                └─────────────┘
```

**Data flow:** Samples are written continuously into a circular buffer. A parallel trigger logic path identifies event candidates and pushes descriptors (timestamp, amplitude, energy estimate) into a descriptor FIFO. A waveform reader consults the descriptor FIFO, extracts the corresponding segment from the circular buffer, and assembles a packet (waveform + metadata). Packets stream out via a high‑speed USB link to the host.

---

## 5. Key Design Decisions

| Decision | Rationale |
|---|---|
| **Pure RTL, no soft‑core CPU** | Deterministic timing, minimal resource usage, full timing control. Avoids Linux‑on‑FPGA complexity for the real‑time path. |
| **Trigger‑less continuous capture as baseline** | Preserves all signal information; conventional triggering is a *downstream* software choice, not a hardware limitation. |
| **Separate trigger path from data path** | Trigger logic runs in parallel with the circular buffer write — no dead‑time during event detection. |
| **Continuous capture vs. trigger arbitration** | When both modes are active, the TX FIFO arbitrator must enforce fairness so trigger events are not starved by bulk streaming, and vice versa. Design can also operate in pure continuous mode (trigger disabled, all bandwidth to samples). |
| **Status path per block** | Required for self‑diagnosis (see §6). |
| **FT232H DPTI for host link** | On-board FT232H provides synchronous FIFO at 60 MHz (~7 MB/s sustained empirical, ~30 MB/s theoretical). Primary bottleneck — forces trigger-based event selection. Low-cost, no external hardware needed. |
| **HDF5 / ROOT output at host** | Both formats are standard in nuclear and ML communities; HDF5 is preferred for Python‑based ML workflows. |
| **Event window configurable** | 1800-sample default (600 pre + 1200 post = 17.14 µs). `cfg_pre`/`cfg_post` parameterisable. 512-sample window suffices for rising-edge physics while tripling event throughput. |
| **Glitch filter on real-time path** | 3-stage temporal up-down pattern detector between CDC FIFO and downstream processing. Separate `always` blocks required to prevent Vivado SRL32 inference. Adds 2-cycle pipeline latency accounted for in timestamp generation. |
| **Baseline estimator (planned)** | First-order IIR (EWMA) running average. ~0 DSP, <100 LUTs, 1 register per channel. Alpha N=8–12 for 2.5–40 µs time constant. |

---

## 6. Observability and Self‑Diagnosis

Each functional block is equipped with both a **data path** and a **status path**, enabling real‑time monitoring and self‑diagnosis.

| Block | Status Signals |
|---|---|
| **ADC** | Clock lock status, sample counter, bit‑error counter, over‑range counter |
| **CDC FIFO** | Fill level, overflow flag, underflow flag |
| **Circular Buffer** | Write pointer, read pointer(s), wrap‑around count |
| **Trigger Logic** | Trigger count (total / accepted / rejected), rate estimate |
| **Descriptor FIFO** | Fill level, overflow flag, lost‑event counter |
| **TX FIFO / USB** | Fill level, underflow, packet‑error count, retry count |

This built‑in observability transforms the acquisition system into a truly characterised instrument—an essential feature for high‑rate experiments where dead‑time and data loss often go unnoticed.

Diagnostic counters are:
- logged alongside every waveform in the output dataset,
- accessible via a slow‑control register interface,
- pollable by the host to generate live dashboards.

---

## 7. Literature Review & Related Work

### 7.1 FPGA Waveform Digitizers for Nuclear & Particle Physics

**"A 500 MS/s waveform digitizer for PandaX dark matter experiments"** — He et al. (2021) [1]

> Key reference. Presents an FPGA‑based digitizer supporting both external‑trigger and **triggerless readout**. The triggerless mode writes all samples into a circular buffer and streams out on request. Achieves 500 MS/s with 14‑bit resolution. Closely aligned with our continuous‑capture approach.

**"FPGA code for the data acquisition and real‑time processing prototype of the ITER Radial Neutron Camera"** — Fernandes et al. (2018) [2]

> Real‑time FPGA DAQ for high‑rate neutron diagnostics. Demonstrates trapezoidal filtering, pile‑up rejection, and baseline restoration in FPGA logic. Useful reference for on‑chip pulse processing.

**"FPGA based High Speed Data Acquisition System for High Energy Physics Application"** — Mandal et al. (2015) [3]

> General‑purpose FPGA DAQ architecture for HEP. Covers fault‑tolerant communication, data serialisation, and host interface design.

**"A data acquisition system based on ROOT and waveform digital technology for Photo‑Neutron Source"** — Liu et al. (2017) [4]

> DAQ system integrating waveform digitizers with the ROOT framework. Demonstrates the waveform→ROOT pipeline.

### 7.2 HPGe Digitizer Performance Studies

**"Analysis and Verification of Relation between Digitizer's Sampling Properties and Energy Resolution of HPGe Detectors"** — Zhu et al. (2020) [5]

> CDEX experiment study quantifying how digitizer sampling rate, resolution, and noise shape HPGe energy resolution. Provides quantitative motivation for digitizer specifications: 14+ bit ENOB, ≥100 MS/s recommended for good energy resolution at typical gamma energies.

**"CDEX dark matter experiment: Status and prospects"** — Ma et al. (2017) [6]

> Overview of the CDEX HPGe dark matter experiment at CJPL. Describes the p‑type point‑contact HPGe detector technology, background suppression, and DAQ requirements.

**"Identification of single events in the HPGe detector: Comparison of various methods based on the analysis of simulated pulse shapes"** — Bakalyarov et al. (2002) [7]

> Early comparison of pulse‑shape analysis methods (library matching, neural networks, statistical moments) for HPGe event localisation. Foundation for ML‑based pulse processing.

### 7.3 FPGA DAQ Infrastructure & Tools

**"Application of FPGA Acceleration in ADC Performance Calibration"** — Yuan et al. (2018) [8]

> FPGA‑based ADC calibration methods (histogram, sine‑wave fitting) that can be integrated into the DAQ chain for real‑time self‑calibration.

**"Development of the firmware logic validation system using the FPGA accelerator"** — Mizuhiki et al. (2025) [9]

> Very recent work on FPGA firmware validation for particle physics. Important for our own verification methodology.

### 7.4 Gap Analysis

| What exists | What is missing | Our contribution |
|---|---|---|
| Commercial digitizers (CAEN, Struck, XIA) | Closed firmware, proprietary format, high cost | Open HDL + open data format |
| Triggerless digitizer (PandaX [1]) | Specific to LXe TPC, not HPGe; not open‑source | HPGe‑optimised, fully open |
| HPGe pulse‑shape studies [7] | No accompanying open dataset | Open waveform dataset with metadata |
| FPGA DAQ examples [2][3][4] | Not HPGe‑specific, partial open‑source | Complete, documented HPGe acquisition chain |
| CDEX research [5][6] | Commercial or in‑house digitizers; designs not published | Reproducible low‑cost alternative |

---

## 8. Expected Contributions

The system will deliver:

1. **An open‑source FPGA DAQ architecture**, fully documented and synthesizable, targeting COTS FPGA boards.
2. **A reproducible pipeline** for generating HPGe waveform datasets—complete with metadata and self‑diagnostic logs.
3. **High‑rate waveform streaming capability**, supporting both continuous capture and triggered modes with minimal dead‑time.
4. **A characterised instrument** with built‑in observability, enabling real‑time monitoring of DAQ health and data quality.
5. **A foundation for ML‑based detector research**, providing the raw data required for training and evaluating advanced algorithms (pile‑up recovery, pulse‑shape discrimination, background rejection).

By providing an open, transparent platform, we move the DAQ from a passive black‑box digitizer to an active experimental tool that empowers both hardware and ML communities.

---

## 9. Prospective Technical Specifications

*Hardware-constrained specifications based on Digilent USB104 A7 + Zmod ADC 1410-105.*

| Parameter | Value | Notes |
|---|---|---|
| **Board / FPGA** | Digilent USB104 A7 Rev. B.2 / XC7A100T-1CSG324I | ~101K logic cells, 4,860 Kb BRAM, 240 DSP slices |
| **ADC module** | Zmod ADC 1410-105 / AD9648 | Dual 14-bit, 105 MSPS, interleaved CMOS output |
| **ADC resolution** | 14 bit | ENOB ≥ 11.0 @ 105 MS/s (AD9648 datasheet) |
| **Sampling rate** | 105 MS/s (fixed max) | ≥100 MS/s satisfies HPGe requirement per [5] |
| **Number of channels** | 2 (interleaved CMOS bus) | Ch A on DCO rising edge, Ch B on falling edge |
| **Input range** | ±1 V / ±2.5 V (programmable) | Gain set via SPI or I²C before run |
| **Input coupling** | AC / DC (per channel) | Controlled via SYZYGY control signals |
| **ADC interface** | Single-ended LVCMOS18, 14-bit parallel | No LVDS, no SERDES — simple IDDR deinterleaver |
| **Glitch filter** | 3-stage up-down pattern detector | HW removal of AD9648 0x0C98 artifact, threshold=500, 100% effective (verified 0/912K samples) |
| **Host interface** | On-board FT232H DPTI (synchronous FIFO) | 8-bit bidirectional, 60 MHz, ~30 MB/s sustained |
| **Sustained throughput (theoretical)** | ~30 MB/s | Limited by USB 2.0 HS + FT232H overhead |
| **Sustained throughput (empirical)** | **~7 MB/s** | Measured with DPTI round-robin PHY on this platform |
| **Burst throughput** | ~60 MB/s (short bursts) | FT232H FIFO absorbs bursts before USB DMA |
| **Max event rate (1800-samp window)** | ~1,900 evt/s @ 7 MB/s | Dominated by FT232H bottleneck |
| **Max event rate (512-samp window)** | ~6,700 evt/s @ 7 MB/s | Sufficient for most HPGe use cases |
| **Circular buffer depth** | ~300K samples max (theoretical) / **8192 samples (current impl.)** | 8192×16 = 3 BRAMs. 2-level buffering: capture memory separate from transport memory (TX FIFO 4096×16). |
| **Event window size** | **1800 samples** (600 pre + 1200 post) = **17.14 µs** @ 105 MSPS | Physics-critical rising edge (~200 ns = 21 samples) fully captured. `cfg_pre`/`cfg_post` parameterisable. |
| **Glitch filter threshold** | 500 counts (configurable) | 3-stage up-down pattern detector. Catches both baseline and mid-pulse glitches. |
| **Trigger modes** | Leading‑edge, CFD, external, continuous (burst) | Aggressive selection needed due to host link limit |
| **Output packet format** | Self-describing binary frames over DPTI | 32‑byte header (magic, type, length, timestamp, board ID, fw version, seq); see Architecture.md §Host Interface |
| **Host file format** | HDF5 (primary) / ROOT | `/waveforms`, `/diagnostics`, `/run_metadata`, `/configuration` |
| **Metadata per run** | Board ID, firmware version, run time, ADC config, register dump | Injected as HDF5 attributes + periodic diagnostic frames |
| **Target toolchain** | Xilinx Vivado (free WebPACK) | XC7A100T supported; open-source Yosys/nextpnr experimental for Artix‑7 |

---

## 10. Research Plan & Milestones

### Phase 1: Platform Design (Months 1–6)
- [x] Research direction defined
- [x] Selected board: Digilent USB104 A7 + Zmod ADC 1410-105
- [x] RTL for ADC CMOS interface (IDDR deinterleaver, SAME_EDGE_PIPELINED) + CDC FIFO (XPM async, depth 64)
- [x] Circular buffer (8192×16, 3 BRAMs) — implement 2-level buffering architecture (Issue 001): capture memory separated from transport memory (TX FIFO 4096×16)
- [x] Trigger logic (leading-edge, neg-edge, programmable threshold/hysteresis, hold-off)
- [x] FT232H DPTI synchronous FIFO host interface (~7 MB/s sustained)
- [x] CDCE6214 I²C clock generator init (22 reg writes) — enables analog front-end power
- [x] AD9648 SPI init (20-step, 2-wire ADI SPI)
- [x] HW glitch filter: 3-stage temporal up-down pattern detector (100% effective against 0x0C98 artifact)
- [x] Test with synthetic pulser signal (triangle ramp, 1 kHz pulses)
- [x] DPTI round-robin arbitration + event pipeline FSM (descriptor FIFO → waveform reader → TX FIFO → host)
- [ ] AD9648 glitch root-cause experiments (DCO invert, clock divide, test patterns via SPI register writes)
- [ ] Characterise empirical throughput ceiling and identify DPTI PHY overhead sources

### Phase 2: HPGe Integration (Months 7–12)
- [ ] Interface with HPGe preamplifier (shaping amplifier bypassed or minimal)
- [ ] Characterise noise floor, baseline stability
- [ ] Implement baseline estimator (EWMA, <100 LUTs, 0 DSP)
- [ ] Implement trapezoidal/pulse shaping filter in FPGA
- [ ] Implement runtime-configurable `cfg_pre`/`cfg_post` event window via DPTI command
- [ ] Implement CFD trigger mode for improved timing resolution
- [ ] Validate against commercial digitizer (CAEN V1724 or similar)
- [ ] Publish initial dataset (calibration sources: ⁶⁰Co, ¹³⁷Cs, ²²Na)

### Phase 3: Advanced Features & ML Pipeline (Months 13–18)
- [ ] Implement continuous‑capture burst mode with metadata tagging
- [ ] Build self‑diagnosis / observability dashboard (host-side, live telemetry from diagnostic counters)
- [ ] Evaluate 2-level buffering burst capacity in hardware (back-to-back triggers, lost_event_counter validation)
- [ ] Publish open waveform dataset (≥10⁶ pulses) with full provenance metadata
- [ ] Develop baseline ML benchmarks: pulse‑shape classification, energy estimation, pile‑up detection
- [ ] Contribute to open‑source FPGA toolchain (Yosys/nextpnr) if needed

### Phase 4: Publication & Community (Months 19–24)
- [ ] Open‑source all HDL, software, and documentation
- [ ] Journal publication (NIM A / IEEE TNS) — see novelty analysis in sig_recorder issue documents
- [ ] Workshop / tutorial for reproducible HPGe DAQ

---

## References

1. C. He et al., *"A 500 MS/s waveform digitizer for PandaX dark matter experiments"*, 2021. arXiv: [2108.11804](https://arxiv.org/abs/2108.11804)
2. A. Fernandes et al., *"FPGA code for the data acquisition and real‑time processing prototype of the ITER Radial Neutron Camera"*, 2018. arXiv: [1806.06150](https://arxiv.org/abs/1806.06150)
3. S. Mandal et al., *"FPGA based High Speed Data Acquisition System for High Energy Physics Application"*, 2015. arXiv: [1503.08819](https://arxiv.org/abs/1503.08819)
4. L. X. Liu et al., *"A data acquisition system based on ROOT and waveform digital technology for Photo‑Neutron Source"*, 2017. arXiv: [1710.09964](https://arxiv.org/abs/1710.09964)
5. J. Zhu et al., *"Analysis and Verification of Relation between Digitizer's Sampling Properties and Energy Resolution of HPGe Detectors"*, 2020. arXiv: [2010.12420](https://arxiv.org/abs/2010.12420)
6. H. Ma et al., *"CDEX dark matter experiment: Status and prospects"*, 2017. arXiv: [1712.06046](https://arxiv.org/abs/1712.06046)
7. A. M. Bakalyarov et al., *"Identification of single events in the HPGe detector: Comparison of various methods based on the analysis of simulated pulse shapes"*, 2002. arXiv: [hep-ex/0203017](https://arxiv.org/abs/hep-ex/0203017)
8. G. Yuan et al., *"Application of FPGA Acceleration in ADC Performance Calibration"*, 2018. arXiv: [1806.04716](https://arxiv.org/abs/1806.04716)
9. R. Mizuhiki et al., *"Development of the firmware logic validation system using the FPGA accelerator"*, 2025. arXiv: [2503.18357](https://arxiv.org/abs/2503.18357)
