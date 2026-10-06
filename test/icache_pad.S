# Testsuite only: puts test/replay.c's code (linked right after this) at a
# fixed icache index, whatever the size of the harness code before it. The
# replay runs between and inside every z80_run of a trace (record parsing,
# state hash, port callbacks), so where its code aliases the core's
# (n64z80_asm.S, also 16 KB aligned) moves the trace timings by up to 30%.
# At 0x2A00 the replay's 4.3 KB run loop ends below 0x4000, over core code
# the traces rarely or never run, not over the hot block (0x0000-0x1990):
# the bench then measures the core, not a harness conflict. (In the game the
# 68k core evicts much more between slices: measure there too.)
#
# Two sections: GAS rounds a section's size up to its alignment, so the
# 16 KB alignment sits in an empty one and the offset in the next.
    .section .text.icache_pad0, "ax", @progbits
    .globl replay_icache_pad0
    .balign 16384
replay_icache_pad0:

    .section .text.icache_pad1, "ax", @progbits
    .globl replay_icache_pad1
replay_icache_pad1:
    .space 0x2A00
