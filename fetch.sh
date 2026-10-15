#!/bin/sh
#
# fetch.sh - download the proprietary binary blobs this repository does not
# track.
#
# Two files are needed to build, and neither can be produced from the sources
# here:
#
#   vendor/wl/linux/wl_apsta.o    Broadcom's STA driver - a 2.6.36-era
#                                 *relocatable object* (4.8 MB). The whole port
#                                 rests on it still carrying its symbol and
#                                 relocation tables, which the shadow/objcopy
#                                 layer rewrites. It cannot be regenerated from
#                                 a linked wl.ko.
#   vendor/wl/arm-uclibc/wl       Broadcom's prebuilt `wl` control tool (uClibc
#                                 ARM), which talks to the driver's private
#                                 ioctls.
#
# Both are tracked in the public FreshTomato ARM source tree. They are pinned
# here by commit and checked by sha256, so a build either gets the exact bytes
# this port was developed and tested against or fails loudly. Nothing else is
# downloaded - every other component, Broadcom shared sources and the three
# vendored libraries included, is built from source in this tree.
#
# Usage:
#   ./fetch.sh                        # download from GitHub
#   ./fetch.sh /path/to/freshtomato-arm
#                                     # copy from a local checkout of the tree
#   FRESHTOMATO_BASE=/path ./fetch.sh # same, via the environment
#
# The two blobs are redistributed by no one here: fetch.sh only automates
# retrieving them from the vendor's own published source, at a revision that is
# verified to be the one this port was built against.
set -eu

REPO=tomato64/freshtomato-arm
COMMIT=2b34e8520426d86377b51a9df465f10737ed49f9
SUBDIR=release/src-rt-6.x.4708/wl

# `relative/path  sha256` - one per line. Keep the hashes in step with the
# commit above; a changed blob must be an explicit, reviewed change.
FILES="
linux/wl_apsta.o  247bafff4856a1e571d91364b88477ad93099356e549218419d87a95f01ef98e
arm-uclibc/wl     d10a057feda563300b49e185ed627e0419e432febbbe23e2a25929246da0f519
"

# Directory of this script, so it works from any CWD.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# A local tree may be given as $1; otherwise use the environment; otherwise
# download. A local copy is what an air-gapped or rate-limit-averse build uses,
# and it is the same mechanism - same commit, same hashes.
LOCAL=${1:-${FRESHTOMATO_BASE:-}}

log() { printf 'fetch.sh: %s\n' "$*"; }
die() { printf 'fetch.sh: %s\n' "$*" >&2; exit 1; }

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

download() {
	url=$1 out=$2
	if command -v curl >/dev/null 2>&1; then
		curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$out" "$url"
	else
		die "need curl or wget to download $url (or pass a local tree)"
	fi
}

if [ -n "$LOCAL" ] && [ ! -d "$LOCAL/$SUBDIR" ]; then
	die "no $SUBDIR under '$LOCAL' - not a FreshTomato source tree"
fi

rc=0
printf '%s\n' "$FILES" | while read -r rel want; do
	[ -n "${rel:-}" ] || continue
	dst="$here/vendor/wl/$rel"
	mkdir -p "$(dirname "$dst")"

	if [ -n "$LOCAL" ]; then
		log "copying vendor/wl/$rel from $LOCAL"
		cp -f "$LOCAL/$SUBDIR/$rel" "$dst"
	else
		log "downloading vendor/wl/$rel"
		download "https://raw.githubusercontent.com/$REPO/$COMMIT/$SUBDIR/$rel" "$dst"
	fi

	got=$(sha256 "$dst")
	if [ "$got" != "$want" ]; then
		rm -f "$dst"
		die "$(printf 'checksum mismatch for vendor/wl/%s\n  expected %s\n  got      %s' \
			"$rel" "$want" "$got")"
	fi
	if [ "$rel" = "arm-uclibc/wl" ]; then
		chmod 0755 "$dst"
	fi
	log "vendor/wl/$rel ok"
done || rc=$?

[ "$rc" -eq 0 ] || exit "$rc"
log "done - both blobs are in place"
