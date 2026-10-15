# Build the vendored iwinfo subset as a drop-in libiwinfo.so.20230701.
#
# Only the Broadcom `wl' backend is wanted here, but iwinfo_wl.c delegates a
# handful of ops (frequency, txpower, quality, scanlist, freqlist) to the
# generic wext backend, so wext is pulled in with it -- exactly what upstream's
# Makefile does for BACKENDS=wl. nl80211 is deliberately left out: it is the
# only backend that needs libuci/libubus/libnl-tiny, and this board has no
# cfg80211 radio to describe. The uci/ubus helpers in iwinfo_utils.c are
# compiled out (see the USE_NL80211 guards) so the result links against libc
# only.
#
# SPDX-License-Identifier: GPL-2.0-only

CC        ?= gcc
CFLAGS    ?= -Os -fPIC
SOVERSION  = 20230701
BACKENDS   = wl wext

IWINFO_CFLAGS = $(CFLAGS) -Wall -std=gnu99 -fstrict-aliasing \
                -ffunction-sections -fdata-sections -Iinclude
IWINFO_OBJ    = iwinfo_utils.o iwinfo_lib.o

ifneq ($(filter wl wext madwifi,$(BACKENDS)),)
IWINFO_CFLAGS += -DUSE_WEXT
IWINFO_OBJ    += iwinfo_wext.o iwinfo_wext_scan.o
endif

ifneq ($(filter wl,$(BACKENDS)),)
IWINFO_CFLAGS += -DUSE_WL
IWINFO_OBJ    += iwinfo_wl.o
endif

IWINFO_LIB = libiwinfo.so.$(SOVERSION)

all: $(IWINFO_LIB)

%.o: %.c
	$(CC) $(IWINFO_CFLAGS) -c -o $@ $<

$(IWINFO_LIB): $(IWINFO_OBJ)
	$(CC) -shared -static-libgcc -Wl,-soname,$(IWINFO_LIB) -Wl,--gc-sections \
		-o $(IWINFO_LIB) $(IWINFO_OBJ)

clean:
	rm -f *.o $(IWINFO_LIB)

.PHONY: all clean
