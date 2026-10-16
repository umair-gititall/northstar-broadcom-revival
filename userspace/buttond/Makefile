# broadcom-wl-buttond: userspace GPIO button/switch daemon for the WZR-1750DHP.
# Single translation unit, links only libc. Built by the SDK's TARGET_CC like
# the rest of userspace/ (the package Makefile passes CC= and CFLAGS=).

CC ?= cc
CFLAGS ?= -Os -Wall

all: broadcom-wl-buttond

broadcom-wl-buttond: buttond.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f broadcom-wl-buttond

.PHONY: all clean
