/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Entry points the blob reaches by objcopy --redefine-sym (see the Makefile),
 * plus shadow-layer lifecycle. Declared here so both translation units agree
 * and the compiler can check them.
 *
 * The blob's timer arguments are typed void * on purpose: they point at
 * 2.6.36-layout timer_lists, which are NOT struct timer_list as this kernel
 * defines it. Only wl_shadow_timer.c may interpret them, via the generated
 * offsets in shadow/offsets-2.6.36.h.
 */
#ifndef WL_SHADOW_H
#define WL_SHADOW_H

#include <linux/types.h>
#include <linux/netdevice.h>

/* 2.6.36 signatures, not this kernel's. */
void wl_shim_init_timer_key(void *blob_timer, const char *name, void *key);
void wl_shim_add_timer(void *blob_timer);
int  wl_shim_del_timer(void *blob_timer);

void wl_shadow_timer_exit(void);

/* skb reroute targets and wl_shadow_skb_exit() live in wl_shadow_skb.h. */
#include "wl_shadow_skb.h"

/* net_device reroute targets. Blob-visible device pointers are void * for the
 * same reason as skbs: they address 2.6.36-layout shadows. */
void *wl_shim_alloc_netdev_mq(int sizeof_priv, const char *name,
			      void (*setup)(struct net_device *),
			      unsigned int queue_count);
int   wl_shim_register_netdev(void *blob_dev);
int   wl_shim_unregister_netdev(void *blob_dev);
void  wl_shim_free_netdev(void *blob_dev);
void  wl_shim___netif_schedule(void *fake_qdisc);

void wl_shadow_netdev_exit(void);
void wl_shadow_nvram_exit(void);

/* pci reroute targets; blob-visible pci_dev pointers are 2.6.36 shadows. */
int  wl_shim___pci_register_driver(void *blob_drv, struct module *owner,
				   const char *mod_name);
void wl_shim_pci_unregister_driver(void *blob_drv);
int  wl_shim_pci_enable_device(void *blob_pdev);
void wl_shim_pci_disable_device(void *blob_pdev);
void wl_shim_pci_set_master(void *blob_pdev);
void wl_shadow_pci_exit(void);

/* outer_cache is a DATA symbol reroute, not a function - see wl_shadow_l2c.c */
void wl_shadow_l2c_init(void);
void wl_shadow_debug_init(void);

/* tasklet reroute targets; blob-visible pointers are 2.6.36 tasklet_structs. */
void wl_shim_tasklet_init(void *blob_t, void (*func)(unsigned long),
			  unsigned long data);
void wl_shim___tasklet_schedule(void *blob_t);
void wl_shim_tasklet_kill(void *blob_t);
void wl_shadow_tasklet_exit(void);

struct proc_dir_entry;
void wl_shim_remove_proc_entry(const char *name, struct proc_dir_entry *parent);

/* The blob's own module entry, renamed out of the way by objcopy. */
int  wl_blob_init_module(void);
void wl_blob_cleanup_module(void);

/*
 * TX-ring tracing budget, set with the dma_trace= module parameter. Counts
 * down, so `insmod wl.ko dma_trace=60` gives 60 lines and then silence -
 * enough to see the first packets of a session without drowning the console.
 * Lives in wl_shadow_debug.c; read from vendor/shared/hnddma.c.
 */
extern int wl_dma_trace;

/*
 * Receive tracing budget, set with the rx_trace= module parameter. Same
 * counting-down shape as wl_dma_trace. Dumps each frame as handed to
 * netif_rx(), from the mac header, which is what the bridge reads.
 */
extern int wl_rx_trace;

/*
 * Synthesized-XID drop tracing, set with the xid_trace= module parameter.
 * Same counting-down shape as wl_dma_trace. Logs each IEEE 802.2 XID roaming
 * frame the kernel floods back to a radio, which the transmit trampoline
 * discards before the blob can mistake it for a station move. See the long
 * comment in wl_tramp_start_xmit().
 */
extern int wl_xid_trace;

#endif /* WL_SHADOW_H */
