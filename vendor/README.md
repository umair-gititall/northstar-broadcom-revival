# vendor/ — third-party material

The materials here split in two.

**Sources are committed**, so the repo builds without a FreshTomato checkout:
Broadcom's shared C, its headers, the 2.6.36 kernel reference tree, and the
build-tuning config. See the table below.

**The binary blobs are not.** Broadcom's closed driver object
(`wl/linux/wl_apsta.o`) and its prebuilt uClibc `wl` tool (`wl/arm-uclibc/wl`)
ship no source and this repo does not redistribute them. They are fetched
instead:

```sh
./fetch.sh                      # from the vendor's published source, pinned
./fetch.sh /path/to/freshtomato-arm   # ...or from a local checkout
```

`fetch.sh` pins the source to FreshTomato ARM commit
`2b34e8520426d86377b51a9df465f10737ed49f9` and verifies each file's sha256, so a
build gets either the exact bytes this port was developed against or a loud
failure. The two files and their hashes:

| path | sha256 |
|---|---|
| `wl/linux/wl_apsta.o` | `247bafff4856a1e571d91364b88477ad93099356e549218419d87a95f01ef98e` |
| `wl/arm-uclibc/wl` | `d10a057feda563300b49e185ed627e0419e432febbbe23e2a25929246da0f519` |

Provenance: FreshTomato ARM (`tomato64/freshtomato-arm`),
`release/src-rt-6.x.4708/`.

## What is committed

| path | source | why it's here |
|---|---|---|
| `wl/config/` | `wl/config/` | `wltunable_*.h` build-tuning headers |
| `shared/` | `shared/` | Broadcom's Tier-1 sources — 48 `.c` providing the 176 `si_*`/`osl_*`/`bcm_*`/`pktq_*` symbols the blob imports. Replaces the weak stubs as the port matures |
| `include/` | `include/` | Broadcom headers, 100 `.h`. `linux_osl.h:413-414` is the `PKTDATA`/`PKTLEN` evidence |
| `linux-2.6.36/config_base` | `linux/linux-2.6.36/` | **the ABI reference.** 2.6.36.4, ARM, `SMP=y`, `NET_NS=y`, `NF_CONNTRACK=y`, `NET_SCHED=y`, `NET_CLS_ACT=y`, `IPV6=y` — all of which move `sk_buff`/`net_device` fields |
| `linux-2.6.36/include/`, `linux-2.6.36/arch/arm/include/` | same | 2.6.36 kernel headers, for deriving the struct offsets the blob has baked in. 26 MB of the 475 MB tree — only what the offsets probe needs |

## What is fetched, not committed

| path | why it cannot be rebuilt |
|---|---|
| `wl/linux/wl_apsta.o` | **the blob** — a 2.6.36-era ARMv7-A relocatable object (4.8 MB, SMP, Thumb-2, soft-float EABI, 8-byte align). The port rewrites its relocations with objcopy; that requires the unlinked object, which cannot be recovered from a linked `wl.ko` |
| `wl/arm-uclibc/wl` | Broadcom's prebuilt `wl` control tool (uClibc ARM). Talks to the driver's private ioctls |

The unused uniprocessor build (`wl/up/wl_apsta.o`) is deliberately **not**
fetched — the WZR-1750DHP's BCM4708 is dual-core, and the SMP object is the one
that matters.

## What is neither here nor needed

`wl/sysdeps/` (25 MB of per-device CLM regulatory data) is **not needed**. The
blob defines `clm_data`, `clm_limits`, `clm_country_channels` and friends itself
— CLM is self-contained inside it, and imports nothing.

## Why config_base matters

Struct layout is config-dependent, so "2.6.36 offsets" is meaningless without
the config. FreshTomato ships a *working* combination of this config and this
blob, so this config is by definition ABI-compatible with it. That makes it the
authoritative reference for the shadow layer.

## Toolchain the blob was built with

`.comment` says **GCC 4.5.3 (Buildroot 2012.02)**. So `__GNUC__ == 4`, which is
why the 2.6.36 headers want `linux/compiler-gcc4.h` — relevant when compiling
them with a modern GCC. See `shadow/README.md`.
