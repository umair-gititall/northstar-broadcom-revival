# Vendored copy of tomato64/libnvram (the firmadyne-derived C implementation),
# commit e33692277d475d61a03e0772efeef5c829872f34. See README.md.
#
# Upstream builds with `-shared -nostdlib` because the library is designed to be
# LD_PRELOADed into arbitrary firmware binaries and resolve libc lazily from the
# host process. Our consumers (wlconf, eapd, nas, wldiag) are ordinary musl
# binaries built by OpenWrt's toolchain, so we link against musl normally.
CC     ?= cc
CFLAGS ?= -O2 -fPIC -Wall

SOURCES = nvram.c
TARGET  = libnvram.so

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CC) $(CFLAGS) -shared -o $@ $(SOURCES) $(LDFLAGS)

clean:
	rm -f *.o $(TARGET) test

.PHONY: all clean
