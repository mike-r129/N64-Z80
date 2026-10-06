# n64z80: Zilog Z80 interpreter for the N64 (VR4300, libdragon o64 ABI).
#
# n64z80_run is the reference z80_run loop (reference/z80.c) with the Z80
# registers in MIPS registers. M1: every opcode still executes in the C
# fallback (n64z80.c: one reference instruction), but the loop around it is
# the real design (PLAN.md §4, docs/design-notes.md):
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
#     value, lazy R (R = rhi | ((rbase + rN) & 0x7F)) and `wrote` (the write
#     hooks store rN in lastw: wrote = lastw == rN, wrote_any = lastw != 0).
#   - rPC0 is the Z80 address of the current instruction (pc0): the stop
#     test is pc <= pc0 after interrupt service, and *last_pc.
#include <regdef.h>
#include "n64z80_offsets.h"

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

# Stack frame: o64 argument home area, callee-saved registers, rZ.
#define FRAME   128
#define F_S0     32
#define F_RA    104
#define F_Z     112
#define F_RA2   120   // call_c's own return address

# ---------------------------------------------------------------------------
# Private state (gp-relative). The z80 struct itself is the owner's.
    .section .sdata
    .balign 4
    .globl n64z80_insn, n64z80_lastw
n64z80_until:   .word 0     # the run's `until`
n64z80_cbase:   .word 0     # cyc = cbase + rCYC
n64z80_insn:    .word 0     # rN, published for the C write hooks
n64z80_lastw:   .word 0     # rN of the last instruction that wrote (0: none)
n64z80_rbase:   .word 0     # R = rhi | ((rbase + rN) & 0x7F)
n64z80_rhi:     .word 0
n64z80_pc0:     .word 0     # rPC0 across C calls
n64z80_lastpc:  .word 0     # the run's last_pc pointer

# Dispatch table: one handler per opcode. M1: all go to the C fallback.
    .balign 4
n64z80_optab:
    .rept 256
    .word op_fallback
    .endr

    .text

# Next instruction, after the previous one's tail: run out / event check,
# then the fetch.
.macro DISPATCH
    bgez  rCYC, slow_exit
     lbu  t0, 0(rPC)
    DISPATCH_FETCHED
.endm

# Fetch and jump, with t0 = the opcode (already loaded from 0(rPC)).
.macro DISPATCH_FETCHED
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
    beqz  t0, 1f
     lw   t0, %gp_rel(n64z80_cbase)(gp)
    addu  t0, t0, rCYC
    sw    t0, %gp_rel(n64z80_cbase)(gp)
    move  rCYC, zero
1:
.endm

# ---------------------------------------------------------------------------
# unsigned n64z80_run(z80* z, unsigned long until, uint16_t* last_pc)
    .globl n64z80_run
    .type n64z80_run, @function
    .balign 32
n64z80_run:
    addiu sp, sp, -FRAME
    sd    s0, F_S0+0(sp)
    sd    s1, F_S0+8(sp)
    sd    s2, F_S0+16(sp)
    sd    s3, F_S0+24(sp)
    sd    s4, F_S0+32(sp)
    sd    s5, F_S0+40(sp)
    sd    s6, F_S0+48(sp)
    sd    s7, F_S0+56(sp)
    sd    s8, F_S0+64(sp)
    sd    ra, F_RA(sp)
    sw    a0, F_Z(sp)
    sw    a1, %gp_rel(n64z80_until)(gp)
    sw    a1, %gp_rel(n64z80_cbase)(gp)
    sw    a2, %gp_rel(n64z80_lastpc)(gp)
    sw    zero, %gp_rel(n64z80_lastw)(gp)
    move  rN, zero

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
    # The first instruction runs whatever the budget.
    b     pre_insn
     nop

# ---------------------------------------------------------------------------
# Slow exit: the tail of an instruction found rCYC >= 0 (out of cycles or
# poisoned), or a control transfer found a loop edge. Reference order: (3)
# interrupt service, then (4) the stop test, then (1) the next iteration's
# IRQ re-assertion and HALT.
slow_exit:
    lw    t0, %gp_rel(n64z80_cbase)(gp)
    lw    t1, %gp_rel(n64z80_until)(gp)
    subu  t0, t0, t1
    addu  rCYC, rCYC, t0
    sw    t1, %gp_rel(n64z80_cbase)(gp)

    ld    t0, N64Z80_OFF_EVENTS(rZ)
    ld    t1, N64Z80_OFF_EV_MASK(rZ)
    and   t0, t0, t1
    beqz  t0, 2f
     lbu  t0, N64Z80_OFF_IFF_DELAY(rZ)
    lbu   t1, N64Z80_OFF_NMI_PENDING(rZ)
    lbu   t2, N64Z80_OFF_INT_PENDING(rZ)
    lbu   t3, N64Z80_OFF_IFF1(rZ)
    or    t0, t0, t1
    and   t2, t2, t3
    or    t0, t0, t2
    beqz  t0, 1f
     nop
    la    t9, n64z80_c_service
    jal   call_c
     nop
1:  lbu   t0, N64Z80_OFF_HALTED(rZ)
    bnez  t0, stop
     nop
2:  bgez  rCYC, stop
     subu t0, rPC, rBIAS
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
    beqz  t0, 1f                     # irq_line && iff1 && !int_pending
     li   t3, 1
    beqz  t1, 1f
     lw   t0, N64Z80_OFF_IRQ_REDELIVER(rZ)
    bnez  t2, 1f
     nop
    sb    t3, N64Z80_OFF_INT_PENDING(rZ)   # z80_gen_int(z, z->int_data)
    addiu t0, t0, 1
    sw    t0, N64Z80_OFF_IRQ_REDELIVER(rZ)
1:  lbu   t0, N64Z80_OFF_HALTED(rZ)
    beqz  t0, 2f
     lw   t0, %gp_rel(n64z80_cbase)(gp)
    # HALT: a 4-cycle NOP in place (cyc_00[0x00]; R via rN), then its tail.
    subu  rPC0, rPC, rBIAS
    addiu rN, rN, 1
    b     slow_exit
     addiu rCYC, rCYC, 4
2:  addu  t0, t0, rCYC                 # events pending: poison
    sw    t0, %gp_rel(n64z80_cbase)(gp)
    move  rCYC, zero
dispatch_nocyc:
    lbu   t0, 0(rPC)
    DISPATCH_FETCHED

# rPC reached rLIM: rPC is in the last 4 bytes of a page (the instruction
# before was in the fast path, at most 4 bytes long). Extend rLIM if the
# next page continues the same host region (never past 0xFFFF), else run
# this instruction in the fallback.
refetch:
    subu  t0, rPC, rBIAS
    srl   t0, t0, 8
    xori  t1, t0, 0xFF
    beqz  t1, 1f
     sll  t0, t0, 2
    addu  t1, rRMAP, t0
    lw    t1, 4(t1)
    bne   t1, rBIAS, 1f
     nop
    b     dispatch_nocyc
     addiu rLIM, rLIM, 256
1:  subu  rPC0, rPC, rBIAS
    b     op_fallback
     addiu rN, rN, 1

# ---------------------------------------------------------------------------
# C fallback: the whole instruction at rPC (== rPC0) runs in the reference.
# The fallback re-executes the instruction's R increments, so give back the
# one dispatch counted before materializing R.
    .balign 32
op_fallback:
    lw    t0, %gp_rel(n64z80_rbase)(gp)
    addiu t0, t0, -1
    sw    t0, %gp_rel(n64z80_rbase)(gp)
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

# ---------------------------------------------------------------------------
# Call the C function t9(rZ, a1) with the state written back to the struct,
# then reload it (the callee may change anything, including the rmap).
call_c:
    sw    ra, F_RA2(sp)
    jal   save_state
     sw   rPC0, %gp_rel(n64z80_pc0)(gp)
    jalr  t9
     nop
    lw    rZ, F_Z(sp)
    jal   load_state
     lw   rPC0, %gp_rel(n64z80_pc0)(gp)
    lw    ra, F_RA2(sp)
    jr    ra
     nop

# Write the registers back to the struct: pc = rPC - rBIAS, cyc, R.
# Clobbers t0, t1.
save_state:
    sb    rA, N64Z80_OFF_A(rZ)
    sb    rF, N64Z80_OFF_F(rZ)
    srl   t0, rHL, 8
    sb    t0, N64Z80_OFF_H(rZ)
    sb    rHL, N64Z80_OFF_L(rZ)
    srl   t0, rDE, 8
    sb    t0, N64Z80_OFF_D(rZ)
    sb    rDE, N64Z80_OFF_E(rZ)
    srl   t0, rBC, 8
    sb    t0, N64Z80_OFF_B(rZ)
    sb    rBC, N64Z80_OFF_C(rZ)
    sh    rSP, N64Z80_OFF_SP(rZ)
    subu  t0, rPC, rBIAS
    sh    t0, N64Z80_OFF_PC(rZ)
    lw    t0, %gp_rel(n64z80_cbase)(gp)
    addu  t0, t0, rCYC
    sw    t0, N64Z80_OFF_CYC(rZ)
    lw    t0, %gp_rel(n64z80_rbase)(gp)
    lw    t1, %gp_rel(n64z80_rhi)(gp)
    addu  t0, t0, rN
    andi  t0, t0, 0x7F
    or    t0, t0, t1
    sb    t0, N64Z80_OFF_R(rZ)
    jr    ra
     sw   rN, %gp_rel(n64z80_insn)(gp)

# Load the registers from the struct, rebase R and the cycle counter, map PC.
# Clobbers t0-t2.
load_state:
    lbu   rA, N64Z80_OFF_A(rZ)
    lbu   rF, N64Z80_OFF_F(rZ)
    lbu   t0, N64Z80_OFF_H(rZ)
    lbu   rHL, N64Z80_OFF_L(rZ)
    sll   t0, t0, 8
    or    rHL, rHL, t0
    lbu   t0, N64Z80_OFF_D(rZ)
    lbu   rDE, N64Z80_OFF_E(rZ)
    sll   t0, t0, 8
    or    rDE, rDE, t0
    lbu   t0, N64Z80_OFF_B(rZ)
    lbu   rBC, N64Z80_OFF_C(rZ)
    sll   t0, t0, 8
    or    rBC, rBC, t0
    lhu   rSP, N64Z80_OFF_SP(rZ)
    lw    rRMAP, N64Z80_OFF_RMAP(rZ)
    lw    t0, N64Z80_OFF_CYC(rZ)
    lw    t1, %gp_rel(n64z80_cbase)(gp)
    subu  rCYC, t0, t1
    lbu   t0, N64Z80_OFF_R(rZ)
    andi  t1, t0, 0x80
    sw    t1, %gp_rel(n64z80_rhi)(gp)
    subu  t0, t0, rN
    sw    t0, %gp_rel(n64z80_rbase)(gp)
    lhu   t0, N64Z80_OFF_PC(rZ)
    REMAP
    jr    ra
     nop

# ---------------------------------------------------------------------------
# End of the run (cbase == until here): write everything back.
stop:
    jal   save_state
     nop
    lw    t0, %gp_rel(n64z80_lastw)(gp)
    xor   t1, t0, rN
    sltiu t1, t1, 1
    sb    t1, N64Z80_OFF_WROTE(rZ)
    sltu  t0, zero, t0
    sb    t0, N64Z80_OFF_WROTE_ANY(rZ)
    lw    t0, %gp_rel(n64z80_lastpc)(gp)
    sh    rPC0, 0(t0)
    move  v0, rN
    ld    s0, F_S0+0(sp)
    ld    s1, F_S0+8(sp)
    ld    s2, F_S0+16(sp)
    ld    s3, F_S0+24(sp)
    ld    s4, F_S0+32(sp)
    ld    s5, F_S0+40(sp)
    ld    s6, F_S0+48(sp)
    ld    s7, F_S0+56(sp)
    ld    s8, F_S0+64(sp)
    ld    ra, F_RA(sp)
    jr    ra
     addiu sp, sp, FRAME
    .size n64z80_run, .-n64z80_run
