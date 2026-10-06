// Byte offsets of the z80 struct fields (n64z80.h, identical to mvs64's
// z80.h) under libdragon's o64 ABI: pointers and long are 32-bit, the
// events/ev_mask unions are 8-byte aligned. Shared by n64z80_asm.S and the C
// side, which static-asserts every one against the struct.
#ifndef N64Z80_OFFSETS_H
#define N64Z80_OFFSETS_H

#define N64Z80_OFF_READ_BYTE     0
#define N64Z80_OFF_WRITE_BYTE    4
#define N64Z80_OFF_PORT_IN       8
#define N64Z80_OFF_PORT_OUT     12
#define N64Z80_OFF_USERDATA     16
#define N64Z80_OFF_CYC          20
#define N64Z80_OFF_PC           24
#define N64Z80_OFF_SP           26
#define N64Z80_OFF_IX           28
#define N64Z80_OFF_IY           30
#define N64Z80_OFF_MEM_PTR      32
#define N64Z80_OFF_A            34
#define N64Z80_OFF_B            35
#define N64Z80_OFF_C            36
#define N64Z80_OFF_D            37
#define N64Z80_OFF_E            38
#define N64Z80_OFF_H            39
#define N64Z80_OFF_L            40
#define N64Z80_OFF_A_           41
#define N64Z80_OFF_B_           42
#define N64Z80_OFF_C_           43
#define N64Z80_OFF_D_           44
#define N64Z80_OFF_E_           45
#define N64Z80_OFF_H_           46
#define N64Z80_OFF_L_           47
#define N64Z80_OFF_F_           48
#define N64Z80_OFF_I            49
#define N64Z80_OFF_R            50
#define N64Z80_OFF_F            51
#define N64Z80_OFF_IM           52
#define N64Z80_OFF_INT_DATA     53
#define N64Z80_OFF_IFF1         54
#define N64Z80_OFF_IFF2         55
#define N64Z80_OFF_EVENTS       56   // u64: iff_delay, int_pending, nmi_pending, irq_line, halted
#define N64Z80_OFF_IFF_DELAY    56
#define N64Z80_OFF_INT_PENDING  57
#define N64Z80_OFF_NMI_PENDING  58
#define N64Z80_OFF_IRQ_LINE     59
#define N64Z80_OFF_HALTED       60
#define N64Z80_OFF_EV_MASK      64   // u64: one 0xFF/0 lane per events byte
#define N64Z80_OFF_EVM_IFF_DELAY 64
#define N64Z80_OFF_EVM_INT      65
#define N64Z80_OFF_EVM_NMI      66
#define N64Z80_OFF_EVM_LINE     67
#define N64Z80_OFF_EVM_HALTED   68
#define N64Z80_OFF_RMAP         72
#define N64Z80_OFF_WROTE        76
#define N64Z80_OFF_WROTE_ANY    77
#define N64Z80_OFF_IRQ_REDELIVER 80
#define N64Z80_SIZEOF           88

#if !defined(__ASSEMBLER__) && defined(N64)
#include <stddef.h>
#define N64Z80_CHECK_OFF(field, off) \
  _Static_assert(offsetof(z80, field) == (off), "z80." #field " offset")
// Checks the struct in scope against the offsets above (the reference's in
// n64z80.c, n64z80.h's own copy elsewhere).
#define N64Z80_CHECK_LAYOUT()                                                     \
  N64Z80_CHECK_OFF(read_byte, N64Z80_OFF_READ_BYTE);                              \
  N64Z80_CHECK_OFF(write_byte, N64Z80_OFF_WRITE_BYTE);                            \
  N64Z80_CHECK_OFF(port_in, N64Z80_OFF_PORT_IN);                                  \
  N64Z80_CHECK_OFF(port_out, N64Z80_OFF_PORT_OUT);                                \
  N64Z80_CHECK_OFF(userdata, N64Z80_OFF_USERDATA);                                \
  N64Z80_CHECK_OFF(cyc, N64Z80_OFF_CYC);                                          \
  N64Z80_CHECK_OFF(pc, N64Z80_OFF_PC);                                            \
  N64Z80_CHECK_OFF(sp, N64Z80_OFF_SP);                                            \
  N64Z80_CHECK_OFF(ix, N64Z80_OFF_IX);                                            \
  N64Z80_CHECK_OFF(iy, N64Z80_OFF_IY);                                            \
  N64Z80_CHECK_OFF(mem_ptr, N64Z80_OFF_MEM_PTR);                                  \
  N64Z80_CHECK_OFF(a, N64Z80_OFF_A);                                              \
  N64Z80_CHECK_OFF(b, N64Z80_OFF_B);                                              \
  N64Z80_CHECK_OFF(c, N64Z80_OFF_C);                                              \
  N64Z80_CHECK_OFF(d, N64Z80_OFF_D);                                              \
  N64Z80_CHECK_OFF(e, N64Z80_OFF_E);                                              \
  N64Z80_CHECK_OFF(h, N64Z80_OFF_H);                                              \
  N64Z80_CHECK_OFF(l, N64Z80_OFF_L);                                              \
  N64Z80_CHECK_OFF(a_, N64Z80_OFF_A_);                                            \
  N64Z80_CHECK_OFF(b_, N64Z80_OFF_B_);                                            \
  N64Z80_CHECK_OFF(c_, N64Z80_OFF_C_);                                            \
  N64Z80_CHECK_OFF(d_, N64Z80_OFF_D_);                                            \
  N64Z80_CHECK_OFF(e_, N64Z80_OFF_E_);                                            \
  N64Z80_CHECK_OFF(h_, N64Z80_OFF_H_);                                            \
  N64Z80_CHECK_OFF(l_, N64Z80_OFF_L_);                                            \
  N64Z80_CHECK_OFF(f_, N64Z80_OFF_F_);                                            \
  N64Z80_CHECK_OFF(i, N64Z80_OFF_I);                                              \
  N64Z80_CHECK_OFF(r, N64Z80_OFF_R);                                              \
  N64Z80_CHECK_OFF(f, N64Z80_OFF_F);                                              \
  N64Z80_CHECK_OFF(interrupt_mode, N64Z80_OFF_IM);                                \
  N64Z80_CHECK_OFF(int_data, N64Z80_OFF_INT_DATA);                                \
  N64Z80_CHECK_OFF(iff1, N64Z80_OFF_IFF1);                                        \
  N64Z80_CHECK_OFF(iff2, N64Z80_OFF_IFF2);                                        \
  N64Z80_CHECK_OFF(events, N64Z80_OFF_EVENTS);                                    \
  N64Z80_CHECK_OFF(iff_delay, N64Z80_OFF_IFF_DELAY);                              \
  N64Z80_CHECK_OFF(int_pending, N64Z80_OFF_INT_PENDING);                          \
  N64Z80_CHECK_OFF(nmi_pending, N64Z80_OFF_NMI_PENDING);                          \
  N64Z80_CHECK_OFF(irq_line, N64Z80_OFF_IRQ_LINE);                                \
  N64Z80_CHECK_OFF(halted, N64Z80_OFF_HALTED);                                    \
  N64Z80_CHECK_OFF(ev_mask, N64Z80_OFF_EV_MASK);                                  \
  N64Z80_CHECK_OFF(evm_iff_delay, N64Z80_OFF_EVM_IFF_DELAY);                      \
  N64Z80_CHECK_OFF(evm_int, N64Z80_OFF_EVM_INT);                                  \
  N64Z80_CHECK_OFF(evm_nmi, N64Z80_OFF_EVM_NMI);                                  \
  N64Z80_CHECK_OFF(evm_line, N64Z80_OFF_EVM_LINE);                                \
  N64Z80_CHECK_OFF(evm_halted, N64Z80_OFF_EVM_HALTED);                            \
  N64Z80_CHECK_OFF(rmap, N64Z80_OFF_RMAP);                                        \
  N64Z80_CHECK_OFF(wrote, N64Z80_OFF_WROTE);                                      \
  N64Z80_CHECK_OFF(wrote_any, N64Z80_OFF_WROTE_ANY);                              \
  N64Z80_CHECK_OFF(irq_redeliver, N64Z80_OFF_IRQ_REDELIVER);                      \
  _Static_assert(sizeof(z80) == N64Z80_SIZEOF, "sizeof(z80)")
#endif

#endif
