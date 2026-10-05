# Host build of the portable harness (run in WSL from the repo root:
# make -C test/pc). See main.c.
ROOT := ../..
B := $(ROOT)/build/pc
CC := gcc
CFLAGS := -O2 -g -Wall -Wno-unused-function -I$(ROOT)/test -I$(ROOT)/reference

CORES := REF NEW MUT1 MUT2 MUT3 MUT4

all: $(B)/zpc

$(B)/zpc: main.c $(ROOT)/test/zdiff.c $(ROOT)/test/zex.c $(ROOT)/test/replay.c $(CORES:%=$(B)/zcore_%.o)
	$(CC) $(CFLAGS) -o $@ $^

$(B)/zcore_REF.o $(B)/zcore_NEW.o: $(ROOT)/test/zcore.c $(ROOT)/reference/z80.c $(ROOT)/reference/z80.h
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -DPFX=$(patsubst zcore_%.o,%,$(notdir $@)) -c -o $@ $<

$(B)/zcore_MUT%.o: $(ROOT)/test/zcore.c $(B)/mut%/z80.c
	$(CC) -I$(B)/mut$* $(CFLAGS) -DPFX=MUT$* -c -o $@ $<

$(B)/mut%/z80.c: $(ROOT)/reference/z80.c $(ROOT)/test/mutants/mut%.sed
	@mkdir -p $(dir $@)
	sed -z -f $(ROOT)/test/mutants/mut$*.sed $< > $@
	@! cmp -s $< $@ || (echo "mutant mut$* did not apply"; rm -f $@; false)
	cp $(ROOT)/reference/z80.h $(dir $@)

.PRECIOUS: $(B)/mut%/z80.c
.PHONY: all
