/*
 * broadcom-wl-buttond - userspace GPIO button/switch daemon for the Buffalo
 * WZR-1750DHP (BCM4708).
 *
 * Why this exists: the board's five physical controls are described in the DT
 * (gpio-keys: Reset, AOSS/WPS, Mode, AP, USB-eject on bcma_gpio lines 11-15,
 * all active-low), but the stock `gpio-button-hotplug` module refuses the whole
 * node because the Mode switch uses KEY_SETUP (141), which its fixed keymap
 * does not support:
 *
 *   gpio-keys gpio-keys: does not support key code:141
 *   gpio-keys gpio-keys: probe with driver gpio-keys failed with error -22
 *
 * That kills every button on the board (no /dev/input at all), and the kernel
 * is stock so we cannot patch the driver. Instead we watch the lines from
 * userspace and re-create procd's button hotplug protocol: run
 * /etc/rc.button/<name> (or our own copy under /usr/lib/broadcom-wl/buttons/)
 * with BUTTON/ACTION/SEEN/TYPE in the environment, exactly as procd would have.
 *
 * Interface: sysfs GPIO (/sys/class/gpio). The newer GPIO character device
 * (/dev/gpiochipN + GPIO_GET_LINEHANDLE_IOCTL) is NOT usable here: on this
 * kernel the bcma_gpio controller rejects line requests with EINVAL, while the
 * sysfs interface works and supports edge-triggered poll(). So we export each
 * line, set it to input with edge=both, and poll() its value file -- the same
 * mechanism the classic gpio-keys userspace examples use. Measured cost is
 * zero while idle (poll() sleeps until an edge); a 20ms settle is applied
 * before sampling to debounce.
 *
 * Button semantics follow procd:
 *   - press:      ACTION=pressed, script may exit with N>0 to request an
 *                 ACTION=timeout callback N seconds later while held
 *   - release:    ACTION=released with SEEN=<whole seconds held>
 *   - switches:   TYPE=switch, ACTION=pressed (active) / released (inactive)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/stat.h>

#define GPIODIR		"/sys/class/gpio"
#define DEBOUNCE_MS	20
#define POLL_MS		50
#define MAX_HOLD_S	30

struct control {
	unsigned int	line;
	const char	*name;		/* script basename */
	int		is_switch;
	int		vfd;		/* value file fd, -1 if unavailable */
	int		last;		/* debounced raw (1=released) */
	int		press_t;	/* time_t of last press */
	int		pending_timeout; /* seconds; 0 = none */
	int		timeout_at;	/* time_t */
};

/* bcma_gpio, base 0. Lines from the DT button node:
 *   11 Reset, 12 AOSS/WPS, 13 Mode, 14 AP switch, 15 USB eject.
 * All GPIO_ACTIVE_LOW. */
static struct control controls[] = {
	{ 11, "reset", 0, -1, 1, 0, 0, 0 },
	{ 12, "wps",   0, -1, 1, 0, 0, 0 },
	{ 15, "eject", 0, -1, 1, 0, 0, 0 },
	{ 13, "mode",  1, -1, 1, 0, 0, 0 },
	{ 14, "ap",    1, -1, 1, 0, 0, 0 },
};

#define NCTRL (int)(sizeof(controls) / sizeof(controls[0]))

static const char *script_dirs[] = {
	"/usr/lib/broadcom-wl/buttons",
	"/etc/rc.button",
	NULL,
};

static volatile sig_atomic_t running = 1;
static int have_edge;		/* all lines support edge-triggered poll */

#define STATE_FILE "/var/run/broadcom-wl/buttons.state"

/* Publish every line's debounced level so a switch script can see the whole
 * picture (the back-panel Router/AP/WB slider is more than one line). */
static void write_state(void)
{
	FILE *f;
	int i;

	f = fopen(STATE_FILE, "w");
	if (!f)
		return;
	for (i = 0; i < NCTRL; i++)
		fprintf(f, "%s=%d\n", controls[i].name, controls[i].last);
	fclose(f);
}

static void on_term(int sig)
{
	(void)sig;
	running = 0;
}

static int now_s(void)
{
	return (int)time(NULL);
}

static void run_script(struct control *c, const char *action, int seen)
{
	char *argv[2];
	char seenbuf[16];
	char path[128] = "";
	int i;

	for (i = 0; script_dirs[i]; i++) {
		snprintf(path, sizeof(path), "%s/%s", script_dirs[i], c->name);
		if (access(path, X_OK) == 0)
			break;
		path[0] = '\0';
	}
	if (!path[0])
		return;

	pid_t pid = fork();
	if (pid < 0)
		return;
	if (pid == 0) {
		snprintf(seenbuf, sizeof(seenbuf), "%d", seen);
		setenv("BUTTON", c->name, 1);
		setenv("ACTION", action, 1);
		setenv("SEEN", seenbuf, 1);
		if (c->is_switch)
			setenv("TYPE", "switch", 1);
		argv[0] = path;
		argv[1] = NULL;
		execv(path, argv);
		_exit(127);
	}
	/* Parent: reap and honour procd's "return N -> timeout in N sec". */
	if (!c->is_switch && strcmp(action, "pressed") == 0) {
		int status = 0, w;
		/* Bounded wait: button scripts are quick; a hung one must not
		 * stall the daemon. */
		for (i = 0; i < 50; i++) {
			w = waitpid(pid, &status, WNOHANG);
			if (w == pid)
				break;
			struct timespec ts = { 0, 20 * 1000 * 1000 };
			nanosleep(&ts, NULL);
		}
		if (i == 50) {
			kill(pid, SIGKILL);
			waitpid(pid, &status, 0);
			return;
		}
		if (WIFEXITED(status)) {
			int rc = WEXITSTATUS(status);
			if (rc > 0 && rc <= MAX_HOLD_S) {
				c->pending_timeout = rc;
				c->timeout_at = now_s() + rc;
			}
		}
	} else {
		/* Fire and forget for released/timeout/switch. */
		(void)waitpid(pid, NULL, WNOHANG);
	}
}

static void handle_edge(struct control *c, int raw)
{
	int t = now_s();

	if (raw == c->last)
		return;

	if (c->is_switch) {
		c->last = raw;
		/* raw 0 = pressed/active on these active-low lines. */
		write_state();
		run_script(c, raw ? "released" : "pressed", 0);
		return;
	}

	if (raw == 0) {			/* pressed */
		c->last = 0;
		c->press_t = t;
		c->pending_timeout = 0;
		run_script(c, "pressed", 0);
	} else {			/* released */
		int seen = t - c->press_t;
		if (seen < 0)
			seen = 0;
		c->last = 1;
		c->pending_timeout = 0;
		run_script(c, "released", seen);
	}
}

static void check_timeouts(void)
{
	int t = now_s();
	int i;

	for (i = 0; i < NCTRL; i++) {
		struct control *c = &controls[i];
		if (c->is_switch || !c->pending_timeout)
			continue;
		if (c->last != 0) {	/* released before timeout */
			c->pending_timeout = 0;
			continue;
		}
		if (t >= c->timeout_at) {
			c->pending_timeout = 0;
			run_script(c, "timeout", t - c->press_t);
		}
	}
}

/* Write a string to a sysfs file, creating it if necessary. Returns 0/-1. */
static int sysfs_write(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	if (write(fd, val, strlen(val)) < 0) {
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

/* Read the current level of a line's value file (0/1), or -1. */
static int read_value(int fd)
{
	char b;
	if (fd < 0)
		return -1;
	if (lseek(fd, 0, SEEK_SET) < 0)
		return -1;
	if (read(fd, &b, 1) != 1)
		return -1;
	return (b == '1') ? 1 : 0;
}

/* Export a line, set it to input (edge=both if possible) and open its value
 * file. Leaves c->vfd = -1 on failure. */
static int setup_line(struct control *c)
{
	char path[128], nbuf[16];

	snprintf(nbuf, sizeof(nbuf), "%u", c->line);
	if (sysfs_write(GPIODIR "/export", nbuf) < 0 && errno != EBUSY) {
		/* EBUSY just means a previous instance still has it exported. */
	}

	snprintf(path, sizeof(path), GPIODIR "/gpio%u/direction", c->line);
	sysfs_write(path, "in");

	snprintf(path, sizeof(path), GPIODIR "/gpio%u/edge", c->line);
	if (sysfs_write(path, "both") < 0)
		have_edge = 0;

	snprintf(path, sizeof(path), GPIODIR "/gpio%u/value", c->line);
	c->vfd = open(path, O_RDONLY | O_NONBLOCK);
	return c->vfd >= 0 ? 0 : -1;
}

static int setup_all(void)
{
	int i, ok = 0;

	have_edge = 1;
	for (i = 0; i < NCTRL; i++)
		if (setup_line(&controls[i]) == 0)
			ok++;
	return ok;
}

/* True only on the Buffalo WZR-1750DHP. The GPIO line map above (11-15) is
 * board-specific; on any other bcm53xx Northstar router those lines belong to
 * LEDs or USB power rails, and stock gpio-button-hotplug already probes the
 * buttons cleanly (they do not carry this board's KEY_SETUP quirk). Touching
 * foreign lines could damage hardware, so the daemon self-gates and exits
 * without exporting anything unless we are on the supported board.
 *
 * OpenWrt publishes the board name in /tmp/sysinfo/board_name (e.g.
 * "buffalo,wzr-1750dhp"); we also accept a match anywhere in the DT
 * /proc/device-tree/compatible list (NUL-separated) as an early-boot fallback. */
static int board_is_wzr1750(void)
{
	char buf[512];
	size_t n;
	FILE *f;

	f = fopen("/tmp/sysinfo/board_name", "r");
	if (f) {
		n = fread(buf, 1, sizeof(buf) - 1, f);
		fclose(f);
		buf[n] = '\0';
		if (strstr(buf, "wzr-1750dhp") != NULL)
			return 1;
	}

	f = fopen("/proc/device-tree/compatible", "r");
	if (f) {
		n = fread(buf, 1, sizeof(buf) - 1, f);
		fclose(f);
		buf[n] = '\0';
		if (n > 0 && strstr(buf, "wzr-1750dhp") != NULL)
			return 1;
	}
	return 0;
}

int main(void)
{
	struct sigaction sa;
	int i, n;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_term;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	/* Refuse to run anywhere but the board this GPIO map was measured on.
	 * (The init script gates on the board too; this is the belt that keeps
	 * a stale/forced start from ever driving foreign lines.) */
	if (!board_is_wzr1750()) {
		fprintf(stderr, "broadcom-wl-buttond: board is not a Buffalo "
			"WZR-1750DHP (see /tmp/sysinfo/board_name); the GPIO "
			"button map is board-specific, not starting\n");
		return 0;
	}

	/* The controller is absent on a platform we do not recognise. */
	if (access(GPIODIR, F_OK) != 0) {
		fprintf(stderr, "broadcom-wl-buttond: %s not present; not starting\n",
			GPIODIR);
		return 0;
	}
	if (setup_all() == 0) {
		fprintf(stderr, "broadcom-wl-buttond: no button lines could be "
			"set up; not starting\n");
		return 0;
	}

	/* The state file lives under the run dir shared with common.sh. */
	mkdir("/var/run/broadcom-wl", 0755);

	/* Seed initial state (no scripts yet for switches; see below). */
	for (i = 0; i < NCTRL; i++) {
		int v = read_value(controls[i].vfd);
		controls[i].last = (v < 0) ? 1 : v;
	}
	write_state();

	/* procd reports the initial state of switches once at start; do the
	 * same so the mode/AP scripts can colour the LEDs from boot. */
	for (i = 0; i < NCTRL; i++)
		if (controls[i].is_switch)
			run_script(&controls[i],
				   controls[i].last ? "released" : "pressed", 0);

	while (running) {
		if (have_edge) {
			struct pollfd pfds[NCTRL];
			int idx[NCTRL];

			n = 0;
			for (i = 0; i < NCTRL; i++) {
				if (controls[i].vfd < 0)
					continue;
				pfds[n].fd = controls[i].vfd;
				pfds[n].events = POLLPRI | POLLERR;
				idx[n] = i;
				n++;
			}
			if (poll(pfds, n, 200) > 0) {
				for (i = 0; i < n; i++) {
					struct control *c;
					struct timespec ts;
					int raw;

					if (!(pfds[i].revents &
					      (POLLPRI | POLLERR)))
						continue;
					c = &controls[idx[i]];
					/* Consume the event, settle, re-sample
					 * to debounce. */
					(void)read_value(c->vfd);
					ts.tv_sec = 0;
					ts.tv_nsec = DEBOUNCE_MS * 1000000L;
					nanosleep(&ts, NULL);
					raw = read_value(c->vfd);
					if (raw >= 0)
						handle_edge(c, raw);
				}
			}
		} else {
			/* Polling fallback (no edge support). */
			for (i = 0; i < NCTRL; i++) {
				int v = read_value(controls[i].vfd);
				if (v >= 0)
					handle_edge(&controls[i], v);
			}
			struct timespec ts = { 0, POLL_MS * 1000000L };
			nanosleep(&ts, NULL);
		}
		check_timeouts();
	}

	for (i = 0; i < NCTRL; i++) {
		char nbuf[16];
		if (controls[i].vfd >= 0)
			close(controls[i].vfd);
		snprintf(nbuf, sizeof(nbuf), "%u", controls[i].line);
		sysfs_write(GPIODIR "/unexport", nbuf);
	}
	return 0;
}
