#!/usr/bin/ucode
//
// netifd wireless handler for the Broadcom `wl` blob driver.
//
// netifd (OpenWrt 25.12, the ucode rewrite) runs every *.sh in
// /lib/netifd/wireless once with `"" dump` and treats each JSON object printed
// on stdout as a handler descriptor; the descriptor's "name" is the value a
// user puts in `option type` in /etc/config/wireless. So this file registers
// the type "broadcom".
//
// After that, for every device whose type is "broadcom", netifd invokes
//
//	./broadcom.sh <type> <op> <radio> <json>
//
// where <op> is setup or teardown, <radio> is the wifi-device section name
// (radio0/radio1) and <json> is { config: <device>, data: <from set_data>,
// interfaces: { "<NN>": { name, config, stas, vlans }, ... } }. In ucode the
// command line lands in ARGV: ARGV[0]=type, [1]=op, [2]=radio, [3]=json.
//
// The driver is not cfg80211, so there is no hostapd/bss machinery to drive
// and no per-vif setup op: everything for the radio (all of its BSS) is done
// in one setup() by translating the config into wl<N>_* NVRAM and running
// wlconf, exactly as userspace/wlconf/README.md describes. The netifd-facing
// part is just set_vif() per interface (so netifd can attach them to the
// bridge) and set_up() once the radio is beaconing.

'use strict';

import { log } from 'wifi.common';
import { validate } from 'wifi.validate';
import * as netifd from 'wifi.netifd';
import * as fs from 'fs';

// netifd's notify channel (wifi.netifd) targets `device: global.radio`, so the
// radio section name has to be set here. mac80211.sh does the same. Without
// this, every set_vif()/set_up()/setup_failed() notify arrives device-less and
// is dropped, netifd never marks the device "up", and it tears the radio down
// and re-sets-up until retry_setup_failed latches.
global.radio = ARGV[2];

const RUNDIR = '/var/run/broadcom-wl';
const SCHEMA_DIR = '/usr/share/schema';

// Same descriptor format as mac80211.sh's dump_options(), but under our own
// name. netifd calls parse_attribute_list() with these [name, type_id] pairs
// to turn UCI strings into typed values before they reach us.
const types = {
	array: 1,
	string: 3,
	number: 5,
	boolean: 7,
};

function dump_options() {
	let schemas = {};
	for (let k in [ 'device', 'iface', 'vlan', 'station' ])
		schemas[k] = json(fs.readfile(`${SCHEMA_DIR}/wireless.wifi-${k}.json`)).properties;

	let dump = { name: 'broadcom' };

	for (let k, v in schemas) {
		dump[k] = [];
		for (let option in v) {
			let _key = (v[option].type == 'alias') ? v[option].default : option;
			push(dump[k], [ option, types[v[_key].type] ]);
		}
	}

	printf('%J\n', dump);
	return 0;
}

// Single-quote a value for the shell-sourceable spec file the ctl reads.
function shq(v) {
	if (v == null)
		v = '';
	return "'" + replace('' + v, "'", "'\\''") + "'";
}

// Resolve a UCI band to the wl<N> netdev that actually carries it. The mapping
// is not fixed: the driver numbers the radios in PCI probe order, and on the
// WZR-1750DHP the 5GHz radio enumerates first (wl0 = 5GHz, wl1 = 2.4GHz).
// common.sh owns the detection (it reads the chip id from sysfs); ask it rather
// than guessing here, so LuCI's band -> radio mapping stays correct.
function resolve_ifname(band) {
	let f = `${RUNDIR}/.ifname`;
	system(`/usr/sbin/broadcom-wl-ctl ifname ${band} > ${f} 2>/dev/null`);
	let s = fs.readfile(f);
	return s ? split(s, '\n')[0] : '';
}

// The bridge a wireless iface is attached to. netifd names bridges br-<network>
// for a bridge protocol on <network>; the default is br-lan.
function iface_bridge(cfg) {
	let nets = cfg.network;
	if (type(nets) == 'array' && length(nets) > 0)
		return 'br-' + nets[0];
	return 'br-lan';
}

function run(cmd) {
	return system(cmd);
}

function write_spec(radio, unit, config, interfaces) {
	let band = config.band ?? '2g';
	let spec = [
		[ 'RADIO', radio ],
		[ 'UNIT', unit ],
		[ 'BAND', band ],
		[ 'CHANNEL', config.channel ?? 'auto' ],
		[ 'HTMODE', config.htmode ?? 'NOHT' ],
		[ 'COUNTRY', config.country_code ?? '' ],
		[ 'TXPOWER', config.txpower ?? '' ],
	];

	let idx = 0;
	for (let k, v in interfaces) {
		let cfg = v.config;
		if (cfg.mode != 'ap')
			continue;
		// The schema aliases were already expanded by validate() below.
		spec = [
			...spec,
			[ `IFACE_${idx}_SECTION`, v.name ?? k ],
			[ `IFACE_${idx}_MODE`, cfg.mode ],
			[ `IFACE_${idx}_SSID`, cfg.ssid ?? '' ],
			[ `IFACE_${idx}_ENC`, cfg.encryption ?? 'none' ],
			[ `IFACE_${idx}_KEY`, cfg.key ?? cfg['password:wpakey'] ?? '' ],
			[ `IFACE_${idx}_HIDDEN`, cfg.ignore_broadcast_ssid ? '1' : '0' ],
			[ `IFACE_${idx}_ISOLATE`, cfg.ap_isolate ? '1' : '0' ],
			[ `IFACE_${idx}_MAXASSOC`, cfg.max_num_sta ?? 0 ],
			[ `IFACE_${idx}_MACADDR`, cfg.macaddr ?? '' ],
		];
		idx++;
	}

	let out = '';
	for (let entry in spec)
		out += `${entry[0]}=${shq(entry[1])}\n`;

	let path = `${RUNDIR}/${radio}.spec`;
	let f = fs.open(path, 'w');
	f.write(out);
	f.close();
	return path;
}

function setup() {
	let data = json(ARGV[3]);
	let radio = ARGV[2];
	let config = data.config;

	if (config.disabled) {
		log(`${radio}: disabled`);
		return 0;
	}

	let band = config.band;
	if (!band) {
		switch (config.hw_mode) {
		case '11a':
			band = '5g';
			break;
		default:
			band = '2g';
			break;
		}
		config.band = band;
	}

	validate('device', config);

	let ifname = resolve_ifname(band);
	if (ifname == '') {
		log(`${radio}: no ${band} radio found (is the wl module loaded?)`);
		netifd.setup_failed(`${radio}: no ${band} radio`);
		return 1;
	}
	let unit = substr(ifname, 2);

	// Collect the AP interfaces and normalise them the same way mac80211 does.
	let ap_ifaces = 0;
	for (let k, v in data.interfaces) {
		if (v.config.mode == 'ap')
			validate('iface', v.config);
		else if (v.config.mode != null)
			log(`${radio}: mode '${v.config.mode}' not supported; interface not configured`);
		let cfg = v.config;
		if (cfg.mode == 'ap')
			ap_ifaces++;
	}

	if (ap_ifaces == 0) {
		log(`${radio}: no AP interface configured`);
		return 0;
	}

	let spec = write_spec(radio, unit, config, data.interfaces);

	log(`configuring ${ifname} (${radio}, band ${band}, ${ap_ifaces} BSS)`);
	if (run(`/usr/sbin/broadcom-wl-ctl apply ${spec}`) != 0) {
		netifd.setup_failed(`${radio}: unsupported configuration`);
		return 1;
	}

	// Tell netifd which OS interface each UCI section maps to. The primary
	// AP is wl<unit>; additional AP BSS are wl<unit>.<n>, created by the
	// driver when wlconf runs, so the names reported here are the real ones.
	let pk = 0;
	for (let k, v in data.interfaces) {
		if (v.config.mode != 'ap')
			continue;
		let vif = (pk == 0) ? ifname : `${ifname}.${pk}`;
		netifd.set_vif(k, vif);
		pk++;
	}

	if (run(`/usr/sbin/broadcom-wl-ctl up ${unit}`) != 0) {
		// wlconf logs each rejected ioctl but still exits 0; a non-zero
		// status here means it could not be run at all.
		netifd.setup_failed(`${radio}: wlconf failed`);
		return 1;
	}

	// WPA needs a bridge, and needs to know which one (see common.sh).
	let bridge = 'br-lan';
	for (let k, v in data.interfaces)
		if (v.config.mode == 'ap') {
			bridge = iface_bridge(v.config);
			break;
		}
	run(`/usr/sbin/broadcom-wl-ctl security-start ${bridge}`);

	netifd.set_up();
	return 0;
}

function teardown() {
	let data = json(ARGV[3]);
	let config = data.config ?? {};
	let band = config.band ?? '2g';
	let ifname = resolve_ifname(band);

	run('/usr/sbin/broadcom-wl-ctl security-stop');
	if (ifname != '')
		run(`/usr/sbin/broadcom-wl-ctl down ${substr(ifname, 2)}`);

	return 0;
}

let ret = 1;

switch (ARGV[1]) {
case 'dump':
	ret = dump_options();
	break;
case 'setup':
	ret = setup();
	break;
case 'teardown':
	ret = teardown();
	break;
}

exit(ret);
