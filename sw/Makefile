# ============================================================
# sw/Makefile  —  Bare-metal RISC-V build system
# ============================================================
# Targets:
#   make gol      → build Game-of-Life binary + imem.hex
#   make matmul   → build MatMul binary + imem.hex
#   make golden   → run both under Spike and save golden outputs
#   make clean    → remove all build artefacts
#
# Requires: riscv32-unknown-elf toolchain on PATH
#           (or set CROSS_COMPILE=riscv64-unknown-elf- with -march=rv32i -mabi=ilp32)
#
# Spike golden-output requires: spike + pk  (or custom ELF loader)
# ============================================================

CROSS   ?= riscv32-unknown-elf
CC       = $(CROSS)-gcc
AS       = $(CROSS)-gcc    # use gcc as assembler (handles .s preprocessing)
LD       = $(CROSS)-ld
OBJCOPY  = $(CROSS)-objcopy
OBJDUMP  = $(CROSS)-objdump

# ---- Flags ----
CFLAGS  = -march=rv32i -mabi=ilp32 -O1 -ffreestanding -nostdlib \
          -Wall -Wextra -I include
ASFLAGS = -march=rv32i -mabi=ilp32 -ffreestanding -nostdlib
LDFLAGS = -T link.ld -nostdlib -static

BUILD   = build

# ---- Common objects ----
STARTUP = $(BUILD)/startup.o

# ======================================================
# Game of Life
# ======================================================
.PHONY: gol
gol: $(BUILD)/gol.elf $(BUILD)/gol.hex
	@echo "GOL built: $(BUILD)/gol.elf  $(BUILD)/gol.hex"

$(BUILD)/gol.o: gol/gol.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/gol.elf: $(STARTUP) $(BUILD)/gol.o
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@ -lgcc

$(BUILD)/gol.hex: $(BUILD)/gol.elf
	$(OBJCOPY) -O verilog --verilog-data-width=4 $< $@
	@# Vivado readmemh needs plain hex — strip addresses if needed
	@echo "imem.hex → $(BUILD)/gol.hex"
	cp $@ imem.hex

# ======================================================
# Matrix Multiplication
# ======================================================
.PHONY: matmul
matmul: $(BUILD)/matmul.elf $(BUILD)/matmul.hex
	@echo "MatMul built: $(BUILD)/matmul.elf  $(BUILD)/matmul.hex"

$(BUILD)/matmul.o: matmul/matmul.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/matmul.elf: $(STARTUP) $(BUILD)/matmul.o
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@ -lgcc

$(BUILD)/matmul.hex: $(BUILD)/matmul.elf
	$(OBJCOPY) -O verilog --verilog-data-width=4 $< $@
	cp $@ imem.hex

# ======================================================
# Golden Reference Outputs (host simulation via Spike)
# ======================================================
# Spike must be built with --enable-32bit or use rv32i pk
.PHONY: golden
golden: golden/gol_golden.txt golden/matmul_golden.txt

golden/gol_golden.txt: $(BUILD)/gol.elf | golden
	spike --isa=rv32i pk $< 2>/dev/null | tee $@
	@echo "GOL golden output saved → $@"

golden/matmul_golden.txt: $(BUILD)/matmul.elf | golden
	spike --isa=rv32i pk $< 2>/dev/null | tee $@
	@echo "MatMul golden output saved → $@"

# ======================================================
# Common startup
# ======================================================
$(BUILD)/startup.o: startup/startup.s | $(BUILD)
	$(AS) $(ASFLAGS) -c $< -o $@

$(BUILD) golden:
	mkdir -p $@

# ======================================================
# Disassembly (useful for debugging)
# ======================================================
.PHONY: disasm
disasm: $(BUILD)/gol.elf $(BUILD)/matmul.elf
	$(OBJDUMP) -d $(BUILD)/gol.elf    > $(BUILD)/gol.dis
	$(OBJDUMP) -d $(BUILD)/matmul.elf > $(BUILD)/matmul.dis

# ======================================================
# Clean
# ======================================================
.PHONY: clean
clean:
	rm -rf $(BUILD) golden imem.hex dmem.hex
