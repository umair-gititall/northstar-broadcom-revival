# broadcom-wl — the wl driver and its userspace, for bcm53xx

Everything the Netgear R7000 (BCM4709A0, two BCM4360 radios) needs to run
WiFi: the proprietary `wl` driver, and the userspace that configures it.

This is the source tree only. Tomato64 consumes it as a Buildroot package; the
`Config.in` and `broadcom-wl.mk` that wrap it live in the tomato64 repo under
`tomato64/package/broadcom-wl/`, and every path named below that is not in this
tree is a path in that repo.

**bcm53xx only.** Every other Tomato64 platform configures WiFi through
mac80211/netifd/hostapd; this one cannot, because these radios have no
open-source driver. `b43`'s AC-PHY support is `depends on BROKEN` and
`brcmfmac` only handles fullmac parts.

## What it builds

| binary | what it is |
|---|---|
| `wl.ko` | FreshTomato's `wl_apsta.o` — a blob compiled against **Linux 2.6.36** — linked against a shadow-struct translation layer so it runs on 6.12 |
| `wlconf` | Broadcom's radio configurator, driven by `wl<N>_*` NVRAM through the driver's private ioctls. `up` and `start` are two different actions and both are needed |
| `eapd` | EAP dispatcher. Owns the raw socket on `ETHER_TYPE_BRCM` (0x886c) and relays to `nas` over UDP on loopback |
| `nas` | WPA authenticator. The 4-way handshake ends in `WLC_SET_KEY`, the driver's own ioctl |
| `wldiag` | Written for this port: asks the driver what it thinks its state is |
| `wl` | FreshTomato's command-line tool, shipped **as their prebuilt uClibc binary** — they have no source for it. `rc` shells out to it for `antdiv`, `txant`, `txpwr1`, `interference`, `ldpc_cap`, `vhtmode` and `vht_features` |
| `uclibc.so` | Not a libc: the small shim that lets that binary run against musl — `__uClibc_main`, and a `__ctype_b_loc` whose class bits are uClibc's |

`libbcmcrypto` is built as a static archive and linked into `nas`; it is not
installed.

## Running FreshTomato's `wl` on musl

`vendor/wl/arm-uclibc/wl` comes out of the same `src-rt-6.x.4708/wl/` tree as
the blob, so its ioctl version matches the driver by construction, and it is
already the right machine: ARM v7-A, soft-float AAPCS, EABI5 — same as
`arm-tomato64-linux-musleabi`.

It also asks for very little. Of its 67 undefined symbols musl already provides
64; `__register_frame_info` and `__deregister_frame_info` are `WEAK UND` and
resolve to 0. That leaves one gap, `__uClibc_main`, filled by `uclibc.so` —
a shim whose own `DT_NEEDED libc.so` pulls musl into the global scope behind
it, so everything else resolves there.

    /lib/ld-uClibc.so.0  ->  symlink to musl's ld-musl-arm.so.1   (its INTERP)
    /lib/uclibc.so       ->  userspace/uclibc-compat              (its DT_NEEDED)

**The DT_NEEDED cannot stay `libc.so.0`.** musl's loader resolves any
`libc.*`, `libpthread.*`, `librt.*`, `libm.*`, `libdl.*`, `libutil.*` or
`libxnet.*` to *itself* and never opens the file (`ldso/dynlink.c`,
`load_library()`), so a shim under that name is unreachable by construction and
the binary dies with `Error relocating: __uClibc_main: symbol not found`. So
the build renames it to `uclibc.so`, which does not even begin with `lib`.

That rename is the only modification to the binary: nine bytes of `.dynstr`,
chosen to be exactly as long as the original so that nothing in the ELF moves —
no new `PT_LOAD`, no relocated `.dynsym`/`.hash`, no rewritten program headers.
`rename-needed.py` does it, resolves the offset through the section header
table (the string also occurs in `.interp`, as the tail of
`/lib/ld-uClibc.so.0`, where it is correct and must not be touched), and
refuses to run if anything about that picture stops holding.

`uclibc_compat.c` carries the disassembly of the binary's `_start` that pins
down `__uClibc_main`'s argument list, and the reason it forwards to musl's own
`__libc_start_main` instead of open-coding the startup.

"Provides" is not the same as "agrees with", and one of those 64 does not:
**`__ctype_b_loc`**. Both libcs hand back a table of per-byte class masks and
the binary has the mask constants compiled into it, but uClibc numbers the
classes `1 << bit` while musl reproduces glibc's `_ISbit`, which swaps the two
halves — space is `0x20` for one and `0x2000` for the other. So `isspace()`,
`isxdigit()` and `isprint()` were false for every byte, and `isdigit()` was
really `isalnum()`. `wl_find()` — the interface search that runs when no `-i`
is given — skips leading whitespace with `isspace()` before splitting a
`/proc/net/dev` line, and the kernel prints those lines with `"%6s: "`, so the
name it looked up kept its padding: `"   wl0"`, `ENODEV`, no interface ever
matched, and `wl ver` answered `wl driver adapter not found` on a working
driver. `uclibc.so` therefore also exports `__ctype_b_loc` with uClibc's
layout; it is ahead of musl in the global symbol scope, and `find_sym2()`
stops at the first match. Nothing else in the process reads that table — musl's
own `is*()` are range tests, and it exports `__ctype_b_loc` only for
glibc-ABI callers like this one.

Only `wl -i <ifname>` was ever exercised before, which is why this went
unseen: `rc` names the interface on every call and that branch skips
`wl_find()` entirely.

One more of the 64 disagrees the same way and is **not** bridged: `fstat`.
The binary reads `st_size` at offset 44, uClibc's non-LFS `struct stat`
position; musl's is the kernel `stat64` layout, where 44 is padding and
`st_size` is at 48. Its one caller is the `dload`/CLM-from-file path, which
therefore sees every file as empty. Nothing in Tomato64 uses it — the driver
carries its own CLM — so it is recorded here rather than shimmed.

## How wl.ko works, briefly

The blob reads and writes kernel structs at **compiled-in 2.6.36 offsets**. It
is never handed a real kernel object; each one is *shadowed*, and translation
happens at the boundary. Interposition is entirely `objcopy --redefine-sym` on
the blob (27 reroutes, in `Makefile`), which rewrites only the blob's
references and leaves the genuine kernel functions callable by the translation
code. Nothing patches the kernel.

`shadow/offsets-2.6.36.h` holds the measured offsets and is committed. The
machinery that *generates* it — a probe built against 2.6.36 kernel headers,
using the kernel's own asm-offsets trick — is not vendored here, because it
needs 26 MB of 2.6.36 headers that this package would otherwise never touch.
It lives in the development repo, along with the full derivation, the hardware
log for every bug found, and the reasoning behind each shadow layer.

`shadow/wlflags` is load-bearing and is not a tuning knob: Broadcom's own
struct layouts (`osl_t`, `si_t`, `sk_buff` under `-DHNDCTF`) depend on those
defines, so a different set describes structs the blob never sees.

## Kernel dependency

`CONFIG_BCMA_HOST_PCI` must stay **off**. bcma's `bcma-pci-bridge` lists
`0x43a0` in its id table and will claim both radios before `wl` sees them. The
Buildroot package declares this in `LINUX_CONFIG_FIXUPS`, and it is already
unset in tomato64's `board/arm/bcm53xx/linux.config`.

## libshared dependency

libshared builds `wlif_utils.o` **only for bcm53xx** — nothing else in Tomato64
had ever used it. `get_wsec()` there is where `nas` gets its entire
per-interface configuration.

`wsec_info_t` inserts a field mid-struct under `TCONFIG_BCMARM`, so a caller
that disagrees with libshared would read every field after `wsec` at the wrong
offset, from a `get_wsec()` that wrote them at the right one, and nothing would
warn. Nothing here passes a flag for it: `package/rc/features` exports
`TCONFIG_BCMARM` and `TCONFIG_RTNPLUS` permanently, `gen_tomato_config.h.sh`
writes them into `tomato_config.h`, and every consumer reaches that through
`shutils.h` → `shared.h` before including `wlif_utils.h`. Keep that include
order and both sides stay in agreement.
