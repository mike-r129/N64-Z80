# N64Z80 testsuite ROM (modeled on m64k/Makefile). Run in WSL with N64_INST
# set (e.g. /root/n64inst):
#   make                 build n64z80_testsuite.z64 (fetches the ZEX ROMs once)
#   make ares            build, then run it headless in ares (tools/ares-run.ps1)
#   make pc              host build of the harness (build/pc/zpc)
# Test knobs: ZDIFF_CASES, ZDIFF_SEED, ZEX_MAX_STEPS (0 = all 67 ZEXDOC groups).
BUILD_DIR = build
include $(N64_INST)/include/n64.mk

ROM := n64z80_testsuite

# Cores linked into the ROM (test/zcore.c, one copy each): the reference, its
# stand-in for the candidate core, and the planted-bug mutants (test/mutants).
CORES := REF NEW MUT1 MUT2 MUT3 MUT4

ZDIFF_CASES ?= 20000
ZDIFF_SEED ?= 1
ZEX_MAX_STEPS ?= 5000000

# ZEX exercisers (GPLv2: fetched, not committed). See test/roms/README.md.
ZEX_COMMIT := d64fe10a2274e5e40019b1086bf7d8990cbc5f23
ZEX_URL := https://raw.githubusercontent.com/superzazu/z80/$(ZEX_COMMIT)/roms
ZEX_ROMS := test/roms/prelim.com test/roms/zexdoc.cim test/roms/zexall.cim
SHA_prelim.com := 3b3578f19030a4df7e25ce852f763af26053b12582a576c4dffb014aa7c590d1
SHA_zexdoc.cim := 10b7c3972ff6765712ed160e5bd8750e4a13642f62b75711e062ef06a7f2f7b5
SHA_zexall.cim := af7e5d86146d390a68440fb85668648f14a648602da29a1816d2ef11459411ae

src := test/testsuite.c test/zdiff.c test/zex.c test/bench.c test/replay.c
asm := test/zex_roms.S
OBJS := $(src:%.c=$(BUILD_DIR)/%.o) $(asm:%.S=$(BUILD_DIR)/%.o) $(CORES:%=$(BUILD_DIR)/zcore_%.o)

N64_CFLAGS += -Itest -Ireference -I$(BUILD_DIR)

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
	@printf '#define ZDIFF_CASES %s\n#define ZDIFF_SEED %s\n#define ZEX_MAX_STEPS %s\n' \
		$(ZDIFF_CASES) $(ZDIFF_SEED) $(ZEX_MAX_STEPS) > $@.tmp
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
