/*
 * box-bind0: under krun, give TCP listeners a real port instead of port 0.
 *
 * krun hands the guest's sockets to the VMM (TSI), which binds them in the
 * container's network namespace. A bind to port 0 gets one port from the
 * guest kernel and another from the VMM, and the guest is never told the
 * VMM's: the listener is unreachable even from its own process
 * (https://github.com/libkrun/libkrun/issues/818). opencode's TUI, test
 * suites' mock servers and the like all bind port 0.
 *
 * Loaded with LD_PRELOAD in krun boxes only. A TCP bind to port 0 becomes a
 * bind to a random port below the kernel's ephemeral range, retried while
 * one is taken; a fixed port is the same on both sides. Anything else passes
 * through untouched.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define PORT_LO 20000
#define PORT_N 12000 /* up to 31999, below the ephemeral range (32768-) */
#define TRIES 64

static int (*real_bind)(int, const struct sockaddr *, socklen_t);

/* Resolved before main, so threads never race to set it; bind() still
 * resolves it itself if another library's constructor binds first. */
__attribute__((constructor)) static void init(void) {
  real_bind = (int (*)(int, const struct sockaddr *, socklen_t))dlsym(RTLD_NEXT, "bind");
}

static uint32_t next(uint32_t *s) {
  /* xorshift32: enough to spread concurrent processes over the range */
  *s ^= *s << 13;
  *s ^= *s >> 17;
  *s ^= *s << 5;
  return *s;
}

int bind(int fd, const struct sockaddr *addr, socklen_t len) {
  struct sockaddr_storage ss;
  in_port_t *port;
  int type, i, r;
  socklen_t tl = sizeof type;
  struct timespec ts;
  uint32_t seed;

  if (!real_bind) {
    real_bind = (int (*)(int, const struct sockaddr *, socklen_t))dlsym(RTLD_NEXT, "bind");
    if (!real_bind) {
      errno = ENOSYS;
      return -1;
    }
  }
  if (!addr || len < sizeof(sa_family_t) || len > sizeof ss)
    return real_bind(fd, addr, len);
  if (addr->sa_family == AF_INET && len >= sizeof(struct sockaddr_in))
    port = &((struct sockaddr_in *)&ss)->sin_port;
  else if (addr->sa_family == AF_INET6 && len >= sizeof(struct sockaddr_in6))
    port = &((struct sockaddr_in6 *)&ss)->sin6_port;
  else
    return real_bind(fd, addr, len);
  memcpy(&ss, addr, len);
  if (*port != 0 || getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl) != 0 || type != SOCK_STREAM)
    return real_bind(fd, addr, len);

  clock_gettime(CLOCK_MONOTONIC, &ts);
  seed = (uint32_t)ts.tv_nsec ^ ((uint32_t)getpid() << 16) ^ (uint32_t)fd;
  if (!seed)
    seed = 1;
  for (i = 0; i < TRIES; i++) {
    *port = htons((in_port_t)(PORT_LO + next(&seed) % PORT_N));
    r = real_bind(fd, (struct sockaddr *)&ss, len);
    if (r == 0 || errno != EADDRINUSE)
      return r;
  }
  /* the range is full: let the kernel pick, as it would have */
  return real_bind(fd, addr, len);
}
