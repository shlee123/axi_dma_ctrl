SHELL := /bin/bash

SIMULATOR ?= vcs
ROOT      := ..
RTL_DIR   := $(ROOT)/rtl
TB_DIR    := tb
BUILD_DIR := build
LOG_DIR   := log
FSDB_DIR  := fsdb
COV_DIR   := coverage

TESTS := \
	tb_dma_data_fifo \
	tb_dma_read_engine \
	tb_dma_write_engine \
	tb_dma_ctrl \
	tb_dma_cdc \
	tb_dma_apb_regs \
	tb_axi_dma_ctrl_smoke \
	tb_axi_dma_ctrl_matrix \
	tb_axi_dma_ctrl_error_matrix

RTL_ALL := \
	$(RTL_DIR)/dma_reset_sync.v \
	$(RTL_DIR)/dma_data_fifo.v \
	$(RTL_DIR)/dma_read_engine.v \
	$(RTL_DIR)/dma_write_engine.v \
	$(RTL_DIR)/dma_ctrl.v \
	$(RTL_DIR)/dma_cdc.v \
	$(RTL_DIR)/dma_apb_regs.v \
	$(RTL_DIR)/axi_dma_ctrl.v

.PHONY: help dirs regression run_verdi clean coverage-clean coverage-merge $(TESTS)

help:
	@echo "AXI2AXI DMA simulation"
	@echo "  make SIMULATOR=iverilog regression"
	@echo "  make SIMULATOR=vcs regression"
	@echo "  make SIMULATOR=vcs TEST=tb_axi_dma_ctrl_smoke run"
	@echo "  make TEST=tb_axi_dma_ctrl_smoke run_verdi"
	@echo "  make coverage-merge"
	@echo "SIMULATOR defaults to vcs."

dirs:
	@mkdir -p $(BUILD_DIR) $(LOG_DIR) $(FSDB_DIR) $(COV_DIR)/vdb $(COV_DIR)/report

define TB_RTL_tb_dma_data_fifo
$(RTL_DIR)/dma_data_fifo.v
endef
define TB_RTL_tb_dma_read_engine
$(RTL_DIR)/dma_read_engine.v
endef
define TB_RTL_tb_dma_write_engine
$(RTL_DIR)/dma_write_engine.v
endef
define TB_RTL_tb_dma_ctrl
$(RTL_DIR)/dma_ctrl.v
endef
define TB_RTL_tb_dma_cdc
$(RTL_DIR)/dma_cdc.v
endef
define TB_RTL_tb_dma_apb_regs
$(RTL_DIR)/dma_apb_regs.v
endef
define TB_RTL_tb_axi_dma_ctrl_smoke
$(RTL_ALL)
endef
define TB_RTL_tb_axi_dma_ctrl_matrix
$(RTL_ALL)
endef
define TB_RTL_tb_axi_dma_ctrl_error_matrix
$(RTL_ALL)
endef

define run_test
	@$(MAKE) --no-print-directory TEST=$(1) run
endef

regression: dirs
	@set -e; \
	for t in $(TESTS); do \
		echo "===== $$t ====="; \
		$(MAKE) --no-print-directory TEST=$$t run; \
	done
	@echo "PASS regression"

run: dirs
	@if [ -z "$(TEST)" ]; then echo "ERROR: specify TEST=<tb_name>"; exit 2; fi
	@if [ ! -f "$(TB_DIR)/$(TEST).v" ]; then echo "ERROR: missing $(TB_DIR)/$(TEST).v"; exit 2; fi
	@if [ "$(SIMULATOR)" = "iverilog" ]; then \
		$(MAKE) --no-print-directory run-iverilog TEST=$(TEST); \
	elif [ "$(SIMULATOR)" = "vcs" ]; then \
		$(MAKE) --no-print-directory run-vcs TEST=$(TEST); \
	else \
		echo "ERROR: unsupported SIMULATOR=$(SIMULATOR)"; exit 2; \
	fi

run-iverilog: dirs
	@rtl_files='$($(addprefix TB_RTL_,$(TEST)))'; \
	iverilog -g2012 -I $(RTL_DIR) -s $(TEST) \
		-o $(BUILD_DIR)/$(TEST).vvp $$rtl_files $(TB_DIR)/$(TEST).v
	@set -o pipefail; \
	vvp $(BUILD_DIR)/$(TEST).vvp | tee $(LOG_DIR)/$(TEST)_iverilog.log; \
	grep -q "PASS $(TEST)" $(LOG_DIR)/$(TEST)_iverilog.log

VCS_CM ?= line+cond+fsm+tgl+branch
VCS_OPTS ?= -full64 -sverilog -debug_access+all
VCS_RUN_OPTS ?=
VERDI_OPTS ?= -nologo -sv

run-vcs: dirs
	@rtl_files='$($(addprefix TB_RTL_,$(TEST)))'; \
	vcs $(VCS_OPTS) +incdir+$(RTL_DIR) -top $(TEST) \
		-cm $(VCS_CM) \
		-cm_dir $(COV_DIR)/vdb/$(TEST).vdb \
		+define+ENABLE_FSDB \
		-o $(BUILD_DIR)/simv_$(TEST) \
		$$rtl_files $(TB_DIR)/$(TEST).v \
		-l $(LOG_DIR)/$(TEST)_vcs_compile.log
	@set -o pipefail; \
	$(BUILD_DIR)/simv_$(TEST) $(VCS_RUN_OPTS) \
		+FSDB_FILE=$(FSDB_DIR)/$(TEST).fsdb \
		-cm $(VCS_CM) \
		-cm_dir $(COV_DIR)/vdb/$(TEST).vdb \
		-l $(LOG_DIR)/$(TEST)_vcs_run.log | tee $(LOG_DIR)/$(TEST)_vcs_stdout.log; \
	grep -q "PASS $(TEST)" $(LOG_DIR)/$(TEST)_vcs_run.log

coverage-merge: dirs
	@./script/vcs_coverage_merge.sh

run_verdi: dirs
	@if [ -z "$(TEST)" ]; then echo "ERROR: specify TEST=<tb_name>"; exit 2; fi
	@if [ ! -f "$(TB_DIR)/$(TEST).v" ]; then echo "ERROR: missing $(TB_DIR)/$(TEST).v"; exit 2; fi
	@if [ ! -f "$(FSDB_DIR)/$(TEST).fsdb" ]; then echo "ERROR: missing $(FSDB_DIR)/$(TEST).fsdb; run VCS simulation first"; exit 2; fi
	@rtl_files='$($(addprefix TB_RTL_,$(TEST)))'; \
	verdi $(VERDI_OPTS) +incdir+$(RTL_DIR) +define+ENABLE_FSDB \
		-top $(TEST) \
		$rtl_files $(TB_DIR)/$(TEST).v \
		-ssf $(FSDB_DIR)/$(TEST).fsdb &

coverage-clean:
	@rm -rf $(COV_DIR)/vdb $(COV_DIR)/merged.vdb $(COV_DIR)/report
	@mkdir -p $(COV_DIR)/vdb $(COV_DIR)/report

clean:
	@rm -rf $(BUILD_DIR)/*
	@rm -f $(LOG_DIR)/*.log
	@rm -f $(FSDB_DIR)/*.fsdb
