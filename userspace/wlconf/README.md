# wlconf — configuring the radios

The kernel side is done: both radios attach and both interfaces come up. They
carry no traffic because the radios are unconfigured, and configuring them is
userspace work.

## Why not `iw` / `iwconfig`

This driver is **not** cfg80211 or mac80211. It predates both and exposes its
own private ioctls, which reach it through `ndo_siocdevprivate` in the
net_device shadow. `wlconf` is Broadcom's tool for driving them, from
`wl<N>_*` NVRAM variables. `nas` handles WPA supplicant/authenticator duties
if encryption is wanted later.

## The two NVRAM stores are not a problem

This was the open question, and the answer is that the split is clean:

| store | holds | who reads it |
|---|---|---|
| **MTD NVRAM** | per-radio calibration — `pci/1/1/macaddr`, `devid`, `rpcal*`, `boardflags` | the **kernel driver**, via `bcm47xx_nvram_get_contents()`. Read-only, already working |
| **Tomato64 libnvram** | configuration — `wl0_ssid`, `wl0_channel`, … | `wlconf`, read **and written** |

`wlconf` touches **no** board or calibration keys — verified against its
source: no `boardflags`, no `pci/`, no `sromrev`, no `il0macaddr`. So Tomato64's
libnvram being a separate store from the MTD partition costs nothing. Userspace
never needs the MTD side.

## Which variant

FreshTomato ships three: `wlconf_arm`, `wlconf_arm_7`, `wlconf_arm_714`, and
they differ (3499 / 3870 / 4060 lines). `common.mak` picks by `BCMEX`, which is
`_arm` when neither `CONFIG_BCM7` nor `CONFIG_BCM714` is set — the base 6.x
SDK. That matches our blob (6.37.14.126, `src-rt-6.x.4708`), so **`wlconf_arm`**
is the one vendored here. The others would give a mismatched ioctl ABI.

Reassuringly, Tomato64's `libshared/include/wlioctl.h` is **byte-identical** to
FreshTomato's `src-rt-6.x.4708` copy, so the ioctl ABI already lines up.

## Building

```sh
make -C userspace/wlconf
```

Standalone, against the vendored `libnvram`/`libshared`, rather than through the
OpenWrt package — the per-component Makefiles are for development, and the root
`Makefile` builds and packages everything (see the repository README). Two
gotchas, both handled in the Makefile:

- **Do not pass `shadow/wlflags`.** Those are the *driver's* flags and include
  `-DBCMDRIVER`, which sends the Broadcom headers down their kernel branch
  (`generated/autoconf.h`, `dma_addr_t`, a conflicting `bool` typedef).
  FreshTomato builds `wlconf` with no driver feature flags at all; the ioctl
  structs are the stable ABI and do not depend on them.
- **`-std=gnu11`.** GCC 15 defaults to C23, where `bool` is a keyword, and
  Broadcom's `typedefs.h` typedefs it.

Tomato64 already provided 11 of the 13 headers `wlconf.c` needs. Only
`bcmwifi_channels.h` and `proto/802.1d.h` were missing, and both were already
vendored for the kernel work.

## Running

Normal operation is UCI-driven: `/etc/config/wireless` holds two `wifi-device`
sections of `option type 'broadcom'`, and the netifd handler maps each onto the
`wl<N>_*` keys `wlconf` reads and runs it for you (see the repository README).
What the handler does per radio is, in effect:

1. `broadcom-wl-ctl apply <spec>` — write the `wl<N>_*` keys from a
   shell-sourceable spec it builds from the UCI section;
2. `broadcom-wl-ctl up <unit>` — run `wlconf wl<unit> up` then
   `wlconf wl<unit> start`.

To exercise that by hand, write a spec and run the same two commands:

```sh
cat > /tmp/wl0.spec <<'EOF'
RADIO='radio0'
UNIT='0'
BAND='2g'
CHANNEL='1'
HTMODE='NOHT'
COUNTRY='US'
IFACE_0_SECTION='default_radio0'
IFACE_0_MODE='ap'
IFACE_0_SSID='MyNet'
IFACE_0_ENC='none'
EOF
broadcom-wl-ctl apply /tmp/wl0.spec
broadcom-wl-ctl up 0
```

`wlconf` reads its configuration entirely from the `wl<N>_*` variables in the
firmadyne NVRAM store (`/firmadyne/libnvram`, written through
`broadcom-wl-ctl nvset`). The keys that matter for bring-up — `phytype`,
`nband`, `channel`, `nmode`/`vhtmode`/`bw_cap`, `country_code`, `ssid`,
`akm`/`crypto`/`psk` … — come from the spec, with values chosen to match
FreshTomato; the rest read through `nvram_safe_get()`, where a missing key is
`""` and `atoi("")` is `0`.

The spec above is an **open** network (`ENC='none'`: `akm=""`, `wep=disabled`)
deliberately — fewest moving parts for a first association test. Encryption
needs `nas` and comes after (see `../nas/README.md`).

## `up` is not enough: you also need `start`

This is what kept the radios silent, and it is not obvious from the tool's own
usage line, which advertises only `up|down`.

`main()` dispatches on `argv[2]` to four different functions:

| argument | function | what it does |
|---|---|---|
| `up` | `wlconf()` | the whole configuration pass, ending in `WLC_UP` — and it **disables every BSS config** on the way in and never re-enables them |
| `start` | `wlconf_start()` | enables the BSS configs (the `bss` iovar loop) |
| `down` | `wlconf_down()` | |
| `security` | `wlconf_security()` | |

The bss-enable loop exists **only** in `wlconf_start()`. So `wlconf wl0 up` on
its own leaves the radio up, configured, on the right channel, with the right
SSID — and not beaconing:

```
isup 1   ap 1   radio 0x0 (on)   ssid "Tomato64-24"   chanspec 0x1808
bss[0] 0  <-- BSS DOWN: not beaconing
```

Confirmed by hand: `wldiag wl0 bss 1` performs exactly the set that
`wlconf_start()` would, it returns ok, `bss[0]` reads 1, and the driver logs
`wl0: link up (wl0)`. Nothing was wrong with the ioctl path — the call was
simply never being made.

FreshTomato's `rc` does three steps in this order, in `network.c`:

1. `eval("wlconf", ifname, "up")` — line 433
2. build the LAN bridge and add the wl interfaces to it
3. `eval("wlconf", ifname, "start")` — line 922

`broadcom-wl-ctl up` collapses steps 1 and 3 into one command — it runs `up`
then `start` back to back. Step 2 is netifd's: the handler calls `set_vif()`
for each AP interface and netifd puts them on the bridge named by the section's
`network` (default `br-lan`), once `set_up()` fires.

## Reading wlconf's output

`wlconf` writes an error line for every ioctl the driver rejects and then
carries on, so **its exit status is not evidence that the radio is serving**.
The messages come from libshared's `wl_ioctl` wrapper (`wl_linux.c`), not from
wlconf itself, and the driver collapses every `BCME_*` error except
`BCME_UNSUPPORTED` onto `-EINVAL`. So:

- *"Invalid argument"* = the driver said no.
- *"Not supported"* = the ioctl or iovar does not exist in this build.

Neither means userspace passed something malformed.

The messages seen on the R7000, and what each one is:

| message | verdict |
|---|---|
| `cmd=231: Invalid argument` | `WLC_SET_WET`, called with 0. AP mode, so this asks to turn WET *off* when it is already off. Believed cosmetic — see the caveat below. |
| `cmd=142: Invalid argument` (wl1, twice) | `WLC_SET_BAND` to 2.4 GHz on the 5 GHz radio. **Caused by `wlX_phytype`** — fixed, see below. |
| `WLC_SET_VAR(avg_dma_xfer_rate): Not supported` | iovar absent from this blob. wlconf discards the return value; it does not even check. |
| `cmd=64: Not supported` | `WLC_SET_ANTDIV`. ACPHY has no antenna diversity to set. |
| `WLC_SET_VAR(bsscfg:radio_pwrsave_level): Invalid argument` | The driver advertises the `radio_pwrsave` capability, so wlconf pushes the whole group; level `0` is out of range. FreshTomato's `defaults.c` ships `wl_radio_pwrsave_level=0` too, so **stock hits this identically**. |

Only appears on the second run because the driver's `cap` string differs
between down and up, which is what gates the `radio_pwrsave` block.

The `WLC_SET_WET` verdict is **inference from the call site, not something
read**: no `wlc.c` exists in any tree on this machine — only headers, other
`wlconf` copies, and EasyTomato's `wl/exe/wlu.c`, which is the tool rather than
the driver. The blob is the only copy of that handler. What settles it is
reading the state back:

```sh
./wldiag wl0 ioctl 230     # WLC_GET_WET - expect 0
```

If that reports 0, the rejected write was asking for the value already in
force and nothing was lost. If it reports 1, this is not cosmetic.


### The one that was real: `wlX_phytype`

Every variable the integration writes comes from a FreshTomato default, but
this one is not inert. wlconf uses it to pick the band:

```c
val = str ? WLCONF_STR2PHYTYPE(str[0]) : PHY_TYPE_G;
if (WLCONF_PHYTYPE_11N(val))     /* n, ssn, lcn, ht, ac */
        val = atoi(nvram_get(prefix "nband"));
else
        val = WLCONF_PHYTYPE2BAND(val);   /* 'a' -> 5G, everything else -> 2.4G */
WL_SETINT(name, WLC_SET_BAND, val);
```

FreshTomato's default is `"b"`, which is not in the 11N family, so `wlX_nband`
was being **ignored** and both radios were being forced to 2.4 GHz. wl1 then
failed `WLC_SET_BAND` twice and only landed on 5 GHz through wlconf's "card may
have changed" fallback, which re-reads `WLC_GET_BANDLIST`.

dmesg reports `phy_type 11` (`PHY_TYPE_AC`) for both radios, so the integration
now sets `phytype=v` (`bcw_radio_apply()`). The band choice is then deliberate
rather than salvaged from an error path, and the two `cmd=142` failures go
away.

FreshTomato does not rely on the `defaults.c` value either. Its `rc` overwrites
it at runtime, immediately before calling `wlconf`, from the driver itself
(`network.c`, under `TCONFIG_BCMARM`):

```c
if ((subunit == -1) && !wl_ioctl(ifname, WLC_GET_PHYTYPE, &phytype, sizeof(phytype))) {
        snprintf(buf, sizeof(buf), "%s", WLCONF_PHYTYPE2STR(phytype));
        nvram_set(wl_nvname("phytype", unit, 0), buf);
}
```

`WLCONF_PHYTYPE2STR(11)` is `"v"`, so the hardcoded value here is exactly what
that code would compute on this hardware.

## wldiag

`wlconf` tells you nothing about the result. `../wldiag` asks the driver
directly over the same private-ioctl path — radio up, BSS started, SSID, BSSID,
channel, country, associated stations. The package installs it to `/usr/sbin`:

```sh
wldiag wl0                 # full state dump
```

It also takes single queries, which is how to check anything the dump does not
cover:

```sh
wldiag wl0 ioctl 230       # WLC_GET_WET
wldiag wl0 iovar mbss
```

FreshTomato's own `wl` tool would be the natural thing to use, but the tree
ships it prebuilt against uClibc (`wl/arm-uclibc/wl`) and carries no source for
it, so this covers the subset bring-up needs.

## Packaging

`wlconf.c` is Broadcom's, and its own header declares it *"UNPUBLISHED
PROPRIETARY SOURCE CODE of Broadcom Corporation"*. It is vendored here for the
same reason the other Broadcom sources are (see `vendor/README.md`): nothing
else speaks the driver's private ABI, and the prebuilt `wl` tool ships no source
to adapt.

The split this repo draws is between **source**, which is committed, and the
**binary blobs** (`wl_apsta.o`, the prebuilt `wl`), which are not: `fetch.sh`
retrieves those from the vendor's published tree at a pinned, hash-verified
revision. See the repository README's licensing section.
