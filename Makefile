# N64Z80 testsuite ROM (modeled on m64k/Makefile). Run in WSL with N64_INST
# set (e.g. /root/n64inst):
#   make                 build n64z80_testsuite.z64 (fetches the ZEX ROMs once)
#   make ares            build, then run it headless in ares (tools/ares-run.ps1)
#   make pc              host build of the harness (build/pc/zpc)
# Test knobs: ZDIFF_CASES, ZDIFF_SEED, ZEX_MAX_STEPS (0 = all 67 groups),
# ZEX_SETS (1 = ZEXDOC, 2 = ZEXALL, 3 = both), ZEX_ONLY=1 (skip everything
# but prelim and ZEX). Full ZEXALL: make ZEX_ONLY=1 ZEX_SETS=2 ZEX_MAX_STEPS=0.
BUILD_DIR = build
include $(N64_INST)/include/n64.mk

ROM := n64z80_testsuite

# Cores linked into the ROM (test/zcore.c, one wrapper each): the reference,
# the asm core and the planted-bug mutants (test/mutants). The C-vs-C
# harness self-check (NEW) runs in the PC build.
CORES := REF ASM MUT1 MUT2 MUT3 MUT4

ZDIFF_CASES ?= 20000
ZDIFF_SEED ?= 1
ZEX_MAX_STEPS ?= 5000000
ZEX_SETS ?= 3
ZEX_ONLY ?= 0
# PROF=1: per-opcode cycle profile of the asm core on the traces (slower).
PROF ?= 0
ifeq ($(PROF),1)
N64_CFLAGS += -DN64Z80_PROF
N64_ASFLAGS += -DN64Z80_PROF
endif

# ZEX exercisers (GPLv2: fetched, not committed). See test/roms/README.md.
ZEX_COMMIT := d64fe10a2274e5e40019b1086bf7d8990cbc5f23
ZEX_URL := https://raw.githubusercontent.com/superzazu/z80/$(ZEX_COMMIT)/roms
ZEX_ROMS := test/roms/prelim.com test/roms/zexdoc.cim test/roms/zexall.cim
SHA_prelim.com := 3b3578f19030a4df7e25ce852f763af26053b12582a576c4dffb014aa7c590d1
SHA_zexdoc.cim := 10b7c3972ff6765712ed160e5bd8750e4a13642f62b75711e062ef06a7f2f7b5
SHA_zexall.cim := af7e5d86146d390a68440fb85668648f14a648602da29a1816d2ef11459411ae

# The core is n64z80_asm.S plus its C side, n64z80.c (which includes the C
# fallback generated below).
src := test/testsuite.c test/zdiff.c test/zex.c test/bench.c test/replay.c
asm := test/zex_roms.S
OBJS := $(BUILD_DIR)/n64z80.o $(BUILD_DIR)/n64z80_asm.o \
	$(src:%.c=$(BUILD_DIR)/%.o) $(asm:%.S=$(BUILD_DIR)/%.o) $(CORES:%=$(BUILD_DIR)/zcore_%.o)

N64_CFLAGS += -I. -Itest -Ireference -I$(BUILD_DIR)
N64_ASFLAGS += -I. -I$(BUILD_DIR)

all: $(ROM).z64
test: all

$(BUILD_DIR)/$(ROM).elf: $(OBJS)
$(ROM).z64: N64_ROM_TITLE="N64Z80 Testsuite"
$(ROM).z64: $(BUILD_DIR)/$(ROM).dfs

# mvs64 owner traces (test/traces/*.z80t: gitignored, they contain game ROM)
# go into the ROM filesystem when present; the testsuite replays every one.
TRACES := $(wildcard test/traces/*.z80t)
$(BUILD_DIR)/$(ROM).dfs: $(TRACES:test/traces/%=filesystem/%) | filesystem
filesystem/%.z80t: test/traces/%.z80t | filesystem
	@echo "    [DATA] $@"
	cp $< $@
filesystem:
	mkdir -p $@

# One wrapper object per core; the core's directory goes first on the
# include path so zcore.c's #include "z80.c" picks the right copy.
$(BUILD_DIR)/zcore_REF.o $(BUILD_DIR)/zcore_NEW.o: test/zcore.c reference/z80.c reference/z80.h
	@mkdir -p $(dir $@)
	@echo "    [CC] $< ($(patsubst zcore_%.o,%,$(notdir $@)))"
	$(CC) -c $(CFLAGS) -DPFX=$(patsubst zcore_%.o,%,$(notdir $@)) -o $@ $<

$(BUILD_DIR)/zcore_ASM.o: test/zcore.c n64z80.h n64z80_offsets.h
	@mkdir -p $(dir $@)
	@echo "    [CC] $< (ASM)"
	$(CC) -c $(CFLAGS) -DPFX=ASM -DZCORE_ASM -o $@ $<

# The C fallback: the reference with its write_byte / port_out calls routed
# through n64z80.c's hooks (core-managed `wrote`). The check fails the build
# if a call site is left over, e.g. after a reference update.
$(BUILD_DIR)/n64z80_ref.c: reference/z80.c
	@mkdir -p $(dir $@)
	sed -e 's/z->write_byte(z->userdata, /n64z80_c_wb(z, /' \
	    -e 's/z->port_out(z, /n64z80_c_out(z, /' $< > $@
	@! grep -n -e '->write_byte(' -e '->port_out(' $@ || (rm -f $@; false)
$(BUILD_DIR)/n64z80.o: $(BUILD_DIR)/n64z80_ref.c

# Cycle tables and sz53p for the asm handlers, taken from the reference.
$(BUILD_DIR)/n64z80_tables.h: reference/z80.c tools/gen_tables.py
	@mkdir -p $(dir $@)
	python3 tools/gen_tables.py $< > $@
$(BUILD_DIR)/n64z80_asm.o: $(BUILD_DIR)/n64z80_tables.h

$(BUILD_DIR)/zcore_MUT%.o: test/zcore.c $(BUILD_DIR)/mut%/z80.c
	@echo "    [CC] $< (MUT$*)"
	$(CC) -c -I$(BUILD_DIR)/mut$* $(CFLAGS) -DPFX=MUT$* -o $@ $<

$(BUILD_DIR)/mut%/z80.c: reference/z80.c test/mutants/mut%.sed
	@mkdir -p $(dir $@)
	sed -z -f test/mutants/mut$*.sed $< > $@
	@! cmp -s $< $@ || (echo "mutant mut$* did not apply"; rm -f $@; false)
	cp reference/z80.h $(dir $@)
.PRECIOUS: $(BUILD_DIR)/mut%/z80.c

# The test knobs live in a generated header, rewritten only when they change,
# so changing one rebuilds testsuite.o.
$(BUILD_DIR)/test_config.h: FORCE
	@mkdir -p $(BUILD_DIR)
	@printf '#define ZDIFF_CASES %s\n#define ZDIFF_SEED %s\n#define ZEX_MAX_STEPS %s\n#define ZEX_SETS %s\n#define ZEX_ONLY %s\n' \
		$(ZDIFF_CASES) $(ZDIFF_SEED) $(ZEX_MAX_STEPS) $(ZEX_SETS) $(ZEX_ONLY) > $@.tmp
	@cmp -s $@.tmp $@ && rm -f $@.tmp || mv $@.tmp $@
$(BUILD_DIR)/test/testsuite.o: $(BUILD_DIR)/test_config.h

$(BUILD_DIR)/test/zex_roms.o: $(ZEX_ROMS)
roms: $(ZEX_ROMS)
$(ZEX_ROMS): test/roms/%:
	@echo "    [FETCH] $@"
	curl -fsSL -o $@.tmp $(ZEX_URL)/$*
	echo "$(SHA_$*)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

pc:
	$(MAKE) -C test/pc

# Headless ares run (WSL -> Windows PowerShell); log in build/ares-testsuite.log.
ARES_SECONDS ?= 900
ares: $(ROM).z64
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$$(wslpath -w tools/ares-run.ps1)" \
		-Rom "$$(wslpath -w $(ROM).z64)" -Out "$$(wslpath -w $(BUILD_DIR))\ares-testsuite.log" \
		-Seconds $(ARES_SECONDS)

clean:
	rm -rf $(BUILD_DIR) filesystem $(ROM).z64

-include $(wildcard $(BUILD_DIR)/*.d $(BUILD_DIR)/test/*.d)

.PHONY: all test roms pc ares clean FORCE
