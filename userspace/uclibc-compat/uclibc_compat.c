/*
 * uClibc-ABI compatibility shim, so FreshTomato's prebuilt `wl` runs on musl.
 *
 * FreshTomato ships `wl` only as a binary - there is no source for it anywhere
 * in their tree - built against uClibc for arm. It is otherwise a perfect fit
 * for this port: same v7-A, same soft-float AAPCS, same 8-byte alignment as
 * our arm-tomato64-linux-musleabi toolchain, and it comes out of the same
 * src-rt-6.x.4708/wl/ tree as the wl_apsta.o blob we link the driver from, so
 * its ioctl version matches the driver by construction.
 *
 * It also asks for almost nothing. Of its 67 undefined symbols, musl already
 * provides 64. __register_frame_info and __deregister_frame_info are WEAK
 * undefined and resolve to 0 harmlessly. That leaves exactly one gap:
 * __uClibc_main, uClibc's equivalent of __libc_start_main.
 *
 * One of the 64 musl does provide, it provides with the wrong layout:
 * __ctype_b_loc. That one is interposed here too, at the end of this file,
 * along with the failure it caused.
 *
 * So the binary keeps its own code, and the ABI differences are bridged around
 * it:
 *
 *   /lib/ld-uClibc.so.0  ->  symlink to ld-musl-arm.so.1   (its INTERP)
 *   /lib/uclibc.so       ->  this file                     (its DT_NEEDED)
 *
 * The DT_NEEDED cannot stay `libc.so.0`. musl's loader refuses to open any
 * library whose name begins lib + one of "c." "pthread." "rt." "m." "dl."
 * "util." "xnet." - it resolves them to itself, so a file called
 * /lib/libc.so.0 is never even looked at and the binary dies with
 * "Error relocating: __uClibc_main: symbol not found". The name is therefore
 * changed to `uclibc.so`, which is exactly the same nine bytes, so the edit is
 * an overwrite inside .dynstr with nothing moved. rename-needed.py does it and
 * explains why it has to be section-aware.
 *
 * This shim's own DT_NEEDED libc.so pulls musl into the global scope, where
 * the other 64 symbols resolve.
 *
 * The argument list below is not guessed. Disassembling the binary's _start
 * (entry 0x8fd4) shows it verbatim:
 *
 *	mov  fp, #0
 *	mov  lr, #0
 *	pop  {r1}		@ r1 = argc
 *	mov  r2, sp		@ r2 = argv
 *	push {r2}		@ stack[2] = stack_end
 *	push {r0}		@ stack[1] = rtld_fini (r0 from the loader)
 *	ldr  ip, =0x00045c08	@ _fini
 *	push {ip}		@ stack[0] = app_fini
 *	ldr  r0, =0x0003e450	@ main
 *	ldr  r3, =0x00008c98	@ _init
 *	b    __uClibc_main
 *
 * Forwarding to musl's own __libc_start_main rather than open-coding the
 * startup is deliberate: that is the entry musl's crt1 would have used, so
 * __init_libc, the stack guard, DT_INIT and DT_INIT_ARRAY all happen exactly
 * as they do for a native musl binary, and nothing here has to track musl
 * internals.
 */

#include <ctype.h>

extern int __libc_start_main(int (*main)(int, char **, char **),
                             int argc, char **argv,
                             void (*init)(void), void (*fini)(void),
                             void (*ldso_fini)(void));

void __uClibc_main(int (*main)(int, char **, char **), int argc, char **argv,
                   void (*app_init)(void), void (*app_fini)(void),
                   void (*rtld_fini)(void), void *stack_end);

void __uClibc_main(int (*main)(int, char **, char **), int argc, char **argv,
                   void (*app_init)(void), void (*app_fini)(void),
                   void (*rtld_fini)(void), void *stack_end)
{
	(void)stack_end;	/* musl derives its own from the initial sp */

	__libc_start_main(main, argc, argv, app_init, app_fini, rtld_fini);

	__builtin_unreachable();
}

/*
 * __ctype_b_loc - uClibc's class-bit layout, not musl's.
 *
 * This is the one symbol `wl` imports where musl HAS a definition and the
 * definition is wrong for this caller. Both libcs export __ctype_b_loc() as a
 * pointer to a table of per-byte class masks, and the binary inlines its
 * isspace()/isdigit()/isxdigit()/isprint()/islower() as a halfword load from
 * that table plus a bit test - so the mask constants are compiled into the
 * binary and the table has to agree with them. It does not:
 *
 *	class     uClibc (1 << bit)      musl/glibc (_ISbit)
 *	upper     0x0001                 0x0100
 *	lower     0x0002                 0x0200
 *	alpha     0x0004                 0x0400
 *	digit     0x0008                 0x0800
 *	xdigit    0x0010                 0x1000
 *	space     0x0020                 0x2000
 *	print     0x0040                 0x4000
 *	graph     0x0080                 0x8000
 *	blank     0x0100                 0x0001
 *	cntrl     0x0200                 0x0002
 *	punct     0x0400                 0x0004
 *	alnum     0x0800                 0x0008
 *
 * glibc's _ISbit(bit) is ((bit) < 8 ? (1 << (bit)) << 8 : (1 << (bit)) >> 8)
 * and musl reproduces it byte-for-byte (src/ctype/__ctype_b_loc.c swaps each
 * entry on little-endian for exactly that reason). uClibc uses a plain
 * 1 << bit. So every test the binary makes reads a bit that means something
 * else, or nothing at all: of the five masks it uses, 0x08 lands on musl's
 * alnum, 0x02 on cntrl, and 0x10 / 0x20 / 0x40 are bits musl never sets in any
 * entry, so isxdigit(), isspace() and isprint() are false for every byte.
 *
 * isspace() is the one that is fatal. wl_find() - what runs when no -i is
 * given - reads /proc/net/dev and does
 *
 *	while (isspace(*c)) c++;
 *	name = strsep(&c, ":");
 *
 * and the kernel prints those lines with "%6s: " (net/core/net-procfs.c), so
 * every name is right-aligned in six columns. With the skip a no-op the name
 * keeps its padding, SIOCETHTOOL on "   wl0" fails with ENODEV, no interface
 * ever matches, and the tool exits with
 *
 *	wl: wl driver adapter not found
 *
 * even though the driver is up and `wl -i wl0` on the same interface works.
 * That is also why nothing else noticed: rc only ever calls `wl -i <ifname>`,
 * which takes the branch that skips wl_find() entirely.
 *
 * Interposing works because of the load order the shim already relies on: the
 * global symbol scope is built in head->next order (musl ldso/dynlink.c,
 * __dls3), so it is `wl`, then uclibc.so, then musl - which enters the chain
 * only when this file's own DT_NEEDED libc.so resolves to the loader itself.
 * find_sym2() returns the first match and stops, so this definition is the one
 * the binary's relocations get. Nothing else in the process reads the table:
 * musl's own is*() are range tests, not table lookups, and musl exports
 * __ctype_b_loc purely for glibc-ABI callers like this one.
 *
 * The table is filled from musl's own classifiers rather than transcribed, so
 * it cannot drift from what the C locale actually says. Indices -128..-1 stay
 * zero: the callers here index with an unsigned char, and EOF must read as
 * unclassified. Bytes >= 0x80 are unclassified in the C locale, which is what
 * musl's own table says too.
 */
#define UC_ISupper	(1 << 0)
#define UC_ISlower	(1 << 1)
#define UC_ISalpha	(1 << 2)
#define UC_ISdigit	(1 << 3)
#define UC_ISxdigit	(1 << 4)
#define UC_ISspace	(1 << 5)
#define UC_ISprint	(1 << 6)
#define UC_ISgraph	(1 << 7)
#define UC_ISblank	(1 << 8)
#define UC_IScntrl	(1 << 9)
#define UC_ISpunct	(1 << 10)
#define UC_ISalnum	(1 << 11)

static unsigned short uc_ctype_b[128 + 256];
static const unsigned short *uc_ctype_b_ptr = uc_ctype_b + 128;

const unsigned short **__ctype_b_loc(void);

const unsigned short **__ctype_b_loc(void)
{
	return &uc_ctype_b_ptr;
}

/*
 * A constructor, so the table is built before the binary's main() - musl runs
 * a dependency's DT_INIT_ARRAY ahead of the app's. Should that ever stop being
 * true, an unfilled table classifies nothing, which is what the unpatched
 * binary already did.
 */
__attribute__((constructor))
static void uc_ctype_init(void)
{
	int c;

	for (c = 0; c < 256; c++) {
		unsigned short m = 0;

		if (isupper(c))		m |= UC_ISupper;
		if (islower(c))		m |= UC_ISlower;
		if (isalpha(c))		m |= UC_ISalpha;
		if (isdigit(c))		m |= UC_ISdigit;
		if (isxdigit(c))	m |= UC_ISxdigit;
		if (isspace(c))		m |= UC_ISspace;
		if (isprint(c))		m |= UC_ISprint;
		if (isgraph(c))		m |= UC_ISgraph;
		if (isblank(c))		m |= UC_ISblank;
		if (iscntrl(c))		m |= UC_IScntrl;
		if (ispunct(c))		m |= UC_ISpunct;
		if (isalnum(c))		m |= UC_ISalnum;

		uc_ctype_b[128 + c] = m;
	}
}
