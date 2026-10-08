# n64z80: Zilog Z80 interpreter for the N64 (VR4300, libdragon o64 ABI).
#
# Based on the reference core reference/z80.c (superzazu/z80, MIT License,
# Copyright (c) 2019 Nicolas Allemand).
#
# n64z80_run is the reference z80_run loop (reference/z80.c) with the Z80
# registers in MIPS registers. Every opcode has an asm handler; a debug
# build (N64Z80_C_FALLBACK=1) can send table entries without one to the C
# fallback (n64z80.c: one reference instruction), and otherwise such an
# entry is a build error. Design (PLAN.md §4, docs/design-notes.md):
#
#   - PC is a host pointer (rPC) plus a bias (rBIAS = rmap[page], so the
#     Z80 PC is rPC - rBIAS). The dispatch fetches through rPC while it is
#     below rLIM, the host end of the mapped page minus 4; past it, refetch
#     extends rLIM over the next page when that page continues the same host
#     region (equal rmap entries), and otherwise sends the instruction to the
#     C fallback, which reads byte-wise through rmap. The -4 keeps every
#     fast-path instruction inside the page, so a sequential 0xFFFF -> 0x0000
#     wrap (a loop edge) only happens in the fallback.
#   - Cycles count up: rCYC = cyc - cbase, the run ends when rCYC >= 0, and
#     cyc = cbase + rCYC everywhere. cbase is `until`, except while
#     "poisoned": when events & ev_mask may be nonzero, cbase += rCYC and
#     rCYC = 0, so the next instruction's tail takes the slow exit, which
#     restores cbase = until and services events in the reference's order.
#   - rN counts instructions, 1-based: dispatch increments it, so during
#     instruction k (and its interrupt service) rN == k. It gives the return
#     value, lazy R (R = rhi | ((rRB + rN) & 0x7F)) and `wrote` (the write
#     hooks store rN in lastw: wrote = lastw == rN, wrote_any = lastw != 0).
#   - rPC0 is the Z80 address of the current instruction (pc0): the stop
#     test is pc <= pc0 after interrupt service, and *last_pc.
#   - Handlers charge the reference's base cycles (CYC00_xx, generated from
#     reference/z80.c) before any bus callback, and the conditional extras
#     where the reference adds them, so callback cycle stamps match.
#   - Writes go through wr8, which calls the owner's write_byte with `cyc`
#     written back; write callbacks may change the rmap and the event bytes
#     (wr8 remaps the PC and poisons). Other struct fields are not written
#     back for write callbacks (design-notes, M0 review item 5).
#include <regdef.h>
#ifndef N64Z80_C_FALLBACK
#define N64Z80_C_FALLBACK 0
#endif
#include "n64z80_offsets.h"
#include "n64z80_tables.h"   // generated: CYC00_xx / CYCED_xx / CYCDD_xx, sz53p

    .set noreorder
    .set noat

#define rA     s0    // A (zero-extended byte)
#define rF     s1    // F (Z80 layout)
#define rHL    s2    // HL (16-bit)
#define rDE    s3
#define rBC    s4
#define rPC    s5    // host pointer to the next byte to fetch
#define rCYC   s6    // cyc - cbase: >= 0 ends the run or services an event
#define rSP    s7
#define rN     s8    // instructions in this run, 1-based
#define rZ     a0    // the owner's z80*
#define rBIAS  v1    // rmap[page of PC]: Z80 PC = rPC - rBIAS
#define rLIM   a3    // fast fetch while rPC < rLIM
#define rRMAP  a2    // z->rmap (reloaded after every C call)
#define rPC0   t8    // Z80 address of the current instruction
#define rRB    $at   // rbase (lazy R); C clobbers it: kept in R across calls

# Save area: callee-saved registers, rZ, and the registers kept across
# owner callbacks. It is not on the stack but in the core's own data
# (n64z80_frame; the core is not reentrant), so its dcache sets do not
# depend on the caller's stack depth. The stack frame is only the o64
# argument home area (FRAME) for the C functions the core calls. Slot
# offsets count from the frame's start, as when the area was on the stack.
#define FRAME    32
#define SAVE    192   // FRAME + the save area
#define FR(x)   %gp_rel(n64z80_frame+(x)-FRAME)(gp)
#define F_S0     32
#define F_RA    104
#define F_Z     112
#define F_RA2   120   // call_c's own return address
#define F_WR    128   // wr8: ra, t2-t7, t8, Z80 PC, rRB (10 words); port_in/out: ra
#define F_IO    168   // in_bc / inx_core / outx_core: ra, a1
#define F_BN    176   // call_c / wr8: rLIM, rPC, rBIAS (a bounce across the call)

# ---------------------------------------------------------------------------
# Private state (gp-relative). The z80 struct itself is the owner's.
#
# Data layout, by dcache set (8 KB, 16-byte lines). Subsection 0 holds the
# data nearly every instruction touches: optab (0x000), fdtab (0x400), sz53p
# (0x800), cycdd (0x900); subsection 1 these variables and the save area
# (0xA00-0xAEF); subsection 2 the tables only some prefixed instructions
# use (cbtab, xcbtab, edtab, ddtab) and the bounce buffer, from 0xAF0. With
# N64Z80_DCACHE_ALIGN the block starts on an 8 KB boundary (plus
# N64Z80_DCACHE_OFFSET, to make room for other pinned data), so those
# offsets (plus the offset) are the sets, and the owner's per-instruction
# data (rmap, wmap, Z80 RAM, the struct) belongs in the 0x1510 bytes of sets
# after the hot part (0xB00-0x1FFF), clear of it. Without the alignment the
# block is 16-byte aligned: adding a variable never regroups table entries
# into different lines (an 8-byte shift once cost 2%).
    .section .sdata
    .subsection 1
    .balign 4
    .globl n64z80_insn, n64z80_lastw
n64z80_until:   .word 0     # the run's `until`
n64z80_cbase:   .word 0     # cyc = cbase + rCYC
n64z80_insn:    .word 0     # rN, published for the C write hooks
n64z80_lastw:   .word 0     # rN of the last instruction that wrote (0: none)
n64z80_rhi:     .word 0     # R = rhi | ((rRB + rN) & 0x7F)
n64z80_pc0:     .word 0     # rPC0 across C calls
n64z80_lastpc:  .word 0     # the run's last_pc pointer
n64z80_wmap:    .word 0     # write page map (n64z80_set_wmap), or 0
n64z80_im0:     .word 0     # IM 0 instruction running: 0x10000 | pc0
    .balign 8
n64z80_frame:   .space SAVE - FRAME   # the save area (FR)
    .globl n64z80_nfallback
n64z80_nfallback: .word 0   # instructions run by the C fallback (statistics)
#ifdef N64Z80_PROF
n64z80_prof_down:  .word 1  # dispatches until the next sample event
n64z80_prof_open:  .word 0  # 1 while an instruction is being timed
n64z80_prof_start: .word 0  # COP0 Count at its dispatch
n64z80_prof_key:   .word 0  # its key
#endif


#ifdef N64Z80_PROF
# Profiling build (make PROF=1), sampling: every 32nd dispatch starts timing
# that instruction (COP0 Count) and the next dispatch charges the ticks to
# its key: the opcode, or 256 * group + second byte for prefixed ones
# (group 1 CB, 2 ED, 3 DD, 4 FD). n64z80_prof_cyc[key] holds ticks,
# n64z80_prof_cnt[key] (right after it) the samples. Every dispatch pays a
# 5-instruction countdown, included in the samples; a sample still open at
# the end of a run is dropped.
#define PROF_KEYS 1281
    .section .bss
    .balign 4
    .globl n64z80_prof_cyc, n64z80_prof_cnt
n64z80_prof_cyc: .space 4 * PROF_KEYS
n64z80_prof_cnt: .space 4 * PROF_KEYS
#endif

# Code placement. The handlers of the most frequent instructions, the
# dispatch support and the run loop go first in .text.n64z80 (subsection 0),
# so they share icache lines instead of being spread over the whole core;
# everything else follows directly (subsection 1). The hot list is the Metal
# Slug sound driver's opcode profile (trace mslug_36s_10s,
# docs/measurements.md): every opcode above ~0.3% of the instructions.
.macro HOT
    .section .text.n64z80, "ax", @progbits
    .subsection 0
.endm
.macro COLD
    .section .text.n64z80, "ax", @progbits
    .subsection 1
.endm
# Code that rarely runs (fallbacks, interrupt service, bounce buffer) goes
# last, so edits there do not move the cold handlers in the icache.
.macro RARE
    .section .text.n64z80, "ax", @progbits
    .subsection 2
.endm
.macro PLACE name
  .ifdef HOT_\name
    HOT
  .else
  .ifdef USED_\name
    COLD
  .else
    RARE
  .endif
  .endif
.endm
    .irp op, 28,FD,A7,7E,21,23,CA,3A,77,6F,08,ED,E6,2C,C4,CD,C9,BE,DD,20
    .set HOT_\op, 1
    .endr
    .irp op, EB,3D,4F,26,19,9F,0E,4E,7D,2D,46,78,CB,30,81,86,47,24,3E,5F
    .set HOT_\op, 1
    .endr
    .irp op, 5E,C8,C2,DE,91,22,B0,FE,0F,32,87,AF,00,15,79,29,7A,F2,2A,C3
    .set HOT_\op, 1
    .endr
    .irp op, FD_CB,FD_21,FD_7E,FD_56,FD_6E,FD_2A,FD_77,FD_5E,DD_21,DD_CB
    .set HOT_\op, 1
    .endr
    .irp op, DB,D3,F3,FB          # port I/O and EI/DI: few, but costly
    .set HOT_\op, 1
    .endr
    .irp op, ED_5B,ED_42,ED_52,ED_53,ED_51,ED_59,ED_78,CB_57,CB_66
    .set HOT_\op, 1
    .endr
# The other opcodes the three traces run (a full sampling profile): cold.
# Everything else, never seen there, goes to the rare subsection, which
# fills the code at 16 KB multiples past the hot block's icache lines.
    .irp op, 01,04,05,06,09,0B,0C,0D,10,11,12,13,14,16,17,18
    .set USED_\op, 1
    .endr
    .irp op, 1A,1E,1F,25,2B,2E,2F,34,35,36,37,38,3C,41,43,44
    .set USED_\op, 1
    .endr
    .irp op, 4D,50,51,54,56,57,58,59,5A,5C,5D,60,62,66,67,69
    .set USED_\op, 1
    .endr
    .irp op, 6A,6B,6E,72,73,7B,7C,80,83,84,85,88,8B,8E,8F,90
    .set USED_\op, 1
    .endr
    .irp op, 94,96,98,AA,AB,AC,B1,B2,B3,B4,B5,B6,B7,B8,B9,BB
    .set USED_\op, 1
    .endr
    .irp op, C0,C1,C5,C6,CB_0B,CB_1C,CB_1D,CB_20,CB_28,CB_38,CB_47,CB_4F,CB_5F,CB_67,CB_6F,CB_77
    .set USED_\op, 1
    .endr
    .irp op, CB_CE,CB_FD,CE,CF,D0,D1,D2,D5,D6,D9,DA,DC,DD_09,DD_19,DD_35,DD_36
    .set USED_\op, 1
    .endr
    .irp op, DD_46,DD_4E,DD_54,DD_56,DD_5D,DD_5E,DD_62,DD_66,DD_6B,DD_6E,DD_70,DD_71,DD_72,DD_73,DD_74,DD_75
    .set USED_\op, 1
    .endr
    .irp op, DD_77,DD_7E,DD_86,DD_96,DD_AE,DD_BE,DD_E1,DD_E3,DD_E5,E1,E2,E3,E5,E9,ED_41,ED_43
    .set USED_\op, 1
    .endr
    .irp op, ED_4B,ED_4D,ED_5F,ED_73,ED_79,ED_A0,ED_A8,ED_B0,F1,F5,FA,FD_19,FD_22,FD_36,FD_46,FD_4E
    .set USED_\op, 1
    .endr
    .irp op, FD_54,FD_5D,FD_66,FD_6B,FD_70,FD_72,FD_73,FD_74,FD_75,FD_86,FD_E1,FD_E5,XC_06,XC_0E,XC_16,XC_1E
    .set USED_\op, 1
    .endr
    .irp op, XC_26,XC_2E,XC_36,XC_3E,XC_86,XC_8E,XC_96,XC_9E,XC_A6,XC_AE,XC_B6,XC_BE,XC_C6,XC_CE,XC_D6,XC_DE
    .set USED_\op, 1
    .endr
    .irp op, XC_E6,XC_EE,XC_F6,XC_FE
    .set USED_\op, 1
    .endr

    HOT
#ifdef N64Z80_ICACHE_ALIGN
    .balign 16384   # testsuite builds: fixed icache index of the core (Makefile)
#endif

# Profiling: count down to the next sample event (keeps t0, the opcode;
# clobbers t1-t3, t9, ra).
.macro PROF_TICK
#ifdef N64Z80_PROF
    lw    t1, %gp_rel(n64z80_prof_down)(gp)
    addiu t1, t1, -1
    bnez  t1, .Lprof\@
     sw   t1, %gp_rel(n64z80_prof_down)(gp)
    bal   prof_sample
     nop
.Lprof\@:
#endif
.endm

# Next instruction, after the previous one's tail: run out / event check,
# then the fetch. Handlers branch to one shared copy (dispatch) to keep the
# core small for the icache; DISPATCH_INLINE is the copy itself.
.macro DISPATCH_INLINE
    bgez  rCYC, slow_exit
     lbu  t0, 0(rPC)
    DISPATCH_FETCHED
.endm
.macro DISPATCH
    b     dispatch
     nop
.endm

# Fetch and jump, with t0 = the opcode (already loaded from 0(rPC)).
.macro DISPATCH_FETCHED
    PROF_TICK
    sltu  t1, rPC, rLIM
    sll   t0, t0, 2
    beqz  t1, refetch
     addu t0, t0, gp
    lw    t0, %gp_rel(n64z80_optab)(t0)
    subu  rPC0, rPC, rBIAS
    jr    t0
     addiu rN, rN, 1
.endm

# Map Z80 address t0 (16-bit) for fetching: rBIAS, rPC, rLIM.
# Clobbers t2.
.macro REMAP
    srl   t2, t0, 8
    sll   t2, t2, 2
    addu  t2, t2, rRMAP
    lw    rBIAS, 0(t2)
    ori   t2, t0, 0xFF
    addu  rPC, rBIAS, t0
    addu  rLIM, rBIAS, t2
    addiu rLIM, rLIM, -3        # host(page end) - 4
.endm

# rCYC >= 0 until the next tail if events & ev_mask is nonzero.
# Clobbers t0, t1.
.macro POISON_IF_EVENTS
    ld    t0, N64Z80_OFF_EVENTS(rZ)
    ld    t1, N64Z80_OFF_EV_MASK(rZ)
    and   t0, t0, t1
    beqz  t0, .Lpoison\@
     lw   t0, %gp_rel(n64z80_cbase)(gp)
    addu  t0, t0, rCYC
    sw    t0, %gp_rel(n64z80_cbase)(gp)
    move  rCYC, zero
.Lpoison\@:
.endm

# ---------------------------------------------------------------------------
# unsigned n64z80_run(z80* z, unsigned long until, uint16_t* last_pc)
    .globl n64z80_run
    .type n64z80_run, @function
    .balign 32
# Entry of n64z80_run and n64z80_step: save the callee-saved registers,
# a1 = until, a2 = last_pc (0 for a step), rebuild ev_mask, load the state.
.macro PROLOGUE
    addiu sp, sp, -FRAME
    sd    s0, FR(F_S0+0)
    sd    s1, FR(F_S0+8)
    sd    s2, FR(F_S0+16)
    sd    s3, FR(F_S0+24)
    sd    s4, FR(F_S0+32)
    sd    s5, FR(F_S0+40)
    sd    s6, FR(F_S0+48)
    sd    s7, FR(F_S0+56)
    sd    s8, FR(F_S0+64)
    sd    ra, FR(F_RA)
    sw    a0, FR(F_Z)
    sw    a1, %gp_rel(n64z80_until)(gp)
    sw    a1, %gp_rel(n64z80_cbase)(gp)
    sw    a2, %gp_rel(n64z80_lastpc)(gp)
    sw    zero, %gp_rel(n64z80_lastw)(gp)
    move  rN, zero
    li    rPC0, -1                  # below any pc for bounce's stop test
#ifdef N64Z80_PROF
    sw    zero, %gp_rel(n64z80_prof_open)(gp)
#endif

    # The owner may have changed IFF1 or the event bytes since the last run:
    # rebuild ev_mask (constant lanes, then IFF1's), as the reference does.
    li    t0, 0xFF
    lbu   t1, N64Z80_OFF_IFF1(rZ)
    sd    zero, N64Z80_OFF_EV_MASK(rZ)
    sb    t0, N64Z80_OFF_EVM_IFF_DELAY(rZ)
    sb    t0, N64Z80_OFF_EVM_NMI(rZ)
    sb    t0, N64Z80_OFF_EVM_HALTED(rZ)
    subu  t1, zero, t1
    sb    t1, N64Z80_OFF_EVM_INT(rZ)
    sb    t1, N64Z80_OFF_EVM_LINE(rZ)

    jal   load_state
     nop
.endm

n64z80_run:
    PROLOGUE
    # The first instruction runs whatever the budget.
    b     pre_insn
     nop

# void n64z80_step(z80* z): one instruction (or HALT's NOP) and the
# interrupt service, as a run with until = cyc and no last_pc: no IRQ
# re-assertion, `wrote` only set, wrote_any untouched. The step also
# rebuilds ev_mask, which the reference's z80_step leaves alone (it only
# caches IFF1 and the constant lanes, so the service test is the same).
    .globl n64z80_step
    .type n64z80_step, @function
n64z80_step:
    lw    a1, N64Z80_OFF_CYC(a0)
    move  a2, zero
    PROLOGUE
    b     pre_halt
     nop
    .size n64z80_step, .-n64z80_step

#ifdef N64Z80_PROF
# Sample event (t0 = the opcode being dispatched): close the open sample and
# charge it, or open one on this instruction.
prof_sample:
    lw    t2, %gp_rel(n64z80_prof_open)(gp)
    beqz  t2, 1f
     mfc0 t3, $9
    lw    t2, %gp_rel(n64z80_prof_start)(gp)
    lw    t1, %gp_rel(n64z80_prof_key)(gp)
    subu  t3, t3, t2
    sll   t1, t1, 2
    la    t9, n64z80_prof_cyc
    addu  t9, t9, t1
    lw    t1, 0(t9)
    addu  t1, t1, t3
    sw    t1, 0(t9)
    lw    t1, 4 * PROF_KEYS(t9)
    addiu t1, t1, 1
    sw    t1, 4 * PROF_KEYS(t9)
    sw    zero, %gp_rel(n64z80_prof_open)(gp)
    li    t1, 31
    jr    ra
     sw   t1, %gp_rel(n64z80_prof_down)(gp)
1:  li    t1, 1
    sw    t1, %gp_rel(n64z80_prof_open)(gp)
    sw    t1, %gp_rel(n64z80_prof_down)(gp)
    sw    t0, %gp_rel(n64z80_prof_key)(gp)
    mfc0  t3, $9
    jr    ra
     sw   t3, %gp_rel(n64z80_prof_start)(gp)
#endif

# Taken JR / JR cc / DJNZ: t1 = signed displacement; rPC at the opcode.
# WZ = the new PC, +5 cycles (the reference's jr() and cond_jr()). Falls
# through to jp_to, which falls through to the dispatch.
jr_taken:
    subu  t0, rPC, rBIAS
    addiu t0, t0, 2
    addu  t0, t0, t1
    andi  t0, t0, 0xFFFF
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    addiu rCYC, rCYC, 5

# Control transfer to Z80 address t0 (16-bit): loop-edge test against rPC0,
# remap, next instruction.
jp_to:
    subu  t2, rPC, rBIAS
    xor   t2, t2, t0
    srl   t2, t2, 8
    bnez  t2, jp_remap
     sltu t1, rPC0, t0
    # Same 256-byte page as rPC, whose mapping (rBIAS, rLIM) is current even
    # after a callback in this instruction (those remap rPC's page).
    beqz  t1, edge_exit
     addu rPC, rBIAS, t0

dispatch:
    DISPATCH_INLINE

jp_remap:
    REMAP
    beqz  t1, edge_exit
     nop
    DISPATCH

# ---------------------------------------------------------------------------
# Slow exit: the tail of an instruction found rCYC >= 0 (out of cycles or
# poisoned), or a control transfer found a loop edge. Reference order: (3)
# interrupt service, then (4) the stop test, then (1) the next iteration's
# IRQ re-assertion and HALT.
slow_exit:
    lw    t0, %gp_rel(n64z80_cbase)(gp)
    lw    t1, %gp_rel(n64z80_until)(gp)
    lw    t2, %gp_rel(n64z80_im0)(gp)
    subu  t0, t0, t1
    addu  rCYC, rCYC, t0
    bnez  t2, svc_im0_done
     sw   t1, %gp_rel(n64z80_cbase)(gp)

    ld    t0, N64Z80_OFF_EVENTS(rZ)
    ld    t1, N64Z80_OFF_EV_MASK(rZ)
    and   t0, t0, t1
    beqz  t0, se_test
     lbu  t0, N64Z80_OFF_IFF_DELAY(rZ)
    # process_interrupts: EI delay, else NMI, else an accepted INT.
    bnez  t0, svc_delay
     lbu  t1, N64Z80_OFF_NMI_PENDING(rZ)
    lbu   t2, N64Z80_OFF_INT_PENDING(rZ)
    bnez  t1, svc_nmi
     lbu  t3, N64Z80_OFF_IFF1(rZ)
    and   t2, t2, t3
    bnez  t2, svc_int
     nop
se_halted:
    lbu   t0, N64Z80_OFF_HALTED(rZ)
    bnez  t0, stop
     nop
se_test:
    bgez  rCYC, stop
     subu t0, rPC, rBIAS
    andi  t0, t0, 0xFFFF            # past 0xFFFF after a bounce
    sltu  t1, rPC0, t0
    beqz  t1, stop
     nop

# Start of an iteration: (1) re-assert a level IRQ, execute HALT's NOP, and
# poison while events & ev_mask is nonzero; then dispatch without the
# rCYC test (the first instruction of a run always executes).
pre_insn:
    ld    t0, N64Z80_OFF_EVENTS(rZ)
    ld    t1, N64Z80_OFF_EV_MASK(rZ)
    and   t0, t0, t1
    beqz  t0, dispatch_nocyc
     lbu  t0, N64Z80_OFF_IRQ_LINE(rZ)
    lbu   t1, N64Z80_OFF_IFF1(rZ)
    lbu   t2, N64Z80_OFF_INT_PENDING(rZ)
    beqz  t0, pre_halt               # irq_line && iff1 && !int_pending
     li   t3, 1
    beqz  t1, pre_halt
     lw   t0, N64Z80_OFF_IRQ_REDELIVER(rZ)
    bnez  t2, pre_halt
     nop
    sb    t3, N64Z80_OFF_INT_PENDING(rZ)   # z80_gen_int(z, z->int_data)
    addiu t0, t0, 1
    sw    t0, N64Z80_OFF_IRQ_REDELIVER(rZ)
pre_halt:
    lbu   t0, N64Z80_OFF_HALTED(rZ)
    beqz  t0, 2f
     lw   t0, %gp_rel(n64z80_cbase)(gp)
    # HALT: a 4-cycle NOP in place (cyc_00[0x00]; R via rN), then its tail.
    subu  rPC0, rPC, rBIAS
    andi  rPC0, rPC0, 0xFFFF
    addiu rN, rN, 1
    b     slow_exit
     addiu rCYC, rCYC, 4
2:  addu  t0, t0, rCYC                 # events pending: poison
    sw    t0, %gp_rel(n64z80_cbase)(gp)
    move  rCYC, zero
dispatch_nocyc:
    lbu   t0, 0(rPC)
    DISPATCH_FETCHED

# rPC reached rLIM: rPC is in the last 4 bytes of rBIAS's page, or (after a
# callback remapped the PC mid-instruction) up to 4 bytes past it. Extend
# rLIM if the page is rBIAS's and the next one continues the same host
# region (never past 0xFFFF), else run this instruction from a copy
# (bounce). After an instruction run from the copy (rLIM = 0), map the PC
# again (unbounce).
refetch:
    beqz  rLIM, unbounce             # only a bounce sets rLIM = 0
     subu t0, rPC, rBIAS
    srl   t0, t0, 8
    sltiu t1, t0, 0xFF
    beqz  t1, bounce                 # page 0xFF, or past 0xFFFF
     sll  t0, t0, 2
    addu  t0, rRMAP, t0
    lw    t1, 0(t0)
    lw    t0, 4(t0)
    bne   t1, rBIAS, bounce          # a callback remapped mid-instruction
     nop
    bne   t0, rBIAS, bounce
     nop
    b     dispatch_nocyc
     addiu rLIM, rLIM, 256

# EI delay (t0 = iff_delay > 0): count it down; at 0, IFF1 = IFF2 = 1.
svc_delay:
    addiu t0, t0, -1
    bnez  t0, se_halted
     sb   t0, N64Z80_OFF_IFF_DELAY(rZ)
    li    t0, 1
    sb    t0, N64Z80_OFF_IFF1(rZ)
    sb    t0, N64Z80_OFF_IFF2(rZ)
    li    t0, 0xFF
    sb    t0, N64Z80_OFF_EVM_INT(rZ)
    b     se_halted
     sb   t0, N64Z80_OFF_EVM_LINE(rZ)

#if N64Z80_C_FALLBACK
# ---------------------------------------------------------------------------
# C fallback: the whole instruction at rPC (== rPC0) runs in the reference.
# The fallback re-executes the instruction's R increments, so give back the
# one dispatch counted before materializing R.
    .balign 32
    RARE
    .balign 4
op_fallback:
    lw    t1, %gp_rel(n64z80_nfallback)(gp)
    addiu rRB, rRB, -1
    addiu t1, t1, 1
    sw    t1, %gp_rel(n64z80_nfallback)(gp)
    move  a1, rPC
    la    t9, n64z80_c_exec
    jal   call_c
     nop
    POISON_IF_EVENTS
    # Any instruction can be a transfer: loop-edge test (pc <= pc0).
    subu  t0, rPC, rBIAS
    sltu  t1, rPC0, t0
    beqz  t1, slow_exit
     nop
    DISPATCH
#endif

# ---------------------------------------------------------------------------
# Call the C function t9(rZ, a1) with the state written back to the struct,
# then reload it (the callee may change anything, including the rmap).
    HOT
# An instruction running from the bounce buffer (rLIM = 0) stays there: its
# bytes are already copied, and unbounce maps the PC again afterwards with
# the stop test (load_state's 16-bit PC would hide a wrap past 0xFFFF).
call_c:
    sw    ra, FR(F_RA2)
    sw    rLIM, FR(F_BN+0)
    sw    rPC, FR(F_BN+4)
    sw    rBIAS, FR(F_BN+8)
    jal   save_state
     sw   rPC0, %gp_rel(n64z80_pc0)(gp)
    jalr  t9
     nop
    lw    rZ, FR(F_Z)
    jal   load_state
     lw   rPC0, %gp_rel(n64z80_pc0)(gp)
    lw    t0, FR(F_BN+0)
    bnez  t0, 1f
     lw   ra, FR(F_RA2)
    lw    rPC, FR(F_BN+4)
    lw    rBIAS, FR(F_BN+8)
    move  rLIM, zero
1:  jr    ra
     nop

# Write the registers back to the struct: pc = rPC - rBIAS, cyc, R.
# Clobbers t0, t1.
save_state:
    sll   t0, rBC, 16
    or    t0, t0, rDE
    swl   t0, N64Z80_OFF_B(rZ)      # B C D E
    swr   t0, N64Z80_OFF_E(rZ)
    sb    rA, N64Z80_OFF_A(rZ)
    sb    rF, N64Z80_OFF_F(rZ)
    srl   t0, rHL, 8
    sb    t0, N64Z80_OFF_H(rZ)
    sb    rHL, N64Z80_OFF_L(rZ)
    sh    rSP, N64Z80_OFF_SP(rZ)
    subu  t0, rPC, rBIAS
    sh    t0, N64Z80_OFF_PC(rZ)
    lw    t0, %gp_rel(n64z80_cbase)(gp)
    addu  t0, t0, rCYC
    sw    t0, N64Z80_OFF_CYC(rZ)
    lw    t1, %gp_rel(n64z80_rhi)(gp)
    addu  t0, rRB, rN
    andi  t0, t0, 0x7F
    or    t0, t0, t1
    sb    t0, N64Z80_OFF_R(rZ)
    jr    ra
     sw   rN, %gp_rel(n64z80_insn)(gp)

# Load the registers from the struct, rebase R and the cycle counter, map PC.
# Clobbers t0-t2.
load_state:
    lwl   t0, N64Z80_OFF_B(rZ)      # B C D E (big endian, unaligned)
    lwr   t0, N64Z80_OFF_E(rZ)
    lwl   t1, N64Z80_OFF_H(rZ)      # H L A' B'
    lwr   t1, N64Z80_OFF_H+3(rZ)
    lbu   rA, N64Z80_OFF_A(rZ)
    lbu   rF, N64Z80_OFF_F(rZ)
    srl   rBC, t0, 16
    andi  rDE, t0, 0xFFFF
    srl   rHL, t1, 16
    lhu   rSP, N64Z80_OFF_SP(rZ)
    lw    rRMAP, N64Z80_OFF_RMAP(rZ)
    lw    t0, N64Z80_OFF_CYC(rZ)
    lw    t1, %gp_rel(n64z80_cbase)(gp)
    subu  rCYC, t0, t1
    lbu   t0, N64Z80_OFF_R(rZ)
    andi  t1, t0, 0x80
    sw    t1, %gp_rel(n64z80_rhi)(gp)
    subu  rRB, t0, rN
    lhu   t0, N64Z80_OFF_PC(rZ)
    REMAP
    jr    ra
     nop

# ---------------------------------------------------------------------------
# A control transfer found a loop edge. rCYC < 0 means not poisoned: cbase
# is `until` and events & ev_mask is zero (every change that can make it
# nonzero poisons), so slow_exit would only reach the stop test: stop now.
edge_exit:
    bgez  rCYC, slow_exit
     nop

# End of the run (cbase == until here): write everything back.
stop:
#ifdef N64Z80_PROF
    lw    t0, %gp_rel(n64z80_prof_open)(gp)
    sw    zero, %gp_rel(n64z80_prof_open)(gp)
    beqz  t0, 1f                  # a sample open across the exit: drop it,
     li   t1, 1                   # and sample the next run's first instruction
    sw    t1, %gp_rel(n64z80_prof_down)(gp)
1:
#endif
    jal   save_state
     nop
    lw    t2, %gp_rel(n64z80_lastpc)(gp)
    lw    t0, %gp_rel(n64z80_lastw)(gp)
    beqz  t2, step_stop
     xor  t1, t0, rN
    sltiu t1, t1, 1
    sb    t1, N64Z80_OFF_WROTE(rZ)
    sltu  t0, zero, t0
    sb    t0, N64Z80_OFF_WROTE_ANY(rZ)
    sh    rPC0, 0(t2)
    move  v0, rN
ret_regs:
    ld    s0, FR(F_S0+0)
    ld    s1, FR(F_S0+8)
    ld    s2, FR(F_S0+16)
    ld    s3, FR(F_S0+24)
    ld    s4, FR(F_S0+32)
    ld    s5, FR(F_S0+40)
    ld    s6, FR(F_S0+48)
    ld    s7, FR(F_S0+56)
    ld    s8, FR(F_S0+64)
    ld    ra, FR(F_RA)
    jr    ra
     addiu sp, sp, FRAME
step_stop:
    bnez  t1, ret_regs              # no write in this instruction
     li   t1, 1
    b     ret_regs
     sb   t1, N64Z80_OFF_WROTE(rZ)
    .size n64z80_run, .-n64z80_run

# void n64z80_set_wmap(const uintptr_t* wmap)
    .globl n64z80_set_wmap
    .type n64z80_set_wmap, @function
n64z80_set_wmap:
    jr    ra
     sw   a0, %gp_rel(n64z80_wmap)(gp)
    .size n64z80_set_wmap, .-n64z80_set_wmap

# ===========================================================================
# Handlers. Each one is entered from the dispatch with rPC at its opcode,
# rPC0 = its Z80 address and rN already counting it; it advances rPC (or
# jumps through jp_to) and ends with DISPATCH. Bodies follow the reference
# case by case (reference/z80.c exec_main / exec_opcode_slow).

.macro OP op
    PLACE \op
op_\op:
.endm

# The reference's base cycles for unprefixed opcode `op` (cyc_00).
.macro CHARGE op
    addiu rCYC, rCYC, CYC00_\op
.endm

# dst = byte at Z80 address `addr` (16-bit) through the rmap. tmp != addr.
.macro READ8 dst, addr, tmp
    srl   \tmp, \addr, 8
    sll   \tmp, \tmp, 2
    addu  \tmp, \tmp, rRMAP
    lw    \tmp, 0(\tmp)
    addu  \tmp, \tmp, \addr
    lbu   \dst, 0(\tmp)
.endm

# dst = the 16-bit operand at rPC+1 (fast path: in the mapped region).
.macro FETCH16 dst, tmp
    lbu   \dst, 1(rPC)
    lbu   \tmp, 2(rPC)
    sll   \tmp, \tmp, 8
    or    \dst, \dst, \tmp
.endm

# 8-bit register r (Z80 encoding: 0 B, 1 C, 2 D, 3 E, 4 H, 5 L, 7 A).
.macro GETR dst, r
  .if \r == 0
    srl   \dst, rBC, 8
  .elseif \r == 1
    andi  \dst, rBC, 0xFF
  .elseif \r == 2
    srl   \dst, rDE, 8
  .elseif \r == 3
    andi  \dst, rDE, 0xFF
  .elseif \r == 4
    srl   \dst, rHL, 8
  .elseif \r == 5
    andi  \dst, rHL, 0xFF
  .elseif \r == 7
    move  \dst, rA
  .else
    .error "GETR: bad register"
  .endif
.endm

# Register r = src (a clean byte, not t9). Clobbers t9.
.macro SETR r, src
  .if \r == 0
    andi  rBC, rBC, 0xFF
    sll   t9, \src, 8
    or    rBC, rBC, t9
  .elseif \r == 1
    andi  rBC, rBC, 0xFF00
    or    rBC, rBC, \src
  .elseif \r == 2
    andi  rDE, rDE, 0xFF
    sll   t9, \src, 8
    or    rDE, rDE, t9
  .elseif \r == 3
    andi  rDE, rDE, 0xFF00
    or    rDE, rDE, \src
  .elseif \r == 4
    andi  rHL, rHL, 0xFF
    sll   t9, \src, 8
    or    rHL, rHL, t9
  .elseif \r == 5
    andi  rHL, rHL, 0xFF00
    or    rHL, rHL, \src
  .elseif \r == 7
    move  rA, \src
  .else
    .error "SETR: bad register"
  .endif
.endm

# The reference's addb: t2 = a + b + cy (9 bits), F = S Z Y X from the
# result byte, H, P/V = overflow, C; N = 0. a, b are bytes, cy is 0/1;
# none of them may be t2-t7.
.macro ADDB a, b, cy
    addu  t2, \a, \b
    addu  t2, t2, \cy
    xor   t3, t2, \a
    xor   t3, t3, \b              # carries into each bit
    andi  t4, t2, 0xFF
    addu  t4, t4, gp
    lbu   t4, %gp_rel(n64z80_sz53p)(t4)
    andi  t5, t3, 0x10            # H: carry into bit 4
    srl   t6, t3, 8               # C: carry out of bit 7
    srl   t7, t3, 7
    xor   t7, t7, t6
    andi  t7, t7, 1
    sll   t7, t7, 2               # V: carry into bit 7 != carry out
    andi  t4, t4, 0xFB
    or    t4, t4, t5
    or    t4, t4, t6
    or    rF, t4, t7
.endm

# dst = the 16-bit word at SP; SP += 2. Clobbers ta, tb.
.macro POP16 dst, ta, tb
    READ8 \dst, rSP, \ta
    addiu \tb, rSP, 1
    andi  \tb, \tb, 0xFFFF
    READ8 \tb, \tb, \ta
    sll   \tb, \tb, 8
    or    \dst, \dst, \tb
    addiu rSP, rSP, 2
    andi  rSP, rSP, 0xFFFF
.endm

# ---------------------------------------------------------------------------
    HOT
# Shared pieces.

# Write byte t1 to Z80 address t0 (bal; rN marks the instruction as
# writing). A page with a wmap entry is stored directly. Otherwise the
# owner's write_byte is called with `cyc` written back; it may change the
# rmap and the event bytes, so the PC is remapped and the poison check runs.
# Keeps t2-t7, t8 and the Z80 PC; clobbers t0, t1, t9, a1, a2 (rRMAP is
# reloaded).
wr8:
    lw    t9, %gp_rel(n64z80_wmap)(gp)
    sw    rN, %gp_rel(n64z80_lastw)(gp)
    beqz  t9, wr8_cb
     srl  a1, t0, 8
    sll   a1, a1, 2
    addu  a1, a1, t9
    lw    a1, 0(a1)
    beqz  a1, wr8_cb
     addu a1, a1, t0
    jr    ra
     sb   t1, 0(a1)
wr8_cb:
    sw    ra, FR(F_WR+0)
    sw    t2, FR(F_WR+4)
    sw    t3, FR(F_WR+8)
    sw    t4, FR(F_WR+12)
    sw    t5, FR(F_WR+16)
    sw    t6, FR(F_WR+20)
    sw    t7, FR(F_WR+24)
    sw    t8, FR(F_WR+28)
    subu  t9, rPC, rBIAS
    andi  t9, t9, 0xFFFF
    sw    t9, FR(F_WR+32)
    sw    rRB, FR(F_WR+36)
    sw    rLIM, FR(F_BN+0)
    sw    rBIAS, FR(F_BN+8)
    lw    t9, %gp_rel(n64z80_cbase)(gp)
    addu  t9, t9, rCYC
    sw    t9, N64Z80_OFF_CYC(rZ)
    lw    t9, N64Z80_OFF_WRITE_BYTE(rZ)
    move  a1, t0
    move  a2, t1
    jalr  t9
     lw   a0, N64Z80_OFF_USERDATA(rZ)
    lw    rZ, FR(F_Z)
    lw    rRMAP, N64Z80_OFF_RMAP(rZ)
    lw    rRB, FR(F_WR+36)
    lw    t0, FR(F_BN+0)
    bnez  t0, 1f
     lw   t0, FR(F_WR+32)
    lw    rBIAS, FR(F_BN+8)         # bouncing: stay in the copy (as call_c)
    b     2f
     move rLIM, zero
1:  REMAP
2:  POISON_IF_EVENTS
    lw    ra, FR(F_WR+0)
    lw    t2, FR(F_WR+4)
    lw    t3, FR(F_WR+8)
    lw    t4, FR(F_WR+12)
    lw    t5, FR(F_WR+16)
    lw    t6, FR(F_WR+20)
    lw    t7, FR(F_WR+24)
    jr    ra
     lw   t8, FR(F_WR+28)

# Push t4 (16-bit) as the reference's pushw: SP -= 2, low byte at SP, high
# byte at SP+1 (bal). Keeps t2-t6; clobbers t0, t1, t7, t9.
push_t4:
    addiu rSP, rSP, -2
    andi  rSP, rSP, 0xFFFF
    # Both bytes in one page the wmap stores directly: one lookup.
    lw    t9, %gp_rel(n64z80_wmap)(gp)
    andi  t1, rSP, 0xFF
    xori  t1, t1, 0xFF
    beqz  t1, push_slow             # SP + 1 is on the next page
     srl  t0, rSP, 8
    beqz  t9, push_slow
     sll  t0, t0, 2
    addu  t0, t0, t9
    lw    t0, 0(t0)
    beqz  t0, push_slow
     addu t0, t0, rSP
    sw    rN, %gp_rel(n64z80_lastw)(gp)
    sb    t4, 0(t0)
    srl   t1, t4, 8
    jr    ra
     sb   t1, 1(t0)
push_slow:
    move  t7, ra
    move  t0, rSP
    bal   wr8
     andi t1, t4, 0xFF
    addiu t0, rSP, 1
    andi  t0, t0, 0xFFFF
    bal   wr8
     srl  t1, t4, 8
    jr    t7
     nop

# Taken RET cc: pop, WZ = PC, +6 (cond_ret).
ret_taken:
    POP16 t0, t1, t2
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    b     jp_to
     addiu rCYC, rCYC, 6

# Taken CALL cc: t5 = target; push the return address, +7 after the push,
# WZ = target (cond_call).
call_taken:
    subu  t4, rPC, rBIAS
    bal   push_t4
     addiu t4, t4, 3
    addiu rCYC, rCYC, 7
    move  t0, t5
    b     jp_to
     sh   t5, N64Z80_OFF_MEM_PTR(rZ)

# ALU on A with operand t0 (rPC advanced, cycles charged).
alu_add:
    ADDB  rA, t0, zero
    b     dispatch
     andi  rA, t2, 0xFF
alu_adc:
    andi  t1, rF, 1
    ADDB  rA, t0, t1
    b     dispatch
     andi  rA, t2, 0xFF
alu_sub:                          # subb: addb(a, ~b, 1), then C/H flipped, N
    xori  t0, t0, 0xFF
    li    t1, 1
    ADDB  rA, t0, t1
    xori  rF, rF, 0x11
    ori   rF, rF, 0x02
    b     dispatch
     andi  rA, t2, 0xFF
alu_sbc:
    andi  t1, rF, 1
    xori  t1, t1, 1
    xori  t0, t0, 0xFF
    ADDB  rA, t0, t1
    xori  rF, rF, 0x11
    ori   rF, rF, 0x02
    b     dispatch
     andi  rA, t2, 0xFF
alu_and:
    and   rA, rA, t0
    addu  t1, rA, gp
    lbu   rF, %gp_rel(n64z80_sz53p)(t1)
    b     dispatch
     ori  rF, rF, 0x10
alu_xor:
    xor   rA, rA, t0
    addu  t1, rA, gp
    b     dispatch
     lbu  rF, %gp_rel(n64z80_sz53p)(t1)
alu_or:
    or    rA, rA, t0
    addu  t1, rA, gp
    b     dispatch
     lbu  rF, %gp_rel(n64z80_sz53p)(t1)
alu_cp:                           # subb(A, v, 0) without the result; Y/X from v
    subu  t2, rA, t0                # r (bit 8 set on a borrow)
    andi  t3, t2, 0xFF
    addu  t3, t3, gp
    lbu   t1, %gp_rel(n64z80_sz53p)(t3)
    sltu  t4, rA, t0                # C
    xor   t5, rA, t0
    xor   t6, t5, t2
    andi  t6, t6, 0x10              # H: borrow into bit 4
    xor   t7, rA, t2
    and   t5, t5, t7
    andi  t5, t5, 0x80
    srl   t5, t5, 5                 # V: (A ^ v) & (A ^ r) & 0x80
    andi  t1, t1, 0xC0              # S Z
    or    t1, t1, t4
    or    t1, t1, t6
    or    t1, t1, t5
    andi  t9, t0, 0x28
    or    t1, t1, t9
    b     dispatch
     ori  rF, t1, 0x02              # N

# INC / DEC of byte t0: t2 = result byte, F as the reference's inc()/dec()
# (addb(v, 1, 0) / subb(v, 1, 0) with C kept): S Z Y X from the result, H
# when the low nibble wraps, V only for 0x7F -> 0x80 / 0x80 -> 0x7F, N for
# DEC. bal; clobbers t1, t3.
inc_core:
    addiu t2, t0, 1
    andi  t2, t2, 0xFF
    addu  t1, t2, gp
    lbu   t1, %gp_rel(n64z80_sz53p)(t1)
    andi  rF, rF, 1
    andi  t1, t1, 0xFB
    or    rF, rF, t1
    andi  t3, t2, 0x0F
    sltiu t3, t3, 1                 # H: xF -> x0
    sll   t3, t3, 4
    or    rF, rF, t3
    xori  t3, t2, 0x80
    sltiu t3, t3, 1                 # V: 0x7F -> 0x80
    sll   t3, t3, 2
    jr    ra
     or   rF, rF, t3
dec_core:
    addiu t2, t0, -1
    andi  t2, t2, 0xFF
    addu  t1, t2, gp
    lbu   t1, %gp_rel(n64z80_sz53p)(t1)
    andi  rF, rF, 1
    andi  t1, t1, 0xFB
    or    rF, rF, t1
    andi  t3, t2, 0x0F
    xori  t3, t3, 0x0F
    sltiu t3, t3, 1                 # H: x0 -> xF
    sll   t3, t3, 4
    or    rF, rF, t3
    xori  t3, t2, 0x7F
    sltiu t3, t3, 1                 # V: 0x80 -> 0x7F
    sll   t3, t3, 2
    or    rF, rF, t3
    jr    ra
     ori  rF, rF, 0x02              # N

# ---------------------------------------------------------------------------
# Handler families.

.macro LD_R_R op, d, s
OP \op
    GETR  t0, \s
    SETR  \d, t0
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE \op
.endm

.macro LD_R_HL op, r
OP \op
    READ8 t0, rHL, t1
    addiu rPC, rPC, 1
    SETR  \r, t0
    b     dispatch
     CHARGE \op
.endm

.macro LD_HL_R op, r
OP \op
    CHARGE \op
    move  t0, rHL
    GETR  t1, \r
    bal   wr8
     addiu rPC, rPC, 1
    DISPATCH
.endm

.macro LD_R_N op, r
OP \op
    lbu   t0, 1(rPC)
    addiu rPC, rPC, 2
    CHARGE \op
    SETR  \r, t0
    DISPATCH
.endm

.macro ALU_R op, tail, r
OP \op
    GETR  t0, \r
    addiu rPC, rPC, 1
    b     \tail
     CHARGE \op
.endm

.macro ALU_HL op, tail
OP \op
    READ8 t0, rHL, t1
    addiu rPC, rPC, 1
    b     \tail
     CHARGE \op
.endm

.macro ALU_N op, tail
OP \op
    lbu   t0, 1(rPC)
    addiu rPC, rPC, 2
    b     \tail
     CHARGE \op
.endm

.macro INC_R op, r
OP \op
    GETR  t0, \r
    bal   inc_core
     CHARGE \op
    SETR  \r, t2
    b     dispatch
     addiu rPC, rPC, 1
.endm

.macro DEC_R op, r
OP \op
    GETR  t0, \r
    bal   dec_core
     CHARGE \op
    SETR  \r, t2
    b     dispatch
     addiu rPC, rPC, 1
.endm

.macro LD_RR_NN op, rr
OP \op
    FETCH16 \rr, t0
    addiu rPC, rPC, 3
    b     dispatch
     CHARGE \op
.endm

.macro INC_RR op, rr
OP \op
    addiu \rr, \rr, 1
    andi  \rr, \rr, 0xFFFF
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE \op
.endm

.macro DEC_RR op, rr
OP \op
    addiu \rr, \rr, -1
    andi  \rr, \rr, 0xFFFF
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE \op
.endm

# ADD HL,rr (addhl): S Z P kept; H, C and Y/X from the high byte; N = 0;
# WZ = HL + 1. One 16-bit add gives the same carries as the reference's two
# byte adds.
.macro ADD_HL op, rr
OP \op
    addu  t0, rHL, \rr
    xor   t1, t0, rHL
    xor   t1, t1, \rr
    addiu t2, rHL, 1
    sh    t2, N64Z80_OFF_MEM_PTR(rZ)
    andi  rF, rF, 0xC4
    srl   t2, t1, 8
    andi  t2, t2, 0x10
    srl   t3, t0, 8
    andi  t3, t3, 0x28
    srl   t4, t0, 16
    or    rF, rF, t2
    or    rF, rF, t3
    or    rF, rF, t4
    andi  rHL, t0, 0xFFFF
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE \op
.endm

# Condition test: t3 = F & mask; `set` = 1 if the condition holds when the
# flag is set (Z, C, PE, M), 0 when it is clear (NZ, NC, PO, P).
.macro BCOND set, target
  .if \set
    bnez  t3, \target
  .else
    beqz  t3, \target
  .endif
.endm

.macro JR_CC op, mask, set
OP \op
    andi  t3, rF, \mask
    CHARGE \op
    BCOND \set, jr_taken
     lb   t1, 1(rPC)
    b     dispatch
     addiu rPC, rPC, 2
.endm

# JP cc,nn (cond_jump): WZ = nn taken or not.
.macro JP_CC op, mask, set
OP \op
    FETCH16 t0, t1
    andi  t3, rF, \mask
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    BCOND \set, jp_to
     CHARGE \op
    b     dispatch
     addiu rPC, rPC, 3
.endm

# CALL cc,nn (cond_call): push and +7 if taken; WZ = nn either way.
.macro CALL_CC op, mask, set
OP \op
    FETCH16 t5, t1
    andi  t3, rF, \mask
    BCOND \set, call_taken
     CHARGE \op
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    b     dispatch
     addiu rPC, rPC, 3
.endm

.macro RET_CC op, mask, set
OP \op
    andi  t3, rF, \mask
    BCOND \set, ret_taken
     CHARGE \op
    b     dispatch
     addiu rPC, rPC, 1
.endm

# RST p: call(z, p): push the next PC, PC = WZ = p.
.macro RST op, vec
OP \op
    CHARGE \op
    subu  t4, rPC, rBIAS
    bal   push_t4
     addiu t4, t4, 1
    li    t0, \vec
    b     jp_to
     sh   t0, N64Z80_OFF_MEM_PTR(rZ)
.endm

.macro PUSH_RR op, rr
OP \op
    CHARGE \op
    bal   push_t4
     move t4, \rr
    b     dispatch
     addiu rPC, rPC, 1
.endm

.macro POP_RR op, rr
OP \op
    POP16 \rr, t0, t1
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE \op
.endm

# ---------------------------------------------------------------------------
# Handlers.

    LD_R_R   40, 0, 0       # ld b,b
    LD_R_R   41, 0, 1       # ld b,c
    LD_R_R   42, 0, 2       # ld b,d
    LD_R_R   43, 0, 3       # ld b,e
    LD_R_R   44, 0, 4       # ld b,h
    LD_R_R   45, 0, 5       # ld b,l
    LD_R_HL  46, 0          # ld b,(hl)
    LD_R_R   47, 0, 7       # ld b,a
    LD_R_R   48, 1, 0       # ld c,b
    LD_R_R   49, 1, 1       # ld c,c
    LD_R_R   4A, 1, 2       # ld c,d
    LD_R_R   4B, 1, 3       # ld c,e
    LD_R_R   4C, 1, 4       # ld c,h
    LD_R_R   4D, 1, 5       # ld c,l
    LD_R_HL  4E, 1          # ld c,(hl)
    LD_R_R   4F, 1, 7       # ld c,a
    LD_R_R   50, 2, 0       # ld d,b
    LD_R_R   51, 2, 1       # ld d,c
    LD_R_R   52, 2, 2       # ld d,d
    LD_R_R   53, 2, 3       # ld d,e
    LD_R_R   54, 2, 4       # ld d,h
    LD_R_R   55, 2, 5       # ld d,l
    LD_R_HL  56, 2          # ld d,(hl)
    LD_R_R   57, 2, 7       # ld d,a
    LD_R_R   58, 3, 0       # ld e,b
    LD_R_R   59, 3, 1       # ld e,c
    LD_R_R   5A, 3, 2       # ld e,d
    LD_R_R   5B, 3, 3       # ld e,e
    LD_R_R   5C, 3, 4       # ld e,h
    LD_R_R   5D, 3, 5       # ld e,l
    LD_R_HL  5E, 3          # ld e,(hl)
    LD_R_R   5F, 3, 7       # ld e,a
    LD_R_R   60, 4, 0       # ld h,b
    LD_R_R   61, 4, 1       # ld h,c
    LD_R_R   62, 4, 2       # ld h,d
    LD_R_R   63, 4, 3       # ld h,e
    LD_R_R   64, 4, 4       # ld h,h
    LD_R_R   65, 4, 5       # ld h,l
    LD_R_HL  66, 4          # ld h,(hl)
    LD_R_R   67, 4, 7       # ld h,a
    LD_R_R   68, 5, 0       # ld l,b
    LD_R_R   69, 5, 1       # ld l,c
    LD_R_R   6A, 5, 2       # ld l,d
    LD_R_R   6B, 5, 3       # ld l,e
    LD_R_R   6C, 5, 4       # ld l,h
    LD_R_R   6D, 5, 5       # ld l,l
    LD_R_HL  6E, 5          # ld l,(hl)
    LD_R_R   6F, 5, 7       # ld l,a
    LD_HL_R  70, 0          # ld (hl),b
    LD_HL_R  71, 1          # ld (hl),c
    LD_HL_R  72, 2          # ld (hl),d
    LD_HL_R  73, 3          # ld (hl),e
    LD_HL_R  74, 4          # ld (hl),h
    LD_HL_R  75, 5          # ld (hl),l
    LD_HL_R  77, 7          # ld (hl),a
    LD_R_R   78, 7, 0       # ld a,b
    LD_R_R   79, 7, 1       # ld a,c
    LD_R_R   7A, 7, 2       # ld a,d
    LD_R_R   7B, 7, 3       # ld a,e
    LD_R_R   7C, 7, 4       # ld a,h
    LD_R_R   7D, 7, 5       # ld a,l
    LD_R_HL  7E, 7          # ld a,(hl)
    LD_R_R   7F, 7, 7       # ld a,a

    ALU_R    80, alu_add, 0     # add a,b
    ALU_R    81, alu_add, 1     # add a,c
    ALU_R    82, alu_add, 2     # add a,d
    ALU_R    83, alu_add, 3     # add a,e
    ALU_R    84, alu_add, 4     # add a,h
    ALU_R    85, alu_add, 5     # add a,l
    ALU_HL   86, alu_add        # add a,(hl)
    ALU_R    87, alu_add, 7     # add a,a
    ALU_R    88, alu_adc, 0     # adc a,b
    ALU_R    89, alu_adc, 1     # adc a,c
    ALU_R    8A, alu_adc, 2     # adc a,d
    ALU_R    8B, alu_adc, 3     # adc a,e
    ALU_R    8C, alu_adc, 4     # adc a,h
    ALU_R    8D, alu_adc, 5     # adc a,l
    ALU_HL   8E, alu_adc        # adc a,(hl)
    ALU_R    8F, alu_adc, 7     # adc a,a
    ALU_R    90, alu_sub, 0     # sub b
    ALU_R    91, alu_sub, 1     # sub c
    ALU_R    92, alu_sub, 2     # sub d
    ALU_R    93, alu_sub, 3     # sub e
    ALU_R    94, alu_sub, 4     # sub h
    ALU_R    95, alu_sub, 5     # sub l
    ALU_HL   96, alu_sub        # sub (hl)
    ALU_R    97, alu_sub, 7     # sub a
    ALU_R    98, alu_sbc, 0     # sbc a,b
    ALU_R    99, alu_sbc, 1     # sbc a,c
    ALU_R    9A, alu_sbc, 2     # sbc a,d
    ALU_R    9B, alu_sbc, 3     # sbc a,e
    ALU_R    9C, alu_sbc, 4     # sbc a,h
    ALU_R    9D, alu_sbc, 5     # sbc a,l
    ALU_HL   9E, alu_sbc        # sbc a,(hl)
    ALU_R    9F, alu_sbc, 7     # sbc a,a
    ALU_R    A0, alu_and, 0     # and b
    ALU_R    A1, alu_and, 1     # and c
    ALU_R    A2, alu_and, 2     # and d
    ALU_R    A3, alu_and, 3     # and e
    ALU_R    A4, alu_and, 4     # and h
    ALU_R    A5, alu_and, 5     # and l
    ALU_HL   A6, alu_and        # and (hl)
    ALU_R    A8, alu_xor, 0     # xor b
    ALU_R    A9, alu_xor, 1     # xor c
    ALU_R    AA, alu_xor, 2     # xor d
    ALU_R    AB, alu_xor, 3     # xor e
    ALU_R    AC, alu_xor, 4     # xor h
    ALU_R    AD, alu_xor, 5     # xor l
    ALU_HL   AE, alu_xor        # xor (hl)
    ALU_R    B0, alu_or, 0      # or b
    ALU_R    B1, alu_or, 1      # or c
    ALU_R    B2, alu_or, 2      # or d
    ALU_R    B3, alu_or, 3      # or e
    ALU_R    B4, alu_or, 4      # or h
    ALU_R    B5, alu_or, 5      # or l
    ALU_HL   B6, alu_or         # or (hl)
    ALU_R    B8, alu_cp, 0      # cp b
    ALU_R    B9, alu_cp, 1      # cp c
    ALU_R    BA, alu_cp, 2      # cp d
    ALU_R    BB, alu_cp, 3      # cp e
    ALU_R    BC, alu_cp, 4      # cp h
    ALU_R    BD, alu_cp, 5      # cp l
    ALU_HL   BE, alu_cp         # cp (hl)
    ALU_R    BF, alu_cp, 7      # cp a

    ALU_N    C6, alu_add        # add a,n
    ALU_N    CE, alu_adc        # adc a,n
    ALU_N    D6, alu_sub        # sub n
    ALU_N    DE, alu_sbc        # sbc a,n
    ALU_N    E6, alu_and        # and n
    ALU_N    EE, alu_xor        # xor n
    ALU_N    F6, alu_or         # or n
    ALU_N    FE, alu_cp         # cp n

    INC_R    04, 0              # inc b
    DEC_R    05, 0              # dec b
    LD_R_N   06, 0              # ld b,n
    INC_R    0C, 1              # inc c
    DEC_R    0D, 1              # dec c
    LD_R_N   0E, 1              # ld c,n
    INC_R    14, 2              # inc d
    DEC_R    15, 2              # dec d
    LD_R_N   16, 2              # ld d,n
    INC_R    1C, 3              # inc e
    DEC_R    1D, 3              # dec e
    LD_R_N   1E, 3              # ld e,n
    INC_R    24, 4              # inc h
    DEC_R    25, 4              # dec h
    LD_R_N   26, 4              # ld h,n
    INC_R    2C, 5              # inc l
    DEC_R    2D, 5              # dec l
    LD_R_N   2E, 5              # ld l,n
    INC_R    3C, 7              # inc a
    DEC_R    3D, 7              # dec a
    LD_R_N   3E, 7              # ld a,n

    LD_RR_NN 01, rBC            # ld bc,nn
    LD_RR_NN 11, rDE            # ld de,nn
    LD_RR_NN 21, rHL            # ld hl,nn
    LD_RR_NN 31, rSP            # ld sp,nn
    INC_RR   03, rBC            # inc bc
    INC_RR   13, rDE            # inc de
    INC_RR   23, rHL            # inc hl
    INC_RR   33, rSP            # inc sp
    DEC_RR   0B, rBC            # dec bc
    DEC_RR   1B, rDE            # dec de
    DEC_RR   2B, rHL            # dec hl
    DEC_RR   3B, rSP            # dec sp
    ADD_HL   09, rBC            # add hl,bc
    ADD_HL   19, rDE            # add hl,de
    ADD_HL   29, rHL            # add hl,hl
    ADD_HL   39, rSP            # add hl,sp

    JR_CC    20, 0x40, 0        # jr nz
    JR_CC    28, 0x40, 1        # jr z
    JR_CC    30, 0x01, 0        # jr nc
    JR_CC    38, 0x01, 1        # jr c
    JP_CC    C2, 0x40, 0        # jp nz
    JP_CC    CA, 0x40, 1        # jp z
    JP_CC    D2, 0x01, 0        # jp nc
    JP_CC    DA, 0x01, 1        # jp c
    JP_CC    E2, 0x04, 0        # jp po
    JP_CC    EA, 0x04, 1        # jp pe
    JP_CC    F2, 0x80, 0        # jp p
    JP_CC    FA, 0x80, 1        # jp m
    CALL_CC  C4, 0x40, 0        # call nz
    CALL_CC  CC, 0x40, 1        # call z
    CALL_CC  D4, 0x01, 0        # call nc
    CALL_CC  DC, 0x01, 1        # call c
    CALL_CC  E4, 0x04, 0        # call po
    CALL_CC  EC, 0x04, 1        # call pe
    CALL_CC  F4, 0x80, 0        # call p
    CALL_CC  FC, 0x80, 1        # call m
    RET_CC   C0, 0x40, 0        # ret nz
    RET_CC   C8, 0x40, 1        # ret z
    RET_CC   D0, 0x01, 0        # ret nc
    RET_CC   D8, 0x01, 1        # ret c
    RET_CC   E0, 0x04, 0        # ret po
    RET_CC   E8, 0x04, 1        # ret pe
    RET_CC   F0, 0x80, 0        # ret p
    RET_CC   F8, 0x80, 1        # ret m
    RST      C7, 0x00
    RST      CF, 0x08
    RST      D7, 0x10
    RST      DF, 0x18
    RST      E7, 0x20
    RST      EF, 0x28
    RST      F7, 0x30
    RST      FF, 0x38
    PUSH_RR  C5, rBC            # push bc
    PUSH_RR  D5, rDE            # push de
    PUSH_RR  E5, rHL            # push hl
    POP_RR   C1, rBC            # pop bc
    POP_RR   D1, rDE            # pop de
    POP_RR   E1, rHL            # pop hl

OP A7                           # and a: A kept, F = sz53p[A] | H
    addu  t1, rA, gp
    lbu   rF, %gp_rel(n64z80_sz53p)(t1)
    addiu rPC, rPC, 1
    ori   rF, rF, 0x10
    b     dispatch
     CHARGE A7

OP B7                           # or a: A kept, F = sz53p[A]
    addu  t1, rA, gp
    lbu   rF, %gp_rel(n64z80_sz53p)(t1)
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE B7

OP AF                           # xor a: A = 0, F = sz53p[0] = Z | P
    move  rA, zero
    li    rF, 0x44
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE AF

OP 00                           # nop
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 00

OP 02                           # ld (bc),a: WZ = A << 8 | (BC + 1) & 0xFF
    CHARGE 02
    move  t0, rBC
    move  t1, rA
    bal   wr8
     addiu rPC, rPC, 1
    addiu t0, rBC, 1
    andi  t0, t0, 0xFF
    sll   t1, rA, 8
    or    t0, t0, t1
    b     dispatch
     sh    t0, N64Z80_OFF_MEM_PTR(rZ)

OP 12                           # ld (de),a
    CHARGE 12
    move  t0, rDE
    move  t1, rA
    bal   wr8
     addiu rPC, rPC, 1
    addiu t0, rDE, 1
    andi  t0, t0, 0xFF
    sll   t1, rA, 8
    or    t0, t0, t1
    b     dispatch
     sh    t0, N64Z80_OFF_MEM_PTR(rZ)

OP 0A                           # ld a,(bc): WZ = BC + 1
    READ8 rA, rBC, t0
    addiu t1, rBC, 1
    sh    t1, N64Z80_OFF_MEM_PTR(rZ)
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 0A

OP 1A                           # ld a,(de)
    READ8 rA, rDE, t0
    addiu t1, rDE, 1
    sh    t1, N64Z80_OFF_MEM_PTR(rZ)
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 1A

OP 07                           # rlca
    srl   t0, rA, 7
    sll   rA, rA, 1
    or    rA, rA, t0
    andi  rA, rA, 0xFF
    andi  rF, rF, 0xC4
    or    rF, rF, t0
    andi  t1, rA, 0x28
    or    rF, rF, t1
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 07

OP 0F                           # rrca
    andi  t0, rA, 1
    srl   rA, rA, 1
    sll   t1, t0, 7
    or    rA, rA, t1
    andi  rF, rF, 0xC4
    or    rF, rF, t0
    andi  t1, rA, 0x28
    or    rF, rF, t1
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 0F

OP 17                           # rla
    andi  t2, rF, 1
    srl   t0, rA, 7
    sll   rA, rA, 1
    or    rA, rA, t2
    andi  rA, rA, 0xFF
    andi  rF, rF, 0xC4
    or    rF, rF, t0
    andi  t1, rA, 0x28
    or    rF, rF, t1
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 17

OP 1F                           # rra
    andi  t2, rF, 1
    andi  t0, rA, 1
    srl   rA, rA, 1
    sll   t2, t2, 7
    or    rA, rA, t2
    andi  rF, rF, 0xC4
    or    rF, rF, t0
    andi  t1, rA, 0x28
    or    rF, rF, t1
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 1F

OP 2F                           # cpl
    xori  rA, rA, 0xFF
    andi  rF, rF, 0xC5
    ori   rF, rF, 0x12
    andi  t1, rA, 0x28
    or    rF, rF, t1
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 2F

OP 37                           # scf
    andi  rF, rF, 0xC4
    ori   rF, rF, 0x01
    andi  t1, rA, 0x28
    or    rF, rF, t1
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 37

OP 3F                           # ccf: H = old C, C = !C
    andi  t0, rF, 1
    andi  rF, rF, 0xC4
    sll   t1, t0, 4
    or    rF, rF, t1
    xori  t0, t0, 1
    or    rF, rF, t0
    andi  t1, rA, 0x28
    or    rF, rF, t1
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 3F

OP 08                           # ex af,af'
    lbu   t0, N64Z80_OFF_A_(rZ)
    lbu   t1, N64Z80_OFF_F_(rZ)
    sb    rA, N64Z80_OFF_A_(rZ)
    sb    rF, N64Z80_OFF_F_(rZ)
    move  rA, t0
    move  rF, t1
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 08

OP D9                           # exx
    lbu   t0, N64Z80_OFF_B_(rZ)
    lbu   t1, N64Z80_OFF_C_(rZ)
    srl   t2, rBC, 8
    sb    t2, N64Z80_OFF_B_(rZ)
    sb    rBC, N64Z80_OFF_C_(rZ)
    sll   t0, t0, 8
    or    rBC, t0, t1
    lbu   t0, N64Z80_OFF_D_(rZ)
    lbu   t1, N64Z80_OFF_E_(rZ)
    srl   t2, rDE, 8
    sb    t2, N64Z80_OFF_D_(rZ)
    sb    rDE, N64Z80_OFF_E_(rZ)
    sll   t0, t0, 8
    or    rDE, t0, t1
    lbu   t0, N64Z80_OFF_H_(rZ)
    lbu   t1, N64Z80_OFF_L_(rZ)
    srl   t2, rHL, 8
    sb    t2, N64Z80_OFF_H_(rZ)
    sb    rHL, N64Z80_OFF_L_(rZ)
    sll   t0, t0, 8
    or    rHL, t0, t1
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE D9

OP EB                           # ex de,hl
    move  t0, rDE
    move  rDE, rHL
    move  rHL, t0
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE EB

OP F9                           # ld sp,hl
    move  rSP, rHL
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE F9

OP 10                           # djnz: --B, cond_jr
    addiu rBC, rBC, -0x100
    andi  rBC, rBC, 0xFFFF
    srl   t3, rBC, 8
    CHARGE 10
    bnez  t3, jr_taken
     lb   t1, 1(rPC)
    b     dispatch
     addiu rPC, rPC, 2

OP 18                           # jr e: no WZ
    lb    t1, 1(rPC)
    subu  t0, rPC, rBIAS
    addiu t0, t0, 2
    addu  t0, t0, t1
    andi  t0, t0, 0xFFFF
    b     jp_to
     CHARGE 18

OP C3                           # jp nn: PC = WZ = nn
    FETCH16 t0, t1
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    b     jp_to
     CHARGE C3

OP E9                           # jp (hl): no WZ
    move  t0, rHL
    b     jp_to
     CHARGE E9

OP C9                           # ret: PC = WZ = pop
    POP16 t0, t1, t2
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    b     jp_to
     CHARGE C9

OP CD                           # call nn: push, PC = WZ = nn
    CHARGE CD
    FETCH16 t5, t1
    subu  t4, rPC, rBIAS
    bal   push_t4
     addiu t4, t4, 3
    move  t0, t5
    b     jp_to
     sh   t5, N64Z80_OFF_MEM_PTR(rZ)

OP F5                           # push af
    CHARGE F5
    sll   t4, rA, 8
    bal   push_t4
     or   t4, t4, rF
    b     dispatch
     addiu rPC, rPC, 1

OP F1                           # pop af
    POP16 t0, t1, t2
    srl   rA, t0, 8
    andi  rF, t0, 0xFF
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE F1

OP E3                           # ex (sp),hl: read (SP), write L then H, WZ = HL
    CHARGE E3
    READ8 t5, rSP, t0
    addiu t2, rSP, 1
    andi  t2, t2, 0xFFFF
    READ8 t3, t2, t0
    sll   t3, t3, 8
    or    t5, t5, t3
    move  t0, rSP
    bal   wr8
     andi t1, rHL, 0xFF
    addiu t0, rSP, 1
    andi  t0, t0, 0xFFFF
    bal   wr8
     srl  t1, rHL, 8
    move  rHL, t5
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    b     dispatch
     addiu rPC, rPC, 1

OP 22                           # ld (nn),hl: L at nn, H at nn+1, WZ = nn + 1
    CHARGE 22
    FETCH16 t5, t1
    move  t0, t5
    bal   wr8
     andi t1, rHL, 0xFF
    addiu t5, t5, 1
    andi  t5, t5, 0xFFFF
    move  t0, t5
    bal   wr8
     srl  t1, rHL, 8
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    b     dispatch
     addiu rPC, rPC, 3

OP 2A                           # ld hl,(nn): WZ = nn + 1
    FETCH16 t0, t1
    READ8 t2, t0, t1
    addiu t0, t0, 1
    andi  t0, t0, 0xFFFF
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    READ8 t3, t0, t1
    sll   t3, t3, 8
    or    rHL, t2, t3
    addiu rPC, rPC, 3
    b     dispatch
     CHARGE 2A

OP 32                           # ld (nn),a: WZ = A << 8 | (nn + 1) & 0xFF
    CHARGE 32
    FETCH16 t5, t1
    move  t0, t5
    bal   wr8
     move t1, rA
    addiu t5, t5, 1
    andi  t5, t5, 0xFF
    sll   t1, rA, 8
    or    t5, t5, t1
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    b     dispatch
     addiu rPC, rPC, 3

OP 3A                           # ld a,(nn): WZ = nn + 1
    FETCH16 t0, t1
    READ8 rA, t0, t1
    addiu t0, t0, 1
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    addiu rPC, rPC, 3
    b     dispatch
     CHARGE 3A

OP 34                           # inc (hl)
    CHARGE 34
    READ8 t0, rHL, t1
    bal   inc_core
     nop
    move  t0, rHL
    move  t1, t2
    bal   wr8
     addiu rPC, rPC, 1
    DISPATCH

OP 35                           # dec (hl)
    CHARGE 35
    READ8 t0, rHL, t1
    bal   dec_core
     nop
    move  t0, rHL
    move  t1, t2
    bal   wr8
     addiu rPC, rPC, 1
    DISPATCH

OP 36                           # ld (hl),n
    CHARGE 36
    move  t0, rHL
    lbu   t1, 1(rPC)
    bal   wr8
     addiu rPC, rPC, 2
    DISPATCH

# ===========================================================================
# Prefixed instructions (CB, DD, ED, FD, DD CB / FD CB).
#
# A prefix handler only counts R's second increment (rRB; rN already counts
# the first), reads the next opcode byte and jumps through that prefix's
# table. The handler there charges the instruction's cycles, so any table
# entry can instead be pfx_fallback, which takes the increment back,
# rewinds to rPC0 and runs the whole instruction in C. One prefix with its
# operands is at most 4 bytes, which the dispatch's limit check already
# covers; a chain (DD DD, FD ED, ...) repeats the check at each further
# prefix (ddfd_chain).

    RARE
# An instruction that straddles a mapping boundary: copy it, run it from the
# copy (the limit check is skipped: it fails there).
bounce:
    subu  t0, rPC, rBIAS
    andi  t0, t0, 0xFFFF
    slt   t1, rPC0, t0
    beqz  t1, edge_exit             # wrapped past 0xFFFF: pc <= pc0 stops
     nop
    bal   bounce_fill
     nop
    lbu   t0, 0(rPC)
    sll   t0, t0, 2
    addu  t0, t0, gp
    lw    t0, %gp_rel(n64z80_optab)(t0)
    subu  rPC0, rPC, rBIAS
    jr    t0
     addiu rN, rN, 1

unbounce:
    subu  t0, rPC, rBIAS
    andi  t0, t0, 0xFFFF
    slt   t1, rPC0, t0
    beqz  t1, edge_exit             # wrapped past 0xFFFF: pc <= pc0 stops
     nop
    REMAP
    b     dispatch_nocyc
     nop

# Copy the 4 bytes at Z80 address t0 (wrapping at 0xFFFF) through the rmap
# to n64z80_bbuf and fetch from there: rBIAS = bbuf - t0 (so rPC - rBIAS is
# still the Z80 address, up to 0x10002 past a wrap: users mask it), rPC =
# bbuf, rLIM = 0 so every dispatch from the copy refetches. bal; clobbers
# t1-t4.
bounce_fill:
    addiu t4, gp, %gp_rel(n64z80_bbuf)
    move  t3, t0
    READ8 t1, t3, t2
    sb    t1, 0(t4)
    addiu t3, t3, 1
    andi  t3, t3, 0xFFFF
    READ8 t1, t3, t2
    sb    t1, 1(t4)
    addiu t3, t3, 1
    andi  t3, t3, 0xFFFF
    READ8 t1, t3, t2
    sb    t1, 2(t4)
    addiu t3, t3, 1
    andi  t3, t3, 0xFFFF
    READ8 t1, t3, t2
    sb    t1, 3(t4)
    subu  rBIAS, t4, t0
    move  rPC, t4
    jr    ra
     move rLIM, zero

# NMI: no IFF2 change, +11, call 0x66.
svc_nmi:
    sb    zero, N64Z80_OFF_NMI_PENDING(rZ)
    li    t5, 0x66
    b     svc_call
     addiu rCYC, rCYC, 11

# Accepted INT: IM 1 calls 0x38 (+13), IM 2 the vector at I << 8 |
# int_data (+19), IM 0 executes int_data (+11 and its own cycles).
svc_int:
    lbu   t0, N64Z80_OFF_IM(rZ)
    sb    zero, N64Z80_OFF_INT_PENDING(rZ)
    sb    zero, N64Z80_OFF_IFF2(rZ)
    li    t1, 1
    beq   t0, t1, 1f
     li   t5, 0x38
    li    t1, 2
    bne   t0, t1, svc_im0
     lbu  t0, N64Z80_OFF_I(rZ)
    lbu   t1, N64Z80_OFF_INT_DATA(rZ)
    sll   t0, t0, 8
    or    t0, t0, t1
    READ8 t5, t0, t1
    addiu t0, t0, 1
    andi  t0, t0, 0xFFFF
    READ8 t1, t0, t2
    sll   t1, t1, 8
    or    t5, t5, t1
    addiu rCYC, rCYC, 6             # 19 in all
1:  addiu rCYC, rCYC, 13

# Both: HALT ends, IFF1 = 0, R + 1, push PC, PC = WZ = t5. A write callback
# in the push may poison: undo it, as the C service never poisons.
svc_call:
    sb    zero, N64Z80_OFF_HALTED(rZ)
    sb    zero, N64Z80_OFF_IFF1(rZ)
    sb    zero, N64Z80_OFF_EVM_INT(rZ)
    sb    zero, N64Z80_OFF_EVM_LINE(rZ)
    addiu rRB, rRB, 1
    subu  t4, rPC, rBIAS
    bal   push_t4
     nop
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    move  t0, t5
    REMAP
    lw    t0, %gp_rel(n64z80_cbase)(gp)
    lw    t1, %gp_rel(n64z80_until)(gp)
    subu  t0, t0, t1
    addu  rCYC, rCYC, t0
    b     se_halted
     sw   t1, %gp_rel(n64z80_cbase)(gp)

# IM 0 (t0 = the mode): exec_opcode(int_data) with the PC where it is. It
# runs from the bounce buffer as the opcode at PC - 1, followed by the bytes
# at PC (its operands), with rPC0 = PC - 1 (block repeats) and without
# counting an instruction. Poisoned, so its tail comes back to slow_exit,
# which sees n64z80_im0, restores rPC0 and resumes at the stop test: the
# reference services once per instruction. Modes 3 and up only acknowledge
# (the reference just reports them).
svc_im0:
    sb    zero, N64Z80_OFF_HALTED(rZ)
    sb    zero, N64Z80_OFF_IFF1(rZ)
    sb    zero, N64Z80_OFF_EVM_INT(rZ)
    sb    zero, N64Z80_OFF_EVM_LINE(rZ)
    lbu   t0, N64Z80_OFF_IM(rZ)
    bnez  t0, se_halted
     addiu rRB, rRB, 1              # the service's R + 1
    addiu rRB, rRB, 1               # exec_opcode's
    addiu rCYC, rCYC, 11
    lw    t0, %gp_rel(n64z80_cbase)(gp)
    addu  t0, t0, rCYC
    sw    t0, %gp_rel(n64z80_cbase)(gp)
    move  rCYC, zero
    lui   t0, 1
    or    t0, t0, rPC0
    sw    t0, %gp_rel(n64z80_im0)(gp)
    subu  t0, rPC, rBIAS
    addiu t0, t0, -1
    bal   bounce_fill
     andi t0, t0, 0xFFFF
    lbu   t1, N64Z80_OFF_INT_DATA(rZ)
    sb    t1, 0(rPC)
    subu  rPC0, rPC, rBIAS
    sll   t1, t1, 2
    addu  t1, t1, gp
    lw    t1, %gp_rel(n64z80_optab)(t1)
    jr    t1
     nop

svc_im0_done:
    sw    zero, %gp_rel(n64z80_im0)(gp)
    b     se_halted
     andi rPC0, t2, 0xFFFF

#if N64Z80_C_FALLBACK
pfx_fallback:
    move  t0, rPC0
    REMAP
    b     op_fallback
     addiu rRB, rRB, -1
#endif

# Jump through `table` on the byte at rPC+1 (t0), with rPC advanced to it.
.macro PREFIX table, group
    lbu   t0, 1(rPC)
    addiu rPC, rPC, 1
#ifdef N64Z80_PROF
    addiu t1, t0, 256 * \group
    sw    t1, %gp_rel(n64z80_prof_key)(gp)
#endif
    sll   t1, t0, 2
    addu  t1, t1, gp
    lw    t1, %gp_rel(\table)(t1)
    jr    t1
     addiu rRB, rRB, 1
.endm

OP CB
    PREFIX n64z80_cbtab, 1
OP DD
    PREFIX n64z80_ddtab, 3
OP ED
    PREFIX n64z80_edtab, 2
OP FD
    PREFIX n64z80_fdtab, 4

# DD/FD before an opcode exec_opcode_ddfd does not handle itself: it runs as
# the unprefixed opcode (t0 = it, rPC at it) after cyc_ddfd[op].
    HOT
ddfd_base:
    addu  t1, t0, gp
    lbu   t1, %gp_rel(n64z80_cycdd)(t1)
    addu  rCYC, rCYC, t1
    sll   t0, t0, 2
    addu  t0, t0, gp
    lw    t0, %gp_rel(n64z80_optab)(t0)
    jr    t0
     nop

# A prefix after DD/FD (DD, ED, FD; exec_opcode_ddfd runs it as the
# unprefixed opcode, i.e. as a new prefix): a chain. Its own handler reads
# up to 4 bytes from rPC, so the limit check is repeated here; past the
# limit, the rest runs from a copy.
    RARE
ddfd_chain:
    sltu  t1, rPC, rLIM
    bnez  t1, ddfd_base
     subu t2, rPC, rBIAS             # (t0 is the opcode on the taken path)
    bal   bounce_fill
     andi t0, t2, 0xFFFF
    b     ddfd_base
     lbu  t0, 0(rPC)
    HOT

# Shared tails: rPC is at the opcode byte after the prefix; skip it and n-1
# more bytes, next instruction.
next1:
    b     dispatch
     addiu rPC, rPC, 1
next2:
    b     dispatch
     addiu rPC, rPC, 2
next3:
    b     dispatch
     addiu rPC, rPC, 3

# Rotate/shift cores (cb_rlc ... cb_srl): t0 = byte -> t2 = result,
# F = sz53p[result] | C (bal). Clobbers t1, t3.
    COLD
rot_rlc:
    srl   t1, t0, 7
    sll   t2, t0, 1
    or    t2, t2, t1
    b     rot_flags
     andi t2, t2, 0xFF
rot_rrc:
    andi  t1, t0, 1
    srl   t2, t0, 1
    sll   t3, t1, 7
    b     rot_flags
     or   t2, t2, t3
rot_rl:
    srl   t1, t0, 7
    sll   t2, t0, 1
    andi  t3, rF, 1
    or    t2, t2, t3
    b     rot_flags
     andi t2, t2, 0xFF
rot_rr:
    andi  t1, t0, 1
    srl   t2, t0, 1
    andi  t3, rF, 1
    sll   t3, t3, 7
    b     rot_flags
     or   t2, t2, t3
rot_sla:
    srl   t1, t0, 7
    sll   t2, t0, 1
    b     rot_flags
     andi t2, t2, 0xFF
rot_sra:
    andi  t1, t0, 1
    srl   t2, t0, 1
    andi  t3, t0, 0x80
    b     rot_flags
     or   t2, t2, t3
rot_sll:
    srl   t1, t0, 7
    sll   t2, t0, 1
    ori   t2, t2, 1
    b     rot_flags
     andi t2, t2, 0xFF
rot_srl:
    andi  t1, t0, 1
    srl   t2, t0, 1
rot_flags:
    addu  t3, t2, gp
    lbu   rF, %gp_rel(n64z80_sz53p)(t3)
    jr    ra
     or   rF, rF, t1

# F for BIT (cb_bit): t2 = byte & mask, t3 = the Y/X source (the byte, or
# the high byte of WZ / of the (IZ+d) address). Clobbers t1, t3.
.macro BITFLAGS
    andi  rF, rF, 0x01
    ori   rF, rF, 0x10
    andi  t1, t2, 0x80
    or    rF, rF, t1
    sltiu t1, t2, 1
    sll   t1, t1, 6               # Z
    or    rF, rF, t1
    srl   t1, t1, 4               # P/V = Z
    or    rF, rF, t1
    andi  t3, t3, 0x28
    or    rF, rF, t3
.endm

# ---------------------------------------------------------------------------
# CB xx (exec_opcode_cb): 8 cycles. (HL) forms read through the rmap and add
# 7 before the write back; BIT n,(HL) adds 4, takes Y/X from WZ's high
# byte and also writes the (unchanged) byte back.

.macro CBOP op
    PLACE CB_\op
op_CB_\op:
    addiu rCYC, rCYC, 8
.endm

.macro CB_ROT op, core, r
CBOP \op
  .if \r == 6
    READ8 t0, rHL, t1
    bal   \core
     nop
    addiu rCYC, rCYC, 7
    move  t0, rHL
    bal   wr8
     move t1, t2
  .else
    GETR  t0, \r
    bal   \core
     nop
    SETR  \r, t2
  .endif
    b     dispatch
     addiu rPC, rPC, 1
.endm

.macro CB_BIT op, y, r
CBOP \op
  .if \r == 6
    READ8 t0, rHL, t1
    lhu   t3, N64Z80_OFF_MEM_PTR(rZ)
    srl   t3, t3, 8
    addiu rCYC, rCYC, 4
  .else
    GETR  t0, \r
    move  t3, t0
  .endif
    andi  t2, t0, (1 << \y)
    BITFLAGS
  .if \r == 6
    # The reference writes the byte back (exec_opcode_cb: reg == &hl), after
    # the +4. Keep it: it is a bus event and sets `wrote`.
    move  t1, t0
    bal   wr8
     move t0, rHL
  .endif
    b     dispatch
     addiu rPC, rPC, 1
.endm

# RES (set = 0) / SET (set = 1) bit y of r.
.macro CB_RES_SET op, set, y, r
CBOP \op
  .if \r == 6
    READ8 t0, rHL, t1
  .else
    GETR  t0, \r
  .endif
  .if \set
    ori   t2, t0, (1 << \y)
  .else
    andi  t2, t0, (0xFF ^ (1 << \y))
  .endif
  .if \r == 6
    addiu rCYC, rCYC, 7
    move  t0, rHL
    bal   wr8
     move t1, t2
  .else
    SETR  \r, t2
  .endif
    b     dispatch
     addiu rPC, rPC, 1
.endm

# ---------------------------------------------------------------------------
# DD CB d xx / FD CB d xx (exec_opcode_dcb), shared by both prefixes: entered
# with t5 = (IZ + d) & 0xFFFF and rPC at the CB byte. WZ = the address; the
# byte is read first; BIT adds 20 cycles (Y/X from the address's high byte),
# the others write back, then add 23. Rotates, RES and SET also copy the
# result to register z unless z = 6. cyc_ddfd[CB] is 0.

.macro XC_ROT op, core, r
    PLACE XC_\op
op_XC_\op:
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    READ8 t0, t5, t1
    bal   \core
     nop
  .if \r != 6
    SETR  \r, t2
  .endif
    b     xc_write
     nop
.endm

.macro XC_BIT y, o0, o1, o2, o3, o4, o5, o6, o7
    HOT
op_XC_\o0:
op_XC_\o1:
op_XC_\o2:
op_XC_\o3:
op_XC_\o4:
op_XC_\o5:
op_XC_\o6:
op_XC_\o7:
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    READ8 t0, t5, t1
    andi  t2, t0, (1 << \y)
    srl   t3, t5, 8
    BITFLAGS
    addiu rCYC, rCYC, 20
    b     dispatch
     addiu rPC, rPC, 3
.endm

.macro XC_RES_SET op, set, y, r
    PLACE XC_\op
op_XC_\op:
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    READ8 t0, t5, t1
  .if \set
    ori   t2, t0, (1 << \y)
  .else
    andi  t2, t0, (0xFF ^ (1 << \y))
  .endif
  .if \r != 6
    SETR  \r, t2
  .endif
    b     xc_write
     nop
.endm

# Write t2 to (IZ+d) = t5, +23, next instruction.
    COLD
xc_write:
    move  t0, t5
    bal   wr8
     move t1, t2
    addiu rCYC, rCYC, 23
    b     dispatch
     addiu rPC, rPC, 3

# ---------------------------------------------------------------------------
# DD/FD xx index-register forms (exec_opcode_ddfd), instantiated for IX and
# IY. `ix` is the struct offset; on N64 (big endian) the high byte is at
# ix, the low byte at ix+1.

.macro IZOP p, op
    PLACE \p\()_\op
op_\p\()_\op:
    addiu rCYC, rCYC, CYCDD_\op
.endm

# dst = (IZ + d) & 0xFFFF with d at rPC+1, WZ = dst (the reference's IZD).
.macro IZADDR dst, ix
    lhu   \dst, \ix(rZ)
    lb    t9, 1(rPC)
    addu  \dst, \dst, t9
    andi  \dst, \dst, 0xFFFF
    sh    \dst, N64Z80_OFF_MEM_PTR(rZ)
.endm

.macro IZ_LD_R_D p, ix, op, r      # ld r,(iz+d)
IZOP \p, \op
    IZADDR t0, \ix
    READ8 t1, t0, t2
    SETR  \r, t1
    b     dispatch
     addiu rPC, rPC, 2
.endm

.macro IZ_LD_D_R p, ix, op, r      # ld (iz+d),r
IZOP \p, \op
    IZADDR t0, \ix
    GETR  t1, \r
    bal   wr8
     nop
    b     dispatch
     addiu rPC, rPC, 2
.endm

.macro IZ_ALU_D p, ix, op, tail    # alu a,(iz+d)
IZOP \p, \op
    IZADDR t1, \ix
    READ8 t0, t1, t2
    b     \tail
     addiu rPC, rPC, 2
.endm

.macro IZ_ALU_B p, ix, op, tail, half   # alu a,izh (half 0) / izl (half 1)
IZOP \p, \op
    lbu   t0, \ix+\half(rZ)
    b     \tail
     addiu rPC, rPC, 1
.endm

.macro IZ_LD_R_B p, ix, op, r, half     # ld r,izh / izl
IZOP \p, \op
    lbu   t0, \ix+\half(rZ)
    SETR  \r, t0
    b     dispatch
     addiu rPC, rPC, 1
.endm

.macro IZ_LD_B_R p, ix, op, half, r     # ld izh / izl,r
IZOP \p, \op
    GETR  t0, \r
    sb    t0, \ix+\half(rZ)
    b     dispatch
     addiu rPC, rPC, 1
.endm

.macro IZ_LD_B_B p, ix, op, dst, src    # ld izh/izl,izh/izl
IZOP \p, \op
    lbu   t0, \ix+\src(rZ)
    sb    t0, \ix+\dst(rZ)
    b     dispatch
     addiu rPC, rPC, 1
.endm

.macro IZ_INCDEC_B p, ix, op, core, half
IZOP \p, \op
    lbu   t0, \ix+\half(rZ)
    bal   \core
     nop
    sb    t2, \ix+\half(rZ)
    b     dispatch
     addiu rPC, rPC, 1
.endm

.macro IZ_LD_B_N p, ix, op, half        # ld izh / izl,n
IZOP \p, \op
    lbu   t0, 1(rPC)
    sb    t0, \ix+\half(rZ)
    b     dispatch
     addiu rPC, rPC, 2
.endm

.macro IZ_INCDEC_D p, ix, op, core      # inc / dec (iz+d)
IZOP \p, \op
    IZADDR a1, \ix
    READ8 t0, a1, t1
    bal   \core
     nop
    move  t0, a1
    bal   wr8
     move t1, t2
    b     dispatch
     addiu rPC, rPC, 2
.endm

# add iz,rr (addiz): S Z P kept, H C Y X from the high byte, N = 0,
# WZ = IZ + 1. rr = iz for add iz,iz.
.macro IZ_ADD p, ix, op, rr
IZOP \p, \op
    lhu   t6, \ix(rZ)
  .ifc \rr,iz
    move  t7, t6
  .else
    move  t7, \rr
  .endif
    addu  t0, t6, t7
    xor   t1, t0, t6
    xor   t1, t1, t7
    addiu t2, t6, 1
    sh    t2, N64Z80_OFF_MEM_PTR(rZ)
    andi  rF, rF, 0xC4
    srl   t2, t1, 8
    andi  t2, t2, 0x10
    srl   t3, t0, 8
    andi  t3, t3, 0x28
    srl   t4, t0, 16
    or    rF, rF, t2
    or    rF, rF, t3
    or    rF, rF, t4
    sh    t0, \ix(rZ)
    b     dispatch
     addiu rPC, rPC, 1
.endm

.macro IZ_FAMILY p, ix
    IZ_LD_R_D \p, \ix, 46, 0
    IZ_LD_R_D \p, \ix, 4E, 1
    IZ_LD_R_D \p, \ix, 56, 2
    IZ_LD_R_D \p, \ix, 5E, 3
    IZ_LD_R_D \p, \ix, 66, 4
    IZ_LD_R_D \p, \ix, 6E, 5
    IZ_LD_R_D \p, \ix, 7E, 7
    IZ_LD_D_R \p, \ix, 70, 0
    IZ_LD_D_R \p, \ix, 71, 1
    IZ_LD_D_R \p, \ix, 72, 2
    IZ_LD_D_R \p, \ix, 73, 3
    IZ_LD_D_R \p, \ix, 74, 4
    IZ_LD_D_R \p, \ix, 75, 5
    IZ_LD_D_R \p, \ix, 77, 7
    IZ_ALU_D \p, \ix, 86, alu_add
    IZ_ALU_D \p, \ix, 8E, alu_adc
    IZ_ALU_D \p, \ix, 96, alu_sub
    IZ_ALU_D \p, \ix, 9E, alu_sbc
    IZ_ALU_D \p, \ix, A6, alu_and
    IZ_ALU_D \p, \ix, AE, alu_xor
    IZ_ALU_D \p, \ix, B6, alu_or
    IZ_ALU_D \p, \ix, BE, alu_cp
    IZ_ALU_B \p, \ix, 84, alu_add, 0
    IZ_ALU_B \p, \ix, 85, alu_add, 1
    IZ_ALU_B \p, \ix, 8C, alu_adc, 0
    IZ_ALU_B \p, \ix, 8D, alu_adc, 1
    IZ_ALU_B \p, \ix, 94, alu_sub, 0
    IZ_ALU_B \p, \ix, 95, alu_sub, 1
    IZ_ALU_B \p, \ix, 9C, alu_sbc, 0
    IZ_ALU_B \p, \ix, 9D, alu_sbc, 1
    IZ_ALU_B \p, \ix, A4, alu_and, 0
    IZ_ALU_B \p, \ix, A5, alu_and, 1
    IZ_ALU_B \p, \ix, AC, alu_xor, 0
    IZ_ALU_B \p, \ix, AD, alu_xor, 1
    IZ_ALU_B \p, \ix, B4, alu_or, 0
    IZ_ALU_B \p, \ix, B5, alu_or, 1
    IZ_ALU_B \p, \ix, BC, alu_cp, 0
    IZ_ALU_B \p, \ix, BD, alu_cp, 1
    IZ_LD_R_B \p, \ix, 44, 0, 0
    IZ_LD_R_B \p, \ix, 45, 0, 1
    IZ_LD_R_B \p, \ix, 4C, 1, 0
    IZ_LD_R_B \p, \ix, 4D, 1, 1
    IZ_LD_R_B \p, \ix, 54, 2, 0
    IZ_LD_R_B \p, \ix, 55, 2, 1
    IZ_LD_R_B \p, \ix, 5C, 3, 0
    IZ_LD_R_B \p, \ix, 5D, 3, 1
    IZ_LD_R_B \p, \ix, 7C, 7, 0
    IZ_LD_R_B \p, \ix, 7D, 7, 1
    IZ_LD_B_R \p, \ix, 60, 0, 0
    IZ_LD_B_R \p, \ix, 61, 0, 1
    IZ_LD_B_R \p, \ix, 62, 0, 2
    IZ_LD_B_R \p, \ix, 63, 0, 3
    IZ_LD_B_R \p, \ix, 67, 0, 7
    IZ_LD_B_R \p, \ix, 68, 1, 0
    IZ_LD_B_R \p, \ix, 69, 1, 1
    IZ_LD_B_R \p, \ix, 6A, 1, 2
    IZ_LD_B_R \p, \ix, 6B, 1, 3
    IZ_LD_B_R \p, \ix, 6F, 1, 7
    IZ_LD_B_B \p, \ix, 64, 0, 0
    IZ_LD_B_B \p, \ix, 65, 0, 1
    IZ_LD_B_B \p, \ix, 6C, 1, 0
    IZ_LD_B_B \p, \ix, 6D, 1, 1
    IZ_INCDEC_B \p, \ix, 24, inc_core, 0
    IZ_INCDEC_B \p, \ix, 25, dec_core, 0
    IZ_INCDEC_B \p, \ix, 2C, inc_core, 1
    IZ_INCDEC_B \p, \ix, 2D, dec_core, 1
    IZ_LD_B_N \p, \ix, 26, 0
    IZ_LD_B_N \p, \ix, 2E, 1
    IZ_INCDEC_D \p, \ix, 34, inc_core
    IZ_INCDEC_D \p, \ix, 35, dec_core
    IZ_ADD \p, \ix, 09, rBC
    IZ_ADD \p, \ix, 19, rDE
    IZ_ADD \p, \ix, 29, iz
    IZ_ADD \p, \ix, 39, rSP

IZOP \p, 36                       # ld (iz+d),n
    IZADDR t0, \ix
    lbu   t1, 2(rPC)
    bal   wr8
     nop
    b     dispatch
     addiu rPC, rPC, 3

IZOP \p, 21                       # ld iz,nn
    FETCH16 t0, t1
    sh    t0, \ix(rZ)
    b     dispatch
     addiu rPC, rPC, 3

IZOP \p, 2A                       # ld iz,(nn): no WZ
    FETCH16 t0, t1
    READ8 t2, t0, t1
    addiu t0, t0, 1
    andi  t0, t0, 0xFFFF
    READ8 t3, t0, t1
    sb    t2, \ix+1(rZ)
    sb    t3, \ix(rZ)
    b     dispatch
     addiu rPC, rPC, 3

IZOP \p, 22                       # ld (nn),iz: no WZ
    FETCH16 t5, t1
    lhu   t4, \ix(rZ)
    move  t0, t5
    bal   wr8
     andi t1, t4, 0xFF
    addiu t0, t5, 1
    andi  t0, t0, 0xFFFF
    bal   wr8
     srl  t1, t4, 8
    b     dispatch
     addiu rPC, rPC, 3

IZOP \p, 23                       # inc iz
    lhu   t0, \ix(rZ)
    addiu t0, t0, 1
    sh    t0, \ix(rZ)
    b     dispatch
     addiu rPC, rPC, 1

IZOP \p, 2B                       # dec iz
    lhu   t0, \ix(rZ)
    addiu t0, t0, -1
    sh    t0, \ix(rZ)
    b     dispatch
     addiu rPC, rPC, 1

IZOP \p, E1                       # pop iz
    POP16 t0, t1, t2
    sh    t0, \ix(rZ)
    b     dispatch
     addiu rPC, rPC, 1

IZOP \p, E5                       # push iz
    bal   push_t4
     lhu  t4, \ix(rZ)
    b     dispatch
     addiu rPC, rPC, 1

IZOP \p, E3                       # ex (sp),iz: WZ = the popped value
    READ8 t5, rSP, t0
    addiu t2, rSP, 1
    andi  t2, t2, 0xFFFF
    READ8 t3, t2, t0
    sll   t3, t3, 8
    or    t5, t5, t3
    lhu   t4, \ix(rZ)
    move  t0, rSP
    bal   wr8
     andi t1, t4, 0xFF
    addiu t0, rSP, 1
    andi  t0, t0, 0xFFFF
    bal   wr8
     srl  t1, t4, 8
    sh    t5, \ix(rZ)
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    b     dispatch
     addiu rPC, rPC, 1

IZOP \p, E9                       # jp (iz): jump() sets WZ
    lhu   t0, \ix(rZ)
    b     jp_to
     sh   t0, N64Z80_OFF_MEM_PTR(rZ)

IZOP \p, F9                       # ld sp,iz
    lhu   rSP, \ix(rZ)
    b     dispatch
     addiu rPC, rPC, 1

# DD CB d op / FD CB d op: t5 = the address, then the shared DDCB table on
# op (at rPC+2; rPC is at the CB byte). No state changes here.
    PLACE \p\()_CB
op_\p\()_CB:
    lhu   t5, \ix(rZ)
    lb    t9, 1(rPC)
    lbu   t0, 2(rPC)
    addu  t5, t5, t9
    andi  t5, t5, 0xFFFF
    sll   t1, t0, 2
    addu  t1, t1, gp
    lw    t1, %gp_rel(n64z80_xcbtab)(t1)
    jr    t1
     nop
.endm

    IZ_FAMILY DD, N64Z80_OFF_IX
    IZ_FAMILY FD, N64Z80_OFF_IY

# ---------------------------------------------------------------------------
# ED xx (exec_opcode_ed): cyc_ed[op], R + 1. IN/OUT (C) and the I/O block
# ops stay in C for now (port callbacks need the full state written back).

.macro EDOP op
    PLACE ED_\op
op_ED_\op:
    addiu rCYC, rCYC, CYCED_\op
.endm

# Every ED opcode exec_opcode_ed doesn't implement: an 8-cycle NOP
# (gen_tables.py checks the 8).
    RARE
ed_nop:
    addiu rCYC, rCYC, 8
    b     dispatch
     addiu rPC, rPC, 1

.macro ED_LD_NN_RR op, rr          # ld (nn),rr: low then high, WZ = nn + 1
EDOP \op
    FETCH16 t5, t1
    move  t0, t5
    bal   wr8
     andi t1, \rr, 0xFF
    addiu t5, t5, 1
    andi  t5, t5, 0xFFFF
    move  t0, t5
    bal   wr8
     srl  t1, \rr, 8
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    b     dispatch
     addiu rPC, rPC, 3
.endm

.macro ED_LD_RR_NN op, rr          # ld rr,(nn): WZ = nn + 1
EDOP \op
    FETCH16 t0, t1
    READ8 t2, t0, t1
    addiu t0, t0, 1
    andi  t0, t0, 0xFFFF
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    READ8 t3, t0, t1
    sll   t3, t3, 8
    or    \rr, t2, t3
    b     dispatch
     addiu rPC, rPC, 3
.endm

# adc hl,rr (sub = 0) / sbc hl,rr (sub = 1): one 17-bit add of HL, rr (or
# ~rr) and the carry (or !carry) gives the reference's two byte adds; S and Z
# from the 16-bit result, H C V Y X from the high byte, WZ = HL + 1.
.macro ED_ADC_SBC op, sub, rr
EDOP \op
    move  t6, \rr
    andi  t7, rF, 1
  .if \sub
    xori  t6, t6, 0xFFFF
    xori  t7, t7, 1
  .endif
    addu  t0, rHL, t6
    addu  t0, t0, t7              # r (17 bits)
    xor   t1, t0, rHL
    xor   t1, t1, t6              # carries
    addiu t2, rHL, 1
    sh    t2, N64Z80_OFF_MEM_PTR(rZ)
    srl   t2, t0, 8
    andi  rF, t2, 0xA8            # S Y X
    srl   t2, t1, 8
    andi  t2, t2, 0x10            # H
    or    rF, rF, t2
    srl   t3, t1, 16              # C
    or    rF, rF, t3
    srl   t2, t1, 15
    xor   t2, t2, t3
    andi  t2, t2, 1
    sll   t2, t2, 2               # V
    or    rF, rF, t2
    andi  rHL, t0, 0xFFFF
    sltiu t2, rHL, 1
    sll   t2, t2, 6               # Z
    or    rF, rF, t2
  .if \sub
    xori  rF, rF, 0x11
    ori   rF, rF, 0x02
  .endif
    b     dispatch
     addiu rPC, rPC, 1
.endm

    ED_LD_NN_RR 43, rBC
    ED_LD_NN_RR 53, rDE
    ED_LD_NN_RR 63, rHL
    ED_LD_NN_RR 73, rSP
    ED_LD_RR_NN 4B, rBC
    ED_LD_RR_NN 5B, rDE
    ED_LD_RR_NN 6B, rHL
    ED_LD_RR_NN 7B, rSP
    ED_ADC_SBC 4A, 0, rBC
    ED_ADC_SBC 5A, 0, rDE
    ED_ADC_SBC 6A, 0, rHL
    ED_ADC_SBC 7A, 0, rSP
    ED_ADC_SBC 42, 1, rBC
    ED_ADC_SBC 52, 1, rDE
    ED_ADC_SBC 62, 1, rHL
    ED_ADC_SBC 72, 1, rSP

    RARE
op_ED_44:                         # neg (all eight encodings): subb(0, A, 0)
op_ED_4C:
op_ED_54:
op_ED_5C:
op_ED_64:
op_ED_6C:
op_ED_74:
op_ED_7C:
    addiu rCYC, rCYC, CYCED_44
    xori  t0, rA, 0xFF
    li    t1, 1
    ADDB  zero, t0, t1
    xori  rF, rF, 0x11
    ori   rF, rF, 0x02
    andi  rA, t2, 0xFF
    b     dispatch
     addiu rPC, rPC, 1

.macro ED_IM op, mode
EDOP \op
    li    t0, \mode
    sb    t0, N64Z80_OFF_IM(rZ)
    b     dispatch
     addiu rPC, rPC, 1
.endm
    ED_IM 46, 0
    ED_IM 66, 0
    ED_IM 56, 1
    ED_IM 76, 1
    ED_IM 5E, 2
    ED_IM 7E, 2

EDOP 47                           # ld i,a
    sb    rA, N64Z80_OFF_I(rZ)
    b     dispatch
     addiu rPC, rPC, 1

# dst = the DD/FD prefixes before this ED (a chain; rPC is at the byte after
# the ED). The reference runs the ED instruction inside them and takes one
# R increment back per prefix afterwards, so inside it R is that much higher.
.macro CHAIN_DEPTH dst
    subu  \dst, rPC, rBIAS
    addiu \dst, \dst, -1
    subu  \dst, \dst, rPC0
    andi  \dst, \dst, 0xFFFF
.endm

EDOP 4F                           # ld r,a: R = A, less the chain's take-back
    andi  t0, rA, 0x80
    sw    t0, %gp_rel(n64z80_rhi)(gp)
    CHAIN_DEPTH t1
    subu  rRB, rA, rN
    subu  rRB, rRB, t1
    b     dispatch
     addiu rPC, rPC, 1

# ld a,i / ld a,r: S Z from A, H = N = 0, P/V = IFF2; Y X C kept.
EDOP 57                           # ld a,i
    b     ld_a_ir
     lbu  rA, N64Z80_OFF_I(rZ)
EDOP 5F                           # ld a,r (R after both increments)
    CHAIN_DEPTH t2
    lw    t1, %gp_rel(n64z80_rhi)(gp)
    addu  t0, rRB, rN
    addu  t0, t0, t2
    andi  t0, t0, 0x7F
    or    rA, t0, t1
ld_a_ir:
    andi  rF, rF, 0x29
    andi  t0, rA, 0x80
    or    rF, rF, t0
    sltiu t0, rA, 1
    sll   t0, t0, 6
    or    rF, rF, t0
    lbu   t0, N64Z80_OFF_IFF2(rZ)
    sltu  t0, zero, t0            # bool: any nonzero byte is true
    sll   t0, t0, 2
    or    rF, rF, t0
    b     dispatch
     addiu rPC, rPC, 1

# retn (seven encodings): IFF1 = IFF2 (set_iff1: the INT/IRQ event lanes
# follow), then ret. reti: ret only.
    COLD
op_ED_45:
op_ED_55:
op_ED_5D:
op_ED_65:
op_ED_6D:
op_ED_75:
op_ED_7D:
    addiu rCYC, rCYC, CYCED_45
    lbu   t0, N64Z80_OFF_IFF2(rZ)
    sltu  t0, zero, t0            # bool: any nonzero byte is true
    sb    t0, N64Z80_OFF_IFF1(rZ)
    subu  t0, zero, t0
    sb    t0, N64Z80_OFF_EVM_INT(rZ)
    sb    t0, N64Z80_OFF_EVM_LINE(rZ)
    POISON_IF_EVENTS
    b     ed_ret
     nop
EDOP 4D                           # reti
ed_ret:
    POP16 t0, t1, t2
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    b     jp_to
     nop

# rrd / rld: (HL) and A's low nibble rotate; F = sz53p[A] | C; WZ = HL + 1.
EDOP 67                           # rrd
    READ8 t0, rHL, t1
    andi  t2, rA, 0xF0
    andi  t3, t0, 0x0F
    or    t2, t2, t3              # new A
    srl   t3, t0, 4
    sll   t4, rA, 4
    or    t1, t3, t4
    andi  t1, t1, 0xFF            # new (HL)
    b     ed_rxd
     move rA, t2
EDOP 6F                           # rld
    READ8 t0, rHL, t1
    andi  t2, rA, 0xF0
    srl   t3, t0, 4
    or    t2, t2, t3              # new A
    sll   t3, t0, 4
    andi  t4, rA, 0x0F
    or    t1, t3, t4
    andi  t1, t1, 0xFF            # new (HL)
    move  rA, t2
ed_rxd:
    bal   wr8
     move t0, rHL
    andi  rF, rF, 0x01
    addu  t0, rA, gp
    lbu   t0, %gp_rel(n64z80_sz53p)(t0)
    addiu t1, rHL, 1
    sh    t1, N64Z80_OFF_MEM_PTR(rZ)
    or    rF, rF, t0
    b     dispatch
     addiu rPC, rPC, 1

# ldi / ldd core (ldi()): (DE) = (HL), HL and DE step by t6 (+1 / -1),
# BC - 1; Y/X from bits 1/3 of (byte + A), H = N = 0, P/V = BC != 0, S Z C
# kept. bal; clobbers t0-t3, t5, t7, t9.
    COLD
ldx_core:
    move  t7, ra
    READ8 t5, rHL, t0
    move  t0, rDE
    bal   wr8
     move t1, t5
    addu  rHL, rHL, t6
    andi  rHL, rHL, 0xFFFF
    addu  rDE, rDE, t6
    andi  rDE, rDE, 0xFFFF
    addiu rBC, rBC, -1
    andi  rBC, rBC, 0xFFFF
    addu  t0, t5, rA
    andi  rF, rF, 0xC1
    andi  t1, t0, 0x08
    or    rF, rF, t1
    andi  t1, t0, 0x02
    sll   t1, t1, 4
    or    rF, rF, t1
    sltu  t1, zero, rBC
    sll   t1, t1, 2
    jr    t7
     or   rF, rF, t1

EDOP A0                           # ldi
    bal   ldx_core
     li   t6, 1
    b     dispatch
     addiu rPC, rPC, 1
EDOP A8                           # ldd
    bal   ldx_core
     li   t6, -1
    b     dispatch
     addiu rPC, rPC, 1

# dst = the address of the ED byte (rPC is at the byte after it): where a
# block instruction repeats from, as the reference's PC - 2. That is pc0
# unless DD/FD prefixes precede the ED (a chain), which the repeat skips.
.macro ED_PC dst
    subu  \dst, rPC, rBIAS
    addiu \dst, \dst, -1
    andi  \dst, \dst, 0xFFFF
.endm

# ldir / lddr: repeat while BC != 0 by going back to the instruction itself
# (+5, WZ = PC + 1): a loop edge, so the run stops after every iteration,
# exactly as in the reference.
EDOP B0                           # ldir
    bal   ldx_core
     li   t6, 1
    b     ldxr_tail
     nop
EDOP B8                           # lddr
    bal   ldx_core
     li   t6, -1
ldxr_tail:
    beqz  rBC, next1
     nop
    addiu rCYC, rCYC, 5
    ED_PC t0
    addiu t1, t0, 1
    b     jp_to
     sh   t1, N64Z80_OFF_MEM_PTR(rZ)

# cpi / cpd core (cpi()): subb(A, (HL), 0) with C kept, HL += a1, BC - 1,
# Y/X from bits 1/3 of (result - H), P/V = BC != 0, WZ += a1 (the step:
# ADDB clobbers t2-t7). bal; clobbers t0-t7, t9.
    RARE
cpx_core:
    andi  t9, rF, 1
    READ8 t0, rHL, t1
    xori  t0, t0, 0xFF
    li    t1, 1
    ADDB  rA, t0, t1
    xori  rF, rF, 0x11
    ori   rF, rF, 0x02
    addu  rHL, rHL, a1
    andi  rHL, rHL, 0xFFFF
    addiu rBC, rBC, -1
    andi  rBC, rBC, 0xFFFF
    srl   t3, rF, 4
    andi  t3, t3, 1               # H
    subu  t2, t2, t3              # result - H
    andi  rF, rF, 0xD2            # S Z H N kept (C, P/V, Y, X replaced)
    or    rF, rF, t9
    andi  t3, t2, 0x08
    or    rF, rF, t3
    andi  t3, t2, 0x02
    sll   t3, t3, 4
    or    rF, rF, t3
    sltu  t3, zero, rBC
    sll   t3, t3, 2
    or    rF, rF, t3
    lhu   t3, N64Z80_OFF_MEM_PTR(rZ)
    addu  t3, t3, a1
    jr    ra
     sh   t3, N64Z80_OFF_MEM_PTR(rZ)

EDOP A1                           # cpi
    bal   cpx_core
     li   a1, 1
    b     dispatch
     addiu rPC, rPC, 1
EDOP A9                           # cpd
    bal   cpx_core
     li   a1, -1
    b     dispatch
     addiu rPC, rPC, 1

# cpir: repeat (+5, WZ = PC + 1) while BC != 0 and not Z, else WZ + 1.
EDOP B1
    bal   cpx_core
     li   a1, 1
    andi  t0, rF, 0x40
    bnez  t0, 1f
     nop
    beqz  rBC, 1f
     nop
    addiu rCYC, rCYC, 5
    ED_PC t0
    addiu t1, t0, 1
    b     jp_to
     sh   t1, N64Z80_OFF_MEM_PTR(rZ)
1:  lhu   t0, N64Z80_OFF_MEM_PTR(rZ)
    addiu t0, t0, 1
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    b     dispatch
     addiu rPC, rPC, 1

# cpdr: as cpir, but a repeat leaves WZ alone.
EDOP B9
    bal   cpx_core
     li   a1, -1
    andi  t0, rF, 0x40
    bnez  t0, 1f
     nop
    beqz  rBC, 1f
     nop
    addiu rCYC, rCYC, 5
    ED_PC t0
    b     jp_to
     nop
1:  lhu   t0, N64Z80_OFF_MEM_PTR(rZ)
    addiu t0, t0, 1
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    b     dispatch
     addiu rPC, rPC, 1


# ---------------------------------------------------------------------------
# CB and DD CB / FD CB handlers (one line per opcode).
# --- CB table
    CB_ROT     00, rot_rlc, 0    # rlc b
    CB_ROT     01, rot_rlc, 1    # rlc c
    CB_ROT     02, rot_rlc, 2    # rlc d
    CB_ROT     03, rot_rlc, 3    # rlc e
    CB_ROT     04, rot_rlc, 4    # rlc h
    CB_ROT     05, rot_rlc, 5    # rlc l
    CB_ROT     06, rot_rlc, 6    # rlc (hl)
    CB_ROT     07, rot_rlc, 7    # rlc a
    CB_ROT     08, rot_rrc, 0    # rrc b
    CB_ROT     09, rot_rrc, 1    # rrc c
    CB_ROT     0A, rot_rrc, 2    # rrc d
    CB_ROT     0B, rot_rrc, 3    # rrc e
    CB_ROT     0C, rot_rrc, 4    # rrc h
    CB_ROT     0D, rot_rrc, 5    # rrc l
    CB_ROT     0E, rot_rrc, 6    # rrc (hl)
    CB_ROT     0F, rot_rrc, 7    # rrc a
    CB_ROT     10, rot_rl, 0    # rl b
    CB_ROT     11, rot_rl, 1    # rl c
    CB_ROT     12, rot_rl, 2    # rl d
    CB_ROT     13, rot_rl, 3    # rl e
    CB_ROT     14, rot_rl, 4    # rl h
    CB_ROT     15, rot_rl, 5    # rl l
    CB_ROT     16, rot_rl, 6    # rl (hl)
    CB_ROT     17, rot_rl, 7    # rl a
    CB_ROT     18, rot_rr, 0    # rr b
    CB_ROT     19, rot_rr, 1    # rr c
    CB_ROT     1A, rot_rr, 2    # rr d
    CB_ROT     1B, rot_rr, 3    # rr e
    CB_ROT     1C, rot_rr, 4    # rr h
    CB_ROT     1D, rot_rr, 5    # rr l
    CB_ROT     1E, rot_rr, 6    # rr (hl)
    CB_ROT     1F, rot_rr, 7    # rr a
    CB_ROT     20, rot_sla, 0    # sla b
    CB_ROT     21, rot_sla, 1    # sla c
    CB_ROT     22, rot_sla, 2    # sla d
    CB_ROT     23, rot_sla, 3    # sla e
    CB_ROT     24, rot_sla, 4    # sla h
    CB_ROT     25, rot_sla, 5    # sla l
    CB_ROT     26, rot_sla, 6    # sla (hl)
    CB_ROT     27, rot_sla, 7    # sla a
    CB_ROT     28, rot_sra, 0    # sra b
    CB_ROT     29, rot_sra, 1    # sra c
    CB_ROT     2A, rot_sra, 2    # sra d
    CB_ROT     2B, rot_sra, 3    # sra e
    CB_ROT     2C, rot_sra, 4    # sra h
    CB_ROT     2D, rot_sra, 5    # sra l
    CB_ROT     2E, rot_sra, 6    # sra (hl)
    CB_ROT     2F, rot_sra, 7    # sra a
    CB_ROT     30, rot_sll, 0    # sll b
    CB_ROT     31, rot_sll, 1    # sll c
    CB_ROT     32, rot_sll, 2    # sll d
    CB_ROT     33, rot_sll, 3    # sll e
    CB_ROT     34, rot_sll, 4    # sll h
    CB_ROT     35, rot_sll, 5    # sll l
    CB_ROT     36, rot_sll, 6    # sll (hl)
    CB_ROT     37, rot_sll, 7    # sll a
    CB_ROT     38, rot_srl, 0    # srl b
    CB_ROT     39, rot_srl, 1    # srl c
    CB_ROT     3A, rot_srl, 2    # srl d
    CB_ROT     3B, rot_srl, 3    # srl e
    CB_ROT     3C, rot_srl, 4    # srl h
    CB_ROT     3D, rot_srl, 5    # srl l
    CB_ROT     3E, rot_srl, 6    # srl (hl)
    CB_ROT     3F, rot_srl, 7    # srl a
    CB_BIT     40, 0, 0    # bit 0,b
    CB_BIT     41, 0, 1    # bit 0,c
    CB_BIT     42, 0, 2    # bit 0,d
    CB_BIT     43, 0, 3    # bit 0,e
    CB_BIT     44, 0, 4    # bit 0,h
    CB_BIT     45, 0, 5    # bit 0,l
    CB_BIT     46, 0, 6    # bit 0,(hl)
    CB_BIT     47, 0, 7    # bit 0,a
    CB_BIT     48, 1, 0    # bit 1,b
    CB_BIT     49, 1, 1    # bit 1,c
    CB_BIT     4A, 1, 2    # bit 1,d
    CB_BIT     4B, 1, 3    # bit 1,e
    CB_BIT     4C, 1, 4    # bit 1,h
    CB_BIT     4D, 1, 5    # bit 1,l
    CB_BIT     4E, 1, 6    # bit 1,(hl)
    CB_BIT     4F, 1, 7    # bit 1,a
    CB_BIT     50, 2, 0    # bit 2,b
    CB_BIT     51, 2, 1    # bit 2,c
    CB_BIT     52, 2, 2    # bit 2,d
    CB_BIT     53, 2, 3    # bit 2,e
    CB_BIT     54, 2, 4    # bit 2,h
    CB_BIT     55, 2, 5    # bit 2,l
    CB_BIT     56, 2, 6    # bit 2,(hl)
    CB_BIT     57, 2, 7    # bit 2,a
    CB_BIT     58, 3, 0    # bit 3,b
    CB_BIT     59, 3, 1    # bit 3,c
    CB_BIT     5A, 3, 2    # bit 3,d
    CB_BIT     5B, 3, 3    # bit 3,e
    CB_BIT     5C, 3, 4    # bit 3,h
    CB_BIT     5D, 3, 5    # bit 3,l
    CB_BIT     5E, 3, 6    # bit 3,(hl)
    CB_BIT     5F, 3, 7    # bit 3,a
    CB_BIT     60, 4, 0    # bit 4,b
    CB_BIT     61, 4, 1    # bit 4,c
    CB_BIT     62, 4, 2    # bit 4,d
    CB_BIT     63, 4, 3    # bit 4,e
    CB_BIT     64, 4, 4    # bit 4,h
    CB_BIT     65, 4, 5    # bit 4,l
    CB_BIT     66, 4, 6    # bit 4,(hl)
    CB_BIT     67, 4, 7    # bit 4,a
    CB_BIT     68, 5, 0    # bit 5,b
    CB_BIT     69, 5, 1    # bit 5,c
    CB_BIT     6A, 5, 2    # bit 5,d
    CB_BIT     6B, 5, 3    # bit 5,e
    CB_BIT     6C, 5, 4    # bit 5,h
    CB_BIT     6D, 5, 5    # bit 5,l
    CB_BIT     6E, 5, 6    # bit 5,(hl)
    CB_BIT     6F, 5, 7    # bit 5,a
    CB_BIT     70, 6, 0    # bit 6,b
    CB_BIT     71, 6, 1    # bit 6,c
    CB_BIT     72, 6, 2    # bit 6,d
    CB_BIT     73, 6, 3    # bit 6,e
    CB_BIT     74, 6, 4    # bit 6,h
    CB_BIT     75, 6, 5    # bit 6,l
    CB_BIT     76, 6, 6    # bit 6,(hl)
    CB_BIT     77, 6, 7    # bit 6,a
    CB_BIT     78, 7, 0    # bit 7,b
    CB_BIT     79, 7, 1    # bit 7,c
    CB_BIT     7A, 7, 2    # bit 7,d
    CB_BIT     7B, 7, 3    # bit 7,e
    CB_BIT     7C, 7, 4    # bit 7,h
    CB_BIT     7D, 7, 5    # bit 7,l
    CB_BIT     7E, 7, 6    # bit 7,(hl)
    CB_BIT     7F, 7, 7    # bit 7,a
    CB_RES_SET 80, 0, 0, 0    # res 0,b
    CB_RES_SET 81, 0, 0, 1    # res 0,c
    CB_RES_SET 82, 0, 0, 2    # res 0,d
    CB_RES_SET 83, 0, 0, 3    # res 0,e
    CB_RES_SET 84, 0, 0, 4    # res 0,h
    CB_RES_SET 85, 0, 0, 5    # res 0,l
    CB_RES_SET 86, 0, 0, 6    # res 0,(hl)
    CB_RES_SET 87, 0, 0, 7    # res 0,a
    CB_RES_SET 88, 0, 1, 0    # res 1,b
    CB_RES_SET 89, 0, 1, 1    # res 1,c
    CB_RES_SET 8A, 0, 1, 2    # res 1,d
    CB_RES_SET 8B, 0, 1, 3    # res 1,e
    CB_RES_SET 8C, 0, 1, 4    # res 1,h
    CB_RES_SET 8D, 0, 1, 5    # res 1,l
    CB_RES_SET 8E, 0, 1, 6    # res 1,(hl)
    CB_RES_SET 8F, 0, 1, 7    # res 1,a
    CB_RES_SET 90, 0, 2, 0    # res 2,b
    CB_RES_SET 91, 0, 2, 1    # res 2,c
    CB_RES_SET 92, 0, 2, 2    # res 2,d
    CB_RES_SET 93, 0, 2, 3    # res 2,e
    CB_RES_SET 94, 0, 2, 4    # res 2,h
    CB_RES_SET 95, 0, 2, 5    # res 2,l
    CB_RES_SET 96, 0, 2, 6    # res 2,(hl)
    CB_RES_SET 97, 0, 2, 7    # res 2,a
    CB_RES_SET 98, 0, 3, 0    # res 3,b
    CB_RES_SET 99, 0, 3, 1    # res 3,c
    CB_RES_SET 9A, 0, 3, 2    # res 3,d
    CB_RES_SET 9B, 0, 3, 3    # res 3,e
    CB_RES_SET 9C, 0, 3, 4    # res 3,h
    CB_RES_SET 9D, 0, 3, 5    # res 3,l
    CB_RES_SET 9E, 0, 3, 6    # res 3,(hl)
    CB_RES_SET 9F, 0, 3, 7    # res 3,a
    CB_RES_SET A0, 0, 4, 0    # res 4,b
    CB_RES_SET A1, 0, 4, 1    # res 4,c
    CB_RES_SET A2, 0, 4, 2    # res 4,d
    CB_RES_SET A3, 0, 4, 3    # res 4,e
    CB_RES_SET A4, 0, 4, 4    # res 4,h
    CB_RES_SET A5, 0, 4, 5    # res 4,l
    CB_RES_SET A6, 0, 4, 6    # res 4,(hl)
    CB_RES_SET A7, 0, 4, 7    # res 4,a
    CB_RES_SET A8, 0, 5, 0    # res 5,b
    CB_RES_SET A9, 0, 5, 1    # res 5,c
    CB_RES_SET AA, 0, 5, 2    # res 5,d
    CB_RES_SET AB, 0, 5, 3    # res 5,e
    CB_RES_SET AC, 0, 5, 4    # res 5,h
    CB_RES_SET AD, 0, 5, 5    # res 5,l
    CB_RES_SET AE, 0, 5, 6    # res 5,(hl)
    CB_RES_SET AF, 0, 5, 7    # res 5,a
    CB_RES_SET B0, 0, 6, 0    # res 6,b
    CB_RES_SET B1, 0, 6, 1    # res 6,c
    CB_RES_SET B2, 0, 6, 2    # res 6,d
    CB_RES_SET B3, 0, 6, 3    # res 6,e
    CB_RES_SET B4, 0, 6, 4    # res 6,h
    CB_RES_SET B5, 0, 6, 5    # res 6,l
    CB_RES_SET B6, 0, 6, 6    # res 6,(hl)
    CB_RES_SET B7, 0, 6, 7    # res 6,a
    CB_RES_SET B8, 0, 7, 0    # res 7,b
    CB_RES_SET B9, 0, 7, 1    # res 7,c
    CB_RES_SET BA, 0, 7, 2    # res 7,d
    CB_RES_SET BB, 0, 7, 3    # res 7,e
    CB_RES_SET BC, 0, 7, 4    # res 7,h
    CB_RES_SET BD, 0, 7, 5    # res 7,l
    CB_RES_SET BE, 0, 7, 6    # res 7,(hl)
    CB_RES_SET BF, 0, 7, 7    # res 7,a
    CB_RES_SET C0, 1, 0, 0    # set 0,b
    CB_RES_SET C1, 1, 0, 1    # set 0,c
    CB_RES_SET C2, 1, 0, 2    # set 0,d
    CB_RES_SET C3, 1, 0, 3    # set 0,e
    CB_RES_SET C4, 1, 0, 4    # set 0,h
    CB_RES_SET C5, 1, 0, 5    # set 0,l
    CB_RES_SET C6, 1, 0, 6    # set 0,(hl)
    CB_RES_SET C7, 1, 0, 7    # set 0,a
    CB_RES_SET C8, 1, 1, 0    # set 1,b
    CB_RES_SET C9, 1, 1, 1    # set 1,c
    CB_RES_SET CA, 1, 1, 2    # set 1,d
    CB_RES_SET CB, 1, 1, 3    # set 1,e
    CB_RES_SET CC, 1, 1, 4    # set 1,h
    CB_RES_SET CD, 1, 1, 5    # set 1,l
    CB_RES_SET CE, 1, 1, 6    # set 1,(hl)
    CB_RES_SET CF, 1, 1, 7    # set 1,a
    CB_RES_SET D0, 1, 2, 0    # set 2,b
    CB_RES_SET D1, 1, 2, 1    # set 2,c
    CB_RES_SET D2, 1, 2, 2    # set 2,d
    CB_RES_SET D3, 1, 2, 3    # set 2,e
    CB_RES_SET D4, 1, 2, 4    # set 2,h
    CB_RES_SET D5, 1, 2, 5    # set 2,l
    CB_RES_SET D6, 1, 2, 6    # set 2,(hl)
    CB_RES_SET D7, 1, 2, 7    # set 2,a
    CB_RES_SET D8, 1, 3, 0    # set 3,b
    CB_RES_SET D9, 1, 3, 1    # set 3,c
    CB_RES_SET DA, 1, 3, 2    # set 3,d
    CB_RES_SET DB, 1, 3, 3    # set 3,e
    CB_RES_SET DC, 1, 3, 4    # set 3,h
    CB_RES_SET DD, 1, 3, 5    # set 3,l
    CB_RES_SET DE, 1, 3, 6    # set 3,(hl)
    CB_RES_SET DF, 1, 3, 7    # set 3,a
    CB_RES_SET E0, 1, 4, 0    # set 4,b
    CB_RES_SET E1, 1, 4, 1    # set 4,c
    CB_RES_SET E2, 1, 4, 2    # set 4,d
    CB_RES_SET E3, 1, 4, 3    # set 4,e
    CB_RES_SET E4, 1, 4, 4    # set 4,h
    CB_RES_SET E5, 1, 4, 5    # set 4,l
    CB_RES_SET E6, 1, 4, 6    # set 4,(hl)
    CB_RES_SET E7, 1, 4, 7    # set 4,a
    CB_RES_SET E8, 1, 5, 0    # set 5,b
    CB_RES_SET E9, 1, 5, 1    # set 5,c
    CB_RES_SET EA, 1, 5, 2    # set 5,d
    CB_RES_SET EB, 1, 5, 3    # set 5,e
    CB_RES_SET EC, 1, 5, 4    # set 5,h
    CB_RES_SET ED, 1, 5, 5    # set 5,l
    CB_RES_SET EE, 1, 5, 6    # set 5,(hl)
    CB_RES_SET EF, 1, 5, 7    # set 5,a
    CB_RES_SET F0, 1, 6, 0    # set 6,b
    CB_RES_SET F1, 1, 6, 1    # set 6,c
    CB_RES_SET F2, 1, 6, 2    # set 6,d
    CB_RES_SET F3, 1, 6, 3    # set 6,e
    CB_RES_SET F4, 1, 6, 4    # set 6,h
    CB_RES_SET F5, 1, 6, 5    # set 6,l
    CB_RES_SET F6, 1, 6, 6    # set 6,(hl)
    CB_RES_SET F7, 1, 6, 7    # set 6,a
    CB_RES_SET F8, 1, 7, 0    # set 7,b
    CB_RES_SET F9, 1, 7, 1    # set 7,c
    CB_RES_SET FA, 1, 7, 2    # set 7,d
    CB_RES_SET FB, 1, 7, 3    # set 7,e
    CB_RES_SET FC, 1, 7, 4    # set 7,h
    CB_RES_SET FD, 1, 7, 5    # set 7,l
    CB_RES_SET FE, 1, 7, 6    # set 7,(hl)
    CB_RES_SET FF, 1, 7, 7    # set 7,a
# --- DDCB/FDCB table
    XC_ROT     00, rot_rlc, 0    # rlc (iz+d) -> b
    XC_ROT     01, rot_rlc, 1    # rlc (iz+d) -> c
    XC_ROT     02, rot_rlc, 2    # rlc (iz+d) -> d
    XC_ROT     03, rot_rlc, 3    # rlc (iz+d) -> e
    XC_ROT     04, rot_rlc, 4    # rlc (iz+d) -> h
    XC_ROT     05, rot_rlc, 5    # rlc (iz+d) -> l
    XC_ROT     06, rot_rlc, 6    # rlc (iz+d)
    XC_ROT     07, rot_rlc, 7    # rlc (iz+d) -> a
    XC_ROT     08, rot_rrc, 0    # rrc (iz+d) -> b
    XC_ROT     09, rot_rrc, 1    # rrc (iz+d) -> c
    XC_ROT     0A, rot_rrc, 2    # rrc (iz+d) -> d
    XC_ROT     0B, rot_rrc, 3    # rrc (iz+d) -> e
    XC_ROT     0C, rot_rrc, 4    # rrc (iz+d) -> h
    XC_ROT     0D, rot_rrc, 5    # rrc (iz+d) -> l
    XC_ROT     0E, rot_rrc, 6    # rrc (iz+d)
    XC_ROT     0F, rot_rrc, 7    # rrc (iz+d) -> a
    XC_ROT     10, rot_rl, 0    # rl (iz+d) -> b
    XC_ROT     11, rot_rl, 1    # rl (iz+d) -> c
    XC_ROT     12, rot_rl, 2    # rl (iz+d) -> d
    XC_ROT     13, rot_rl, 3    # rl (iz+d) -> e
    XC_ROT     14, rot_rl, 4    # rl (iz+d) -> h
    XC_ROT     15, rot_rl, 5    # rl (iz+d) -> l
    XC_ROT     16, rot_rl, 6    # rl (iz+d)
    XC_ROT     17, rot_rl, 7    # rl (iz+d) -> a
    XC_ROT     18, rot_rr, 0    # rr (iz+d) -> b
    XC_ROT     19, rot_rr, 1    # rr (iz+d) -> c
    XC_ROT     1A, rot_rr, 2    # rr (iz+d) -> d
    XC_ROT     1B, rot_rr, 3    # rr (iz+d) -> e
    XC_ROT     1C, rot_rr, 4    # rr (iz+d) -> h
    XC_ROT     1D, rot_rr, 5    # rr (iz+d) -> l
    XC_ROT     1E, rot_rr, 6    # rr (iz+d)
    XC_ROT     1F, rot_rr, 7    # rr (iz+d) -> a
    XC_ROT     20, rot_sla, 0    # sla (iz+d) -> b
    XC_ROT     21, rot_sla, 1    # sla (iz+d) -> c
    XC_ROT     22, rot_sla, 2    # sla (iz+d) -> d
    XC_ROT     23, rot_sla, 3    # sla (iz+d) -> e
    XC_ROT     24, rot_sla, 4    # sla (iz+d) -> h
    XC_ROT     25, rot_sla, 5    # sla (iz+d) -> l
    XC_ROT     26, rot_sla, 6    # sla (iz+d)
    XC_ROT     27, rot_sla, 7    # sla (iz+d) -> a
    XC_ROT     28, rot_sra, 0    # sra (iz+d) -> b
    XC_ROT     29, rot_sra, 1    # sra (iz+d) -> c
    XC_ROT     2A, rot_sra, 2    # sra (iz+d) -> d
    XC_ROT     2B, rot_sra, 3    # sra (iz+d) -> e
    XC_ROT     2C, rot_sra, 4    # sra (iz+d) -> h
    XC_ROT     2D, rot_sra, 5    # sra (iz+d) -> l
    XC_ROT     2E, rot_sra, 6    # sra (iz+d)
    XC_ROT     2F, rot_sra, 7    # sra (iz+d) -> a
    XC_ROT     30, rot_sll, 0    # sll (iz+d) -> b
    XC_ROT     31, rot_sll, 1    # sll (iz+d) -> c
    XC_ROT     32, rot_sll, 2    # sll (iz+d) -> d
    XC_ROT     33, rot_sll, 3    # sll (iz+d) -> e
    XC_ROT     34, rot_sll, 4    # sll (iz+d) -> h
    XC_ROT     35, rot_sll, 5    # sll (iz+d) -> l
    XC_ROT     36, rot_sll, 6    # sll (iz+d)
    XC_ROT     37, rot_sll, 7    # sll (iz+d) -> a
    XC_ROT     38, rot_srl, 0    # srl (iz+d) -> b
    XC_ROT     39, rot_srl, 1    # srl (iz+d) -> c
    XC_ROT     3A, rot_srl, 2    # srl (iz+d) -> d
    XC_ROT     3B, rot_srl, 3    # srl (iz+d) -> e
    XC_ROT     3C, rot_srl, 4    # srl (iz+d) -> h
    XC_ROT     3D, rot_srl, 5    # srl (iz+d) -> l
    XC_ROT     3E, rot_srl, 6    # srl (iz+d)
    XC_ROT     3F, rot_srl, 7    # srl (iz+d) -> a
    XC_BIT     0, 40, 41, 42, 43, 44, 45, 46, 47    # bit 0,(iz+d)
    XC_BIT     1, 48, 49, 4A, 4B, 4C, 4D, 4E, 4F    # bit 1,(iz+d)
    XC_BIT     2, 50, 51, 52, 53, 54, 55, 56, 57    # bit 2,(iz+d)
    XC_BIT     3, 58, 59, 5A, 5B, 5C, 5D, 5E, 5F    # bit 3,(iz+d)
    XC_BIT     4, 60, 61, 62, 63, 64, 65, 66, 67    # bit 4,(iz+d)
    XC_BIT     5, 68, 69, 6A, 6B, 6C, 6D, 6E, 6F    # bit 5,(iz+d)
    XC_BIT     6, 70, 71, 72, 73, 74, 75, 76, 77    # bit 6,(iz+d)
    XC_BIT     7, 78, 79, 7A, 7B, 7C, 7D, 7E, 7F    # bit 7,(iz+d)
    XC_RES_SET 80, 0, 0, 0    # res 0,(iz+d) -> b
    XC_RES_SET 81, 0, 0, 1    # res 0,(iz+d) -> c
    XC_RES_SET 82, 0, 0, 2    # res 0,(iz+d) -> d
    XC_RES_SET 83, 0, 0, 3    # res 0,(iz+d) -> e
    XC_RES_SET 84, 0, 0, 4    # res 0,(iz+d) -> h
    XC_RES_SET 85, 0, 0, 5    # res 0,(iz+d) -> l
    XC_RES_SET 86, 0, 0, 6    # res 0,(iz+d)
    XC_RES_SET 87, 0, 0, 7    # res 0,(iz+d) -> a
    XC_RES_SET 88, 0, 1, 0    # res 1,(iz+d) -> b
    XC_RES_SET 89, 0, 1, 1    # res 1,(iz+d) -> c
    XC_RES_SET 8A, 0, 1, 2    # res 1,(iz+d) -> d
    XC_RES_SET 8B, 0, 1, 3    # res 1,(iz+d) -> e
    XC_RES_SET 8C, 0, 1, 4    # res 1,(iz+d) -> h
    XC_RES_SET 8D, 0, 1, 5    # res 1,(iz+d) -> l
    XC_RES_SET 8E, 0, 1, 6    # res 1,(iz+d)
    XC_RES_SET 8F, 0, 1, 7    # res 1,(iz+d) -> a
    XC_RES_SET 90, 0, 2, 0    # res 2,(iz+d) -> b
    XC_RES_SET 91, 0, 2, 1    # res 2,(iz+d) -> c
    XC_RES_SET 92, 0, 2, 2    # res 2,(iz+d) -> d
    XC_RES_SET 93, 0, 2, 3    # res 2,(iz+d) -> e
    XC_RES_SET 94, 0, 2, 4    # res 2,(iz+d) -> h
    XC_RES_SET 95, 0, 2, 5    # res 2,(iz+d) -> l
    XC_RES_SET 96, 0, 2, 6    # res 2,(iz+d)
    XC_RES_SET 97, 0, 2, 7    # res 2,(iz+d) -> a
    XC_RES_SET 98, 0, 3, 0    # res 3,(iz+d) -> b
    XC_RES_SET 99, 0, 3, 1    # res 3,(iz+d) -> c
    XC_RES_SET 9A, 0, 3, 2    # res 3,(iz+d) -> d
    XC_RES_SET 9B, 0, 3, 3    # res 3,(iz+d) -> e
    XC_RES_SET 9C, 0, 3, 4    # res 3,(iz+d) -> h
    XC_RES_SET 9D, 0, 3, 5    # res 3,(iz+d) -> l
    XC_RES_SET 9E, 0, 3, 6    # res 3,(iz+d)
    XC_RES_SET 9F, 0, 3, 7    # res 3,(iz+d) -> a
    XC_RES_SET A0, 0, 4, 0    # res 4,(iz+d) -> b
    XC_RES_SET A1, 0, 4, 1    # res 4,(iz+d) -> c
    XC_RES_SET A2, 0, 4, 2    # res 4,(iz+d) -> d
    XC_RES_SET A3, 0, 4, 3    # res 4,(iz+d) -> e
    XC_RES_SET A4, 0, 4, 4    # res 4,(iz+d) -> h
    XC_RES_SET A5, 0, 4, 5    # res 4,(iz+d) -> l
    XC_RES_SET A6, 0, 4, 6    # res 4,(iz+d)
    XC_RES_SET A7, 0, 4, 7    # res 4,(iz+d) -> a
    XC_RES_SET A8, 0, 5, 0    # res 5,(iz+d) -> b
    XC_RES_SET A9, 0, 5, 1    # res 5,(iz+d) -> c
    XC_RES_SET AA, 0, 5, 2    # res 5,(iz+d) -> d
    XC_RES_SET AB, 0, 5, 3    # res 5,(iz+d) -> e
    XC_RES_SET AC, 0, 5, 4    # res 5,(iz+d) -> h
    XC_RES_SET AD, 0, 5, 5    # res 5,(iz+d) -> l
    XC_RES_SET AE, 0, 5, 6    # res 5,(iz+d)
    XC_RES_SET AF, 0, 5, 7    # res 5,(iz+d) -> a
    XC_RES_SET B0, 0, 6, 0    # res 6,(iz+d) -> b
    XC_RES_SET B1, 0, 6, 1    # res 6,(iz+d) -> c
    XC_RES_SET B2, 0, 6, 2    # res 6,(iz+d) -> d
    XC_RES_SET B3, 0, 6, 3    # res 6,(iz+d) -> e
    XC_RES_SET B4, 0, 6, 4    # res 6,(iz+d) -> h
    XC_RES_SET B5, 0, 6, 5    # res 6,(iz+d) -> l
    XC_RES_SET B6, 0, 6, 6    # res 6,(iz+d)
    XC_RES_SET B7, 0, 6, 7    # res 6,(iz+d) -> a
    XC_RES_SET B8, 0, 7, 0    # res 7,(iz+d) -> b
    XC_RES_SET B9, 0, 7, 1    # res 7,(iz+d) -> c
    XC_RES_SET BA, 0, 7, 2    # res 7,(iz+d) -> d
    XC_RES_SET BB, 0, 7, 3    # res 7,(iz+d) -> e
    XC_RES_SET BC, 0, 7, 4    # res 7,(iz+d) -> h
    XC_RES_SET BD, 0, 7, 5    # res 7,(iz+d) -> l
    XC_RES_SET BE, 0, 7, 6    # res 7,(iz+d)
    XC_RES_SET BF, 0, 7, 7    # res 7,(iz+d) -> a
    XC_RES_SET C0, 1, 0, 0    # set 0,(iz+d) -> b
    XC_RES_SET C1, 1, 0, 1    # set 0,(iz+d) -> c
    XC_RES_SET C2, 1, 0, 2    # set 0,(iz+d) -> d
    XC_RES_SET C3, 1, 0, 3    # set 0,(iz+d) -> e
    XC_RES_SET C4, 1, 0, 4    # set 0,(iz+d) -> h
    XC_RES_SET C5, 1, 0, 5    # set 0,(iz+d) -> l
    XC_RES_SET C6, 1, 0, 6    # set 0,(iz+d)
    XC_RES_SET C7, 1, 0, 7    # set 0,(iz+d) -> a
    XC_RES_SET C8, 1, 1, 0    # set 1,(iz+d) -> b
    XC_RES_SET C9, 1, 1, 1    # set 1,(iz+d) -> c
    XC_RES_SET CA, 1, 1, 2    # set 1,(iz+d) -> d
    XC_RES_SET CB, 1, 1, 3    # set 1,(iz+d) -> e
    XC_RES_SET CC, 1, 1, 4    # set 1,(iz+d) -> h
    XC_RES_SET CD, 1, 1, 5    # set 1,(iz+d) -> l
    XC_RES_SET CE, 1, 1, 6    # set 1,(iz+d)
    XC_RES_SET CF, 1, 1, 7    # set 1,(iz+d) -> a
    XC_RES_SET D0, 1, 2, 0    # set 2,(iz+d) -> b
    XC_RES_SET D1, 1, 2, 1    # set 2,(iz+d) -> c
    XC_RES_SET D2, 1, 2, 2    # set 2,(iz+d) -> d
    XC_RES_SET D3, 1, 2, 3    # set 2,(iz+d) -> e
    XC_RES_SET D4, 1, 2, 4    # set 2,(iz+d) -> h
    XC_RES_SET D5, 1, 2, 5    # set 2,(iz+d) -> l
    XC_RES_SET D6, 1, 2, 6    # set 2,(iz+d)
    XC_RES_SET D7, 1, 2, 7    # set 2,(iz+d) -> a
    XC_RES_SET D8, 1, 3, 0    # set 3,(iz+d) -> b
    XC_RES_SET D9, 1, 3, 1    # set 3,(iz+d) -> c
    XC_RES_SET DA, 1, 3, 2    # set 3,(iz+d) -> d
    XC_RES_SET DB, 1, 3, 3    # set 3,(iz+d) -> e
    XC_RES_SET DC, 1, 3, 4    # set 3,(iz+d) -> h
    XC_RES_SET DD, 1, 3, 5    # set 3,(iz+d) -> l
    XC_RES_SET DE, 1, 3, 6    # set 3,(iz+d)
    XC_RES_SET DF, 1, 3, 7    # set 3,(iz+d) -> a
    XC_RES_SET E0, 1, 4, 0    # set 4,(iz+d) -> b
    XC_RES_SET E1, 1, 4, 1    # set 4,(iz+d) -> c
    XC_RES_SET E2, 1, 4, 2    # set 4,(iz+d) -> d
    XC_RES_SET E3, 1, 4, 3    # set 4,(iz+d) -> e
    XC_RES_SET E4, 1, 4, 4    # set 4,(iz+d) -> h
    XC_RES_SET E5, 1, 4, 5    # set 4,(iz+d) -> l
    XC_RES_SET E6, 1, 4, 6    # set 4,(iz+d)
    XC_RES_SET E7, 1, 4, 7    # set 4,(iz+d) -> a
    XC_RES_SET E8, 1, 5, 0    # set 5,(iz+d) -> b
    XC_RES_SET E9, 1, 5, 1    # set 5,(iz+d) -> c
    XC_RES_SET EA, 1, 5, 2    # set 5,(iz+d) -> d
    XC_RES_SET EB, 1, 5, 3    # set 5,(iz+d) -> e
    XC_RES_SET EC, 1, 5, 4    # set 5,(iz+d) -> h
    XC_RES_SET ED, 1, 5, 5    # set 5,(iz+d) -> l
    XC_RES_SET EE, 1, 5, 6    # set 5,(iz+d)
    XC_RES_SET EF, 1, 5, 7    # set 5,(iz+d) -> a
    XC_RES_SET F0, 1, 6, 0    # set 6,(iz+d) -> b
    XC_RES_SET F1, 1, 6, 1    # set 6,(iz+d) -> c
    XC_RES_SET F2, 1, 6, 2    # set 6,(iz+d) -> d
    XC_RES_SET F3, 1, 6, 3    # set 6,(iz+d) -> e
    XC_RES_SET F4, 1, 6, 4    # set 6,(iz+d) -> h
    XC_RES_SET F5, 1, 6, 5    # set 6,(iz+d) -> l
    XC_RES_SET F6, 1, 6, 6    # set 6,(iz+d)
    XC_RES_SET F7, 1, 6, 7    # set 6,(iz+d) -> a
    XC_RES_SET F8, 1, 7, 0    # set 7,(iz+d) -> b
    XC_RES_SET F9, 1, 7, 1    # set 7,(iz+d) -> c
    XC_RES_SET FA, 1, 7, 2    # set 7,(iz+d) -> d
    XC_RES_SET FB, 1, 7, 3    # set 7,(iz+d) -> e
    XC_RES_SET FC, 1, 7, 4    # set 7,(iz+d) -> h
    XC_RES_SET FD, 1, 7, 5    # set 7,(iz+d) -> l
    XC_RES_SET FE, 1, 7, 6    # set 7,(iz+d)
    XC_RES_SET FF, 1, 7, 7    # set 7,(iz+d) -> a

# ===========================================================================
# Ports and interrupt control.
#
# Port callbacks get the whole state written back (call_c: registers, PC as
# the reference has it at the call, materialized R, cyc), may change the
# rmap and the event bytes, and are followed by a remap and the poison
# check. OUT marks the instruction as writing.

# v0 = port_in(z, t0). bal; keeps rPC0; clobbers the caller-saved registers.
    HOT
port_in:
    sw    ra, FR(F_WR+0)
    move  a1, t0
    lw    t9, N64Z80_OFF_PORT_IN(rZ)
    jal   call_c
     nop
    POISON_IF_EVENTS
    lw    ra, FR(F_WR+0)
    jr    ra
     nop

# port_out(z, t0, t1). bal; as port_in.
port_out:
    sw    ra, FR(F_WR+0)
    sw    rN, %gp_rel(n64z80_lastw)(gp)
    move  a1, t0
    move  a2, t1
    lw    t9, N64Z80_OFF_PORT_OUT(rZ)
    jal   call_c
     nop
    POISON_IF_EVENTS
    lw    ra, FR(F_WR+0)
    jr    ra
     nop

# in a,(n): port A << 8 | n; WZ = A_old << 8 | (A + 1), an int OR: A = 0xFF
# carries into WZ bit 8, as in the reference. Keep it.
OP DB
    CHARGE DB
    lbu   t0, 1(rPC)
    addiu rPC, rPC, 2
    sll   t1, rA, 8
    sw    t1, FR(F_WR+4)        # A_old << 8 (the stack slot survives the call)
    bal   port_in
     or   t0, t0, t1
    andi  rA, v0, 0xFF
    lw    t1, FR(F_WR+4)
    addiu t0, rA, 1
    or    t0, t0, t1
    b     dispatch
     sh    t0, N64Z80_OFF_MEM_PTR(rZ)

# out (n),a: WZ = (n + 1) | A << 8, the same bit-8 carry (n = 0xFF).
OP D3
    CHARGE D3
    lbu   t0, 1(rPC)
    addiu rPC, rPC, 2
    sw    t0, FR(F_WR+4)
    sll   t1, rA, 8
    or    t0, t0, t1
    bal   port_out
     move t1, rA
    lw    t0, FR(F_WR+4)
    sll   t1, rA, 8
    addiu t0, t0, 1
    or    t0, t0, t1
    b     dispatch
     sh    t0, N64Z80_OFF_MEM_PTR(rZ)

OP F3                           # di: IFF1 = IFF2 = 0 (set_iff1 clears the INT lanes)
    sb    zero, N64Z80_OFF_IFF1(rZ)
    sb    zero, N64Z80_OFF_IFF2(rZ)
    sb    zero, N64Z80_OFF_EVM_INT(rZ)
    sb    zero, N64Z80_OFF_EVM_LINE(rZ)
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE F3

OP FB                           # ei: iff_delay = 1 (an event)
    li    t0, 1
    sb    t0, N64Z80_OFF_IFF_DELAY(rZ)
    addiu rPC, rPC, 1
    CHARGE FB
    POISON_IF_EVENTS
    DISPATCH

OP 76                           # halt: halted = 1 (an event: the run stops)
    li    t0, 1
    sb    t0, N64Z80_OFF_HALTED(rZ)
    addiu rPC, rPC, 1
    CHARGE 76
    POISON_IF_EVENTS
    DISPATCH

OP 27                           # daa (the reference's daa())
    andi  t0, rA, 0x0F
    andi  t1, rF, 0x10          # H
    andi  t2, rF, 0x01          # C
    move  t3, zero              # correction
    sltiu t4, t0, 10
    beqz  t4, 1f                # low digit > 9
     nop
    beqz  t1, 2f
     nop
1:  li    t3, 0x06
2:  sltiu t4, rA, 0x9A
    beqz  t4, 3f                # A > 0x99
     nop
    beqz  t2, 4f
     nop
3:  addiu t3, t3, 0x60
    li    t2, 1                 # C = 1
4:  andi  t4, rF, 0x02          # N
    beqz  t4, 5f
     sltiu t5, t0, 6
    # subtraction: H = H && low digit < 6; A -= correction
    subu  rA, rA, t3
    bnez  t5, 7f
     nop
    b     7f
     move t1, zero
5:  # addition: H = low digit > 9; A += correction
    sltiu t5, t0, 10
    xori  t5, t5, 1
    sll   t1, t5, 4
    addu  rA, rA, t3
7:  andi  rA, rA, 0xFF
    addu  t5, rA, gp
    lbu   t5, %gp_rel(n64z80_sz53p)(t5)
    andi  rF, rF, 0x02          # N kept
    or    rF, rF, t1
    or    rF, rF, t2
    or    rF, rF, t5
    addiu rPC, rPC, 1
    b     dispatch
     CHARGE 27

# ---------------------------------------------------------------------------
# ED I/O: in r,(C) / out (C),r and the block forms. The port is B << 8 | C.

# in_r_c: t2 = port_in(BC); S Z P from it, H = N = 0, Y X C kept.
    HOT
in_bc:
    sw    ra, FR(F_IO+0)
    bal   port_in
     move t0, rBC
    andi  t2, v0, 0xFF
    addu  t0, t2, gp
    lbu   t0, %gp_rel(n64z80_sz53p)(t0)
    andi  rF, rF, 0x29
    andi  t0, t0, 0xC4
    or    rF, rF, t0
    lw    ra, FR(F_IO+0)
    jr    ra
     nop

.macro ED_IN op, r
EDOP \op
    bal   in_bc
     addiu rPC, rPC, 1          # the reference's PC at the call: past the opcode
  .if \r != 6
    SETR  \r, t2
  .endif
  .if \r == 7
    addiu t0, rBC, 1
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
  .endif
    DISPATCH
.endm
    ED_IN 40, 0
    ED_IN 48, 1
    ED_IN 50, 2
    ED_IN 58, 3
    ED_IN 60, 4
    ED_IN 68, 5
    ED_IN 70, 6                 # in (c): flags only
    ED_IN 78, 7                 # in a,(c): WZ = BC + 1

.macro ED_OUT op, r
EDOP \op
    addiu rPC, rPC, 1
  .if \r == 6
    move  t1, zero              # out (c),0
  .else
    GETR  t1, \r
  .endif
    bal   port_out
     move t0, rBC
  .if \r == 7
    addiu t0, rBC, 1
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
  .endif
    DISPATCH
.endm
    ED_OUT 41, 0
    ED_OUT 49, 1
    ED_OUT 51, 2
    ED_OUT 59, 3
    ED_OUT 61, 4
    ED_OUT 69, 5
    ED_OUT 71, 6
    ED_OUT 79, 7                # out (c),a: WZ = BC + 1

# ini / ind (ini(), ind()): (HL) = port_in(BC); HL += a1; B - 1;
# Z = (B == 0), N = 1, the rest kept; WZ = BC + 1 (ini) / BC - 2 (ind).
# rPC is at the second opcode byte. bal.
    RARE
inx_core:
    sw    ra, FR(F_IO+0)
    sw    a1, FR(F_IO+4)
    addiu rPC, rPC, 1           # the reference's PC at the call
    bal   port_in
     move t0, rBC
    move  t0, rHL
    bal   wr8
     andi t1, v0, 0xFF
    lw    a1, FR(F_IO+4)
    addiu rPC, rPC, -1
    b     ioblk_regs
     lw   ra, FR(F_IO+0)

# outi / outd (outi(), outd()): port_out(BC, (HL)) with B not yet
# decremented; then as ini / ind.
outx_core:
    sw    ra, FR(F_IO+0)
    sw    a1, FR(F_IO+4)
    READ8 t1, rHL, t0
    addiu rPC, rPC, 1
    bal   port_out
     move t0, rBC
    lw    a1, FR(F_IO+4)
    addiu rPC, rPC, -1
    lw    ra, FR(F_IO+0)
ioblk_regs:
    addu  rHL, rHL, a1
    andi  rHL, rHL, 0xFFFF
    addiu rBC, rBC, -0x100
    andi  rBC, rBC, 0xFFFF
    srl   t0, rBC, 8
    sltiu t0, t0, 1
    sll   t0, t0, 6
    andi  rF, rF, 0xBF
    or    rF, rF, t0            # Z = (B == 0)
    ori   rF, rF, 0x02          # N
    addiu t0, rBC, 1
    bgtz  a1, 1f
     nop
    addiu t0, rBC, -2
1:  jr    ra
     sh   t0, N64Z80_OFF_MEM_PTR(rZ)

# The block forms: one iteration; while B != 0 go back to the instruction
# itself (a loop edge), +5 except OTDR (the reference adds none there).
.macro ED_IOBLK op, core, step, rep, extra
EDOP \op
    bal   \core
     li   a1, \step
  .if \rep
    srl   t0, rBC, 8
    beqz  t0, next1
     nop
    addiu rCYC, rCYC, \extra
    ED_PC t0
    b     jp_to
     nop
  .else
    b     dispatch
     addiu rPC, rPC, 1
  .endif
.endm
    ED_IOBLK A2, inx_core, 1, 0, 0      # ini
    ED_IOBLK AA, inx_core, -1, 0, 0     # ind
    ED_IOBLK B2, inx_core, 1, 1, 5      # inir
    ED_IOBLK BA, inx_core, -1, 1, 5     # indr
    ED_IOBLK A3, outx_core, 1, 0, 0     # outi
    ED_IOBLK AB, outx_core, -1, 0, 0    # outd
    ED_IOBLK B3, outx_core, 1, 1, 5     # otir
    ED_IOBLK BB, outx_core, -1, 1, 0    # otdr: no +5

# ===========================================================================
# Dispatch tables, built from the handlers that exist. .ifdef only sees
# labels defined above it, so the tables must stay at the end.

# A table entry without a handler: the C fallback `fb` in a debug build, a
# build error otherwise.
.macro NOHANDLER fb, name
#if N64Z80_C_FALLBACK
    .word \fb
#else
    .error "n64z80: no asm handler for \name"
#endif
.endm
    .section .sdata
    .subsection 0
#ifdef N64Z80_DCACHE_ALIGN
    .balign 8192
#ifdef N64Z80_DCACHE_OFFSET
    .space N64Z80_DCACHE_OFFSET     # the block starts this far into the page
#endif
#else
    .balign 16
#endif

n64z80_optab:
    .irp hi, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .irp lo, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .ifdef op_\hi\lo
    .word op_\hi\lo
    .else
    NOHANDLER op_fallback, \hi\lo
    .endif
    .endr
    .endr

    .subsection 2
    .balign 16
n64z80_cbtab:
    .irp hi, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .irp lo, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .ifdef op_CB_\hi\lo
    .word op_CB_\hi\lo
    .else
    NOHANDLER pfx_fallback, prefixed \hi\lo
    .endif
    .endr
    .endr

n64z80_xcbtab:
    .irp hi, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .irp lo, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .ifdef op_XC_\hi\lo
    .word op_XC_\hi\lo
    .else
    NOHANDLER pfx_fallback, prefixed \hi\lo
    .endif
    .endr
    .endr

# ED: handlers; opcodes the reference implements but the asm doesn't yet go
# to C; the rest are the reference's 8-cycle NOP.
n64z80_edtab:
    .irp hi, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .irp lo, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .ifdef op_ED_\hi\lo
    .word op_ED_\hi\lo
    .else
    .ifdef ED_OP_\hi\lo
    NOHANDLER pfx_fallback, prefixed \hi\lo
    .else
    .word ed_nop
    .endif
    .endif
    .endr
    .endr

# DD / FD: index-register handlers; index forms without one go to C; any
# other opcode runs as the unprefixed one (ddfd_base) if that has a handler,
# a second prefix (DD, ED, FD) through ddfd_chain.
    .set CHAIN_DD, 1
    .set CHAIN_ED, 1
    .set CHAIN_FD, 1
.macro DDFD_TABLE p
    .irp hi, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .irp lo, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .ifdef op_\p\()_\hi\lo
    .word op_\p\()_\hi\lo
    .else
    .ifdef DDFD_IZ_\hi\lo
    NOHANDLER pfx_fallback, prefixed \hi\lo
    .else
    .ifdef CHAIN_\hi\lo
    .word ddfd_chain
    .else
    .ifdef op_\hi\lo
    .word ddfd_base
    .else
    NOHANDLER pfx_fallback, prefixed \hi\lo
    .endif
    .endif
    .endif
    .endif
    .endr
    .endr
.endm
n64z80_ddtab:
    DDFD_TABLE DD

# Bounce buffer: a copy of an instruction that straddles a mapping boundary.
    .balign 4
n64z80_bbuf:    .word 0

    .subsection 0
n64z80_fdtab:
    DDFD_TABLE FD

# S, Z, Y, X and P/V of each result byte (the reference's table).
n64z80_sz53p:   .byte N64Z80_SZ53P

# cyc_ddfd, for ddfd_base.
n64z80_cycdd:   .byte N64Z80_CYCDD
