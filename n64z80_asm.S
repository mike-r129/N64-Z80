# n64z80: Zilog Z80 interpreter for the N64 (VR4300, libdragon o64 ABI).
#
# n64z80_run is the reference z80_run loop (reference/z80.c) with the Z80
# registers in MIPS registers. Opcodes without an asm handler (n64z80_optab
# entries left at op_fallback) execute in the C fallback (n64z80.c: one
# reference instruction). Design (PLAN.md §4, docs/design-notes.md):
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
#   - Handlers charge the reference's base cycles (CYC00_xx, generated from
#     reference/z80.c) before any bus callback, and the conditional extras
#     where the reference adds them, so callback cycle stamps match.
#   - Writes go through wr8, which calls the owner's write_byte with `cyc`
#     written back; write callbacks may change the rmap and the event bytes
#     (wr8 remaps the PC and poisons). Other struct fields are not written
#     back for write callbacks (design-notes, M0 review item 5).
#include <regdef.h>
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

# Stack frame: o64 argument home area, callee-saved registers, rZ, and the
# registers wr8 keeps across a write callback.
#define FRAME   176
#define F_S0     32
#define F_RA    104
#define F_Z     112
#define F_RA2   120   // call_c's own return address
#define F_WR    128   // wr8: ra, t2-t7, t8, Z80 PC (9 words)

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

# S, Z, Y, X and P/V of each result byte (the reference's table).
n64z80_sz53p:   .byte N64Z80_SZ53P

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

# ===========================================================================
# Handlers. Each one is entered from the dispatch with rPC at its opcode,
# rPC0 = its Z80 address and rN already counting it; it advances rPC (or
# jumps through jp_to) and ends with DISPATCH. Bodies follow the reference
# case by case (reference/z80.c exec_main / exec_opcode_slow).

.macro OP op
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
# Shared pieces.

# Write byte t1 to Z80 address t0 through the owner's write_byte, with `cyc`
# written back (bal; rN marks the instruction as writing). Keeps t2-t7, t8
# and the Z80 PC; remaps the PC (the callback may change the rmap) and
# poisons if events & ev_mask became nonzero. Clobbers t0, t1, t9, a1, a2
# (rRMAP is reloaded).
wr8:
    sw    rN, %gp_rel(n64z80_lastw)(gp)
    sw    ra, F_WR+0(sp)
    sw    t2, F_WR+4(sp)
    sw    t3, F_WR+8(sp)
    sw    t4, F_WR+12(sp)
    sw    t5, F_WR+16(sp)
    sw    t6, F_WR+20(sp)
    sw    t7, F_WR+24(sp)
    sw    t8, F_WR+28(sp)
    subu  t9, rPC, rBIAS
    sw    t9, F_WR+32(sp)
    lw    t9, %gp_rel(n64z80_cbase)(gp)
    addu  t9, t9, rCYC
    sw    t9, N64Z80_OFF_CYC(rZ)
    lw    t9, N64Z80_OFF_WRITE_BYTE(rZ)
    move  a1, t0
    move  a2, t1
    jalr  t9
     lw   a0, N64Z80_OFF_USERDATA(rZ)
    lw    rZ, F_Z(sp)
    lw    rRMAP, N64Z80_OFF_RMAP(rZ)
    lw    t0, F_WR+32(sp)
    REMAP
    POISON_IF_EVENTS
    lw    ra, F_WR+0(sp)
    lw    t2, F_WR+4(sp)
    lw    t3, F_WR+8(sp)
    lw    t4, F_WR+12(sp)
    lw    t5, F_WR+16(sp)
    lw    t6, F_WR+20(sp)
    lw    t7, F_WR+24(sp)
    jr    ra
     lw   t8, F_WR+28(sp)

# Push t4 (16-bit) as the reference's pushw: SP -= 2, low byte at SP, high
# byte at SP+1 (bal). Keeps t2-t6; clobbers t0, t1, t7, t9.
push_t4:
    move  t7, ra
    addiu rSP, rSP, -2
    andi  rSP, rSP, 0xFFFF
    move  t0, rSP
    bal   wr8
     andi t1, t4, 0xFF
    addiu t0, rSP, 1
    andi  t0, t0, 0xFFFF
    bal   wr8
     srl  t1, t4, 8
    jr    t7
     nop

# Control transfer to Z80 address t0 (16-bit): loop-edge test against rPC0,
# remap, next instruction.
jp_to:
    sltu  t1, rPC0, t0
    REMAP
    beqz  t1, slow_exit
     nop
    DISPATCH

# Taken JR / JR cc / DJNZ: t1 = signed displacement; rPC at the opcode.
# WZ = the new PC, +5 cycles (the reference's jr() and cond_jr()).
jr_taken:
    subu  t0, rPC, rBIAS
    addiu t0, t0, 2
    addu  t0, t0, t1
    andi  t0, t0, 0xFFFF
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    b     jp_to
     addiu rCYC, rCYC, 5

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
    andi  rA, t2, 0xFF
    DISPATCH
alu_adc:
    andi  t1, rF, 1
    ADDB  rA, t0, t1
    andi  rA, t2, 0xFF
    DISPATCH
alu_sub:                          # subb: addb(a, ~b, 1), then C/H flipped, N
    xori  t0, t0, 0xFF
    li    t1, 1
    ADDB  rA, t0, t1
    xori  rF, rF, 0x11
    ori   rF, rF, 0x02
    andi  rA, t2, 0xFF
    DISPATCH
alu_sbc:
    andi  t1, rF, 1
    xori  t1, t1, 1
    xori  t0, t0, 0xFF
    ADDB  rA, t0, t1
    xori  rF, rF, 0x11
    ori   rF, rF, 0x02
    andi  rA, t2, 0xFF
    DISPATCH
alu_and:
    and   rA, rA, t0
    addu  t1, rA, gp
    lbu   rF, %gp_rel(n64z80_sz53p)(t1)
    ori   rF, rF, 0x10
    DISPATCH
alu_xor:
    xor   rA, rA, t0
    addu  t1, rA, gp
    lbu   rF, %gp_rel(n64z80_sz53p)(t1)
    DISPATCH
alu_or:
    or    rA, rA, t0
    addu  t1, rA, gp
    lbu   rF, %gp_rel(n64z80_sz53p)(t1)
    DISPATCH
alu_cp:                           # sub without the result; Y/X from the operand
    andi  t9, t0, 0x28
    xori  t0, t0, 0xFF
    li    t1, 1
    ADDB  rA, t0, t1
    xori  rF, rF, 0x11
    ori   rF, rF, 0x02
    andi  rF, rF, 0xD7
    or    rF, rF, t9
    DISPATCH

# INC / DEC of byte t0: t2 = result byte, F as the reference's inc()/dec()
# (C kept). bal; clobbers t1, t3-t7, t9, v0.
inc_core:
    andi  t9, rF, 1
    li    t1, 1
    ADDB  t0, t1, zero
    andi  rF, rF, 0xFE
    or    rF, rF, t9
    jr    ra
     andi t2, t2, 0xFF
dec_core:                         # subb(v, 1, 0) = addb(v, 0xFE, 1), C/H flipped, N
    andi  t9, rF, 1
    li    t1, 0xFE
    li    v0, 1
    ADDB  t0, t1, v0
    xori  rF, rF, 0x11
    ori   rF, rF, 0x02
    andi  rF, rF, 0xFE
    or    rF, rF, t9
    jr    ra
     andi t2, t2, 0xFF

# ---------------------------------------------------------------------------
# Handler families.

.macro LD_R_R op, d, s
OP \op
    GETR  t0, \s
    SETR  \d, t0
    addiu rPC, rPC, 1
    CHARGE \op
    DISPATCH
.endm

.macro LD_R_HL op, r
OP \op
    READ8 t0, rHL, t1
    addiu rPC, rPC, 1
    CHARGE \op
    SETR  \r, t0
    DISPATCH
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
    addiu rPC, rPC, 1
    DISPATCH
.endm

.macro DEC_R op, r
OP \op
    GETR  t0, \r
    bal   dec_core
     CHARGE \op
    SETR  \r, t2
    addiu rPC, rPC, 1
    DISPATCH
.endm

.macro LD_RR_NN op, rr
OP \op
    FETCH16 \rr, t0
    addiu rPC, rPC, 3
    CHARGE \op
    DISPATCH
.endm

.macro INC_RR op, rr
OP \op
    addiu \rr, \rr, 1
    andi  \rr, \rr, 0xFFFF
    addiu rPC, rPC, 1
    CHARGE \op
    DISPATCH
.endm

.macro DEC_RR op, rr
OP \op
    addiu \rr, \rr, -1
    andi  \rr, \rr, 0xFFFF
    addiu rPC, rPC, 1
    CHARGE \op
    DISPATCH
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
    CHARGE \op
    DISPATCH
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
    addiu rPC, rPC, 2
    DISPATCH
.endm

# JP cc,nn (cond_jump): WZ = nn taken or not.
.macro JP_CC op, mask, set
OP \op
    FETCH16 t0, t1
    andi  t3, rF, \mask
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    BCOND \set, jp_to
     CHARGE \op
    addiu rPC, rPC, 3
    DISPATCH
.endm

# CALL cc,nn (cond_call): push and +7 if taken; WZ = nn either way.
.macro CALL_CC op, mask, set
OP \op
    FETCH16 t5, t1
    andi  t3, rF, \mask
    BCOND \set, call_taken
     CHARGE \op
    sh    t5, N64Z80_OFF_MEM_PTR(rZ)
    addiu rPC, rPC, 3
    DISPATCH
.endm

.macro RET_CC op, mask, set
OP \op
    andi  t3, rF, \mask
    BCOND \set, ret_taken
     CHARGE \op
    addiu rPC, rPC, 1
    DISPATCH
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
    addiu rPC, rPC, 1
    DISPATCH
.endm

.macro POP_RR op, rr
OP \op
    POP16 \rr, t0, t1
    addiu rPC, rPC, 1
    CHARGE \op
    DISPATCH
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
    ALU_R    A7, alu_and, 7     # and a
    ALU_R    A8, alu_xor, 0     # xor b
    ALU_R    A9, alu_xor, 1     # xor c
    ALU_R    AA, alu_xor, 2     # xor d
    ALU_R    AB, alu_xor, 3     # xor e
    ALU_R    AC, alu_xor, 4     # xor h
    ALU_R    AD, alu_xor, 5     # xor l
    ALU_HL   AE, alu_xor        # xor (hl)
    ALU_R    AF, alu_xor, 7     # xor a
    ALU_R    B0, alu_or, 0      # or b
    ALU_R    B1, alu_or, 1      # or c
    ALU_R    B2, alu_or, 2      # or d
    ALU_R    B3, alu_or, 3      # or e
    ALU_R    B4, alu_or, 4      # or h
    ALU_R    B5, alu_or, 5      # or l
    ALU_HL   B6, alu_or         # or (hl)
    ALU_R    B7, alu_or, 7      # or a
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

OP 00                           # nop
    addiu rPC, rPC, 1
    CHARGE 00
    DISPATCH

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
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    DISPATCH

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
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    DISPATCH

OP 0A                           # ld a,(bc): WZ = BC + 1
    READ8 rA, rBC, t0
    addiu t1, rBC, 1
    sh    t1, N64Z80_OFF_MEM_PTR(rZ)
    addiu rPC, rPC, 1
    CHARGE 0A
    DISPATCH

OP 1A                           # ld a,(de)
    READ8 rA, rDE, t0
    addiu t1, rDE, 1
    sh    t1, N64Z80_OFF_MEM_PTR(rZ)
    addiu rPC, rPC, 1
    CHARGE 1A
    DISPATCH

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
    CHARGE 07
    DISPATCH

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
    CHARGE 0F
    DISPATCH

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
    CHARGE 17
    DISPATCH

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
    CHARGE 1F
    DISPATCH

OP 2F                           # cpl
    xori  rA, rA, 0xFF
    andi  rF, rF, 0xC5
    ori   rF, rF, 0x12
    andi  t1, rA, 0x28
    or    rF, rF, t1
    addiu rPC, rPC, 1
    CHARGE 2F
    DISPATCH

OP 37                           # scf
    andi  rF, rF, 0xC4
    ori   rF, rF, 0x01
    andi  t1, rA, 0x28
    or    rF, rF, t1
    addiu rPC, rPC, 1
    CHARGE 37
    DISPATCH

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
    CHARGE 3F
    DISPATCH

OP 08                           # ex af,af'
    lbu   t0, N64Z80_OFF_A_(rZ)
    lbu   t1, N64Z80_OFF_F_(rZ)
    sb    rA, N64Z80_OFF_A_(rZ)
    sb    rF, N64Z80_OFF_F_(rZ)
    move  rA, t0
    move  rF, t1
    addiu rPC, rPC, 1
    CHARGE 08
    DISPATCH

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
    CHARGE D9
    DISPATCH

OP EB                           # ex de,hl
    move  t0, rDE
    move  rDE, rHL
    move  rHL, t0
    addiu rPC, rPC, 1
    CHARGE EB
    DISPATCH

OP F9                           # ld sp,hl
    move  rSP, rHL
    addiu rPC, rPC, 1
    CHARGE F9
    DISPATCH

OP 10                           # djnz: --B, cond_jr
    addiu rBC, rBC, -0x100
    andi  rBC, rBC, 0xFFFF
    srl   t3, rBC, 8
    CHARGE 10
    bnez  t3, jr_taken
     lb   t1, 1(rPC)
    addiu rPC, rPC, 2
    DISPATCH

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
    addiu rPC, rPC, 1
    DISPATCH

OP F1                           # pop af
    POP16 t0, t1, t2
    srl   rA, t0, 8
    andi  rF, t0, 0xFF
    addiu rPC, rPC, 1
    CHARGE F1
    DISPATCH

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
    addiu rPC, rPC, 1
    DISPATCH

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
    addiu rPC, rPC, 3
    DISPATCH

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
    CHARGE 2A
    DISPATCH

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
    addiu rPC, rPC, 3
    DISPATCH

OP 3A                           # ld a,(nn): WZ = nn + 1
    FETCH16 t0, t1
    READ8 rA, t0, t1
    addiu t0, t0, 1
    sh    t0, N64Z80_OFF_MEM_PTR(rZ)
    addiu rPC, rPC, 3
    CHARGE 3A
    DISPATCH

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

# ---------------------------------------------------------------------------
# Dispatch table: op_XX where a handler exists, else the C fallback.
    .section .sdata
    .balign 4
n64z80_optab:
    .irp hi, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .irp lo, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .ifdef op_\hi\lo
    .word op_\hi\lo
    .else
    .word op_fallback
    .endif
    .endr
    .endr
