#!/bin/sh
#
# broadcom-wl userspace glue.
#
# This is the single place that knows the three things the rest of the
# integration (the netifd handler, the init script, the hotplug hook) should
# not have to:
#
#   1. where the userspace NVRAM lives and how to write it;
#   2. how OpenWrt's /etc/config/wireless maps onto the wl<N>_* variables that
#      wlconf, nas and eapd read;
#   3. how to bring a radio up with the driver's private ioctls.
#
# There is no cfg80211/mac80211 here. The driver is Broadcom's `wl` blob, so
# `iw`, `iwconfig` and hostapd have nothing to drive: configuration goes
# through wlconf (an ioctl pass driven entirely by wl<N>_* NVRAM), and WPA goes
# through nas/eapd. See README.md and userspace/{wlconf,nas}/README.md.
#
# The wl<N>_* variables do NOT live in the board's CFE NVRAM partition. The
# kernel driver reads that partition itself (via bcm47xx_nvram_get_contents())
# for calibration only; the configuration half lives in the firmadyne-derived
# libnvram that wlconf/nas/eapd link against. Every write below lands in that
# store, not in flash.

NVRAM_DIR="${NVRAM_DIR:-/firmadyne/libnvram}"
NVRAM_OVERRIDE_DIR="${NVRAM_OVERRIDE_DIR:-/firmadyne/libnvram.override}"
BCW_RUNDIR="${BCW_RUNDIR:-/var/run/broadcom-wl}"

# ---------------------------------------------------------------------------
# NVRAM store
# ---------------------------------------------------------------------------
#
# libnvram's nvram_get() reads one file per key out of NVRAM_DIR, and its first
# call in any process mounts a fresh tmpfs there and then copies
# NVRAM_OVERRIDE_DIR/* on top (nvram_set_default_image()). So a value has to be
# written to both: NVRAM_DIR for a store that is already mounted (live
# reconfiguration, which is the common case), and NVRAM_OVERRIDE_DIR for the
# very first process that mounts it (early boot). Writing both is idempotent.

bcw_nvset() {
	_k="$1"; shift
	_v="$*"
	mkdir -p "$NVRAM_DIR" "$NVRAM_OVERRIDE_DIR"
	printf '%s' "$_v" > "$NVRAM_DIR/$_k"
	printf '%s' "$_v" > "$NVRAM_OVERRIDE_DIR/$_k"
}

bcw_nvget() {
	[ -f "$NVRAM_DIR/$1" ] && cat "$NVRAM_DIR/$1"
}

# ---------------------------------------------------------------------------
# Band -> netdev
# ---------------------------------------------------------------------------
#
# With intf_name=wl%d the driver names the two radios' primary netdevs wl0 and
# wl1 in PCI probe order, and that order is *not* the band order. On the
# WZR-1750DHP the 5GHz BCM4360 enumerates before the 2.4GHz BCM4331, so wl0 is
# the 5GHz radio and wl1 is 2.4GHz. LuCI addresses radios by band (option band
# '2g'/'5g'), so the name has to be resolved, not assumed.
#
# The live netdev is authoritative: the driver points
# /sys/class/net/wlN/device at the PCI function, and that function's `device`
# file is the chip id the driver matched. Detection needs the module loaded, so
# a small board default covers the window before insmod runs.

bcw_pciid_to_band() {
	case "$1" in
	0x4331|0x4332)               echo 2g ;;   # BCM4331 2.4GHz 11n
	0x4352|0x4360|0x43a0|0x43b1) echo 5g ;;   # BCM435x/4360/43a0 5GHz 11ac
	*)                           echo "" ;;
	esac
}

# Band carried by a live wlN netdev; empty if it is not a primary wl iface.
bcw_iface_band() {
	_d="/sys/class/net/$1/device"
	[ -e "$_d/device" ] || return 0
	bcw_pciid_to_band "$(cat "$_d/device" 2>/dev/null)"
}

# Resolve a UCI band to the wl<N> netdev that actually carries it.
bcw_band_to_ifname() {
	case "$1" in
	2g|11b|11g|b|g) _want=2g ;;
	5g|11a|a)       _want=5g ;;
	*)              echo ""; return 0 ;;
	esac
	# 1. A live radio whose chip id matches wins.
	for _if in $(bcw_all_wl_ifaces); do
		[ "$(bcw_iface_band "$_if")" = "$_want" ] && { echo "$_if"; return 0; }
	done
	# 2. Module not up yet: fall back to the WZR-1750DHP probe order.
	case "$_want" in
	2g) echo wl1 ;;
	5g) echo wl0 ;;
	esac
}

# wlconf takes the OS netdev name (wl0/wl1). The unit and the name are the
# same here because the module is loaded with intf_name=wl%d.
bcw_unit_to_ifname() {
	echo "wl$1"
}

# ---------------------------------------------------------------------------
# htmode -> Broadcom width settings
# ---------------------------------------------------------------------------
#
# wlconf builds the chanspec from wl<N>_channel plus wl<N>_nmode / _vhtmode /
# _bw_cap / _nctrlsb (wlconf.c, the WLCONF_PHYTYPE_11N branch around line 2327).
# bw_cap is the *cumulative* WLC_BW_CAP_* mask, not a single bit: wlconf
# compares it against WLC_BW_CAP_80MHZ (0x7) and only then picks the wide
# chanspec, so a bare 0x4 falls back to 20MHz. 20MHz=0x1, 40MHz=0x3, 80MHz=0x7
# (20|40|80).

bcw_apply_htmode() {
	_unit="$1"; _htmode="$2"; _band="$3"; _channel="$4"
	_nmode=1; _vht=0; _bwcap=1; _width=20; _ctrlsb=""

	case "$_htmode" in
	NOHT|"") _nmode=0; _bwcap=1;  _width=20 ;;
	HT20)    _nmode=1; _bwcap=1;  _width=20 ;;
	HT40|HT40+|HT40-) _nmode=1; _bwcap=3; _width=40 ;;
	VHT20)   _nmode=1; _vht=1; _bwcap=1;  _width=20 ;;
	VHT40|HT40B) _nmode=1; _vht=1; _bwcap=3; _width=40 ;;
	VHT80)   _nmode=1; _vht=1; _bwcap=7;  _width=80 ;;
	VHT160)  _nmode=1; _vht=1; _bwcap=15; _width=160 ;;
	esac

	# 40MHz needs a control sideband. HT40+/- spells it out; bare HT40/VHT40
	# derives it the way wlconf's own fallback does.
	if [ "$_width" = 40 ]; then
		case "$_htmode" in
		HT40+) _ctrlsb="upper" ;;
		HT40-) _ctrlsb="lower" ;;
		*)
			if [ "$_band" = 2g ]; then
				[ "$_channel" -lt 7 ] 2>/dev/null && _ctrlsb="lower" || _ctrlsb="upper"
			else
				# 5GHz: block start (36,44,..) -> lower, block end (40,48,..) -> upper.
				[ $(( _channel / 4 % 2 )) = 1 ] 2>/dev/null && _ctrlsb="lower" || _ctrlsb="upper"
			fi
			;;
		esac
	fi

	# 80MHz needs the 80MHz control-word (ll/lu/ul/uu). "ll" is the safe
	# default and what most APs use.
	if [ "$_width" = 80 ] && [ -z "$_ctrlsb" ]; then
		_ctrlsb="ll"
	fi

	bcw_nvset "wl${_unit}_nmode" "$_nmode"
	[ "$_vht" = 1 ] && bcw_nvset "wl${_unit}_vhtmode" 1 || bcw_nvset "wl${_unit}_vhtmode" 0
	bcw_nvset "wl${_unit}_bw_cap" "$_bwcap"
	bcw_nvset "wl${_unit}_nbw_cap" "$_bwcap"
	[ -n "$_ctrlsb" ] && bcw_nvset "wl${_unit}_nctrlsb" "$_ctrlsb"

	# wlconf's channel+bw_cap+nctrlsb path derives the 80MHz centre channel as
	# "configured + 6", i.e. it only works when the configured channel is the
	# *block start* (149 -> centre 155). Any other control channel in the block
	# (e.g. 157) then lands on a non-existent centre (163), the driver rejects
	# the chanspec, and the radio silently stays at its 20MHz default. So spell
	# the chanspec out for 80MHz and let wf_chspec_aton() pick the correct
	# centre and control sideband; wlconf takes an explicit wl<N>_chanspec
	# verbatim (wlconf.c ~2364). Clear it for every other width so a later
	# 40/20MHz apply is not pinned to a stale 80MHz chanspec.
	if [ "$_width" = 80 ]; then
		bcw_nvset "wl${_unit}_chanspec" "${_channel}/80"
	else
		rm -f "$NVRAM_DIR/wl${_unit}_chanspec" "$NVRAM_OVERRIDE_DIR/wl${_unit}_chanspec"
	fi
}

# First legal channel for the band, as reported by the driver. Used to turn UCI
# "auto" into a concrete channel: there is no usable ACS here -- wlconf's auto
# path (wlconf_auto_chanspec) applies a 20MHz chanspec and ignores the
# configured width -- whereas a concrete channel goes through the width-aware
# chanspec path. Falls back to the band's first channel if wl cannot be queried.
bcw_first_channel() {
	_i="$1"; _b="$2"; _c=""
	for _v in $(wl -i "$_i" channels 2>/dev/null); do _c="$_v"; break; done
	if [ -z "$_c" ]; then
		case "$_b" in
		2g|11b|11g|b|g) _c=1 ;;
		*)              _c=36 ;;
		esac
	fi
	echo "$_c"
}

# ---------------------------------------------------------------------------
# encryption -> akm / crypto / wep / auth
# ---------------------------------------------------------------------------
#
# nas reads this back through libshared's get_wsec() (wlif_utils.c):
#   wl<N>_akm     "psk" -> WPA, "psk2" -> WPA2, both -> mixed, "" -> open
#   wl<N>_crypto  "aes" / "tkip" / "tkip+aes"
#   wl<N>_wpa_psk the passphrase
#   wl<N>_auth_mode  "radius" selects enterprise, anything else is PSK
#   wl<N>_auth    1 makes eapd skip the interface (shared-key 802.11 auth)

bcw_apply_encryption() {
	_unit="$1"; _enc="$2"; _key="$3"
	_akm=""; _crypto="aes"; _wep="disabled"; _auth=0; _auth_mode="none" _radius=0

	case "$_enc" in
	""|none)
		_akm=""; _wep="disabled" ;;
	wep-open)
		_akm=""; _wep="enabled"; _auth=0 ;;
	wep-shared)
		_akm=""; _wep="enabled"; _auth=1 ;;
	wep|wep-mixed)
		_akm=""; _wep="enabled"; _auth=0 ;;
	psk)
		_akm="psk"; _crypto="tkip" ;;
	psk+aes|psk2)
		_akm="psk2"; _crypto="aes" ;;
	psk+tkip)
		_akm="psk"; _crypto="tkip" ;;
	psk-mixed|psk2+ccmp)
		_akm="psk psk2"; _crypto="aes" ;;
	psk-mixed+tkip)
		_akm="psk psk2"; _crypto="tkip" ;;
	psk-mixed+tkip+aes|psk2+tkip+aes)
		_akm="psk psk2"; _crypto="tkip+aes" ;;
	wpa|wpa2|wpa-mixed|wpa3|sae|owe)
		# Supplicant/enterprise or WPA3. This driver's nas speaks the
		# original Broadcom WPA/WPA2 ioctl path only; refuse rather than
		# silently start an open network.
		logger -t broadcom-wl "encryption '$_enc' is not supported by nas; refusing"
		return 1 ;;
	*radius*)
		_akm="wpa2"; _crypto="aes"; _auth_mode="radius" _radius=1 ;;
	*)
		logger -t broadcom-wl "unknown encryption '$_enc'; treating as open"
		_akm="" ;;
	esac

	bcw_nvset "wl${_unit}_akm" "$_akm"
	bcw_nvset "wl${_unit}_crypto" "$_crypto"
	bcw_nvset "wl${_unit}_wep" "$_wep"
	bcw_nvset "wl${_unit}_auth" "$_auth"
	bcw_nvset "wl${_unit}_auth_mode" "$_auth_mode"
	[ -n "$_key" ] && bcw_nvset "wl${_unit}_wpa_psk" "$_key"
	return 0
}

# ---------------------------------------------------------------------------
# Per-radio apply
# ---------------------------------------------------------------------------
#
# The netifd handler writes a shell-sourceable spec (see files/lib/netifd/
# wireless/broadcom.sh) and calls `broadcom-wl-ctl apply <file>`. Variables:
#
#   RADIO, UNIT, BAND, CHANNEL, HTMODE, COUNTRY, TXPOWER
#   IFACE_<n>_SECTION / _IFNAME / _MODE / _SSID / _ENC / _KEY / _HIDDEN /
#   _ISOLATE / _MAXASSOC / _MACADDR
#
# The first AP iface becomes the primary BSS (wl<UNIT>); the rest become
# virtual BSS wl<UNIT>.<k>, listed in wl<UNIT>_vifs exactly the way wlconf
# expects (wlconf_get_bsscfgs()).

bcw_radio_apply() {
	_spec="$1"
	[ -r "$_spec" ] || return 1
	# shellcheck disable=SC1090
	. "$_spec"

	# UNIT is authoritative when the caller supplied it (the netifd handler
	# resolves band -> wl<N> and puts it in the spec). Fall back to resolving
	# here so a hand-written spec with only BAND still works.
	_unit="$UNIT"
	if [ -z "$_unit" ]; then
		_ifname="$(bcw_band_to_ifname "$BAND")"
		_unit="${_ifname#wl}"
	else
		_ifname="$(bcw_unit_to_ifname "$_unit")"
	fi

	# Static per-radio identity. phytype=v (11AC) is what both radios report;
	# nband is what wlconf uses to pick the band for an 11N/11AC phytype.
	bcw_nvset "wl${_unit}_phytype" "v"
	case "$BAND" in
	2g|11b|11g|b|g) bcw_nvset "wl${_unit}_nband" 2 ;;
	5g|11a|a)       bcw_nvset "wl${_unit}_nband" 5 ;;
	esac
	bcw_nvset "wl${_unit}_radio" 1
	bcw_nvset "wl${_unit}_bss_enabled" 1

	# Channel. UCI "auto" has no usable ACS here (wlconf's auto path applies a
	# 20MHz chanspec and ignores the configured width), so resolve it to the
	# first legal channel for the band. A concrete channel goes through the
	# width-aware chanspec path in wlconf instead.
	case "$CHANNEL" in
	""|auto) _channel="$(bcw_first_channel "$_ifname" "$BAND")" ;;
	*)       _channel="$CHANNEL" ;;
	esac
	bcw_nvset "wl${_unit}_channel" "$_channel"

	bcw_apply_htmode "$_unit" "$HTMODE" "$BAND" "$_channel"

	[ -n "$COUNTRY" ] && bcw_nvset "wl${_unit}_country_code" "$COUNTRY"
	[ -n "$TXPOWER" ] && bcw_nvset "wl${_unit}_tpc_db" "$TXPOWER"

	# Radio-wide housekeeping defaults. All are read by wlconf with
	# nvram_safe_get(), where a missing key reads as "" and atoi("")==0, so
	# these are safe to fix to sane values rather than leaving unset.
	bcw_nvset "wl${_unit}_frameburst" 1
	bcw_nvset "wl${_unit}_gmode" 1
	bcw_nvset "wl${_unit}_bcn" 100
	bcw_nvset "wl${_unit}_dtim" 2
	bcw_nvset "wl${_unit}_mrate" 0

	# Interfaces. Primary first, then virtual BSS.
	_vifs=""
	_pk=0
	_idx=0
	while :; do
		eval "_sec=\${IFACE_${_idx}_SECTION:-}"
		[ -n "$_sec" ] || break
		eval "_mode=\${IFACE_${_idx}_MODE:-ap}"
		eval "_ssid=\${IFACE_${_idx}_SSID:-}"
		eval "_enc=\${IFACE_${_idx}_ENC:-none}"
		eval "_key=\${IFACE_${_idx}_KEY:-}"
		eval "_hidden=\${IFACE_${_idx}_HIDDEN:-0}"
		eval "_isolate=\${IFACE_${_idx}_ISOLATE:-0}"
		eval "_maxassoc=\${IFACE_${_idx}_MAXASSOC:-0}"
		eval "_macaddr=\${IFACE_${_idx}_MACADDR:-}"

		if [ "$_mode" != ap ]; then
			logger -t broadcom-wl "mode '$_mode' not supported on $_ifname; skipping $_sec"
			_idx=$((_idx + 1))
			continue
		fi

		if [ "$_pk" = 0 ]; then
			_prefix="wl${_unit}_"
			_ifsec="$_ifname"
		else
			_vif="wl${_unit}.${_pk}"
			_prefix="wl${_unit}.${_pk}_"
			_ifsec="$_vif"
			_vifs="$_vifs $_vif"
		fi

		bcw_nvset "${_prefix}ifname" "$_ifsec"
		bcw_nvset "${_prefix}ssid" "$_ssid"
		bcw_nvset "${_prefix}mode" "ap"
		bcw_nvset "${_prefix}closed" "$_hidden"
		bcw_nvset "${_prefix}ap_isolate" "$_isolate"
		bcw_nvset "${_prefix}bss_enabled" 1
		[ "$_maxassoc" != 0 ] && bcw_nvset "${_prefix}maxassoc" "$_maxassoc"
		[ -n "$_macaddr" ] && bcw_nvset "${_prefix}hwaddr" "$_macaddr"

		# Virtual BSS share the primary's akm/crypto/psk via their own
		# prefix; wlconf reads the per-prefix copy.
		if [ "$_pk" = 0 ]; then
			bcw_apply_encryption "$_unit" "$_enc" "$_key" || return 1
		else
			bcw_apply_encryption "$_unit.$_pk" "$_enc" "$_key" || return 1
		fi

		_pk=$((_pk + 1))
		_idx=$((_idx + 1))
	done

	# Hand the list of virtual BSS to wlconf. Empty means "primary only".
	bcw_nvset "wl${_unit}_vifs" "$(echo $_vifs)"
}

# ---------------------------------------------------------------------------
# up / down
# ---------------------------------------------------------------------------
#
# `up` does the whole configuration pass and ends in WLC_UP, but it disables
# every BSS on the way in. The BSS-enable loop lives only in `start`, so both
# are required, and in this order (see userspace/wlconf/README.md).

bcw_radio_up() {
	_unit="$1"
	_ifname="$(bcw_unit_to_ifname "$_unit")"
	wlconf "$_ifname" up
	wlconf "$_ifname" start
	# WLC_UP brings the radio up but leaves the netdev administratively down.
	# netifd's wireless glue only marks the netdev as a bridge master when the
	# handler reports it via set_vif(); it does not set IFF_UP itself, so the
	# port never joins br-lan and no traffic flows. Bring it up here.
	ip link set "$_ifname" up
}

bcw_radio_down() {
	_unit="$1"
	_ifname="$(bcw_unit_to_ifname "$_unit")"
	wlconf "$_ifname" down
}

# ---------------------------------------------------------------------------
# WPA (nas + eapd)
# ---------------------------------------------------------------------------
#
# eapd owns the PF_PACKET socket on ETHER_TYPE_BRCM and needs a *bridge* to
# bind it to: it resolves each wl netdev to its bridge through
# get_ifname_by_wlmac(), which reads lan_ifname/lan_ifnames. So the values
# below matter and are not decorative -- without them eapd binds nothing and
# nas blocks forever in select() having never seen an association.
#
# eapd takes the list of radios once (`eapd -nas wl0 wl1`), so this is a
# radio-agnostic operation: it is re-run whenever a radio is set up and starts
# (or leaves alone) the pair as a whole.

bcw_all_wl_ifaces() {
	# Primary netdevs only: wl0, wl1, ... (not the wl0.1 virtual BSS).
	for _n in /sys/class/net/wl*; do
		[ -e "$_n" ] || continue
		_n="$(basename "$_n")"
		case "$_n" in *.*) continue ;; esac
		echo "$_n"
	done
}

# Any AP radio carrying WPA? (Open networks need neither daemon.)
bcw_any_wpa() {
	for _if in $(bcw_all_wl_ifaces); do
		_u="${_if#wl}"; _u="${_u%%.*}"
		[ -n "$(bcw_nvget "wl${_u}_akm")" ] && return 0
	done
	return 1
}

bcw_security_start() {
	_bridge="${1:-br-lan}"

	bcw_nvset "lan_ifname" "$_bridge"

	# eapd resolves wl netdev -> bridge, so the radios must be listed here.
	_lan="$(bcw_nvget lan_ifnames)"
	for _if in $(bcw_all_wl_ifaces); do
		case " $_lan " in
		*" $_if "*) : ;;
		*) _lan="$(echo $_lan $_if)"; bcw_nvset "lan_ifnames" "$_lan" ;;
		esac
	done

	if ! bcw_any_wpa; then
		bcw_security_stop
		return 0
	fi

	# eapd first (nas's only receive path is eapd's relay), then nas. Both
	# daemonise after initialising, so a non-zero exit is a real failure.
	if ! pidof eapd >/dev/null 2>&1; then
		start-stop-daemon -S -x /usr/sbin/eapd -b -- -nas $(bcw_all_wl_ifaces) \
			>>"$BCW_RUNDIR/eapd.log" 2>&1
	fi
	if ! pidof nas >/dev/null 2>&1; then
		start-stop-daemon -S -x /usr/sbin/nas -b -- \
			>>"$BCW_RUNDIR/nas.log" 2>&1
	fi

	# Remember what eapd is bound *to*, so a later ensure pass can tell a
	# healthy daemon from one whose packet socket went stale (bridge
	# replaced, hence a new ifindex, or lan_ifname rewritten underneath it).
	bcw_daemon_mark "$_bridge"
}

bcw_security_stop() {
	start-stop-daemon -K -x /usr/sbin/nas  >/dev/null 2>&1
	start-stop-daemon -K -x /usr/sbin/eapd >/dev/null 2>&1

	# start-stop-daemon -K only *sends* TERM. nas returns immediately, but
	# eapd unwinds its select loop over ~0.6s, so pidof still reports it for
	# a while. A caller that restarts straight away sees that pid, skips the
	# start, and ends up with nas but no eapd -- and with no 0x886c relay the
	# four-way handshake silently never completes (client shows "wrong
	# password"). So wait until they are really gone; busybox sleep is
	# integer-only here and usleep is absent, hence the 1s granularity.
	_i=0
	while [ "$_i" -lt 3 ]; do
		pidof nas >/dev/null 2>&1 || pidof eapd >/dev/null 2>&1 || break
		sleep 1
		_i=$((_i + 1))
	done
	# One that outlived the grace period only delays the restart: insist.
	for _p in $(pidof nas) $(pidof eapd); do kill -9 "$_p" 2>/dev/null; done
	return 0
}

# ---------------------------------------------------------------------------
# Network hotplug repair
# ---------------------------------------------------------------------------
#
# netifd runs /etc/hotplug.d/iface/* for *every* interface, wan included, and a
# PPPoE link flaps ifup/ifdown repeatedly while it negotiates. Everything
# eapd/nas need is keyed off the LAN bridge, so the WAN path is dangerous:
#
#   * eapd reads lan_ifname ONCE at startup and binds its ETHER_TYPE_BRCM
#     packet socket to that bridge (eapd_linux.c:eapd_brcm_open). Handing it
#     "br-wan" makes SIOCGIFINDEX fail, eapd never sees another 0x886c EAPOL
#     frame, and nas -- whose only receive path is eapd's relay -- completes no
#     handshake. The client then reports an authentication failure, i.e. "wrong
#     password", even though the passphrase is right.
#   * Killing nas on a WAN ifdown produces exactly the same symptom.
#
# So every entry point below resolves the LAN bridge *itself* and never derives
# one from $INTERFACE. Together these are the "plugging in the ISP cable breaks
# Wi-Fi" fix and the shared general guard for any user.

# The bridge the wl radios belong to. netifd names it br-<network> (default
# br-lan); prefer whichever bridge already carries a wl member, which is the
# runtime truth, and fall back to br-lan before the radios are enslaved.
bcw_lan_bridge() {
	[ -n "${BCW_LAN_BRIDGE:-}" ] && { echo "$BCW_LAN_BRIDGE"; return 0; }
	for _b in /sys/class/net/br-*; do
		[ -d "$_b/brif" ] || continue
		for _m in "$_b"/brif/wl*; do
			[ -e "$_m" ] || continue
			basename "$_b"
			return 0
		done
	done
	echo "br-lan"
}

# MAC address of a live netdev, or "" when it does not exist.
bcw_ifmac() {
	[ -r "/sys/class/net/$1/address" ] && cat "/sys/class/net/$1/address"
}

# Bump the last octet by BCW_MAC_OFFSET (default 2), wrapping, OUI preserved.
# The step is 2 rather than 1 on purpose: +1 from the factory WAN MAC
# (...:44:ab here) lands on another port's address, and the point of this
# guard is to separate two *L2* domains, not to reshuffle a single switch.
bcw_mac_offset() {
	_off="${BCW_MAC_OFFSET:-2}"
	_oifs="$IFS"; IFS=':'
	# shellcheck disable=SC2086
	set -- $1
	IFS="$_oifs"
	[ $# -eq 6 ] || return 1
	_last="$(printf '%d' "0x$6")" || return 1
	printf '%s:%s:%s:%s:%s:%02x\n' "$1" "$2" "$3" "$4" "$5" \
		"$(( (_last + _off) % 256 ))"
}

# Persist a device's macaddr in /etc/config/network (netifd only applies it on
# reload, so the caller also applies it live).
bcw_uci_set_devmac() {
	command -v uci >/dev/null 2>&1 || return 0
	for _s in $(uci -q show network 2>/dev/null | \
		sed -n 's/^network\.\([^.]*\)=device$/\1/p'); do
		[ "$(uci -q get "network.$_s.name")" = "$1" ] || continue
		[ "$(uci -q get "network.$_s.macaddr")" = "$2" ] && return 0
		uci -q set "network.$_s.macaddr=$2"
		uci -q commit network
		return 0
	done
	return 0
}

# wan and the LAN bridge must not share a MAC. Users cloning a router's address
# from FreshTomato/DD-WRT typically copy the old `et0macaddr' (or just
# `CC:E1:D5:9D:44:AA') onto `wan', which collides with the shared MAC OpenWrt
# derives br-lan from on the B53 switch (all of eth0/lan1..lan4/br-lan start
# out as ...:44:aa). With both on the same switch the MAC learning table flaps
# between the LAN and WAN sides and bridged frames get black-holed. Detect it,
# move br-lan clear of wan, and leave wan alone -- the ISP PPPoE session owns
# that address.
bcw_mac_collision_guard() {
	_bridge="$1"; _wan="${2:-wan}"
	_bmac="$(bcw_ifmac "$_bridge")"; _wmac="$(bcw_ifmac "$_wan")"
	[ -n "$_bmac" ] && [ -n "$_wmac" ] || return 0
	[ "$_bmac" = "$_wmac" ] || return 0
	_new="$(bcw_mac_offset "$_bmac")" || return 0
	[ -n "$_new" ] && [ "$_new" != "$_wmac" ] || return 0
	logger -t broadcom-wl "$_bridge MAC $_bmac collides with $_wan ($_wmac); moving $_bridge to $_new"
	ip link set "$_bridge" address "$_new" 2>/dev/null
	bcw_uci_set_devmac "$_bridge" "$_new"
	return 0
}

# Keep every radio UP and a member of the LAN bridge. netifd is the owner of
# enslavement (it reports each netdev through set_vif()), so this only repairs
# a port it has dropped or left down; a membership that is already correct is a
# no-op, and nothing here can run when the bridge is absent.
bcw_ensure_bridge_member() {
	_bridge="$1"
	[ -d "/sys/class/net/$_bridge" ] || return 0
	for _if in $(bcw_all_wl_ifaces); do
		ip link set "$_if" up 2>/dev/null
		_cur="$(basename "$(readlink "/sys/class/net/$_if/master" 2>/dev/null)" 2>/dev/null)"
		[ "$_cur" = "$_bridge" ] && continue
		ip link set "$_if" master "$_bridge" 2>/dev/null || \
			brctl addif "$_bridge" "$_if" 2>/dev/null
	done
	return 0
}

# eapd marks (bridge + ifindex) it was started against.
bcw_daemon_mark() {
	_bridge="$1"
	_idx="$(cat "/sys/class/net/$_bridge/ifindex" 2>/dev/null)"
	printf '%s %s\n' "$_bridge" "$_idx" > "$BCW_RUNDIR/daemons.state"
}

# Full repair pass for one interface event: MAC hygiene, NVRAM identity, radio
# membership, and (re)start of eapd+nas whenever their binding went stale.
# Safe to call on every event -- each step is idempotent.
bcw_security_ensure() {
	_bridge="${1:-$(bcw_lan_bridge)}"
	[ -n "$_bridge" ] || _bridge="br-lan"
	[ -n "$(bcw_all_wl_ifaces)" ] || return 0

	bcw_mac_collision_guard "$_bridge"

	# The NVRAM keys eapd/nas/libshared resolve the radios through.
	bcw_nvset "lan_ifname" "$_bridge"
	_lan="$(bcw_nvget lan_ifnames)"
	for _if in $(bcw_all_wl_ifaces); do
		case " $_lan " in
		*" $_if "*) : ;;
		*) _lan="$(echo $_lan $_if)"; bcw_nvset lan_ifnames "$_lan" ;;
		esac
	done
	_hw="$(bcw_ifmac "$_bridge")"
	[ -n "$_hw" ] && bcw_nvset lan_hwaddr "$_hw"

	bcw_ensure_bridge_member "$_bridge"

	# If eapd is alive but was started against a different bridge, or the
	# bridge has since been recreated (new ifindex), its PF_PACKET bind is
	# stale and no EAPOL frame will ever reach nas again -- restart both.
	_state="$(cat "$BCW_RUNDIR/daemons.state" 2>/dev/null)"
	_cur="$(cat "/sys/class/net/$_bridge/ifindex" 2>/dev/null)"
	if [ -n "$(pidof eapd 2>/dev/null)" ] && \
	   [ "$_state" != "$_bridge $_cur" ]; then
		logger -t broadcom-wl \
			"eapd bound to '${_state:-nothing}' but LAN bridge is '$_bridge $_cur'; restarting eapd+nas"
		bcw_security_stop
	fi

 	bcw_security_start "$_bridge"
 	return 0
 }

 # ---------------------------------------------------------------------------
# Defaults seeded once, from the init script
# ---------------------------------------------------------------------------

bcw_seed_defaults() {
	bcw_nvset wl_ifnames "wl0 wl1"
	bcw_nvset wl_msglevel 0x1
	bcw_nvset wl_msglevel2 0x0
	bcw_nvset lan_ifname "br-lan"
	# Keep whatever lan_ifnames already holds; make sure the radios can be
	# appended later without duplicating.
	[ -n "$(bcw_nvget lan_ifnames)" ] || bcw_nvset lan_ifnames ""
}

# ---------------------------------------------------------------------------
# netifd handler: keep exactly one
# ---------------------------------------------------------------------------
#
# netifd discovers wireless protocol handlers by globbing
# /lib/netifd/wireless/*.sh and running each one to dump its capabilities.
# Its reader loop does not stop at EOF (f.error() never leaves the null state),
# so with more than one handler script present netifd busy-spins at ~100% CPU
# and never finishes bringing up networking. Stock ships a single handler
# (mac80211.sh); installing ours alongside it makes two and triggers the bug.
#
# There is no cfg80211/mac80211 driver on this board -- ours is the only
# wireless handler that means anything here -- so move every handler except
# broadcom.sh out of the scan path. This is reversible: the files are kept
# beside the dir as <name>.sh.disabled and restored by the package prerm.

BCW_WIRELESS_DIR="${BCW_WIRELESS_DIR:-/lib/netifd/wireless}"
BCW_HANDLER_DISABLED_DIR="${BCW_HANDLER_DISABLED_DIR:-/lib/netifd}"

bcw_single_handler() {
	[ -d "$BCW_WIRELESS_DIR" ] || return 0
	for _h in "$BCW_WIRELESS_DIR"/*.sh; do
		[ -e "$_h" ] || continue
		_b="$(basename "$_h")"
		[ "$_b" = broadcom.sh ] && continue
		mv -f "$_h" "$BCW_HANDLER_DISABLED_DIR/$_b.disabled" 2>/dev/null
	done
	return 0
}

bcw_restore_handler() {
	for _h in "$BCW_HANDLER_DISABLED_DIR"/*.sh.disabled; do
		[ -e "$_h" ] || continue
		_b="$(basename "$_h")"; _b="${_b%.disabled}"
		mv -f "$_h" "$BCW_WIRELESS_DIR/$_b" 2>/dev/null
	done
	return 0
}

# ---------------------------------------------------------------------------
# libiwinfo: provide the wl-enabled build at the canonical path
# ---------------------------------------------------------------------------
#
# rpcd-mod-luci (LuCI's luci-rpc getWirelessDevices) describes the radios by
# dlopen()ing /usr/lib/libiwinfo.so* and dlsym()ing iwinfo_backend() and the
# IWINFO_*_NAMES tables. The stock libiwinfo is built with the nl80211 backend
# only, so on this cfg80211-less board every call fails and LuCI falls back to
# "Generic / unknown" with no channel, bitrate or station list.
#
# This package ships the same iwinfo built with the Broadcom `wl' backend (plus
# wext, which the wl backend delegates to). It cannot be installed at the
# canonical path directly -- that file belongs to the stock libiwinfo package,
# and a second package owning it is an apk file conflict -- so it lives in
# /usr/lib/broadcom-wl/ and the canonical name is pointed at it here, with the
# stock file moved safely aside. prerm undoes both moves.
#
# The backup name deliberately does NOT match the /usr/lib/libiwinfo.so* glob
# rpcd scans, or it would find two libraries.

BCW_IFWIN_CANON="/usr/lib/libiwinfo.so.20230701"
BCW_IFWIN_SHIPPED="broadcom-wl/libiwinfo.so.20230701"
BCW_IFWIN_BACKUP="/usr/lib/broadcom-wl/libiwinfo.so.20230701.stock"

bcw_iwinfo_install() {
	[ -e "/usr/lib/$BCW_IFWIN_SHIPPED" ] || return 0

	# Already pointing at us (init runs every boot)? Nothing to do.
	if [ -L "$BCW_IFWIN_CANON" ] && \
	   [ "$(readlink "$BCW_IFWIN_CANON" 2>/dev/null)" = "$BCW_IFWIN_SHIPPED" ]; then
		return 0
	fi

	# Move a real stock library aside, once. A symlink left over from a
	# removed package is simply replaced.
	if [ -e "$BCW_IFWIN_CANON" ] && [ ! -L "$BCW_IFWIN_CANON" ]; then
		mkdir -p "$(dirname "$BCW_IFWIN_BACKUP")"
		mv -f "$BCW_IFWIN_CANON" "$BCW_IFWIN_BACKUP" 2>/dev/null
	fi

	ln -sf "$BCW_IFWIN_SHIPPED" "$BCW_IFWIN_CANON"
}

bcw_iwinfo_restore() {
	[ -L "$BCW_IFWIN_CANON" ] && rm -f "$BCW_IFWIN_CANON"
	[ -e "$BCW_IFWIN_BACKUP" ] && mv -f "$BCW_IFWIN_BACKUP" "$BCW_IFWIN_CANON" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# /etc/config/wireless repair
# ---------------------------------------------------------------------------
#
# LuCI's frequency widget calls rpcd `iwinfo freqlist'; with the stock
# nl80211-only libiwinfo that fails, and the widget then clears band, channel
# and htmode when the section is saved (this is what emptied the radios here).
# The missing `band' is what let both radios resolve to the same netdev (see
# the netifd handler). With the wl-enabled libiwinfo installed this no longer
# happens, but a config already damaged in the field has to be healed once.
#
# Also removes phantom non-broadcom wifi-device sections (the stock mac80211
# radio that `wifi config' recreates from board.json on every boot), since this
# board has no mac80211 radio once the wl driver owns the hardware.
#
# On the broadcom sections it only touches those that have neither band nor
# hwmode: an operator-set value is never overwritten, and 2g/5g is assigned by
# radio order, matching the factory default and the handler's own fallback.

bcw_radio_config_repair() {
	command -v uci >/dev/null 2>&1 || return 0
	_changed=0

	# Drop phantom wifi-devices. /etc/init.d/boot (S10) runs `wifi config',
	# which turns the stock /etc/board.json `wlan' entry -- the bcma 2.4GHz
	# radio the stock image describes as mac80211 -- into a `wifi-device' of
	# type mac80211. That happens before our S19 `handler-single' removes
	# mac80211.sh, so netifd (S20) ends up with a radio section no handler
	# claims: ignored at runtime, but it clutters UCI and LuCI's config view,
	# and reappears on every boot. We own the only radios on this board, so
	# any wifi-device that is not ours is a phantom; remove it and every
	# wifi-iface bound to it. Runs before netifd reads the config.
	for _sec in $(uci -q show wireless 2>/dev/null | \
		sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p'); do
		[ "$(uci -q get "wireless.$_sec.type")" = broadcom ] && continue
		for _if in $(uci -q show wireless 2>/dev/null | \
			sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
			[ "$(uci -q get "wireless.$_if.device")" = "$_sec" ] || continue
			uci -q delete "wireless.$_if"
			_changed=1
		done
		uci -q delete "wireless.$_sec"
		_changed=1
		logger -t broadcom-wl "wireless.$_sec: removed phantom non-broadcom radio"
	done

	_idx=-1
	for _sec in $(uci -q show wireless 2>/dev/null | \
		sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p'); do
		[ "$(uci -q get "wireless.$_sec.type")" = broadcom ] || continue
		_idx=$((_idx + 1))
		[ -n "$(uci -q get "wireless.$_sec.band")" ] && continue
		[ -n "$(uci -q get "wireless.$_sec.hwmode")" ] && continue
		case "$_idx" in
		0) _band=2g ;;
		1) _band=5g ;;
		*) _band=2g ;;
		esac
		uci set "wireless.$_sec.band=$_band"
		_changed=1
		logger -t broadcom-wl "wireless.$_sec: restored missing band ($_band)"
	done
	[ "$_changed" = 1 ] && uci commit wireless
	return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

bcw_main() {
	case "$1" in
	apply)   bcw_radio_apply "$2" ;;
	up)      bcw_radio_up "$2" ;;
	down)    bcw_radio_down "$2" ;;
	seed)    bcw_seed_defaults ;;
	handler-single)  bcw_single_handler ;;
	handler-restore) bcw_restore_handler ;;
	iwinfo-install)  bcw_iwinfo_install ;;
	iwinfo-restore)  bcw_iwinfo_restore ;;
	config-repair)   bcw_radio_config_repair ;;
	security-start) shift; bcw_security_start "$@" ;;
	security-stop)  bcw_security_stop ;;
	net-repair)     shift; bcw_security_ensure "$@" ;;
	mac-guard)      shift; bcw_mac_collision_guard "$@" ;;
	ifname)  bcw_band_to_ifname "$2" ;;
	nvset)   bcw_nvset "$2" "$3" ;;
	nvget)   bcw_nvget "$2" ;;
	*)
		echo "usage: broadcom-wl-ctl {seed|handler-single|handler-restore|iwinfo-install|iwinfo-restore|config-repair|apply <file>|up <unit>|down <unit>|security-start <if> <bridge>|security-stop|net-repair [<bridge>]|mac-guard [<bridge>] [<wan>]|ifname <band>|nvset <k> <v>|nvget <k>}" >&2
		return 1
		;;
	esac
}

[ -n "$BCW_NO_MAIN" ] || bcw_main "$@"
