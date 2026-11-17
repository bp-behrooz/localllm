"""box-proxy-relay: a fenced box's way to the host's forwarded ports.

Runs in the proxy container beside mitmdump, only when the launch forwards host
ports (--host-port, a profile's BOX_LAUNCH_PORT). A fenced box's only neighbor
is the proxy, so each forward goes box -> proxy -> host:

    python3 relay.py VIA SPEC [SPEC...]

Each SPEC is PORT or PORT=unix:PATH. It listens on PORT on the proxy's
fence-network address and connects each client to VIA:PORT (a Mac, where the
host serves that forward on its gateway to the proxy alone) or to the Unix
socket PATH (podman, where the host serves it on a socket mounted in). VIA is
an address reached through the outbound network, which tells the two sides
apart. It binds only the fence side: nothing else on the proxy's outbound
network gets in.
"""

import socket
import sys
import threading
import time


def local_addrs():
    """The container's own IPv4 addresses, from the kernel's routing table."""
    addrs, prev = set(), None
    with open("/proc/net/fib_trie") as f:
        for line in f:
            line = line.strip()
            if line == "/32 host LOCAL" and prev:
                addrs.add(prev)
            prev = line[4:] if line.startswith("|-- ") else None
    return {a for a in addrs if not a.startswith("127.")}


def outbound_addr(via):
    """The address the container reaches VIA from: its outbound side."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((via, 9))
        return s.getsockname()[0]


def fence_addrs(via):
    # Both networks are attached by the time this runs, but give them a moment.
    for _ in range(50):
        try:
            found = local_addrs() - {outbound_addr(via)}
        except OSError:
            found = set()
        if found:
            return sorted(found)
        time.sleep(0.1)
    sys.exit("box-proxy-relay: no fence-network address found; not relaying")


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s, how in ((dst, socket.SHUT_WR), (src, socket.SHUT_RD)):
            try:
                s.shutdown(how)
            except OSError:
                pass


def dial(target):
    if isinstance(target, str):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(10)
        try:
            s.connect(target)
        except OSError:
            s.close()
            raise
    else:
        s = socket.create_connection(target, 10)
    s.settimeout(None)
    return s


def show(target):
    return "unix:" + target if isinstance(target, str) else "%s:%d" % target


def serve(listener, target):
    while True:
        # This loop is the listener's only reader: if it died, connections
        # would queue unanswered and look like a hang of the forwarded service.
        try:
            client, _ = listener.accept()
        except OSError as e:
            print(f"box-proxy-relay: {show(target)}: accept: {e}", file=sys.stderr, flush=True)
            time.sleep(0.1)  # EMFILE and the like: don't spin on it
            continue
        try:
            upstream = dial(target)
        except OSError as e:
            print(f"box-proxy-relay: {show(target)}: {e}", file=sys.stderr, flush=True)
            client.close()
            continue

        def run(a=client, b=upstream):
            t = threading.Thread(target=pipe, args=(b, a), daemon=True)
            t.start()
            pipe(a, b)
            t.join()
            a.close()
            b.close()

        threading.Thread(target=run, daemon=True).start()


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: relay.py VIA PORT[=unix:PATH] [...]")
    via, routes = sys.argv[1], []
    for spec in sys.argv[2:]:
        port, _, target = spec.partition("=")
        if target.startswith("unix:"):
            routes.append((int(port), target[len("unix:"):]))
        elif not target:
            routes.append((int(port), (via, int(port))))
        else:
            sys.exit(f"box-proxy-relay: {spec}: not PORT or PORT=unix:PATH")
    threads = []
    for addr in fence_addrs(via):
        for port, target in routes:
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((addr, port))
            s.listen(64)
            print(f"box-proxy-relay: {addr}:{port} -> {show(target)}",
                  file=sys.stderr, flush=True)
            t = threading.Thread(target=serve, args=(s, target), daemon=True)
            t.start()
            threads.append(t)
    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
