/*
 * Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
 * SPDX-License-Identifier: BSD-3-Clause-Clear
 */

/* Shadow-call-stack startup object for hexagon-unknown-linux-musl.
 *
 * This is musl's crt1 (_start + _start_c) with a single addition: _start
 * initialises r19 -- the Hexagon shadow-call-stack pointer, which grows up --
 * to a static shadow-stack buffer BEFORE any instrumented code runs. Without
 * this, a program built with -fsanitize=shadow-call-stack -ffixed-r19 SEGVs at
 * startup, because musl's __libc_start_main / .init_array (compiled into the
 * scs multilib and therefore instrumented) execute their SCS prologues before
 * anything has set r19.
 *
 * Installed as usr/lib/scs/crt1.o; the Hexagon driver selects it when the scs
 * multilib is chosen. Building r19 setup here (rather than in the base crt1.o)
 * keeps the 1 MiB shadow-stack buffer out of non-SCS programs. Setting r19 is
 * harmless for any program -- r19 is callee-saved, so ordinary (non-SCS) code
 * saves/restores it regardless.
 *
 * The _start body mirrors musl's arch/hexagon/crt_arch.h; keep in sync if that
 * changes. Compile WITHOUT -fsanitize=shadow-call-stack (this file must not be
 * instrumented), and with -fPIC so it works for the default (PIE) links.
 */
#include <features.h>

__asm__(
".weak _DYNAMIC \n"
".hidden _DYNAMIC \n"
".text \n"
".global _start \n"
".type _start, %function \n"
"_start: \n"
"       r19 = add(pc,##__scs_shadow_stack@pcrel)\n" /* SCS shadow-stack base */
"       jump 1f\n"
".word  _DYNAMIC - .\n"
"1:     r2 = pc\n"
"       r2 = add(r2, #-4)\n"
"       r1 = memw(r2)\n"
"       r1 = add(r2, r1)\n"
"       r30 = #0\n"
"       r31 = #0\n"
"       r0 = r29\n"
"       r29 = and(r29, #-16)\n"
"       memw(r29+#-8) = r29\n"
"       r29 = add(r29, #-8)\n"
"       call _start_c \n"
".size _start, .-_start\n"
".bss \n"
".global __scs_shadow_stack \n"
".p2align 3 \n"
"__scs_shadow_stack: .space (1<<20) \n" /* 1 MiB = 256K nested frames */
".text \n"
);

int main();
__attribute__((weak)) void _init();
__attribute__((weak)) void _fini();
int __libc_start_main(int (*)(), int, char **, void (*)(), void (*)(),
                      void (*)());

__attribute__((no_sanitize("shadow-call-stack"))) void _start_c(long *p) {
	int argc = p[0];
	char **argv = (void *)(p + 1);
	__libc_start_main(main, argc, argv, _init, _fini, 0);
}
