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
# bw_cap is a WL_BW_CAP_* bit: 1=20MHz, 2=40MHz, 4=80MHz.

bcw_apply_htmode() {
	_unit="$1"; _htmode="$2"; _band="$3"; _channel="$4"
	_nmode=1; _vht=0; _bwcap=1; _ctrlsb=""

	case "$_htmode" in
	NOHT|"") _nmode=0; _bwcap=1 ;;
	HT20)    _nmode=1; _bwcap=1 ;;
	HT40|HT40+|HT40-) _nmode=1; _bwcap=2 ;;
	VHT20)   _nmode=1; _vht=1; _bwcap=1 ;;
	VHT40|HT40B) _nmode=1; _vht=1; _bwcap=2 ;;
	VHT80)   _nmode=1; _vht=1; _bwcap=4 ;;
	VHT160)  _nmode=1; _vht=1; _bwcap=8 ;;
	esac

	# 40MHz needs a control sideband. HT40+/- spells it out; bare HT40/VHT40
	# derives it the way wlconf's own fallback does.
	if [ "$_bwcap" = 2 ]; then
		case "$_htmode" in
		HT40+) _ctrlsb="upper" ;;
		HT40-) _ctrlsb="lower" ;;
		*)
			if [ "$_band" = 2g ]; then
				[ "$_channel" -lt 7 ] 2>/dev/null && _ctrlsb="upper" || _ctrlsb="lower"
			else
				# 5GHz: even /4 -> upper, odd -> lower.
				[ $(( _channel / 4 % 2 )) = 1 ] 2>/dev/null && _ctrlsb="upper" || _ctrlsb="lower"
			fi
			;;
		esac
	fi

	# 80MHz needs the 80MHz control-word (ll/lu/ul/uu). "ll" is the safe
	# default and what most APs use.
	if [ "$_bwcap" = 4 ] && [ -z "$_ctrlsb" ]; then
		_ctrlsb="ll"
	fi

	bcw_nvset "wl${_unit}_nmode" "$_nmode"
	[ "$_vht" = 1 ] && bcw_nvset "wl${_unit}_vhtmode" 1 || bcw_nvset "wl${_unit}_vhtmode" 0
	bcw_nvset "wl${_unit}_bw_cap" "$_bwcap"
	bcw_nvset "wl${_unit}_nbw_cap" "$_bwcap"
	[ -n "$_ctrlsb" ] && bcw_nvset "wl${_unit}_nctrlsb" "$_ctrlsb"
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

	# Channel. UCI "auto" means 0 (let the driver pick / ACS is not available
	# here, so this is "first legal channel").
	case "$CHANNEL" in
	""|auto) bcw_nvset "wl${_unit}_channel" 0 ;;
	*)       bcw_nvset "wl${_unit}_channel" "$CHANNEL" ;;
	esac

	bcw_apply_htmode "$_unit" "$HTMODE" "$BAND" "${CHANNEL:-0}"

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
}

bcw_security_stop() {
	start-stop-daemon -K -x /usr/sbin/nas  >/dev/null 2>&1
	start-stop-daemon -K -x /usr/sbin/eapd >/dev/null 2>&1
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
	security-start) shift; bcw_security_start "$@" ;;
	security-stop)  bcw_security_stop ;;
	ifname)  bcw_band_to_ifname "$2" ;;
	nvset)   bcw_nvset "$2" "$3" ;;
	nvget)   bcw_nvget "$2" ;;
	*)
		echo "usage: broadcom-wl-ctl {seed|handler-single|handler-restore|apply <file>|up <unit>|down <unit>|security-start <if> <bridge>|security-stop|ifname <band>|nvset <k> <v>|nvget <k>}" >&2
		return 1
		;;
	esac
}

[ -n "$BCW_NO_MAIN" ] || bcw_main "$@"
