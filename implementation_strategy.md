# Implementation Strategy — data_engine FPGA Acquisition Pipeline

**Date:** 2026-06-30
**Board:** Digilent USB104 A7 (XC7A100T-1CSG324I) + Zmod ADC 1410-105 (AD9648)
**Architecture reference:** `Architecture.md` (especially §12 Debug & Validation Architecture)

---

## 1. Design Principle

**Hardware confidence first, debug infrastructure second.** The #1 risk is not debug observability — it's whether the ADC data reaches the PC at all. Therefore:

1. Build the **minimum viable acquisition path** first (ADC → FPGA → PC)
2. **Smoke-test on real hardware** — see actual ADC samples arriving via USB
3. Only then add pipeline features and debug infrastructure on top of a known-good foundation

Debug ports (`dbg_if`) are designed into each module's interface from day one, but the Audit Aggregator and BIST are built *after* the hardware smoke test confirms the acquisition chain works.

**Implementation approach: port from sig_recorder, don't build from scratch.** The reference implementation at `/home/adminministrator/Dropbox/FPGA/DIGILENT/sig_recorder/` has working, hardware-verified RTL for every Phase 1-2 module (ADC SPI init, CDCE I²C init, comm_dpti with CDC, circular buffer, trigger, waveform reader, descriptor FIFO, TX FIFO, top integration, and host Python DAQ). Each module should be **ported from sig_recorder and wrapped with `dbg_if` + `sample_token_t`**, not written from datasheets. This cuts Phase 1-2 timeline by ~50% and eliminates the top 3 Phase 1 risks (DCO lock, SPI init, DPTI protocol) — all already proven in sig_recorder on this exact board with timing MET.

---

## 2. Implementation Phases

```
Phase 0 ──► Foundation packages (sim-only, 3 days)
                │
                ▼
Phase 1 ──► MINIMUM VIABLE ACQUISITION PATH ─────► HARDWARE SMOKE TEST
                │  ADC interface + CDC FIFO + DPTI      │  See ADC data on PC
                │  bridge + streaming top                │  (Week 1-2)
                │                                       │
                ▼                                       │
Phase 2 ──► Pipeline features ──────────────────────────┤
                │  glitch filter, circular buffer,       │  Re-use same top,
                │  trigger, descriptor FIFO,             │  same host script
                │  waveform reader, TX FIFO              │
                │                                       │
                ▼                                       │
Phase 3 ──► Debug infrastructure ───────────────────────┤
                │  Audit Aggregator + register map +     │  Poll debug regs
                │  dbg_if wiring + snapshot frames       │  during acquisition
                │                                       │
                ▼                                       │
Phase 4 ──► BIST + host software ───────────────────────┤
                │  BIST pattern gen, dbg_client.py,      │  Validate pipeline
                │  daq.py, bist_runner.py                │  from PC only
                │                                       │
                ▼                                       ▼
Phase 5 ──► Full hardware validation
                │  Pulse gen 1 kHz → 10 kHz
                │  Throughput characterisation
                │  lost_event_counter accuracy
```

### Phase 0 — Foundation Packages (sim-only, ~4 files, ~150 lines)

Build the shared type definitions. Everything else imports these. No hardware needed.

| Step | File | Contents |
|:----:|------|----------|
| 0.1 | `rtl/pkg/pipeline_pkg.sv` | `sample_token_t` (53-bit packed: valid[1] + sample[16] + seq_id[32] + flags[4]), `frame_type_t` enum, `descriptor_t` struct (160-bit packed) |
| 0.2 | `rtl/pkg/dbg_pkg.sv` | `dbg_info_t` (128-bit packed, 32-bit-aligned for 4-register access), `dbg_if` interface definition. See `docs/debug_register_map.md` for field layout |
| 0.3 | `rtl/pkg/register_map_pkg.sv` | Address map constants (all blocks, 0x20 spacing per block). Derived from `docs/debug_register_map.md` |
| 0.4 | `tb/tb_types.sv` | Prove all three packages' types pack/unpack correctly in simulation |

**Milestone:** Types compile in both iverilog (unit sim) and Vivado xvlog (integration sim). `sample_token_t` packs to exactly 53 bits. `dbg_info_t` packs to exactly 128 bits (4 × 32-bit registers). `descriptor_t` packs to exactly 160 bits.

---

### Phase 1 — Minimum Viable Acquisition Path → HARDWARE SMOKE TEST 🚀

This is the most important phase. Build just enough to see real ADC data on the PC.

| Step | File | Contents |
|:----:|------|----------|
| 1.0 | `rtl/adc_init/adc_spi_init.v` + `rtl/adc_init/cdce_iic_init.v` | **Port from sig_recorder** (`/home/adminministrator/Dropbox/FPGA/DIGILENT/sig_recorder/src/`). AD9648 20-step SPI init + CDCE6214 22-reg I²C init. Verified working on this exact board. No modifications needed. |
| 1.1 | `rtl/adc_interface/adc_interface.sv` + `tb/tb_adc_interface.sv` | IDDR deinterleaver (SAME_EDGE_PIPELINED), configurable channel select. **With `dbg_if` port** (DCO lock state, error, word_count). TB: model ADC DDR data, verify deinterleave + DCO loss detect |
| 1.2 | `rtl/cdc_fifo/cdc_fifo.sv` + `tb/tb_cdc_fifo.sv` | **One wide async FIFO** (`xpm_fifo_async`, 32-bit: ch_a[15:0]+ch_b[15:0]), adc_dco → sys_clk. **With `dbg_if` port** (fill level, overflow flag, event_count). TB: write/read, overflow, CDC correctness |
| 1.3 | `rtl/ft232h_dpti/comm_dpti.sv` + `tb/tb_comm_dpti.sv` | **Port from sig_recorder** `comm_dpti.v` — DPTI sync FIFO protocol, **toggle-handshake CDC (sys_clk → ft_clk handled internally, no separate TX FIFO needed in Phase 1)**. Add `dbg_if` port (TX stall count, bytes_sent, protocol errors). TB: byte TX/RX, stall handling |
| 1.4 | `rtl/top_stream.sv` | **Minimal streaming top** — 100 MHz onboard osc as sys_clk (BUFG-buffered, no PLL/MMCM, per sig_recorder). ADC → CDC FIFO → decimator (1:32, ~6.5 MB/s) → comm_dpti. **Sends 16-bit sample only** (2 bytes LE on wire — no seq_id/flags/frame header in Phase 1). No trigger, no buffer, no glitch filter. |
| 1.5 | `constraints/timing.xdc` | `read_xdc` the existing `hardware_spec/USB104_A7_Zmod_ADC1410.xdc` + append data_engine-specific constraints (CDC false paths, DPTI timing, debug signal false paths). Do not rewrite pin constraints. |
| 1.6 | `tb/tb_stream.sv` | Simulate full streaming path: model ADC DDR data → verify bytes arrive at DPTI output |
| 1.7 | `host/stream_receiver.py` | Minimal Python script: open FT232H, read bytes, parse 16-bit samples, print min/max/rate |

**Phase 1 top-level (`top_stream.sv`) is deliberately simple:**

```
100 MHz osc (E3) ── BUFG ── sys_clk (no PLL, per sig_recorder)
                                │
ADC (AD9648)                     │
    │ 14-bit DDR CMOS            │
    ▼                            │
ADC Interface ─── dco_clk (~105 MHz)
    │ ch_a[15:0] + ch_b[15:0] (packed 32-bit)
    ▼
CDC FIFO (xpm_fifo_async) ─── crosses to sys_clk (100 MHz)
    │ 32-bit packed sample
    ▼
Decimator (1:32) ─── ~6.5 MB/s, within FT232H empirical bandwidth
    │ 16-bit sample (2 bytes LE on wire — no seq_id/flags/frame header)
    ▼
DPTI Bridge ──── toggle-handshake CDC to ft_clk (60 MHz), 8-bit bytes
    │
    ▼
FT232H ──────── USB to PC
```

**No glitch filter, no circular buffer, no trigger, no descriptor FIFO.** Decimated streaming — validates the full data path (ADC → IDDR → CDC → DPTI → PC) at a feasible rate. Full-rate streaming at 105 MS/s × 16-bit = 210 MB/s is inherently impossible over FT232H (7-30 MB/s); Phase 2 event mode (triggered, 1800-sample windows) is the rate-matching solution.

**`stream_receiver.py` logic:**
```python
import pyftdi

def stream_test(duration_s=10):
    dev = open_ft232h()
    start = time.time()
    bytes_read = 0
    while time.time() - start < duration_s:
        buf = dev.read(4096)
        bytes_read += len(buf)
        # Parse 16-bit little-endian samples
        for i in range(0, len(buf)-1, 2):
            sample = buf[i] | (buf[i+1] << 8)
            # Track min/max for visual confirmation
    rate = bytes_read / (time.time() - start)
    print(f"Throughput: {rate/1e6:.1f} MB/s")
```

#### 🚀 PHASE 1 HARDWARE SMOKE TEST

| Step | What | Pass criteria |
|:----:|------|--------------|
| H1 | Synthesize `top_stream.sv` | Timing MET, no DRC errors |
| H2 | Program FPGA, run `stream_receiver.py` with ADC inputs floating | See decimated ADC samples (mid-code ~8192 with floating inputs). Confirm samples vary (not stuck at 0 or 0xFFFF). |
| H3 | Connect pulse generator (1 kHz, 1 Vpp) to CH1 input | See pulses in the sample stream. Confirm ADC captures the full waveform shape. |
| H4 | Check `dbg_if` registers via LED or debug header | DCO lock status visible, CDC overflow flag behavior (some overflow expected — decimator doesn't backpressure), DPTI stall count reasonable |
| H5 | Run for 60 seconds at 1 kHz | CDC overflow counter does not grow unbounded (decimation prevents full-rate accumulation). Zero DPTI protocol errors. |

**If any step fails, stop and fix before proceeding.** A bug found here costs minutes. A bug found after adding circular buffer/trigger costs hours.

---

### Phase 2 — Pipeline Features (est. 7 modules)

Add the feature blocks one at a time, each with `dbg_if`. Each is independently simulable. After each module, re-run the hardware smoke test to confirm no regression. Each module is **ported from sig_recorder** (`/home/adminministrator/Dropbox/FPGA/DIGILENT/sig_recorder/src/`) and wrapped with `dbg_if` + `sample_token_t` — not written from scratch.

| Step | Module | Key `dbg_if` exposure | Testbench |
|:----:|--------|-----------------------|-----------|
| 2.1 | Glitch filter (3-stage up-down, new — not in sig_recorder) | glitch_count, max_jump, bypass | `tb_glitch_filter` |
| 2.2 | Circular buffer (8192×16) — **port from sig_recorder** `circular_buffer.v` | wr_ptr, rd_ptr, wrap_count, collision flag | `tb_circular_buffer` |
| 2.3 | Trigger (**LEADING_EDGE only** — port from sig_recorder `trigger.v`; CFD deferred to Phase 2.5; ML trigger out of scope — requires dataset first) | FSM state, trigger_count, holdoff_remaining | `tb_trigger` |
| 2.4 | Descriptor FIFO (64×160) — **port from sig_recorder** `event_descriptor_fifo.v`, widen 106→160 bit | fill_level, overflow, lost_event | `tb_descriptor_fifo` |
| 2.5 | Waveform reader — **port from sig_recorder** `waveform_reader.v` | FSM state, events_read, remaining | `tb_waveform_reader` |
| 2.6 | TX FIFO (4096×16 dual-clock) — **port from sig_recorder** `tx_wave_fifo.v` | fill_level, watermark, overflow | `tb_tx_fifo` |
| 2.7 | `top_pipeline.sv` (full integration) | All | `tb_pipeline` |

**Note: Continuous Capture (Architecture §7) is deferred** — not implemented in the initial release. It's burst-only at 105 MS/s (exceeds FT232H link by 6-50×) and not required for triggered HPGe event acquisition. HPGe event mode (triggered, 1800-sample windows) is the primary use case.

**After each module:** synthesize, program, and smoke-test with pulse generator. Regression suite:
- Bypass new module → confirm streaming still works
- Enable new module → confirm its function works
- Read its `dbg_if` register via debug header LEDs or simple DPTI command

---

### Phase 3 — Debug Infrastructure

Now that the pipeline is verified on hardware, add the centralized debug layer.

| Step | File | Contents |
|:----:|------|----------|
| 3.1 | `rtl/audit_aggregator/audit_aggregator.sv` | Collects all `dbg_if` ports, register address decode, periodic diagnostic snapshot (frame type `0x04`), CDC synchronisers for dco_clk/ft_clk domains |
| 3.2 | `rtl/top.sv` **update** | Replace `top_stream.sv` / `top_pipeline.sv` with full top that includes Audit Aggregator. Add DPTI command decoder for register read/write (§12.4 protocol) |
| 3.3 | `tb/tb_audit_aggregator.sv` | Verify every register address is readable/writable, snapshot packet format correct |
| 3.4 | `tb/tb_pipeline_debug.sv` | Full pipeline + debug: read all debug registers via model DPTI during acquisition, verify they reflect live state |

**Hardware test (after 3.2):**
- Write DPTI command to read `glitch_filter.dbg.event_count` → get correct count of glitches filtered
- Write DPTI command to read `trigger.dbg.event_count` → get correct trigger count
- Poll all debug registers during acquisition → verify they don't interfere with data stream

---

### Phase 4 — BIST + Host Software

| Step | File | Contents |
|:----:|------|----------|
| 4.1 | `rtl/bist/bist_pattern_gen.sv` | LFSR-16, ramp, alternating, pulse, glitch-injected patterns. Mux selects between ADC data and BIST data at pipeline input |
| 4.2 | `rtl/top.sv` **update** | Add BIST mux at pipeline input (before ADC interface). Wire BIST control to register map |
| 4.3 | `host/dbg_client.py` | Python class: `read_reg(addr)`, `write_reg(addr, data)`, `poll_all()`, `continuity_check()` |
| 4.4 | `host/bist_runner.py` | `run_bist(pattern_id, cycles)` → poll results → pass/fail per block |
| 4.5 | `host/daq.py` | Full acquisition loop: streaming + triggered modes, background debug polling, ROOT output |
| 4.6 | `tb/tb_bist.sv` | BIST patterns produce expected waveforms. Error injection test. |

---

### Phase 5 — Full Hardware Validation

| Test | Duration | Pass criteria |
|:----:|:--------:|--------------|
| BIST all patterns | 1 min | All blocks PASS for all 5 patterns |
| Pulse gen 1 kHz, 1000 events | 30 s | No seq_id gaps, lost_event_counter = 0 |
| Pulse gen 5 kHz, 5000 events | 30 s | Measure event rate, verify no buffer overflow |
| Pulse gen 10 kHz, 10000 events | 30 s | Max event rate characterisation, lost_event_counter accuracy |
| Continuous streaming 10 s | 10 s | Throughput measurement (target >7 MB/s) |
| DPTI backpressure test | 10 s | FT232H stall counter increments, no data corruption |
| 24-hour soak | 24 hr | Zero errors, zero lost events |

---

## 3. Pulse Generator vs. HPGe Detector — When to Use What

Your pulse generator (controllable rise time, decay time, frequency, amplitude, polarity) can simulate HPGe pulses well enough for **all hardware development and validation**. The real HPGe detector is only needed for the final scientific validation and dataset generation.

### Pulse Generator Capabilities vs. HPGe Requirements

| Parameter | Pulse Generator | HPGe Detector + Preamp | Can pulse gen simulate it? |
|-----------|:---------------:|:----------------------:|:--------------------------:|
| Rise time | ~10 ns – 100 µs | 100–1000 ns (planar/coaxial) | ✅ Yes, set to 200–500 ns |
| Decay tail | ~100 ns – 10 ms | 50–200 µs (preamplifier) | ✅ Yes, set to 50–100 µs |
| Amplitude | ~10 mV – 10 V | ~1 mV – 1 V (depending on energy) | ✅ Yes |
| Polarity | Positive/negative | Positive (typical for HPGe) | ✅ Yes |
| Rate | Single-shot – 10 MHz | 0.1–10 kHz typical | ✅ Yes, 1–10 kHz |
| Amplitude jitter | Low (ideal) | Present (energy resolution) | ❌ No — but not needed for DAQ validation |
| Rise time variation | None (fixed) | Position-dependent (for PSD) | ❌ No — but this is physics, not DAQ |
| Noise characteristics | Clean | 1/f + series noise from HV bias | ❌ No — but can inject external noise |
| Random arrival (Poisson) | Periodic | True random | ❌ Periodic only — acceptable for trigger testing |

### When to Switch to HPGe

| Phase | Pulse gen sufficient? | HPGe needed? | What changes with HPGe |
|:-----:|:--------------------:|:------------:|------------------------|
| **1** — Hardware smoke test | ✅ Yes | ❌ No | Nothing. If streaming works with pulse gen, it works with HPGe. |
| **2** — Pipeline features | ✅ Yes | ❌ No | Trigger threshold tuning, glitch filter bypass verification. Maybe re-tune threshold for real noise floor. |
| **3** — Debug infrastructure | ✅ Yes | ❌ No | Debug registers work identically regardless of signal source. |
| **4** — BIST + host software | ✅ Yes | ❌ No | BIST uses internal patterns — no external signal needed at all. |
| **5** — Full validation (throughput, errors) | ✅ Yes | ❌ No | Error rates, throughput, lost_event_counter are independent of signal shape. |
| **📄 Pre-publication validation** | ❌ No | ✅ **Yes** | Peer reviewers will want to see real HPGe waveforms. Confirm PSD-relevant features preserved. |
| **📊 Open dataset generation** | ❌ No | ✅ **Yes** | The project's goal is an open HPGe waveform dataset for ML research. Pulse gen data is a proxy, not the real thing. |

### Recommended HPGe Deployment Plan

```
Phase 1-5 (6 weeks) ──────► Pulse generator only
                               │
                               ▼
Pre-publication validation ──► Rent/borrow HPGe + preamp + HV supply
(1 week)                       │  Validate: waveform fidelity, noise floor,
                               │  trigger threshold for real HPGe pulses
                               │
                               ▼
Open dataset acquisition ────► Dedicated HPGe setup
(1-4 weeks)                    │  Acquire 10⁵–10⁶ events at multiple energies
                               │  Publish dataset + platform paper
```

### What You Can Validate Without HPGe (and What You Can't)

**Can validate with pulse generator:**
- ADC linearity, DCO lock stability, CDC FIFO integrity
- Glitch filter accuracy (inject 0x0C98 at known times, verify filter catches them)
- Trigger threshold accuracy (set known pulse amplitude, verify trigger fires at expected level)
- Event window sizing (known rise/decay time, verify pre/post samples correct)
- Throughput characterisation (up to 10 kHz pulse rate)
- Lost event counter accuracy (saturate descriptor FIFO, verify counter matches)
- BIST pipeline validation (internal patterns, no external signal)
- 24-hour soak stability

**Cannot validate without HPGe:**
- Position-dependent rise time preservation (requires real gamma interactions)
- HPGe-specific noise floor characterisation (preamplifier + HV bias noise)
- Trigger threshold for low-energy pulses near noise floor
- Pole-zero correction accuracy for real preamp decay times
- Dataset quality for ML training (real HPGe waveform diversity)

**Bottom line:** You can develop, debug, and validate 95% of the platform with your pulse generator alone. Bring in the HPGe only for the final 5% — the pre-publication validation and dataset generation.

---

## 4. File Creation Order (Build Schedule)

Each phase is independently testable. Phase 1 includes the **hardware smoke test** — the critical go/no-go decision point.

```
Week 1 — Foundation (sim only)
  Day 0:  git init + .gitignore + custom non-commercial academic license (at data_engine/ root)
          docs/debug_register_map.md — full field-level register map (contract for all RTL + host)
  Day 1:  rtl/pkg/pipeline_pkg.sv + rtl/pkg/dbg_pkg.sv + rtl/pkg/register_map_pkg.sv
  Day 2:  tb/tb_types.sv — prove types compile and pack correctly (iverilog + xvlog)

Week 2 — MINIMUM VIABLE ACQUISITION PATH + HARDWARE SMOKE TEST 🚀
  Day 1:  rtl/adc_init/adc_spi_init.v + rtl/adc_init/cdce_iic_init.v (copy from sig_recorder)
          rtl/adc_interface/adc_interface.sv + tb/tb_adc_interface.sv
  Day 2:  rtl/cdc_fifo/cdc_fifo.sv + tb/tb_cdc_fifo.sv
  Day 3:  rtl/ft232h_dpti/comm_dpti.sv + tb/tb_comm_dpti.sv (port from sig_recorder)
  Day 4:  rtl/top_stream.sv + constraints/timing.xdc + host/stream_receiver.py
          tb/tb_stream.sv — simulate streaming path
  Day 5:  SYNTHESIZE + PROGRAM + HARDWARE SMOKE TEST ⭐
          (If this fails, STOP and fix. Don't proceed to Phase 2.)

Week 3 — Pipeline features (add one at a time, test each on hardware)
  Day 1:  rtl/signal_processing/glitch_filter.sv + tb/tb_glitch_filter.sv
          → update top, synthesize, test with pulse gen
  Day 2:  rtl/waveform_buffer/circular_buffer.sv + tb/tb_circular_buffer.sv
          → update top, synthesize, test
  Day 3:  rtl/trigger_logic/trigger.sv + tb/tb_trigger.sv
          rtl/descriptor_fifo/descriptor_fifo.sv + tb/tb_descriptor_fifo.sv
          → update top, synthesize, test
  Day 4:  rtl/waveform_reader/waveform_reader.sv + tb/tb_waveform_reader.sv
          rtl/tx_fifo/tx_fifo.sv + tb/tb_tx_fifo.sv
          → update top, synthesize, test

Week 4 — Full pipeline integration + debug infrastructure
  Day 1:  rtl/top_pipeline.sv (full pipeline, no debug agg yet)
          tb/tb_pipeline.sv — full integration simulation
          → synthesize, test with pulse gen
  Day 2:  rtl/audit_aggregator/audit_aggregator.sv + tb/tb_audit_aggregator.sv
  Day 3:  rtl/top.sv (full + debug agg + DPTI register read/write)
          tb/tb_pipeline_debug.sv
          → synthesize, test: read debug regs during acquisition
  Day 4:  rtl/bist/bist_pattern_gen.sv + tb/tb_bist.sv
          → update top with BIST mux, synthesize, test BIST over USB

Week 5 — Host software + full validation
  Day 1:  host/dbg_client.py + host/bist_runner.py
  Day 2:  host/daq.py
  Day 3:  Full hardware validation (pulse gen 1 kHz → 10 kHz, throughput)
  Day 4:  24-hour soak test
```

**Critical rule:** If the hardware smoke test (Week 2, Day 5) fails — no ADC data reaches the PC — stop and debug before writing any Phase 2 code. The most likely failure modes are:
- DCO not locking (check `dbg.state` via LED)
- FT232H not enumerating (check USB descriptors)
- ADC SPI/CDCE init sequence wrong (check scope on adc_clk_p/n)
- XDC timing constraints incorrect (check Vivado timing report)

**Toolchain:** Use **iverilog v12.0** for unit testbenches (Phase 0-2 per-module, fast compile ~10×). Use **Vivado xvlog** for integration testbenches (Phase 2.7, Phase 3-4 — full SystemVerilog interface + Xilinx primitive support). Use **Vivado batch synth** for all hardware builds. A `Makefile` at project root provides `make sim_unit`, `make sim_integ`, `make synth`, `make program` targets.

---

## 5. Key Risks & Mitigations

| Risk | Impact | When it hits | Mitigation |
|------|--------|:------------:|------------|
| **ADC DCO doesn't lock** | No data reaches FPGA | Phase 1 🚀 | ADC interface exposes DCO lock status via `dbg.state`. LED indicator. Quick fix: check XDC timing, check AD9648 SPI init sequence. |
| **FT232H doesn't enumerate / DPTI fails** | No USB communication | Phase 1 🚀 | Test FT232H with Digilent's own test utility first. Then test `comm_dpti` standalone with loopback. |
| **ADC SPI init sequence wrong** | ADC outputs zero or garbage | Phase 1 🚀 | `adc_spi_init` and `cdce_iic_init` verified in sig_recorder — re-use the same register sequences. Verify with scope on SPI lines. |
| **Clock domain crossing metastability** | Random bit errors in sample data | Phase 1 🚀 | CDC FIFO uses `xpm_fifo_async` (Xilinx Parameterized Macro — Xilinx handles Gray-code pointers and CDC internally, no hand-written pointer logic). Verify with `tb_cdc_fifo`. Check `dbg.error` (overflow/underflow) during hardware test. |
| **Glitch filter swallows valid pulses** | Lost events, hard to detect | Phase 2 | Glitch filter has `bypass` mode. Compare event rate with bypass on/off. `dbg.event_count` reveals false positives. |
| **Circular buffer wr_ptr collision during burst** | Corrupted event data | Phase 2 | `dbg.error` (collision flag) catches this. Inherently limited to 2 back-to-back events per §9 of Architecture.md. |
| **Audit Aggregator register map grows too large** | Address space exhaustion | Phase 3 | 16-bit address with block base + offset. Each block gets 16 registers (64 bytes). 10 blocks = 640 bytes. Trivial. |
| **dbg_if CDC across clock domains** | Metastability in debug readback | Phase 3 | Audit Aggregator runs on sys_clk. ADC Interface (dco_clk) debug signals synchronised via 2-stage FF. DPTI Bridge (ft_clk) debug is read-side synchronised. |
| **BIST mux adds latency to critical path** | Timing failure | Phase 4 | BIST mux is at pipeline INPUT, not inline. Selects between `adc_interface.sample_out` and `bist_pattern_gen.sample_out`. Zero added latency to real data path. |
| **Debug logic bloats LUT usage** | Resource exhaustion | Phase 3 | Each `dbg_if` ~15 registers + mux. 10 blocks = 150 regs + ~100 LUTs aggregator = **~250 LUTs total** (~4%). Synthesis-trimmed when unconnected. |
| **DPTI command polling interferes with data** | Debug reads disrupt acquisition | Phase 3+ | Debug polling is once/second, ~20 register reads = 80 bytes. Data stream is ~7 MB/s. Overhead **0.001%**. |

---

## 6. Test Coverage Matrix

| Testbench | Phase | Validates | Debug-specific checks |
|-----------|:-----:|-----------|----------------------|
| `tb_types.sv` | 0 | Types pack/unpack correctly, enums match expected values | — |
| `tb_adc_interface.sv` | 1 | IDDR deinterleave, DCO loss detect | `dbg.state` transitions, `dbg.error` on DCO loss |
| `tb_cdc_fifo.sv` | 1 | Write/read, overflow | `dbg.event_count` matches write side, `dbg.error` on overflow |
| `tb_comm_dpti.sv` | 1 | Byte TX/RX, stall handling | `dbg.stall_cycles` on TXE#, `dbg.event_count` (bytes) matches |
| `tb_stream.sv` | 1 | Full streaming path ADC→DPTI | Continuity token `seq_id` intact through pipeline |
| **🚀 Hardware smoke test** | **1** | **Real ADC data arrives at PC via USB** | **DCO lock, CDC overflow=0, DPTI protocol errors=0** |
| `tb_glitch_filter.sv` | 2 | Glitch removal, bypass, threshold | `dbg.event_count` matches injected glitch count |
| `tb_circular_buffer.sv` | 2 | Continuous write, burst read, wrap | `dbg.wr_ptr` live, `dbg.event_count` (wraps) matches |
| `tb_trigger.sv` | 2 | Threshold, hysteresis, hold-off | `dbg.event_count` matches trigger pulses, `dbg.state` transitions |
| `tb_descriptor_fifo.sv` | 2 | Push/pop, overflow | `dbg.event_count` matches, `dbg.error` on overflow |
| `tb_waveform_reader.sv` | 2 | Burst read, wrap, backpressure | `dbg.remaining` live, `dbg.stall_cycles` during TX full |
| `tb_tx_fifo.sv` | 2 | FWFT, full/empty, watermark | `dbg.watermark` captures max fill |
| `tb_pipeline.sv` | 2 | Full pipeline simulation, all blocks | Every block's `dbg` readable via model DPTI |
| `tb_audit_aggregator.sv` | 3 | Register R/W, snapshot generation | Every register readable/writable, snapshot format correct |
| `tb_pipeline_debug.sv` | 3 | Pipeline + debug agg integration | Live debug reads during acquisition don't corrupt data |
| `tb_bist.sv` | 4 | All 5 patterns, error injection | `dbg.error` on injected mismatch, passes on clean run |

---

## 7. First Steps (Immediate Action)

If you approve this strategy, I propose starting with **Phase 0**:

0. **`git init`** at `data_engine/` root. Add `.gitignore` for Vivado artifacts. Custom non-commercial academic/research license (see `LICENSE` — contact thnam@dnri.vn for commercial licensing).
1. **`docs/debug_register_map.md`** — Full register map with 16-bit address, 32-bit data, field bit offsets, R/W, reset values, descriptions. This is the authoritative contract between RTL, Audit Aggregator, and host software — define before coding.
2. **`rtl/pkg/dbg_pkg.sv`** — Define `dbg_info_t` (128-bit packed, 32-bit-aligned), `dbg_if`, `dbg_monitor_t`
3. **`rtl/pkg/pipeline_pkg.sv`** — Define `sample_token_t` (53-bit packed), `bist_pattern_t`, `frame_type_t`, `descriptor_t` (160-bit packed)
4. **`rtl/pkg/register_map_pkg.sv`** — Define address map constants (derived from `docs/debug_register_map.md`)
5. **`tb/tb_types.sv`** — Prove all three packages' types pack/unpack correctly in simulation (iverilog + xvlog)

After those files, every subsequent module has a foundation to build on.
