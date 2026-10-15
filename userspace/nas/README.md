# nas + eapd — WPA

Everything up to this point ran on an open network. This is the encryption
half: `nas` is Broadcom's WPA authenticator, and `eapd` is the dispatcher that
gives it something to hear.

**Status: working** (2026-09-06). Both radios advertise WPA2-PSK, clients
associate with a passphrase and pass traffic.

## Why not hostapd

Same reason `iw` was no use for bring-up. This driver is not
cfg80211/mac80211, so hostapd has nothing to drive. The 4-way handshake ends
in `WLC_SET_KEY` — the driver's own ioctl, over the private-ioctl path in the
net_device shadow — and `nas` is the tool that speaks it.

`wlconf` already does its part: it sets `wsec`, `wsec_restrict`, `wpa_auth`
and `eap_restrict` from `wl<N>_akm` and `wl<N>_crypto`. That configures the
radio to *demand* WPA. It does not perform the handshake, so with `wlconf`
alone a client is asked for credentials that nothing on the router will ever
check, and association stalls.

## The three-process shape, and why eapd is not optional

```
   STA  --EAPOL-->  wl driver  --0x886c-->  eapd  --UDP/lo-->  nas
                        ^                                       |
                        +------------- WLC_SET_KEY -------------+
```

`nas` **never reads from the driver**. It opens exactly one receive socket: a
UDP socket on loopback, port `EAPD_WKSP_NAS_UDP_SPORT`. `eapd` is what owns a
`PF_PACKET`/`SOCK_RAW` socket bound to `ETHER_TYPE_BRCM` (**0x886c**), not to
`ETHER_TYPE_802_1X`. The driver encapsulates both its association events and
the STA's EAPOL frames in that Broadcom ethertype and sends them up; `eapd`
unpacks them and relays to `nas`.

**That socket is on the bridge, not on the radio.** This is the single most
surprising thing about eapd and it is worth stating plainly, because getting
it wrong is silent. `eapd_add_interface()` takes each interface it is told
about, calls `get_ifname_by_wlmac()` to find which bridge that radio belongs
to, and stores the *bridge* as `cb->ifname`; `eapd_add_brcm()` then binds one
socket per bridge. So:

- **WPA needs a bridge.** The radios have to be on a bridge (the default
  `br-lan`) for the handshake to have anywhere to happen.
- **`lan_ifnames` must list `wl0`/`wl1` and `lan_ifname` must name the
  bridge**, because that lookup is exactly what `get_ifname_by_wlmac()`
  performs. Naming the radios on eapd's command line does *not* substitute:
  the command line says which radios to care about, nvram says where they
  live. `bcw_security_start()` (in `common.sh`) appends to `lan_ifnames`
  rather than replacing it.

So `nas` started on its own comes up perfectly, reports nothing wrong, and
blocks in `select()` forever having never seen an association. FreshTomato's
`start_nas()` (`router/rc/wnas.c`) launches `eapd` first for this reason, and
`bcw_security_start()` mirrors that order.

## The two bugs it took to get there

Both were invisible — one process died with no output, the other exited with
no output — which is why the instrumentation below exists.

### nas segfaulted instantly: `setitimer(which, NULL, &old)` on musl

`nas_wksp_init()`'s first act is `bcm_timer_module_init()`, which reaches
libshared's `init_event_queue()` in `linux_timer.c`:

```c
setitimer(ITIMER_REAL, &tv, 0);
setitimer(ITIMER_REAL, 0, &tv);   /* read back the granularity */
```

The second call is a *read*, expressed as a `setitimer` with a NULL new value.
glibc and uclibc hand NULL to the kernel, which accepts it. musl does not: when
`sizeof(time_t) > sizeof(long)` — every 32-bit target, bcm53xx included — it
takes a conversion path that dereferences the new value with no NULL check,

```c
time_t is = new->it_interval.tv_sec, vs = new->it_value.tv_sec;
```

and faults at address 0 before any syscall. `getitimer()` is the call that
means "read it back", and that is the fix, guarded `TOMATO64` in
`libshared/shared/linux_timer.c`.

**This had never fired before because `nas` is the only caller of
`bcm_timer_module_init()` anywhere in Tomato64** — nothing else in the tree
touches the timer module. It is also 32-bit-only, so no other Tomato64
platform could have hit it.

`nas` compiles that file in directly rather than taking it from
`libshared.so`, so a correct `nas` does not have to wait for a firmware
rebuild. The libshared fix still matters for anything that uses the timer
module later.

### eapd exited silently: its own error macros are compiled out

`eapd.h` ships

```c
#define EAPD_ERROR(fmt, arg...)
#define EAPD_INFO(fmt, arg...)
```

— not behind `BCMDBG`, not behind `eapd_msg_level`, just empty, in every
Broadcom tree on this machine. So `"Unable to auto config. Quitting..."` and
`"Command line parsing error. Quitting..."` printed nothing and the process
simply vanished. Restored here to honour `eapd_msg_level`, which is what it
exists for, and eapd is now built `-DBCMDBG` — without it the `eapd_dbg` nvram
read is not compiled either, so the level could never be raised. Errors print
by default; `broadcom-wl-ctl nvset eapd_dbg 3` adds the informational trace.

Restoring `EAPD_INFO` exposed two call sites that reference an `eabuf` that
was never declared, because they had never been compiled. Both marked
`WL-SHADOW-PATCH`.

### And a false alarm worth recording

libshared also exports `clock_gettime` (as `__clock_gettime64` under musl's
time64 redirect), overriding libc's, and its body calls `gettimeofday()` —
which musl implements *by calling `clock_gettime`*. That looks like guaranteed
infinite recursion for anything linking libshared. It is not: musl links
`libc.so` with `-Wl,-Bsymbolic-functions`, so its internal call is a direct
`bl` to its own definition and cannot be interposed. Verified by
disassembling `__gettimeofday_time64`. The override is real but harmless.

For this port that 0x886c path is the part worth watching, because it is
receive, and receive is where the `cloned` bug hid for two days after transmit
was declared working. If the handshake never starts, the question to ask first
is whether the 0x886c frames are reaching a packet socket at all — `rx_trace=N`
on the module dumps received frames from the mac header, which is the same
view a `PF_PACKET` socket gets.

## Where the configuration comes from

`nas` reads almost no NVRAM itself — one call, in `nas_safe_get_conf()`. Its
whole per-interface configuration arrives through **`get_wsec()`**, in
libshared's `wlif_utils.c`, which reads:

| variable | used for |
|---|---|
| `wl<N>_akm` | `psk` → WPA, `psk2` → WPA2, both → mixed. Empty means open, and is what made every earlier run an open network |
| `wl<N>_crypto` | `aes` / `tkip` / `tkip+aes` |
| `wl<N>_wpa_psk` | the passphrase |
| `wl<N>_auth_mode` | `radius` selects enterprise; anything else (`none`) is PSK |
| `wl<N>_wpa_gtk_rekey` | group key rotation, seconds |
| `wl<N>_ssid`, `wl<N>_mode`, `wl<N>_infra` | identity, and the authenticator/supplicant role |
| `wl<N>_auth` | 802.11 shared-key auth. **`1` makes eapd skip the interface entirely** |
| `wl<N>_radio`, `wl<N>_bss_enabled` | `0` in either also makes eapd skip it |
| `wl<N>_mfp`, `wl<N>_preauth`, `wl<N>_nas_dbg` | management frame protection, pre-auth, per-interface debug |
| `wl<N>_radius_*`, `wl<N>_net_reauth` | enterprise only; inert while `auth_mode` is `none` |

From the UCI `encryption`/`key` the integration writes `akm`, `crypto`,
`wpa_psk`, `auth` and `auth_mode` (plus `wep`) via `bcw_apply_encryption()`;
`ssid`/`mode`/`radio`/`bss_enabled` come from the other UCI fields
(`bcw_radio_apply()`), and the enterprise-only keys (`wpa_gtk_rekey`, `mfp`,
`preauth`, `radius_*`, `net_reauth`) are left unset, where `get_wsec()` treats
them as off.

## Two missing libshared symbols

`get_wsec()`, `wl_wlif_is_psta()` and `get_ifname_by_wlmac()` all live in
`wlif_utils.c`, which Tomato64 **ships but does not build** — it is not in
libshared's `OBJS`, so the source is in the tree and the symbols are not in
`libshared.so`. Both `nas` and `eapd` need them.

Tomato64's copy is byte-identical to FreshTomato's (as `wlioctl.h` already
turned out to be), so both Makefiles compile *that* file rather than vendoring
a third copy. It needs `-DTCONFIG_RTNPLUS -DTCONFIG_BCMARM`, which is what
`package/rc/features` sets permanently for this tree; without `TCONFIG_RTNPLUS`
the `wl_wlif_is_psta()` definition is not compiled at all. Those two defines
are scoped to that one object file — nothing else in either build sees them.

## Building

```sh
make -C userspace/libbcmcrypto   # static, built from source, not the prebuilts
make -C userspace/eapd
make -C userspace/nas            # builds libbcmcrypto if needed
```

Standalone against Tomato64's already-built `libnvram`/`libshared`, exactly as
`wlconf` is. Both binaries are dynamically linked against `libnvram.so`,
`libshared.so` and `libc.so` and nothing else; every other undefined symbol is
a weak `crtstuff`/ITM one.

Notes on the flags, all in the Makefiles:

- **`-DBCMDBG` is the one addition to FreshTomato's flag set.** Both macros it
  enables are already runtime-gated — `dbg()` on `nas->debug`, which
  `get_wsec()` reads from `wl<N>_nas_dbg`, and `NASDBG()` on `debug_nwksp`,
  which `nas -d` sets — so a default run prints exactly what it printed
  without it. It also compiles in `nas -h` and `eapd`'s usage text, which are
  otherwise absent. It is ABI-safe: the only two `BCMDBG` sites in the headers
  `nas` includes are additive (two unused typedefs in `wlioctl.h`, an `extern`
  declaration in `proto/802.11e.h`) and move no field of any struct handed to
  the driver — which is the check that matters here, given what this project
  spends its time on.
- **libbcmcrypto is built from `bcmcrypto/*.c`, not from
  `router/libbcmcrypto/prebuilt/`.** The prebuilt objects are 2012-toolchain
  uclibc ones; the sources compile clean against Tomato64's musl toolchain.
  Static, because nothing else here links it and a `.a` means one binary to
  copy rather than a library that has to land in `/usr/lib` first.
- **`_arm`, not `_arm_7` / `_arm_714`** — the same reasoning as `wlconf_arm`:
  `common.mak` picks `_arm` for the base 6.x SDK, which is what our blob is
  (6.37.14.126, `src-rt-6.x.4708`). The 7.x variants would give a mismatched
  ioctl ABI.
- **`-DNAS_WKSP_ON_DEMAND`**, FreshTomato's own setting, is why `nas` takes no
  arguments: it builds per-interface state from eapd's events as they arrive
  rather than enumerating at startup.

## Running

Normal operation starts both daemons from the netifd handler, once the radio is
up and bridged: the handler calls `broadcom-wl-ctl security-start <bridge>`,
which seeds `lan_ifname`/`lan_ifnames` and starts `eapd` then `nas` — but only
if some radio actually carries WPA (`bcw_any_wpa()`), so an open config starts
neither. To do it by hand, set the keys `get_wsec()` reads and call it directly:

```sh
broadcom-wl-ctl nvset wl0_akm psk2
broadcom-wl-ctl nvset wl0_crypto aes
broadcom-wl-ctl nvset wl0_wpa_psk 'somepassphrase'
broadcom-wl-ctl security-start br-lan
```

With no `wl<N>_akm` set the network stays open and neither daemon starts — that
is still the baseline to fall back to.

`eapd` is given its interfaces explicitly (`eapd -nas wl0 wl1`) rather than
through its `EAPD_WKSP_AUTO_CONFIG` path, which enumerates `lan_ifnames`. That
is a narrower use of the variable, not an avoidance of it: `lan_ifnames` still
has to contain the radios, because that is how eapd finds their bridge.
`bcw_security_start()` appends to it and leaves the existing entries alone.

Both daemonise with `daemon(1, 1)` *after* initialising, so an init failure is
reported in the foreground by a non-zero exit. `bcw_security_start()` guards
each launch with `pidof` so it never double-starts, and captures each daemon's
output under `/var/run/broadcom-wl/`. `pkill`/`pgrep` are deliberately not used
— the target's busybox has neither applet.

## Turning the logging on

```sh
broadcom-wl-ctl nvset nas_dbg 1        # global: nas's workspace trace (debug_nwksp)
broadcom-wl-ctl nvset wl0_nas_dbg 1    # per interface; read by get_wsec into nas->debug
broadcom-wl-ctl nvset eapd_dbg 3       # eapd: 1 = errors (default), 3 = + interface trace
kill -USR1 $(pidof eapd)               # eapd dumps its interface/socket table
```

`nas_dbg` and `wl<N>_nas_dbg` are different switches: the global one drives
`NASDBG()` in the workspace layer, the per-interface one drives `dbg()` inside
the state machine. Set any of them with `broadcom-wl-ctl nvset <key> <value>`
(e.g. `broadcom-wl-ctl nvset wl0_nas_dbg 1`).

Started by hand, both daemonise with `noclose=1`, so their output stays on the
terminal that launched them; the netifd handler instead redirects each daemon's
output to `/var/run/broadcom-wl/{eapd,nas}.log`.

## When something crashes

There is no gdb, no strace and no core dump on the target, so both binaries
link `../crashinfo.c`: a constructor installs handlers for SIGSEGV/SIGBUS/
SIGILL/SIGFPE/SIGABRT that print the faulting address and the register state
with `write(2)` — no stdio, which is not safe from a fault handler — then
re-raise on the default handler so the exit status still tells the truth.

Both are built `-no-pie` so those addresses are absolute and map straight onto
the symbol table:

```sh
arm-tomato64-linux-musleabi-addr2line -fpe ./nas 0x<pc>
```

## Known, and not fixed

- `wpa.c` draws two `-Warray-bounds` warnings in `wpa_send_mic_failure()`,
  where a 113-byte buffer is overlaid with `eapol_wpa_key_header_t` whose
  trailing `data[1]` overhangs it. It is upstream's code, on the TKIP
  countermeasures path in the **supplicant** role only, so a WPA2/AES AP never
  reaches it. Left alone rather than edited: vendor code here changes only for
  a reason, and `make vendor-diff` exists so that those reasons stay visible.
- WPS is not built. `eapd` still probes `wps_app_enabled()` per interface,
  which returns 0 with no `wps_*` NVRAM set, so nothing tries to start it.
- RADIUS/enterprise is compiled in (`-DNAS_RADIUS`, matching FreshTomato) but
  untested — `auth_mode` stays `none`.
