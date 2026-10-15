# broadcom-wl

Broadcom's proprietary `wl` WiFi driver, and the userspace that configures it,
running on a **stock, unmodified** OpenWrt kernel (25.12 `bcm53xx/generic`,
Linux 6.12) — no reflash, no custom kernel, no kernel patches.

The driver is FreshTomato's `wl_apsta.o` — a binary blob compiled against Linux
**2.6.36** — hosted on 6.12 by a translation layer that interposes on the
symbols it imports and presents it the struct layouts it was built against.
Everything outside the blob (the translation layer, the userspace tools, the
libraries) is built from source in this tree.

## Why this exists

On BCM4708/BCM4709 "Northstar" routers the WiFi is two PCIe radios
(BCM4331/BCM4360). There is **no open-source driver** for them:

- `b43`'s AC-PHY support is `depends on BROKEN` — it cannot bring up a 4360,
  and on this hardware 5 GHz either does not appear or falls back to 802.11g
  rates.
- `brcmfmac` only drives FullMAC parts, not these SoftMAC PCIe radios.

Vendor firmware (Tomato, DD-WRT, stock) uses Broadcom's closed `wl` driver,
which is why AC works there and not under stock OpenWrt. This repo packages
that driver for OpenWrt's kernel.

## Supported hardware

| device | SoC | radios |
|---|---|---|
| **Buffalo WZR-1750DHP** | BCM4708A0 | BCM4331 (2.4 GHz) + BCM4360 (5 GHz) |
| Netgear R7000 | BCM4709A0 | 2× BCM4360 |
| generally | BCM4708/4709 | BCM4331/BCM4360-class PCIe radios |

Target: OpenWrt 25.12.x, `bcm53xx/generic`, Linux 6.12.x. The blob is SMP,
ARMv7-A, Thumb-2, soft-float EABI, GCC 4.5.3, driver version
`6.37.14.126 (r561982)`.

## What it builds

| artifact | install | what it is |
|---|---|---|
| `wl.ko` | `/lib/modules/$(uname -r)/` | the blob linked through the translation layer |
| `wlconf` | `/usr/sbin/` | Broadcom's radio configurator, driven by `wl<N>_*` NVRAM over the driver's private ioctls. `up` and `start` are two separate actions and both are needed |
| `wldiag` | `/usr/sbin/` | written for this port: asks the driver what it thinks its state is |
| `eapd` | `/usr/sbin/` | EAP dispatcher. Owns the raw socket on `ETHER_TYPE_BRCM` (`0x886c`) and relays to `nas` over UDP on loopback |
| `nas` | `/usr/sbin/` | WPA authenticator. The 4-way handshake ends in `WLC_SET_KEY`, the driver's own ioctl |
| `wl` | `/usr/sbin/` | FreshTomato's command-line tool, shipped as their **prebuilt uClibc binary** — they publish no source |
| `uclibc.so` | `/lib/` | not a libc: the shim that lets that binary run against musl |
| `libnvram.so`, `libshared.so` | `/usr/lib/` | the NVRAM store the tools share, and Broadcom's shared helpers (`get_wsec()`, `get_ifname_by_wlmac()`, …) |

`libbcmcrypto` is a static archive linked into `nas`; it is not installed.

## Architecture

### Interposition, not patching

The blob is compiled with hard-coded addresses of kernel structs and calls
kernel APIs that no longer exist under those names. Rather than patch either the
blob or the kernel, the build rewrites the blob's *imports* with
`objcopy --redefine-sym` (26 reroutes, listed in `Makefile.standalone`):

```
init_module      -> wl_blob_init_module        (the shim owns module entry)
alloc_netdev_mq  -> wl_shim_alloc_netdev_mq    (shadow net_device)
dev_alloc_skb    -> wl_shim_dev_alloc_skb      (shadow sk_buff)
outer_cache      -> wl_shim_outer_cache        (2.6.36 symbol removed)
...
```

`--redefine-sym` only changes the blob's references. The real kernel function
stays callable by the translation code, which sits between the two. `__param` is
removed rather than translated: the blob ships a 2.6.36-laid-out
`struct kernel_param` array and 6.12 changed the layout, so the loader walked it
wrong. Its eight tunables fall back to compiled-in defaults; the one that must
be settable, `intf_name`, is re-exposed as a module parameter of this port.

Nothing patches the kernel. That is what makes the stock-kernel goal reachable.

### The `sk_buff` shadow

The central problem is `sk_buff`. Its layout changed substantially between
2.6.36 and 6.12 (CTF inserts fields immediately after `->cb`, shifting
everything later). The blob does not call `skb_put()`/`PKTDATA()` — it inlines
them, addressing buffers at 2.6.36 offsets.

So every skb the driver touches is *shadowed*: the real 6.12 skb is allocated
normally, and a parallel struct of the 2.6.36 shape travels beside it.
`shadow/bcm-override/linux_osl.h` overrides `PKTDATA`/`PKTLEN`/friends to
address the shadow, and the alloc/free/rx/tx entry points
(`dev_alloc_skb`, `netif_rx`, `eth_type_trans`, `skb_put`, …) are interposed to
attach and detach it. The interposition covers the whole hot path, so the blob
never sees a real skb. `shadow/offsets-2.6.36.h` holds the measured offsets;
`shadow/README.md` has the derivation.

The wire format itself is unchanged — the shadowing is a presentation detail,
not a translation of packets.

### PCIe domains and CFE NVRAM

The two radios sit on separate PCIe bridges. The blob asks the OSL for each
radio's bus/domain and matches it against NVRAM. On the WZR-1750DHP the CFE
NVRAM carries:

```
devpath0=pci/1/1/      # 2.4 GHz radio
devpath1=pci/2/1/      # 5 GHz radio
```

The kernel's `pci_domain_nr()` numbers these differently from what the blob
expects, so the OSL shim (`wl_shadow_pci.c`) adds the right `pcidomain_offset`.
Getting this wrong makes the driver a no-op — it loads, finds no matching radio,
and exits silently.

NVRAM itself is provided by a vendored libnvram (`/firmadyne/libnvram/`, one
file per key, overlaying the CFE values). The port seeds the keys the blob reads
before it is handed control — including `wl_ifnames`, whose absence was an
unconditional NULL dereference in the blob's `.init.text` (it does
`strspn(nvram_get("wl_ifnames"), " ")` with no NULL check). See
`wl_shadow_nvram.c`.

### Interface naming

The blob's primary interfaces are template-named from its `intf_name` parameter
(default `eth%d`), with virtual BSS renamed to `wl0.1` etc. Without
`intf_name=wl%d` the interfaces register as `eth0`/`eth1` and `wlconf`/`nas`/
`eapd` never find them. The init script sets it on the `insmod` line.

### `/etc/config/wireless` integration

A netifd wireless handler (`files/lib/netifd/wireless/broadcom.sh`, ucode)
registers a new device type `broadcom`, so LuCI configures these radios exactly
like `mac80211` ones: SSID, channel/width, country, encryption, and per-radio
enable. It translates UCI into the `wl<N>_*` NVRAM keys the tools read, drives
`wlconf`/`eapd`/`nas`, and reports the interfaces back to netifd. The init
script (`/etc/init.d/broadcom-wl`) owns module load and the radio unbind.

## Installation

### Packages

```sh
apk update
apk add broadcom-wl          # pulls kmod-broadcom-wl + userspace + integration
```

`broadcom-wl` is the userspace and OpenWrt glue; `kmod-broadcom-wl` is the
module. They move together.

### The stock-kernel radio handover

Stock OpenWrt builds bcma with `CONFIG_BCMA_HOST_PCI=y`, so the built-in
`bcma-pci-bridge` driver claims the radios (`14e4:4331`, `14e4:43a0`) at boot,
and `b43` attaches. To hand them to `wl`, the init script:

1. `rmmod b43` (its `remove()` cascades through the bcma bus),
2. for each bound BDF, `echo <BDF> > /sys/bus/pci/drivers/bcma-pci-bridge/unbind`,
3. `insmod /lib/modules/$(uname -r)/wl.ko intf_name=wl%d`.

Registering `wl`'s own PCI driver re-attaches the now-free radios. This is the
whole reason no reflash is needed — the clean alternative is a custom kernel
with `CONFIG_BCMA_HOST_PCI` off, which this port does not require.

### Configuring

After install, `/etc/config/wireless` gets two `wifi-device` sections of
`option type 'broadcom'` (radio0 = 2.4 GHz, radio1 = 5 GHz) and matching
`wifi-iface` sections. They start disabled; enable and edit in LuCI, or:

```sh
uci set wireless.radio1.disabled=0
uci set wireless.default_radio1.ssid='my-net'
uci set wireless.default_radio1.encryption='psk2'
uci set wireless.default_radio1.key='secret'
uci commit wireless && wifi reload
```

`wifi` starts the netifd handler, which applies the config and starts the
security daemons. `wldiag` prints the driver's view if anything looks wrong:

```sh
wldiag wl0            # full state dump
wldiag wl1 iovar mbss # one query
```

## Running the prebuilt `wl` on musl

`vendor/wl/arm-uclibc/wl` is already the right machine (ARM v7-A, soft-float
EABI) and its ioctl version matches the driver by construction. It needs two
things musl will not provide:

```
/lib/ld-uClibc.so.0  ->  symlink to musl's ld-musl-arm.so.1   (its INTERP)
/lib/uclibc.so       ->  the shim                              (its DT_NEEDED)
```

`wl` shipped with `DT_NEEDED libc.so.0`, and musl resolves any `libc.*` name to
*itself* and never opens the file — so a shim under that name is unreachable by
construction. The build renames it to `uclibc.so` (nine bytes of `.dynstr`,
nothing else moved — `rename-needed.py`). The shim provides `__uClibc_main` and
a `__ctype_b_loc` whose class bits are uClibc's (musl reproduces glibc's, which
swaps the two halves, so without it `wl_find()`'s `isspace()` never matches and
`wl ver` reports "adapter not found" on a working driver). `uclibc_compat.c`
documents both. The package symlinks `ld-uClibc.so.0` in `postinst`.

## Generalizing to another router

The same recipe applies to any BCM4708/4709-class SoftMAC radio, provided you
can obtain a matching blob:

1. **Get the blob.** A `wl_apsta.o` relocatable object (not a linked `wl.ko` —
   the interposition needs its relocation tables) built for the radio, plus its
   2.6.36 `config_base` for the ABI reference. `fetch.sh` is the example: it
   pulls this one from FreshTomato's published tree at a pinned, hash-verified
   revision.
2. **Interpose.** List the symbols the blob imports (`nm -u`), compare against
   the target kernel's exports, and `--redefine-sym` the ones whose ABI moved.
   `Makefile.standalone` is the template.
3. **Measure the shadowed structs.** Build the kernel's `asm-offsets` trick
   against the blob's `config_base` to recover the offset it baked in, and
   diff against the running kernel's. `shadow/` holds the machinery.
4. **Provide an OSL.** The blob expects a Broadcom OSL; `linux_osl.c` plus the
   header overrides in `shadow/bcm-override/` supply it for this radio.
5. **Seed NVRAM.** Supply the keys the blob reads unguarded (`wl_ifnames`, the
   `devpath0`/`devpath1` domain mapping, per-radio defaults) before handing it
   control.

`userspace/` needs no per-radio changes — the ioctl ABI is the driver's, not the
radio's.

## Licensing

This repo contains two kinds of material.

**Source is committed.** The translation layer, the build system, the userspace
tools, and the vendored Broadcom sources and headers (see `vendor/README.md`).
Several of these files are Broadcom proprietary source, carrying their original
"UNPUBLISHED PROPRIETARY SOURCE CODE" headers; they are vendored because nothing
else speaks the driver's private ABI.

**Binary blobs are not.** Broadcom's closed driver object (`wl_apsta.o`,
`.modinfo license=Proprietary`) and its prebuilt `wl` tool ship no source and
are not redistributed here. Run **`./fetch.sh`** once to retrieve them from the
vendor's published source at a pinned, sha256-verified revision:

```sh
./fetch.sh                          # download
./fetch.sh /path/to/freshtomato-arm # or copy from a local checkout
```

The resulting `wl.ko` taints the kernel, which is correct and expected.

## Building from source

The normal path is the OpenWrt package (root `Makefile`). To build by hand
against a kernel tree:

```sh
./fetch.sh
make -f Makefile.standalone OBJCOPY=<cross-objcopy> wl_apsta.o_shipped
make -C <linux-6.12-tree> M=$PWD ARCH=arm CROSS_COMPILE=<abs-path>- modules
make -f Makefile.standalone userspace CROSS_COMPILE=<abs-path>-
```

`CROSS_COMPILE` must be absolute — the kernel `cd`s during the build.
