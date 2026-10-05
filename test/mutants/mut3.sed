# CALL cc charges its taken +7 before the push instead of after: the final
# state is identical, only the cycle stamps of the two pushed bytes move.
s/    call(z, addr);\n    z->cyc += 7;/    z->cyc += 7;\n    call(z, addr);/
