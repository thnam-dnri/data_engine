# data_engine — FPGA Acquisition Pipeline Makefile
#
# Targets:
#   make sim_unit                     — Run unit testbenches with iverilog
#   make sim_integ                    — Run integration testbenches with Vivado xvlog
#   make synth [TOP=<name>]           — Synthesize top with Vivado batch mode
#                                        (TOP defaults to $(SYNTH_TOP))
#   make program [TOP=<name>]         — Program bitstream to FPGA via hw_server
#   make clean                        — Remove build artifacts
#   make clean_sim                    — Remove simulation artifacts only
#   make clean_synth                  — Remove synthesis artifacts only

# --- Paths ---
RTL_DIR     := rtl
TB_DIR      := tb
CONST_DIR   := constraints
HW_SPEC_DIR := hardware_spec
BUILD_DIR   := build
SIM_DIR     := $(BUILD_DIR)/sim
SYNTH_DIR   := $(BUILD_DIR)/synth

# --- Toolchain ---
IVERILOG    := iverilog
VVP         := vvp
VIVADO      := vivado
VIVADO_MODE := -mode batch
HW_SERVER   := $(HOME)/Xilinx/2026.1/Vivado_Lab/bin/hw_server

# --- RTL source files (auto-collected) ---
# Packages are compiled separately from other RTL sources to avoid double-compilation
RTL_PKG     := $(wildcard $(RTL_DIR)/pkg/*.sv)
RTL_SRCS    := $(filter-out $(RTL_PKG),$(wildcard $(RTL_DIR)/*/*.sv) $(wildcard $(RTL_DIR)/*/*.v)) $(wildcard $(RTL_DIR)/top_*.sv)

# --- Simulation support files (Xilinx primitive models) ---
SIM_SUPPORT := $(wildcard sim/*.sv)

# --- Unit testbenches (iverilog, per-module) ---
# Dynamic discovery: only existing .sv testbenches are compiled.
# Exclude support modules that are not standalone testbenches.
TB_UNIT     := $(filter-out $(TB_DIR)/tb_top_pipeline_lite.sv,$(wildcard $(TB_DIR)/tb_*.sv))

# --- Support modules for testbenches (not standalone) ---
TB_SUPPORT  := $(TB_DIR)/tb_top_pipeline_lite.sv

# --- Integration testbenches (Vivado xvlog, coming in Phase 2.7) ---
TB_INTEG    := $(wildcard $(TB_DIR)/tb_integ_*.sv)

# --- Synthesis top (override with `make synth TOP=<name>`) ---
SYNTH_TOP   := top_pipeline
XDC_FILES   := $(HW_SPEC_DIR)/USB104_A7_Zmod_ADC1410.xdc $(CONST_DIR)/timing.xdc
PART        := xc7a100tcsg324-1

# --- Default target ---
.DEFAULT_GOAL := help

.PHONY: help sim_unit sim_integ synth program clean clean_sim clean_synth

help:
	@echo "data_engine Makefile targets:"
	@echo "  make sim_unit                       — Unit testbenches via iverilog"
	@echo "  make sim_integ                      — Integration testbenches via Vivado xvlog"
	@echo "  make synth [TOP=<name>]             — Synthesize top with Vivado batch"
	@echo "                                         (TOP defaults to $(SYNTH_TOP))"
	@echo "  make program [TOP=<name>]           — Program bitstream to FPGA"
	@echo "  make clean                          — Remove all build artifacts"
	@echo "  make clean_sim                      — Remove sim artifacts only"
	@echo "  make clean_synth                    — Remove synth artifacts only"

# =============================================================================
# Unit simulation (iverilog — fast, ~10x compile vs xvlog)
# Note: iverilog has incomplete SystemVerilog interface support.
#       Unit testbenches should use packed structs directly, not interfaces.
# =============================================================================

sim_unit: $(TB_UNIT:.sv=.vvp)

# Pattern rule: compile each standalone testbench to .vvp with iverilog
%.vvp: %.sv $(RTL_PKG) $(SIM_SUPPORT)
	@mkdir -p $(SIM_DIR)/unit
	@echo "=== Compiling $< with iverilog ==="
	$(IVERILOG) -g2012 -o $@ $(RTL_PKG) $(SIM_SUPPORT) $(RTL_SRCS) $< 2>&1 | tee $(SIM_DIR)/unit/$(notdir $@).log
	@echo "=== Running $@ ==="
	$(VVP) $@ 2>&1 | tee -a $(SIM_DIR)/unit/$(notdir $@).log

# Special rule: tb_top_pipeline depends on the lite wrapper
$(TB_DIR)/tb_top_pipeline.vvp: $(TB_DIR)/tb_top_pipeline.sv $(TB_DIR)/tb_top_pipeline_lite.sv $(RTL_PKG) $(SIM_SUPPORT)
	@mkdir -p $(SIM_DIR)/unit
	@echo "=== Compiling $< (+ tb_top_pipeline_lite.sv) with iverilog ==="
	$(IVERILOG) -g2012 -o $@ $(RTL_PKG) $(SIM_SUPPORT) $(RTL_SRCS) $(TB_DIR)/tb_top_pipeline_lite.sv $< 2>&1 | tee $(SIM_DIR)/unit/$(notdir $@).log
	@echo "=== Running $@ ==="
	$(VVP) $@ 2>&1 | tee -a $(SIM_DIR)/unit/$(notdir $@).log

# =============================================================================
# Integration simulation (Vivado xvlog — full SV interface + Xilinx primitive support)
# =============================================================================

sim_integ:
	@mkdir -p $(SIM_DIR)/integ
	@echo "=== Running integration testbenches with Vivado xvlog ==="
	$(VIVADO) $(VIVADO_MODE) -source scripts/sim_integ.tcl 2>&1 | tee $(SIM_DIR)/integ/run.log

# =============================================================================
# Synthesis (Vivado batch mode)
# Override the top with `make synth TOP=top_stream` (defaults to $(SYNTH_TOP)).
# The TOP variable is exported to the tcl script via the environment.
# =============================================================================

synth: TOP ?= $(SYNTH_TOP)
synth:
	@mkdir -p $(SYNTH_DIR)
	@echo "=== Synthesizing $(TOP) with Vivado ==="
	TOP=$(TOP) $(VIVADO) $(VIVADO_MODE) -source scripts/synth.tcl 2>&1 | tee $(SYNTH_DIR)/synth.log
	@echo "=== Synthesis complete. Check $(SYNTH_DIR)/ for reports. ==="

# =============================================================================
# Program FPGA (via hw_server + Vivado Lab)
# Override the top with `make program TOP=top_stream` (defaults to $(SYNTH_TOP)).
# =============================================================================

program: TOP ?= $(SYNTH_TOP)
program:
	@echo "=== Programming FPGA (bitstream = $(TOP).bit) ==="
	@if ! pgrep -x hw_server > /dev/null; then \
		echo "Starting hw_server..."; \
		$(HW_SERVER) & \
		sleep 2; \
	fi
	TOP=$(TOP) $(VIVADO) $(VIVADO_MODE) -source scripts/program.tcl 2>&1 | tee $(SYNTH_DIR)/program.log

# =============================================================================
# Clean targets
# =============================================================================

clean: clean_sim clean_synth
	rm -rf $(BUILD_DIR)

clean_sim:
	rm -rf $(SIM_DIR)
	rm -f $(TB_DIR)/*.vvp

clean_synth:
	rm -rf $(SYNTH_DIR)
