# BIT b,r loses the H flag (from seed/harness/zdiff/mut.sh).
s/(val \& (FLAG_Y | FLAG_X)) | FLAG_H;/(val \& (FLAG_Y | FLAG_X));/
