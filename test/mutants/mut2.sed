# R increments carry into bit 7 (from seed/harness/zdiff/mut.sh).
s/z->r = (z->r \& 0x80) | ((z->r + 1) \& 0x7f);/z->r = z->r + 1;/
