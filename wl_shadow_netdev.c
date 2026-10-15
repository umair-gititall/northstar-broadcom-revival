// SPDX-License-Identifier: GPL-2.0
/*
 * Shadow layer, part 3 of 3: struct net_device.
 *
 * See wl_shadow_netdev.h for the layout rationale and
 * shadow/netdev-findings.md for how the field set was established.
 *
 * Rerouted by objcopy --redefine-sym in the Makefile:
 *   alloc_netdev_mq  register_netdev  unregister_netdev  free_netdev
 *   __netif_schedule
 */

#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/if_ether.h>
#include <linux/list.h>
#include <linux/spinlock.h>
#include <linux/errno.h>

#include "wl_shadow_netdev.h"
#include "wl_shadow_pci.h"
#include "wl_shadow_skb.h"
#include "wl_shadow.h"

/* Handful of interfaces at most, so a list beats a hash table here. */
static LIST_HEAD(wl_netdev_shadows);
static DEFINE_SPINLOCK(wl_netdev_lock);

static inline struct wl_netdev_shadow *to_shadow(void *blob_dev)
{
	struct wl_netdev_shadow *sh = (struct wl_netdev_shadow *)blob_dev;

	if (!sh)
		return NULL;
	if (sh->magic != WL_NETDEV_SHADOW_MAGIC) {
		pr_err_once("wl: %p is not a net_device shadow (magic %08x)\n",
			    blob_dev, sh->magic);
		return NULL;
	}
	return sh;
}

/* netdev_priv(real) holds the back-pointer, so this is O(1). */
static inline struct wl_netdev_shadow *shadow_of(struct net_device *real)
{
	return *(struct wl_netdev_shadow **)netdev_priv(real);
}

/* Read a callback out of the blob's 2.6.36-laid-out net_device_ops. */
static inline void *blob_ndo(void *ops, unsigned int off)
{
	return ops ? *(void **)((u8 *)ops + off) : NULL;
}

/*
 * An empty struct list_head points at itself; kzalloc leaves it NULL. The blob
 * walks dev->mc.list via netdev_for_each_mc_addr(), so a zeroed head means it
 * dereferences NULL on the very first iteration - which is exactly how
 * _wl_set_multicast_list() died.
 */
static void shadow_init_list_head(struct wl_netdev_shadow *sh, unsigned int off)
{
	void **lh = (void **)(sh->s236 + off);

	lh[0] = lh[1] = (void *)(sh->s236 + off);	/* next = prev = self */
}

/*
 * Mirror the real device's readiness bits into the shadow.
 *
 * register_netdevice() sets __LINK_STATE_PRESENT and __dev_open() sets
 * __LINK_STATE_START - both on the REAL device, which the blob never sees. It
 * reads ->state off the shadow instead, and an all-zero word there means
 * wl_sendup() treats every VIF frame as "interface not ready" and frees it.
 * That silently killed the EAPOL exchange on a virtual BSS, so clients could
 * never complete the WPA handshake.
 *
 * Only the first three bits are copied: START, PRESENT and NOCARRIER hold the
 * same positions in 2.6.36 and 6.12, while everything above them has been
 * reordered and extended since, and the blob is not known to read any of it.
 */
static void shadow_sync_state(struct wl_netdev_shadow *sh)
{
	const unsigned long mask = (1UL << __LINK_STATE_START) |
				   (1UL << __LINK_STATE_PRESENT) |
				   (1UL << __LINK_STATE_NOCARRIER);

	wl236_nd_state(sh->s236) = READ_ONCE(sh->real->state) & mask;
}

/* ---- trampolines ----------------------------------------------------- */
/*
 * Each converts the kernel's real objects into the blob's shadows. The blob's
 * callbacks then do netdev_priv(dev) == dev + 896, which lands in the shadow's
 * own private area - the whole point of the exercise.
 */

static int wl_tramp_open(struct net_device *real)
{
	struct wl_netdev_shadow *sh = shadow_of(real);
	int (*fn)(void *) = blob_ndo(sh->blob_ops, WL236_NET_DEVICE_OPS_NDO_OPEN);

	/* __dev_open() has already set __LINK_STATE_START by this point. */
	shadow_sync_state(sh);
	return fn ? fn(sh->s236) : -EOPNOTSUPP;
}

static int wl_tramp_stop(struct net_device *real)
{
	struct wl_netdev_shadow *sh = shadow_of(real);
	int (*fn)(void *) = blob_ndo(sh->blob_ops, WL236_NET_DEVICE_OPS_NDO_STOP);

	/* __dev_close_many() clears __LINK_STATE_START before calling us. */
	shadow_sync_state(sh);
	return fn ? fn(sh->s236) : 0;
}

/*
 * Counts the transmits the blob refused. Nothing in the port is known to
 * produce them, which is exactly why it is worth knowing whether they happen:
 * a refused transmit is retried by the kernel with the same skb, and every
 * retry makes another shadow for a packet the blob may still be holding.
 */
static atomic_t wl_xmit_notok = ATOMIC_INIT(0);

/*
 * Broadcom's wlc_ap() synthesizes an IEEE 802.2 XID frame on every station
 * association and hands it to wl_sendup() so the local bridge learns the
 * station's MAC on the wireless port. That is the frame the rx_trace output
 * shows as `ffffffffffff <STA_MAC> 0006 | 0001af...`: DA broadcast, the
 * station as source, a 2-byte length of 6 and six bytes of LLC XID payload.
 *
 * The learning half of that is fine and is left alone. The trouble is the
 * second half. The bridge floods the broadcast back out every port, radios
 * included, and a radio that receives it runs:
 *
 *   wl_start() -> wl->txq -> wl_start_txqwork()   (sets cb bit 0x100 on every
 *                                                  packet it hands down)
 *            -> wlc_sendpkt()
 *
 * wlc_sendpkt(), seeing a host-originated (0x100) group-addressed 802.3 frame
 * whose length field is 6 and whose source address matches an SCB, reads it
 * as an L2 roaming advertisement and calls wlc_scbfree() on that station. On
 * a single AP the only SCB that can match is the one the station just
 * created, so it is deleted about ten milliseconds after association; every
 * data frame afterwards lands on "non-associated station", and the driver
 * deauths the client with reason 7.
 *
 * The XID exists only to update a bridge FDB, and that already happened on
 * the receive path - putting it on the air serves no purpose. Drop it here,
 * at the one point where a kernel packet crosses in to a radio, before the
 * blob can turn it into a roaming notification. Note the 0x100 bit cannot be
 * cleared to achieve the same thing: the blob sets it itself, inside
 * wl_start_txqwork(), after this trampoline has already returned.
 */
static bool wl_xid_roaming_frame(const struct sk_buff *skb)
{
	const u8 *e;

	/* Ethernet header plus the 6-byte 802.2 payload. */
	if (skb->len < ETH_HLEN + 6 || !skb->data)
		return false;

	e = skb->data;
	if (!(e[0] & 0x01))				/* DA group-addressed */
		return false;
	if (e[12] != 0x00 || e[13] != 0x06)		/* 802.3 length == 6 */
		return false;
	if (e[14] != 0x00 || e[15] != 0x01 || e[16] != 0xaf)	/* LLC XID */
		return false;

	return true;
}

static netdev_tx_t wl_tramp_start_xmit(struct sk_buff *skb, struct net_device *real)
{
	struct wl_netdev_shadow *sh = shadow_of(real);
	int (*fn)(void *, void *) =
		blob_ndo(sh->blob_ops, WL236_NET_DEVICE_OPS_NDO_START_XMIT);
	void *bskb;
	int ret;

	if (!fn) {
		kfree_skb(skb);
		return NETDEV_TX_OK;
	}

	/*
	 * Swallow the driver's own XID roaming frame before wlc_sendpkt() can
	 * mistake it for a station move and free the station's SCB. See
	 * wl_xid_roaming_frame() for the whole story.
	 */
	if (wl_xid_roaming_frame(skb)) {
		if (wl_xid_trace > 0) {
			wl_xid_trace--;
			pr_info("wl: %s: dropped synthesized XID roaming frame "
				"from %pM (kept the station's SCB)\n",
				real->name, skb->data + ETH_ALEN);
		}
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	/*
	 * The packet's head must be ours alone before the blob touches it.
	 *
	 * A bridge floods broadcast and multicast frames to every port using
	 * skb_clone(), which duplicates the sk_buff but SHARES the data buffer.
	 * The blob then prepends its 124-byte transmit header into that buffer
	 * via PKTPUSH. With both radios in one bridge, wl0 and wl1 are handed
	 * two clones of the same frame and each writes its own header into the
	 * one shared buffer - so whichever runs second overwrites the first.
	 *
	 * That is exactly what the transmit-status errors were: the ring trace
	 * showed a packet queued with fid=0x1201 reclaimed as fid=0x0c01, and
	 * 0x0c01 was the frame ID the *other* radio had written microseconds
	 * earlier. Five for five, always the other radio's ID. The hardware had
	 * transmitted the right frame; only the driver's read-back was wrong,
	 * because the header it wrote had been overwritten in place.
	 *
	 * skb_cow_head() with 0 extra headroom reallocates the linear area if
	 * and only if the head is cloned, which is the condition that matters
	 * here - headroom itself was never short, or skb_push() would have
	 * panicked rather than corrupted.
	 */
	if (skb_cow_head(skb, 0)) {
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	bskb = wl_skb_wrap(skb);
	if (!bskb) {
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	/*
	 * Deliberately no wl_skb_shadow_put() on the success path. wl_start()
	 * queues the packet on its own list (pktq, via PKTLINK on the shadow)
	 * and releases it later through osl_pktfree(), which is compiled now
	 * and does call wl_skb_shadow_put().
	 */
	ret = fn(bskb, sh->s236);

	/*
	 * Anything but NETDEV_TX_OK means the blob did not take the packet, and
	 * the kernel will hand us the same skb again - at which point we would
	 * wrap it a second time. Both values are 0 and 0x10 in 2.6.36 and 6.12,
	 * so the return needs no translation, only watching.
	 *
	 * Not freeing the shadow here on purpose: the contract says a BUSY
	 * return means the packet was not queued, but this blob's actual
	 * behaviour is not established, and freeing a wrapper it still holds
	 * would be a use-after-free in a softirq. Leak one and say so - if this
	 * ever fires, that is the thing to chase, and the counter says how hard.
	 */
	if (unlikely(ret != NETDEV_TX_OK)) {
		atomic_inc(&wl_xmit_notok);
		pr_warn_once("wl: %s: blob's ndo_start_xmit returned %d, not "
			     "NETDEV_TX_OK; the kernel will retry this skb and "
			     "it will be wrapped again\n", real->name, ret);
	}
	return ret;
}

static void wl_tramp_set_rx_mode(struct net_device *real)
{
	struct wl_netdev_shadow *sh = shadow_of(real);
	/* 2.6.36's ndo_set_multicast_list; removed in 3.1 in favour of
	 * ndo_set_rx_mode, same signature. */
	void (*fn)(void *) =
		blob_ndo(sh->blob_ops, WL236_NET_DEVICE_OPS_NDO_SET_MULTICAST_LIST);
	unsigned int allmulti;

	if (!fn)
		return;

	/*
	 * The address lists themselves are not mirrored: struct netdev_hw_addr
	 * differs between the two kernels, so building shadow entries would be
	 * a third layout to track. Instead the lists stay empty (self-linked)
	 * and, if the kernel has any multicast addresses registered, the blob
	 * is told ALLMULTI so it opens the filter rather than enumerating.
	 *
	 * That is deliberately less selective than the real thing - the driver
	 * accepts all multicast instead of a chosen set - but it is correct
	 * behaviour rather than an approximation of it, and the hardware filter
	 * is an optimisation. Mirroring the lists properly is the better fix if
	 * multicast load ever matters.
	 */
	allmulti = real->allmulti;
	if (netdev_mc_count(real) > 0)
		allmulti++;

	wl236_nd_flags(sh->s236) = real->flags;
	WL236_ND(sh->s236, WL236_NET_DEVICE_PROMISCUITY, unsigned int) =
		real->promiscuity;
	WL236_ND(sh->s236, WL236_NET_DEVICE_ALLMULTI, unsigned int) = allmulti;

	fn(sh->s236);
}

static int wl_tramp_set_mac_address(struct net_device *real, void *addr)
{
	struct wl_netdev_shadow *sh = shadow_of(real);
	int (*fn)(void *, void *) =
		blob_ndo(sh->blob_ops, WL236_NET_DEVICE_OPS_NDO_SET_MAC_ADDRESS);
	int ret;

	if (!fn)
		return -EOPNOTSUPP;

	ret = fn(sh->s236, addr);
	if (!ret)
		dev_addr_set(real, sh->mac);	/* the blob wrote into sh->mac */
	return ret;
}

static int wl_tramp_do_ioctl(struct net_device *real, struct ifreq *ifr, int cmd)
{
	struct wl_netdev_shadow *sh = shadow_of(real);
	int (*fn)(void *, struct ifreq *, int) =
		blob_ndo(sh->blob_ops, WL236_NET_DEVICE_OPS_NDO_DO_IOCTL);

	return fn ? fn(sh->s236, ifr, cmd) : -EOPNOTSUPP;
}

/*
 * wl's private ioctls are SIOCDEVPRIVATE, which 2.6.36 delivered through
 * ndo_do_ioctl. Since 5.15 they arrive here instead, with the user pointer
 * passed separately rather than in ifr->ifr_data. Put it back where the blob
 * expects to find it.
 */
static int wl_tramp_siocdevprivate(struct net_device *real, struct ifreq *ifr,
				   void __user *data, int cmd)
{
	struct wl_netdev_shadow *sh = shadow_of(real);
	int (*fn)(void *, struct ifreq *, int) =
		blob_ndo(sh->blob_ops, WL236_NET_DEVICE_OPS_NDO_DO_IOCTL);

	if (!fn)
		return -EOPNOTSUPP;
	ifr->ifr_data = data;
	return fn(sh->s236, ifr, cmd);
}

static struct net_device_stats *wl_tramp_get_stats(struct net_device *real)
{
	struct wl_netdev_shadow *sh = shadow_of(real);
	void *(*fn)(void *) =
		blob_ndo(sh->blob_ops, WL236_NET_DEVICE_OPS_NDO_GET_STATS);
	void *s;

	if (fn && (s = fn(sh->s236)))
		/* Safe because the layouts are identical - see the
		 * static_assert in the header. */
		memcpy(&sh->stats, s, WL236_NET_DEVICE_STATS_SIZEOF);
	return &sh->stats;
}

/*
 * ethtool get_drvinfo. Not a nicety: libshared's wl_probe() does not use a wl
 * ioctl at all - it calls wl_get_dev_type(), which is ETHTOOL_GDRVINFO, and
 * rejects anything whose ->driver does not start with "wl". Everything that
 * enumerates wireless interfaces gates on wl_probe(), silently: foreach_wif()
 * (so httpd emits no wl0.1_* nvram and the GUI shows no VIFs), eapd's
 * nas_app_enabled() and eapd_add_interface() (so no br1 socket, so no EAPOL,
 * so no WPA handshake on a guest SSID).
 *
 * The primary interface survived without this because the blob gives it a
 * parent via SET_NETDEV_DEV, and ethtool_get_drvinfo() falls back to
 * parent->driver->name - which is "wl". _wl_add_if() sets no parent on a VIF,
 * so that fallback is not available and the ioctl returns -EOPNOTSUPP.
 *
 * This is the one place the blob's 2.6.36 ethtool_ops is worth reaching into,
 * and it is safe to: the offset is verified against the relocations and both
 * kernels lay struct ethtool_drvinfo out identically. The blob memsets all 196
 * bytes of its argument, ->cmd included, so it gets a scratch struct and only
 * the two fields it actually fills are copied back.
 */
static_assert(sizeof(struct ethtool_drvinfo) == WL236_ETHTOOL_DRVINFO_SIZEOF,
	      "ethtool_drvinfo layout diverged from the one the blob memsets");

static void wl_tramp_get_drvinfo(struct net_device *real,
				 struct ethtool_drvinfo *info)
{
	struct wl_netdev_shadow *sh = shadow_of(real);
	void (*fn)(void *, void *) =
		blob_ndo(sh->blob_ethtool_ops, WL236_ETHTOOL_OPS_GET_DRVINFO);
	struct ethtool_drvinfo blob_info;

	if (!fn)
		return;

	fn(sh->s236, &blob_info);
	blob_info.driver[sizeof(blob_info.driver) - 1] = '\0';
	blob_info.version[sizeof(blob_info.version) - 1] = '\0';
	strscpy(info->driver, blob_info.driver, sizeof(info->driver));
	strscpy(info->version, blob_info.version, sizeof(info->version));
}

static void build_real_ops(struct wl_netdev_shadow *sh)
{
	void *ops = wl236_nd_netdev_ops(sh->s236);

	sh->blob_ops = ops;
	memset(&sh->real_ops, 0, sizeof(sh->real_ops));
	if (!ops) {
		pr_warn("wl: no netdev_ops in shadow %p\n", sh->s236);
		return;
	}

	if (blob_ndo(ops, WL236_NET_DEVICE_OPS_NDO_OPEN))
		sh->real_ops.ndo_open = wl_tramp_open;
	if (blob_ndo(ops, WL236_NET_DEVICE_OPS_NDO_STOP))
		sh->real_ops.ndo_stop = wl_tramp_stop;
	if (blob_ndo(ops, WL236_NET_DEVICE_OPS_NDO_START_XMIT))
		sh->real_ops.ndo_start_xmit = wl_tramp_start_xmit;
	if (blob_ndo(ops, WL236_NET_DEVICE_OPS_NDO_SET_MULTICAST_LIST))
		sh->real_ops.ndo_set_rx_mode = wl_tramp_set_rx_mode;
	if (blob_ndo(ops, WL236_NET_DEVICE_OPS_NDO_SET_MAC_ADDRESS))
		sh->real_ops.ndo_set_mac_address = wl_tramp_set_mac_address;
	if (blob_ndo(ops, WL236_NET_DEVICE_OPS_NDO_GET_STATS))
		sh->real_ops.ndo_get_stats = wl_tramp_get_stats;
	if (blob_ndo(ops, WL236_NET_DEVICE_OPS_NDO_DO_IOCTL)) {
		sh->real_ops.ndo_do_ioctl = wl_tramp_do_ioctl;
		sh->real_ops.ndo_siocdevprivate = wl_tramp_siocdevprivate;
	}

	sh->real->netdev_ops = &sh->real_ops;
}

/* ---- rerouted entry points ------------------------------------------ */

/*
 * 2.6.36: struct net_device *alloc_netdev_mq(int sizeof_priv, const char *name,
 *                                            void (*setup)(struct net_device *),
 *                                            unsigned int queue_count)
 */
void *wl_shim_alloc_netdev_mq(int sizeof_priv, const char *name,
			      void (*setup)(struct net_device *),
			      unsigned int queue_count)
{
	struct wl_netdev_shadow *sh;
	unsigned long flags;

	if (sizeof_priv > WL236_NETDEV_PRIV_SIZE)
		pr_warn("wl: sizeof_priv %d exceeds the %d bytes the shadow reserves\n",
			sizeof_priv, WL236_NETDEV_PRIV_SIZE);

	/*
	 * The blob passes the kernel's own ether_setup here (confirmed by
	 * relocation), which must run against the REAL device, not the shadow.
	 * Anything else would expect a 2.6.36 device and cannot be forwarded.
	 */
	if (setup != ether_setup) {
		pr_err("wl: alloc_netdev_mq with an unexpected setup callback %pS; "
		       "not forwarding it\n", setup);
		setup = ether_setup;
	}

	sh = kzalloc(sizeof(*sh), GFP_KERNEL);
	if (!sh)
		return NULL;

	/* One pointer of private data: the back-reference for shadow_of(). */
	sh->real = alloc_netdev_mqs(sizeof(struct wl_netdev_shadow *), name,
				    NET_NAME_UNKNOWN, setup,
				    queue_count, queue_count);
	if (!sh->real) {
		kfree(sh);
		return NULL;
	}
	*(struct wl_netdev_shadow **)netdev_priv(sh->real) = sh;

	sh->magic = WL_NETDEV_SHADOW_MAGIC;

	/* Point the shadow's pointer fields at storage we own. 2.6.36's
	 * alloc_netdev_mq() left dev_addr valid, and the blob relies on that:
	 * it reads the pointer and memcpy()s into it before registering. */
	wl236_nd_dev_addr(sh->s236) = sh->mac;
	wl236_nd_tx(sh->s236)       = sh->fake_txq;
	wl236_txq_dev(sh->fake_txq) = sh->s236;

	/*
	 * The blob reads dev->name off the shadow - notably as the IRQ name for
	 * request_irq(), which produced "__proc_create: name len 0" when it was
	 * empty. alloc_netdev_mqs() has put the template there; copy it over.
	 * register_netdev() later replaces it with the final name, which
	 * wl_shim_register_netdev() copies back.
	 */
	strscpy((char *)sh->s236 + WL236_NET_DEVICE_NAME, sh->real->name,
		IFNAMSIZ);

	shadow_init_list_head(sh, WL236_NET_DEVICE_UC);
	shadow_init_list_head(sh, WL236_NET_DEVICE_MC);

	/* Mirror what ether_setup() gave the real device, so the blob sees
	 * sane values if it reads them back. */
	wl236_nd_type(sh->s236)  = sh->real->type;
	wl236_nd_mtu(sh->s236)   = sh->real->mtu;
	wl236_nd_flags(sh->s236) = sh->real->flags;

	spin_lock_irqsave(&wl_netdev_lock, flags);
	list_add(&sh->link, &wl_netdev_shadows);
	spin_unlock_irqrestore(&wl_netdev_lock, flags);

	return sh->s236;
}

int wl_shim_register_netdev(void *blob_dev)
{
	struct wl_netdev_shadow *sh = to_shadow(blob_dev);
	void *parent;
	int ret;

	if (!sh)
		return -EINVAL;

	/* Push everything the blob configured on the shadow into the real
	 * device. These are exactly the fields the disassembly showed it
	 * writing; see shadow/netdev-findings.md. */
	sh->real->type = wl236_nd_type(sh->s236);
	dev_addr_set(sh->real, sh->mac);

	/*
	 * The blob's SET_NETDEV_DEV stored &pdev->dev, where pdev is our pci_dev
	 * shadow - so this points into zeroed shadow bytes, not a real device.
	 * Handing it to register_netdev() gave "kobject_add_internal failed for
	 * net (error: -2 parent: (null))" and a cascade of refcount warnings.
	 */
	parent = wl236_nd_parent(sh->s236);
	if (parent) {
		struct device *real_parent = wl_pci_embedded_dev_real(parent);

		if (real_parent)
			SET_NETDEV_DEV(sh->real, real_parent);
		else
			pr_warn("wl: SET_NETDEV_DEV parent %p is not a pci_dev shadow; leaving unset\n",
				parent);
	}

	/*
	 * The name, if the blob changed it since alloc_netdev_mq().
	 *
	 * wl_attach() never does - the primary interface keeps whatever
	 * intf_name gave it - but _wl_add_if() renames every virtual BSS and
	 * WDS interface between allocation and registration, with a
	 * strncpy(dev->name, wlif->name, strlen(wlif->name)) straight into the
	 * shadow (wlif->name having been sprintf'd as "%s%d.%d" -> "wl0.1").
	 * Nothing else carries that across, so without this the interface
	 * registers under the allocation template ("eth%d") and wlconf, nas and
	 * eapd never find the device they were told to configure.
	 *
	 * The blob's strncpy() writes exactly strlen() bytes and does not
	 * terminate; the shadow is kzalloc'd and the field is IFNAMSIZ wide, so
	 * strscpy() bounded by that width is what makes it a C string again.
	 */
	{
		char name[IFNAMSIZ];

		strscpy(name, (char *)sh->s236 + WL236_NET_DEVICE_NAME,
			sizeof(name));
		if (name[0] && strcmp(name, sh->real->name)) {
			pr_info("wl: registering shadow %p as '%s' (was '%s')\n",
				sh->s236, name, sh->real->name);
			strscpy(sh->real->name, name, IFNAMSIZ);
		}
	}

	build_real_ops(sh);

	/*
	 * Only get_drvinfo is forwarded, into an ethtool_ops of our own. The
	 * rest of the blob's 2.6.36 struct stays untouched - it has been
	 * reordered and extended many times since, and a wrong slot there would
	 * be silent corruption. get_drvinfo is the only member the relocations
	 * populate anyway, and wl_probe() cannot see a VIF without it; see
	 * wl_tramp_get_drvinfo().
	 */
	sh->blob_ethtool_ops = wl236_nd_ethtool_ops(sh->s236);
	if (blob_ndo(sh->blob_ethtool_ops, WL236_ETHTOOL_OPS_GET_DRVINFO)) {
		memset(&sh->real_ethtool_ops, 0, sizeof(sh->real_ethtool_ops));
		sh->real_ethtool_ops.get_drvinfo = wl_tramp_get_drvinfo;
		sh->real->ethtool_ops = &sh->real_ethtool_ops;
	}
	else if (sh->blob_ethtool_ops)
		pr_warn("wl: the blob's ethtool_ops has no get_drvinfo; wl_probe() will not see %s\n",
			sh->real->name);

	ret = register_netdev(sh->real);
	if (!ret) {
		/* __LINK_STATE_PRESENT is set on the real device here; the blob
		 * gates its receive path on seeing it in the shadow. */
		shadow_sync_state(sh);

		/* The core may have expanded "eth%d"; let the blob see the
		 * name the interface actually got. */
		strscpy((char *)sh->s236 + WL236_NET_DEVICE_NAME,
			sh->real->name, IFNAMSIZ);
	}
	return ret;
}

int wl_shim_unregister_netdev(void *blob_dev)
{
	struct wl_netdev_shadow *sh = to_shadow(blob_dev);

	if (sh) {
		unregister_netdev(sh->real);
		shadow_sync_state(sh);	/* PRESENT is gone; stop the receive path */
	}
	return 0;
}

void wl_shim_free_netdev(void *blob_dev)
{
	struct wl_netdev_shadow *sh = to_shadow(blob_dev);
	unsigned long flags;

	if (!sh)
		return;

	spin_lock_irqsave(&wl_netdev_lock, flags);
	list_del(&sh->link);
	spin_unlock_irqrestore(&wl_netdev_lock, flags);

	free_netdev(sh->real);
	sh->magic = 0;
	kfree(sh);
}

/*
 * The blob calls this with the fake queue's ->qdisc, which is meaningless to
 * the kernel. It only ever reaches here from its open-coded
 * netif_wake_queue(), and wl_shadow_netdev_txq_bitop() has already done the
 * real wake (netif_tx_wake_queue() performs the schedule itself), so there is
 * nothing left to do.
 */
void wl_shim___netif_schedule(void *fake_qdisc)
{
	pr_debug("wl: __netif_schedule(%p) absorbed by the shadow queue\n",
		 fake_qdisc);
}

/* ---- fake tx queue: the open-coded stop/wake ------------------------ */

int wl_shadow_netdev_txq_bitop(int nr, volatile unsigned long *p, int op, int *old)
{
	struct wl_netdev_shadow *sh, *found = NULL;
	struct netdev_queue *realq;
	unsigned long flags;
	int prev;

	spin_lock_irqsave(&wl_netdev_lock, flags);
	list_for_each_entry(sh, &wl_netdev_shadows, link) {
		if ((void *)p == (void *)&wl236_txq_state(sh->fake_txq)) {
			found = sh;
			break;
		}
	}
	spin_unlock_irqrestore(&wl_netdev_lock, flags);

	if (!found)
		return 0;		/* not ours: fall through to the plain bit op */

	/* Keep the shadow's own copy coherent - the blob reads it back. */
	prev = test_bit(nr, (volatile unsigned long *)p) ? 1 : 0;
	if (op == 2)
		clear_bit(nr, (volatile unsigned long *)p);
	else
		set_bit(nr, (volatile unsigned long *)p);
	if (old)
		*old = prev;

	/*
	 * bit 0 is 2.6.36's __QUEUE_STATE_XOFF. Everything else on this word is
	 * not something the blob is known to use, so leave it shadow-local.
	 */
	if (nr != 0)
		return 1;

	realq = netdev_get_tx_queue(found->real, 0);
	if (op == 2) {
		/* netif_tx_wake_queue() does the test_and_clear and the
		 * __netif_schedule() itself, which is why the blob's own
		 * follow-up __netif_schedule() can be absorbed. */
		if (prev)
			netif_tx_wake_queue(realq);
	} else {
		netif_tx_stop_queue(realq);
	}
	return 1;
}

/* ---- lifecycle ------------------------------------------------------ */

/* ---- lookup, both directions ---------------------------------------- */
/*
 * The skb shadow needs to translate net_device pointers in both directions:
 * a packet's ->dev crossing into the blob must become the shadow, and the
 * ->dev the blob hands to eth_type_trans() must become the real device. Both
 * must be safe on a pointer that is not ours at all, so neither takes the
 * netdev_priv() shortcut shadow_of() uses - a foreign device's private area
 * may not even exist. The list holds one entry per radio, so walking it is
 * cheaper than the cache miss a hash table would cost.
 */
void *wl_netdev_blob_of(struct net_device *real)
{
	struct wl_netdev_shadow *sh;
	unsigned long flags;
	void *ret = NULL;

	if (!real)
		return NULL;

	spin_lock_irqsave(&wl_netdev_lock, flags);
	list_for_each_entry(sh, &wl_netdev_shadows, link) {
		if (sh->real == real) {
			ret = sh->s236;
			break;
		}
	}
	spin_unlock_irqrestore(&wl_netdev_lock, flags);

	return ret;
}

struct net_device *wl_netdev_real_of(void *blob_dev)
{
	struct wl_netdev_shadow *sh;
	unsigned long flags;
	struct net_device *ret = NULL;

	if (!blob_dev)
		return NULL;

	spin_lock_irqsave(&wl_netdev_lock, flags);
	list_for_each_entry(sh, &wl_netdev_shadows, link) {
		if (sh->s236 == (u8 *)blob_dev) {
			ret = sh->real;
			break;
		}
	}
	spin_unlock_irqrestore(&wl_netdev_lock, flags);

	return ret;
}

void wl_shadow_netdev_exit(void)
{
	struct wl_netdev_shadow *sh, *tmp;
	int n = 0;

	/* Anything left here means the blob did not free an interface. Report
	 * and reclaim rather than leak the real devices. */
	list_for_each_entry_safe(sh, tmp, &wl_netdev_shadows, link) {
		list_del(&sh->link);
		if (sh->real)
			free_netdev(sh->real);
		sh->magic = 0;
		kfree(sh);
		n++;
	}
	if (n)
		pr_warn("wl: reclaimed %d net_device shadow(s) at unload\n", n);

	n = atomic_read(&wl_xmit_notok);
	if (n)
		pr_warn("wl: the blob refused %d transmit(s); each one was "
			"retried by the kernel and re-wrapped\n", n);
}
