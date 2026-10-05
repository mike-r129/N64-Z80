# z80_run treats a self-jump (new PC == old PC) as forward progress: only the
# stop point (step count, last_pc) changes.
s/z->pc > pc0)) break;/z->pc >= pc0)) break;/
