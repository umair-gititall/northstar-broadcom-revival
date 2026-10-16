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
| `broadcom-wl-buttond` | `/usr/sbin/` | userspace GPIO button/switch daemon; replaces the kernel's `gpio-button-hotplug`, which rejects this board's buttons |
| `broadcom-wl-leds` | `/usr/sbin/` | intelligent front-panel LED controller (kernel triggers only, no userspace loop) |
| `broadcom-wl-leds` (init) / `broadcom-wl-buttond` (init) | `/etc/init.d/` | enable + supervise the two services above |
| `libiwinfo.so.20230701` | `/usr/lib/broadcom-wl/`, symlinked from `/usr/lib/` | iwinfo built with the `wl` backend, for LuCI (see **LuCI and `libiwinfo`**) |

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

### HT/VHT width and channel

`htmode` maps to the driver's bandwidth capability `wl<N>_bw_cap`, which is the
*cumulative* `WLC_BW_CAP_*` mask — 20MHz=0x1, 40MHz=0x3, 80MHz=0x7 — because
wlconf compares it against `WLC_BW_CAP_80MHZ`/`_40MHZ` and only then programs a
wide chanspec. A bare single bit (e.g. 0x4 for 80MHz) fails that test and
silently leaves the AP at 20MHz. For 40MHz the control sideband
(`wl<N>_nctrlsb`) is derived from the band and channel.

There is no usable ACS here, so UCI `channel 'auto'` is resolved to the first
legal channel for the band (as reported by `wl channels`); wlconf's own auto
path applies a 20MHz chanspec and ignores the configured width, whereas a
concrete channel is programmed with the requested width.

### LuCI and `libiwinfo`

LuCI does not talk to the netifd handler directly: `rpcd-mod-luci` describes the
radios by `dlopen()`ing `/usr/lib/libiwinfo.so*` and calling its backend-neutral
API. The stock library is built with the **nl80211** backend only, so on this
cfg80211-less board every call fails and LuCI shows the radios as
"Generic / unknown", with no channel, rate or station list. The package
therefore ships the same iwinfo rebuilt with the Broadcom `wl` backend (plus
`wext`, which `wl` delegates to a few ops) and points the canonical
`/usr/lib/libiwinfo.so.20230701` at it, moving the stock file aside as
`…/broadcom-wl/libiwinfo.so.20230701.stock`; `prerm` puts it back. It cannot be
installed at the canonical path directly — that file belongs to the stock
`libiwinfo` package, and a second owner is an apk file conflict — so it lives in
`/usr/lib/broadcom-wl/` and the init script re-asserts the symlink every boot (§
`bcw_iwinfo_install`).

Three things make that backend usable from LuCI:

- **Section names.** LuCI addresses a radio by its UCI `wifi-device` section
  (`radio0`), not by its netdev, and the driver only knows `wl<N>`. The nl80211
  backend resolves this through its `path` option; here the netifd handler
  records the section → netdev mapping under
  `/var/run/broadcom-wl/<radio>.ifname` (the band → netdev order is PCI probe
  order and must not be assumed), and `wl_resolve()` in `iwinfo_wl.c` consults
  it. Without it every `iwinfo` call addressed at a section — `info`, not just
  `freqlist` — fails.
- **Channel list.** LuCI's frequency widget calls `iwinfo freqlist`; with an
  empty reply it hides its band/channel selectors, and then LuCI drops band,
  channel and htmode when the section is saved (which is what once emptied these
  radios' configs). `wl_get_freqlist()` therefore reports the driver's legal
  channels via `WLC_GET_VALID_CHANNELS` instead of delegating to wext, which
  always came back empty on `wl`. The init script's `config-repair` step heals a
  config that was damaged before the swap.
- **Wide channels.** For a wide channel `WLC_GET_CHANNEL` returns the *center*
  channel, so an 80 MHz AP on 36/80 (center 42) would be reported as channel 42.
  `wl_get_channel()` instead derives the control/primary channel from the
  chanspec's bandwidth and control sideband, matching what mac80211 returns
  (36). LuCI's frequency widget selects its value from the UCI `channel` option
  rather than from this, so the impact is limited to the channel shown in the
  status output, but the value is now correct.

netifd discovers wireless handlers by globbing `/lib/netifd/wireless/*.sh` and
its reader loop does not stop at EOF, so with more than one handler present it
busy-spins at ~100% CPU. Stock ships `mac80211.sh`; the init script moves that
(and any other handler) aside with `broadcom-wl-ctl handler-single`, leaving
only `broadcom.sh`, and `prerm` restores it.

## LEDs and buttons

The front panel is driven entirely from userspace: nothing here touches the
driver, and all the work is done by the kernel's own LED/GPIO subsystems, so
the cost while idle is zero.

### LEDs (`/usr/sbin/broadcom-wl-leds`)

The eight LEDs sit on the `74hc595` shift register behind `gpiochip3`. All of
them use a kernel *trigger* — `netdev`, `usbport`, `default-on` or `timer` — so
the blinking is interrupt/traffic driven and no userspace loop runs:

| LED | trigger | meaning |
|---|---|---|
| `white:power` | `default-on` | solid once both radios are up (ready) |
| `red:power` | `timer` | blinks while a radio is still coming up |
| `blue:wireless` | `netdev (wl0)` | traffic while dual-band |
| `amber:wireless` | `netdev (active radio)` | traffic while single-band |
| `blue:wan` | `netdev (wan)` | traffic while the Internet is up |
| `amber:router` | `default-on` | solid when there is **no** Internet |
| `blue:router` | `default-on` | solid in Router mode (see the Mode switch) |
| `blue:usb` | `usbport` | lit while a USB device is attached |

The mapping is chosen deliberately. Stock firmware names a few LEDs this board
does **not** have — there is no separate `white:internet` and no
`white:movie_engine` (logo) LED. So spec-white-power → `white:power`,
spec-amber-power → `red:power`, spec-white-wireless → `blue:wireless`,
spec-white-internet → `blue:wan`, and the logo/"movie engine" slot maps to the
nearest thing present, `blue:router`. The Internet state is expressed as
`blue:wan` (netdev, on) versus `amber:router` (default-on, off), and the Mode
switch owns `blue:router` alone — nothing else writes it, so the two never
fight.

`broadcom-wl-leds apply` is re-run on every relevant event: radio bring-up
(`bcw_radio_up`), WPA (`bcw_security_start`), and the iface hotplug
(`31-broadcom-wl-leds`). It is fire-and-forget, so radio bring-up never waits
on the LED pass.

### Buttons (`broadcom-wl-buttond` + `/usr/lib/broadcom-wl/buttons/`)

The five controls are described in the DT (`gpio-keys` on `bcma_gpio` lines
11-15, all active-low), but the stock `gpio-button-hotplug` module **refuses
the whole node** because the Mode switch uses `KEY_SETUP` (141), which its
fixed keymap does not support:

```
gpio-keys gpio-keys: does not support key code:141
gpio-keys gpio-keys: probe with driver gpio-keys failed with error -22
```

That single unsupported code kills every button on the board (no `/dev/input`
at all), and the kernel is stock, so it cannot be patched. Instead
`broadcom-wl-buttond` watches the lines from userspace and re-creates procd's
button protocol exactly: it exports each line through sysfs GPIO
(`/sys/class/gpio`), sets it to input with `edge=both`, and `poll()`s its value
file — the same mechanism gpio-keys itself uses. On each edge it runs
`/usr/lib/broadcom-wl/buttons/<name>` (falling back to `/etc/rc.button/`) with
`BUTTON`/`ACTION`/`SEEN`/`TYPE` in the environment.

(The newer GPIO *character* device is deliberately not used: on this kernel the
`bcma_gpio` controller rejects its line requests with `EINVAL`, while sysfs works
and supports edge-triggered poll.)

| button | GPIO | action |
|---|---|---|
| **Reset** | 11 | < 2 s ignored; 2–5 s reboot; > 5 s factory reset (`jffs2reset`) |
| **AOSS/WPS** | 12 | short press toggles both radios; held ≥ 3 s cycles band mode (Dual → 5 GHz → 2.4 GHz → Dual) |
| **USB Eject** | 15 | `sync` + unmount any `/dev/sd*` partitions, blinks `blue:usb`, leaves the `usbport` trigger in charge |
| **Mode** | 13 | Router / AP / WB slider — recolours `blue:router`, logs; by default it does not touch Wi-Fi |
| **AP** | 14 | the slider's second line — keeps the combined state current |

The Mode/AP lines are treated as *switches*: buttond publishes both levels to
`/var/run/broadcom-wl/buttons.state` so the decoder sees the whole slider, and
reports their initial position once at boot. Its behaviour is opt-in: set
`broadcom-wl.mode_switch_action` to `killswitch` (toggles the radios) or
`ap-mode` to act on it, or leave the default `log` to only colour the LED. This
is deliberate — a slider must never be able to cut the LAN bridge out from under
a remote admin.

Button scripts live in `/usr/lib/broadcom-wl/buttons/`, **not** `/etc/rc.button/`:
there `reset`/`rfkill` belong to `base-files` and `wps` to `wifi-scripts`, so
claiming them would make this package uninstallable. buttond searches our
directory first, then falls back to `/etc/rc.button/` for anything we do not
ship (`failsafe`, `power`, `rfkill`, …).

## Installation

### Packages

```sh
apk update
apk add broadcom-wl          # pulls kmod-broadcom-wl + userspace + integration
```

`broadcom-wl` is the userspace and OpenWrt glue; `kmod-broadcom-wl` is the
module. They move together.

Installing the userspace package triggers one automatic reboot: its `postinst`
schedules a reboot once the pair is in place. netifd reads
`/etc/config/wireless` only at startup, before `wl.ko` has claimed the radios,
so without the reboot the wireless daemons come up with the stock no-driver
view and never see the broadcom radios until the next boot. The reboot is
deferred and detached so `apk` finishes and reports success first; wait for the
box to come back up before configuring.

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

## Workarounds and troubleshooting

Every symptom below is something this port hit on real hardware, with the
mechanism behind it. They are collected here so the next person does not have to
rediscover them.

| symptom | cause | fix (in this repo) |
|---|---|---|
| LuCI shows the radios as "Generic / unknown", no channel or stations | stock `libiwinfo` is built with the nl80211 backend only; there is no cfg80211 here | ship the `wl`-backed `libiwinfo` and symlink it over the canonical path (`§ LuCI and libiwinfo`) |
| Wi-Fi password suddenly "wrong" the moment the ISP cable is plugged in | netifd's iface hotplug derives the bridge from `$INTERFACE`, so a WAN flap rebinds or kills `eapd`/`nas` | never derive a bridge from `$INTERFACE`; `net-repair` re-resolves the LAN bridge on every event (`30-broadcom-wl`) |
| `eapd` runs but no handshake ever completes | `eapd` bound its `ETHER_TYPE_BRCM` socket to the wrong bridge (or the bridge was recreated, changing its ifindex) | `net-repair` compares the recorded bridge/ifindex and restarts `eapd`+`nas` when it went stale |
| No buttons work at all (`/dev/input` absent) | `gpio-button-hotplug` rejects the DT node's `KEY_SETUP` (141) and aborts the probe | `broadcom-wl-buttond` watches the lines via sysfs GPIO instead |
| Front-panel LEDs dark / no traffic blink | newer kernels removed the netdev trigger's combined `mode` attribute | write `link`/`tx`/`rx` instead; `broadcom-wl-leds` supports both |
| `wan` and `lan` end up with the same MAC (the box fights itself) | some boards ship both ports factory-identical, so the radios bridge onto the WAN MAC | `mac-guard` bumps the LAN-bridge MAC by a fixed offset (+2, OUI preserved) |
| netifd busy-spins at ~100% CPU | more than one file in `/lib/netifd/wireless/` — netifd's reader loop does not stop at EOF | `handler-single` moves the other handlers aside; `prerm` restores them |
| radio loads but finds no radio, exits silently | the blob matches radios by CFE NVRAM domain (`devpath0`/`devpath1`) against a different `pci_domain_nr()` than the kernel reports | OSL shim adds the right `pcidomain_offset` (`wl_shadow_pci.c`) |
| driver NULL-derefs at boot on `wl_ifnames` | the blob calls `strspn(nvram_get("wl_ifnames"), " ")` with no NULL check | NVRAM keys seeded before control is handed over (`§ PCIe domains and CFE NVRAM`) |
| `iwinfo <dev> info` prints usage (CLI) | the ucode `iwinfo` wrapper shipped by `wifi-scripts` only resolves nl80211 phys | known; LuCI works because `rpcd-mod-iwinfo` links `libiwinfo` directly, not this CLI |

Debugging tools, in rough order of usefulness:

```sh
wldiag wl0              # the driver's own view of a radio
ubus call network.wireless status
logread | grep broadcom-wl
cat /var/run/broadcom-wl/daemons.state   # bridge + ifindex eapd/nas are bound to
cat /var/run/broadcom-wl/buttons.state   # buttond's decoded switch levels
broadcom-wl-ctl net-repair               # re-run the repair pass by hand
```

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

### The wider landscape

The `wl` blob is not the only route to WiFi on this silicon, and it is worth
knowing where it sits:

| approach | works here? | why not |
|---|---|---|
| `b43` | no | AC-PHY support is `depends on BROKEN`; a 4360 will not come up, and 5 GHz drops to 802.11g |
| `brcmfmac` | no | only drives FullMAC parts, not these SoftMAC PCIe radios |
| a custom kernel with `CONFIG_BCMA_HOST_PCI` off | yes, but | it works *because* it never hands the radios to `b43`/`bcma-pci-bridge` in the first place — at the cost of a reflash |
| **this repo** | yes | hosts the closed `wl` on a **stock** kernel by translating, not patching, so no reflash is needed |

On **other Northstar devices** (Netgear R7000, Asus RT-AC68U, Linksys EA6x00,
… — all BCM4708/4709 with BCM4331/4360-class radios) the recipe is identical:
same `wl_apsta.o` interposition, same shadow layer, same netifd/LuCI glue. Only
the device tree, the GPIO line/button map and the LED trigger names differ
(§ LEDs and buttons), and the `pcidomain_offset` may need re-measuring if the
radios sit on different PCIe domains. The WZR-1750DHP is simply the board that
was available first; nothing in the driver path is board-specific.

### A blueprint for non-Northstar Broadcom parts

The Northstar-specific bits are only the SoC glue. For another Broadcom family
(MIPS BCM47xx, or ARM BCM53xx on a different radio set) the same *shape* holds —
you still need a `wl_apsta.o` and its `config_base`, still interpose the imports
and shadow the skb, still seed NVRAM and drive the tools — and only two things
actually move:

1. **The OSL and PCI glue.** `wl_shadow_pci.c` (the `pcidomain_offset`) and the
   `linux_osl` interposition are where the SoC assumptions live. A MIPS target
   needs the same treatment with its own offsets; a different ARM SoC may need a
   different `alloc_netdev`/`netif_rx` shim if the signatures moved.
2. **The device tree and the panel.** Buttons and LEDs are per-board (the line
   numbers, the active levels, the LED names). `broadcom-wl-buttond` already
   keys off a table of GPIO lines, and `broadcom-wl-leds` off LED sysfs names —
   both are meant to be edited per device, not rewritten.

Everything else — `wlconf`, `eapd`, `nas`, `libiwinfo`, the netifd handler — is
driver-ABI-driven and radio-agnostic, so it carries over unchanged.

## Licensing

This repo contains two kinds of material.

The top-level `LICENSE` (MIT) covers this project's **own work**: the translation
layer, the build system, the OpenWrt integration, and the documentation. The
third-party material below keeps its own terms.

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

## Credits

This port stands on other people's work:

- **[tomato64/broadcom-wl](https://github.com/tomato64/broadcom-wl)** — the
  upstream project this repository is derived from. The translation-layer
  approach (objcopy symbol interposition plus the struct-shadow layer) was
  worked out there; this fork retargets it from Tomato64 to **stock OpenWrt** on
  the Buffalo WZR-1750DHP and adds the netifd/LuCI glue and APK packaging.
- **FreshTomato** ([tomato64/freshtomato-arm](https://github.com/tomato64/freshtomato-arm))
  — the source of the `wl_apsta.o` driver object and the prebuilt `wl` tool,
  and of the Broadcom sources and headers vendored under `vendor/`. FreshTomato
  itself descends from **Tomato** (Jonathan Zarate and contributors).
- **Broadcom** — `wl`, the `wl` control tool, and the shared/userspace libraries
  are Broadcom's proprietary work. This repository only repackages and hosts
  them on a newer kernel; it claims no rights to them.
- **[firmadyne](https://github.com/firmadyne/libnvram)** — `vendor/libnvram/` is
  firmadyne's NVRAM-emulation library.
- **[OpenWrt](https://openwrt.org)** — the target platform, whose netifd
  wireless framework the integration plugs into.
- **Linux** — the kernel the 2.6.36-era blob is hosted on.

Questions about attribution — or a takedown request — are welcome as an issue.
