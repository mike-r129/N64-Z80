
// --- Z80BENCH (scratch experiment, appended to sound_neogeo.c) -------------
// Times the Z80 core at boot on a synthetic table-scan loop, with nothing
// else running: raw steps, then steps wrapped in the sound loop's per-step
// checks. The Z80 working set is saved and restored around it.
#ifdef N64
static struct z80_hot z80bench_save;
static void z80bench_prog(void) {
	static const uint8_t prog[] = { 0x21,0x00,0x00, 0x7E, 0xA7, 0x23, 0x18,0xFB };
	memcpy(z80_ram, prog, sizeof prog);         // at 0xF800
	cpu.pc = 0xF800; cpu.halted = 0; cpu.iff1 = 0; cpu.int_pending = 0; cpu.nmi_pending = 0;
}
void z80bench_run(void) {
	const int N = 400000;
	z80bench_save = z80_hot;
	z80bench_prog();
	uint32_t t0 = TICKS_READ();
	for (int i = 0; i < N; i++) z80_step_inline(&cpu);
	uint32_t raw = TICKS_DISTANCE(t0, TICKS_READ());

	z80bench_prog();
	uint16_t last_back = 0xFFFF; struct z80snap spin_snap = {0,0,0}; int spin_armed = 0;
	unsigned long next = cpu.cyc + 0x7FFFFFFF;
	t0 = TICKS_READ();
	for (int i = 0; i < N; i++) {
		z80_service_level_irq();
		if (cpu.halted && !cpu.nmi_pending && (!cpu.int_pending || !cpu.iff1)) break;
		uint16_t pc0 = cpu.pc;
		z80_wrote = 0;
		z80_step_inline(&cpu);
		if (z80_wrote) spin_armed = 0;
		if (cpu.pc == pc0 && !z80_wrote && !cpu.halted && !cpu.iff_delay && !cpu.nmi_pending &&
		    !(cpu.iff1 && (cpu.int_pending || ym_irq_level))) {
			uint8_t op = z80_read(NULL, pc0);
			unsigned c = op == 0xC3 ? 10 : op == 0x18 ? 12 : 0;
			if (c && (long)(next - cpu.cyc) > 0) break;
		}
		if (cpu.pc < pc0) {
			if (cpu.pc == last_back) {
				struct z80snap now; z80_snap(&now, &cpu);
				if (spin_armed && z80_snap_eq(&now, &spin_snap)) break;
				spin_snap = now; spin_armed = 1;
			} else { last_back = cpu.pc; spin_armed = 0; }
		}
	}
	uint32_t loop = TICKS_DISTANCE(t0, TICKS_READ());
	z80_hot = z80bench_save;
	debugf("[Z80BENCH] raw=%lu ns/step loop=%lu ns/step (%d steps)\n",
	       (unsigned long)((uint64_t)raw * 1000000000ull / TICKS_PER_SECOND / N),
	       (unsigned long)((uint64_t)loop * 1000000000ull / TICKS_PER_SECOND / N), N);
}
#endif

// Real-driver variant: called mid-game; steps the game's own Z80 program
// with a timer IRQ injected every 1300 steps (the measured per-tick work),
// so it runs the driver's tick handler instead of its idle wait.
#ifdef N64
void z80bench_real(void) {
	const int N = 400000;
	z80bench_save = z80_hot;
	uint32_t t0 = TICKS_READ();
	for (int i = 0; i < N; i++) {
		if ((i % 1300) == 0 && cpu.iff1) z80_gen_int(&cpu, 0xff);
		z80_step_inline(&cpu);
	}
	uint32_t raw = TICKS_DISTANCE(t0, TICKS_READ());
	unsigned pc = cpu.pc;
	z80_hot = z80bench_save;
	debugf("[Z80BENCH] real driver raw=%lu ns/step (pc now %04x)\n",
	       (unsigned long)((uint64_t)raw * 1000000000ull / TICKS_PER_SECOND / N), pc);
}
#endif
