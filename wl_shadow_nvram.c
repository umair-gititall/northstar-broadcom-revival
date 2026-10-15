// SPDX-License-Identifier: GPL-2.0
/*
 * Broadcom's NVRAM API, backed by the mainline kernel's Northstar NVRAM
 * driver.
 *
 * The blob and Broadcom's shared sources read calibration and board data
 * through nvram_get(). In FreshTomato that came from its own NVRAM driver,
 * which is not vendored here. It does not need to be: Tomato64's bcm53xx
 * kernel already sets CONFIG_BCM47XX_NVRAM=y, and the mainline driver exports
 * bcm47xx_nvram_get_contents() - the same NVRAM, same flash region, read by
 * in-tree code.
 *
 * So this is a real implementation rather than a stub. Without it the driver
 * would come up with no SROM data at all.
 *
 * The contents are fetched once and parsed into the standard NUL-separated
 * "name=value" run that Broadcom's API expects, so nvram_get() can hand back
 * long-lived pointers into it, exactly as the original did.
 */

#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/bcm47xx_nvram.h>

static char *wl_nvram_buf;	/* NUL-separated name=value entries */
static size_t wl_nvram_len;

/*
 * Runtime NVRAM defaults.
 *
 * Broadcom's wl driver is built to sit on top of FreshTomato, whose /sbin/rc
 * commits a set of wl_* keys into NVRAM every boot. A stock OpenWrt bcm53xx
 * NVRAM partition only carries the CFE/factory keys (boardtype, devpath0,
 * 0:sromrev, pci/1/1/..., ...) - the runtime wl_ keys are not there.
 *
 * wl_module_init() reads several of them through getvar() (= nvram_get()) and
 * is careless with two of them:
 *
 *   str   = getvar(NULL, "wl_ifnames");        // -> nvram_get()
 *   strspn(str, " ");                          // no NULL check
 *
 *   getvar(NULL, "wl0_igs") -> bcm_strtoul();  // no NULL check, per radio
 *
 * Those are the only two unchecked getvar() call sites in the whole blob
 * (everything else NULL-tests first). On FreshTomato wl_ifnames is always
 * "wl0 wl1" (defaults.c, BCM53XX) and the per-radio wlN_igs are present, so
 * the missing checks never fire. On stock OpenWrt the very first call -
 * strspn(NULL, " ") - faults at kernel strspn with r0 == 0, which is exactly
 * the oops at PC 0xc0878528 / LR wl .init.text+0x80 that this fixes.
 *
 * Supply the keys FreshTomato would have supplied. Lookups first fall through
 * to the real NVRAM, so a partitioned NVRAM that does define them still wins.
 */
static char wl_def_ifnames[] = "wl0 wl1";
static char wl_def_zero[] = "0";

static const struct wl_nvram_default {
	const char *name;
	char *value;
} wl_nvram_defaults[] = {
	{ "wl_ifnames",	wl_def_ifnames },
	{ "wl0_igs",	wl_def_zero },
	{ "wl1_igs",	wl_def_zero },
};

static char *wl_nvram_default_lookup(const char *name)
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(wl_nvram_defaults); i++)
		if (!strcmp(name, wl_nvram_defaults[i].name))
			return wl_nvram_defaults[i].value;
	return NULL;
}

static int wl_nvram_load(void)
{
	size_t len = 0;
	char *src;

	if (wl_nvram_buf)
		return 0;

	src = bcm47xx_nvram_get_contents(&len);
	if (!src || !len) {
		pr_err("wl: no NVRAM from bcm47xx_nvram_get_contents()\n");
		return -ENODEV;
	}

	/* +1 so the run is always double-NUL terminated. */
	wl_nvram_buf = kzalloc(len + 1, GFP_KERNEL);
	if (!wl_nvram_buf) {
		bcm47xx_nvram_release_contents(src);
		return -ENOMEM;
	}
	memcpy(wl_nvram_buf, src, len);
	wl_nvram_len = len;
	bcm47xx_nvram_release_contents(src);

	/*
	 * Deliberately no newline translation. An earlier version converted
	 * '\n' to '\0' on the assumption the body was newline-separated. It is
	 * not - Broadcom NVRAM is NUL-separated, as bcm47xx_nvram_getenv()
	 * itself shows - and this router's NVRAM has values that legitimately
	 * contain newlines, including the radio calibration entries
	 * pci/1/1/rpcal2g and pci/2/1/rpcal5gb0..b3, plus rrule0 with three
	 * embedded ones. Converting them would have split those values and
	 * manufactured bogus keys out of the remainders.
	 */

	pr_info("wl: NVRAM loaded (%zu bytes)\n", wl_nvram_len);
	return 0;
}

int nvram_init(void *sih)
{
	return wl_nvram_load();
}

char *nvram_get(const char *name)
{
	size_t nlen;
	char *p;

	if (!name)
		return NULL;

	if (!wl_nvram_load()) {
		nlen = strlen(name);
		for (p = wl_nvram_buf; p < wl_nvram_buf + wl_nvram_len; p += strlen(p) + 1) {
			if (!*p)
				continue;
			if (!strncmp(p, name, nlen) && p[nlen] == '=')
				return p + nlen + 1;
		}
	}

	return wl_nvram_default_lookup(name);
}

int nvram_getall(char *buf, int count)
{
	if (wl_nvram_load())
		return -1;
	if (count < 0 || (size_t)count < wl_nvram_len + 1)
		return -1;

	memcpy(buf, wl_nvram_buf, wl_nvram_len);
	buf[wl_nvram_len] = '\0';
	return 0;
}

void wl_shadow_nvram_exit(void)
{
	kfree(wl_nvram_buf);
	wl_nvram_buf = NULL;
	wl_nvram_len = 0;
}
