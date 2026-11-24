# SPDX-FileCopyrightText: 2024 emmtrix Technologies GmbH
# SPDX-License-Identifier: Apache-2.0

ROOT_DIR := $(abspath .)
CV32E40P_DIR ?= cv32e40p
RTL_DIR := $(abspath $(CV32E40P_DIR)/rtl)
MANIFEST := $(CV32E40P_DIR)/cv32e40p_manifest.flist

TOOLCHAIN_ROOT ?= /opt/corev
RISCV_PREFIX ?= riscv32-corev-elf-
CROSS := $(TOOLCHAIN_ROOT)/bin/$(RISCV_PREFIX)
CC := $(CROSS)gcc
AR := $(CROSS)ar
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
READELF := $(CROSS)readelf

VERILATOR ?= verilator

RISCV_ARCH ?= rv32imc_zicsr_zifencei
RISCV_ABI ?= ilp32
CFLAGS := -Os -g -Wall -pedantic -mabi=$(RISCV_ABI) -march=$(RISCV_ARCH)

BUILD_DIR := build
FW_BUILD_DIR := $(BUILD_DIR)/fw
VERI_BUILD_DIR := $(BUILD_DIR)/verilator
VERI_OBJ_DIR := $(VERI_BUILD_DIR)/obj_dir

APP ?= shared-memory-demo

# Per-core stack size in bytes. The stack sits at the start of each core's
# scratchpad; the rest of the scratchpad starts at SPM_DATA_ADDR(core).
STACK_SIZE ?= 16384
FW_ELF := $(FW_BUILD_DIR)/$(APP).elf
FW_HEX := $(FW_BUILD_DIR)/$(APP).hex
FW_MAP := $(FW_BUILD_DIR)/$(APP).map

BSP_SRCS := bsp/crt0.S bsp/handlers.S bsp/vectors.S bsp/syscalls.c bsp/startup_sync.c
BSP_OBJS := $(addprefix $(FW_BUILD_DIR)/,$(notdir $(BSP_SRCS:.S=.o)))
BSP_OBJS := $(BSP_OBJS:.c=.o)
BSP_LIB := $(FW_BUILD_DIR)/libcv-verif.a

APP_SRC := sw/$(APP).c
APP_OBJ := $(FW_BUILD_DIR)/$(APP).o

# Rewritten only when STACK_SIZE changes, so dependents rebuild on change.
STACK_SIZE_STAMP := $(FW_BUILD_DIR)/stack_size.stamp

SV_TB_SRCS := \
	tb/tb_top_verilator.sv \
	tb/tb_mem_types_pkg.sv \
	tb/tb_core_dma_engine.sv \
	tb/tb_cv32e40p_cluster_wrapper.sv \
	tb/tb_cv32e40p_cluster_core.sv \
	tb/rr_arbiter.sv \
	tb/tb_event_unit.sv \
	tb/tb_shared_latency_pipe.sv \
	tb/tb_icache.sv \
	tb/tb_riscv/include/perturbation_defines.sv \
	tb/tb_riscv/riscv_rvalid_stall.sv \
	tb/tb_riscv/riscv_gnt_stall.sv \
	tb/mm_ram.sv \
	tb/dp_ram.sv \
	tb/scratchpad_ram.sv

CPP_TB_SRC := $(abspath tb/tb_top_verilator.cpp)
SIM_EXE := $(VERI_OBJ_DIR)/Vtb_top_verilator

# Per-core instruction cache. ICACHE=0 removes the caches, so every fetch goes
# straight to the shared instruction port.
ICACHE ?= 1
ICACHE_SIZE ?= 4096
ICACHE_LINE ?= 16
ICACHE_WAYS ?= 2
ICACHE_PARAMS := -GICACHE_ENABLE=$(ICACHE) -GICACHE_SIZE_BYTES=$(ICACHE_SIZE) \
	-GICACHE_LINE_BYTES=$(ICACHE_LINE) -GICACHE_WAYS=$(ICACHE_WAYS)

# Rewritten only when the cache parameters change, so the model re-verilates.
VERI_PARAMS_STAMP := $(VERI_BUILD_DIR)/params.stamp

MAXCYCLES ?= 20000000
VERI_CFLAGS ?= -O2
VERI_TRACE ?=

.PHONY: all run firmware verilate clean FORCE

all: run

run: verilate firmware
	$(SIM_EXE) +firmware=$(FW_HEX) +maxcycles=$(MAXCYCLES)

firmware: $(FW_HEX)

$(FW_HEX): $(FW_ELF)
	$(OBJCOPY) -O verilog $< $@
	$(READELF) -a $< > $(FW_BUILD_DIR)/$(APP).readelf
	$(OBJDUMP) -d -M no-aliases -M numeric -S $< > $(FW_BUILD_DIR)/$(APP).objdump

$(FW_ELF): $(APP_OBJ) $(BSP_LIB) bsp/link.ld $(STACK_SIZE_STAMP) | $(FW_BUILD_DIR)
	$(CC) $(CFLAGS) -nostartfiles -o $@ \
		$(APP_OBJ) -T bsp/link.ld -L$(FW_BUILD_DIR) -lcv-verif \
		-Wl,--defsym=__stack_size=$(STACK_SIZE) \
		-Wl,-Map,$(FW_MAP) -lc -lgcc

$(BSP_LIB): $(BSP_OBJS)
	$(AR) rcs $@ $^

$(FW_BUILD_DIR)/%.o: bsp/%.S | $(FW_BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(FW_BUILD_DIR)/%.o: bsp/%.c | $(FW_BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(APP_OBJ): $(APP_SRC) sw/cluster_sync.h $(STACK_SIZE_STAMP) | $(FW_BUILD_DIR)
	$(CC) $(CFLAGS) -DCL_STACK_SIZE=$(STACK_SIZE) -I bsp -I sw -c $< -o $@

$(STACK_SIZE_STAMP): FORCE | $(FW_BUILD_DIR)
	@echo '$(STACK_SIZE)' | cmp -s - $@ || echo '$(STACK_SIZE)' > $@

verilate: $(SIM_EXE)

$(VERI_PARAMS_STAMP): FORCE | $(VERI_BUILD_DIR)
	@echo '$(ICACHE_PARAMS)' | cmp -s - $@ || echo '$(ICACHE_PARAMS)' > $@

$(SIM_EXE): $(SV_TB_SRCS) $(CPP_TB_SRC) $(MANIFEST) $(VERI_PARAMS_STAMP) | $(VERI_BUILD_DIR)
	DESIGN_RTL_DIR=$(RTL_DIR) $(VERILATOR) --cc --sv --exe \
		--top-module tb_top_verilator \
		--Wno-lint --Wno-UNOPTFLAT --Wno-MODDUP \
		--Wno-BLKANDNBLK --Wno-MULTIDRIVEN --Wno-COMBDLY \
		$(VERI_TRACE) \
		$(ICACHE_PARAMS) \
		-f $(MANIFEST) $(SV_TB_SRCS) $(CPP_TB_SRC) \
		--Mdir $(VERI_OBJ_DIR) \
		-CFLAGS "-std=gnu++14 $(VERI_CFLAGS)"
	$(MAKE) -C $(VERI_OBJ_DIR) -f Vtb_top_verilator.mk

$(FW_BUILD_DIR):
	mkdir -p $(FW_BUILD_DIR)

$(VERI_BUILD_DIR):
	mkdir -p $(VERI_BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
