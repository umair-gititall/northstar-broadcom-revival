# Kbuild for the wl blob link experiment.
#
# kbuild reads THIS file (not ./Makefile) when invoked as `make -C $KDIR M=$PWD`,
# so the wrapper Makefile in this directory cannot recurse into itself.
#
# wl_apsta.o comes from wl_apsta.o_shipped via kbuild's prebuilt-object rule
# (scripts/Makefile.lib: `$(obj)/%: $(src)/%_shipped`). The wrapper Makefile
# generates that file by objcopy'ing FreshTomato's blob.

obj-m := wl.o

wl-objs := wl_apsta.o wl_shim_removed.o \
            wl_shadow_timer.o wl_shadow_skb.o wl_shadow_netdev.o \
            wl_shadow_nvram.o wl_shadow_ctfstubs.o \
            wl_shadow_pci.o wl_shadow_l2c.o wl_shadow_debug.o \
            wl_shadow_tasklet.o

# Phase B only: auto-generated weak stubs for the Tier-1 Broadcom symbols.
# Uncomment after running scripts/gen-stubs.sh.
# wl-objs += wl_stubs_generated.o

# The blob was built for ARMv7-A / Thumb-2 / soft-float EABI with 8-byte
# alignment (readelf -A). Nothing here needs to match that for the *link*,
# but the final module does, so keep the kernel's own ARM flags.
# --- Broadcom shared sources ------------------------------------------
# The file list and flags are FreshTomato's, extracted by evaluating
# vendor/wl/config/{wlconfig_lx_shared,wl.mk} with make, plus the extra defines
# from drivers/net/hnd/Makefile in its kernel tree.
#
# Getting WLFLAGS exactly right is not cosmetic: Broadcom's own struct layouts
# (osl_t, si_t, ...) depend on these defines, so a different set would make
# this code disagree with the blob about its own structures.
# Single source of truth, shared with shadow/mkoffsets.sh - see shadow/wlflags
# for where each flag comes from. They were previously duplicated here and
# omitted from the offsets probe, which measured a struct sk_buff the blob
# never sees: CTF inserts fields immediately after ->cb, shifting everything
# after it.
WLFLAGS := $(strip $(shell cat $(src)/shadow/wlflags))

# shadow/bcm-override must precede vendor/include: it interposes on
# <linux_osl.h> so the PKT* macros address the shadow sk_buff.
# Per-packet header-move recording, for chasing receive-path bugs. OFF by
# default and deliberately compile-time rather than runtime: the ring lives in
# every skb shadow, and carrying it pushes the allocation from the kmalloc-256
# slab into kmalloc-512 - doubling the per-packet footprint on both hot paths.
# A static_assert in wl_shadow_skb.h enforces that, so the cost cannot creep
# back in unnoticed.
#
#   make WL_SKB_OPS_TRACE=1
#
# Everything else (dma_trace, rx_trace) stays compiled in and is switched at
# runtime, because a global read and a branch cost nothing worth measuring.
ifdef WL_SKB_OPS_TRACE
WLDEBUG := -DWL_SKB_OPS_TRACE
endif

ccflags-y := -Wno-unused-function -Wno-missing-prototypes \
	     -I$(src) -I$(src)/shadow/bcm-override -I$(src)/vendor/include -I$(src)/vendor/common-include \
	     -I$(src)/vendor/shared/bcmwifi/include \
	     $(WLFLAGS) $(WLDEBUG)

# OpenWrt kernels build with CONFIG_WERROR=y, so any warning is fatal. This is
# a vendored 2.6.36 blob port: the shim deliberately re-declares APIs that the
# modern headers no longer declare (-Wmissing-declarations) and calls the
# long-deprecated flush_workqueue()/flush_scheduled_work() (-Wattribute-warning).
# Keep the output visible but non-fatal, as it was under Buildroot (no WERROR).
ccflags-y += -Wno-error

# Ported one at a time; each replaces a slice of the 176 weak stubs.
# Full list: aiutils bcmotp bcmsrom bcmutils hnddma hndpmu linux_osl nicpci
#            sbutils siutils
# Enable file by file as each one's FreshTomato-patched-field overrides land in
# shadow/bcm-override/linux_osl.h. bcmutils.o alone builds clean today and
# resolves 38 of the 176; the full list is
#   aiutils bcmotp bcmsrom bcmutils hnddma hndpmu linux_osl nicpci sbutils siutils
# See shadow/README.md "Compiling vendor/shared" for what is left.
BCM_SHARED := aiutils.o bcmotp.o bcmsrom.o bcmutils.o hnddma.o hndpmu.o \
	      linux_osl.o nicpci.o sbutils.o siutils.o
wl-objs += $(addprefix vendor/shared/,$(BCM_SHARED))
