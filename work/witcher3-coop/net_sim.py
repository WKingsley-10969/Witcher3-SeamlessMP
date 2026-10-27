"""Network simulator for co-op tests: a UDP relay between game clients and the Witcher Online server that adds
internet-like delay, jitter, loss, reordering and duplication (as over ZeroTier or Tailscale to a second PC).

    net_sim.py --listen 127.0.0.1:41200 --server 127.0.0.1:41000 --delay 80 --jitter 20 --loss 2

Clients send to --listen; each client address gets its own upstream socket to --server, so the server sees one
endpoint per client and its replies go back to the right client. Every impairment takes one value for both
directions or UP/DOWN (up = client to server, down = server to client), e.g. --delay 60/100:

  --delay MS      one-way delay added to every datagram in that direction (the round trip gets both)
  --jitter MS     each datagram's delay varies uniformly by +-MS; datagrams keep their order (as on a real link,
                  where jitter is mostly queueing), so a burst can be held back behind a slow one
  --loss PCT      chance a datagram is dropped
  --reorder PCT   chance a datagram is held back an extra max(2 x jitter, 20) ms without holding up the ones
                  behind it, which then overtake it
  --duplicate PCT chance a datagram is also delivered a second time, up to `jitter` ms later

The randomness is seeded (--seed) per client and direction, so a run with the same traffic drops, delays and
duplicates the same datagrams. --tcp-listen/--tcp-server add a plain TCP pass-through (no impairment), for the
host's save download and lobby, which clients reach on the game port + 1. Counters (forwarded, dropped, max
datagram size, delay actually applied, per direction) are logged every --stats-every seconds and at the end.
Standard library only. Stops on Ctrl+C / Ctrl+Break, after --max-seconds, or when --parent-pid exits.
"""
import argparse
import heapq
import itertools
import os
import random
import selectors
import signal
import socket
import sys
import threading
import time

UP, DOWN = "up", "down"
MAX_CLIENTS = 64
BUFFER = 1 << 20


def pair(text, name):
    """'80' -> (80.0, 80.0); '60/100' -> (60.0, 100.0)."""
    parts = str(text).split("/")
    if len(parts) > 2:
        raise ValueError(f"--{name}: give one value or UP/DOWN, not {text!r}")
    values = tuple(float(p) for p in parts)
    if any(v < 0 for v in values):
        raise ValueError(f"--{name}: must not be negative")
    return values if len(values) == 2 else values * 2


def address(text):
    host, _, port = text.rpartition(":")
    return host or "127.0.0.1", int(port)


class Impairment:
    """What happens to datagrams in one direction."""

    def __init__(self, delay=0.0, jitter=0.0, loss=0.0, reorder=0.0, duplicate=0.0):
        if loss > 100 or reorder > 100 or duplicate > 100:
            raise ValueError("percentages must be at most 100")
        self.delay, self.jitter = delay / 1000.0, jitter / 1000.0
        self.loss, self.reorder, self.duplicate = loss / 100.0, reorder / 100.0, duplicate / 100.0
        self.reorder_gap = max(2 * self.jitter, 0.020)

    def describe(self):
        return (f"delay {self.delay * 1000:g} ms +-{self.jitter * 1000:g}, loss {self.loss * 100:g}%, "
                f"reorder {self.reorder * 100:g}%, duplicate {self.duplicate * 100:g}%")


class Counters:
    def __init__(self):
        self.received = self.forwarded = self.dropped = self.duplicated = self.reordered = 0
        self.bytes = self.max_size = 0
        self.hold_sum = self.hold_max = 0.0
        self.hold_count = 0

    def line(self, name):
        hold = self.hold_sum / self.hold_count * 1000 if self.hold_count else 0.0
        lost = 100.0 * self.dropped / self.received if self.received else 0.0
        return (f"{name:>4}: received {self.received}, forwarded {self.forwarded}, dropped {self.dropped} ({lost:.2f}%), "
                f"duplicated {self.duplicated}, reordered {self.reordered}, {self.bytes} bytes, "
                f"max datagram {self.max_size} bytes, delay applied avg {hold:.1f} ms max {self.hold_max * 1000:.1f} ms")


class Flow:
    """One client's datagrams in one direction: its own random stream and ordering."""

    def __init__(self, seed, index, direction, impairment):
        self.rng = random.Random(f"{seed}:{index}:{direction}")
        self.impairment = impairment
        self.last_due = 0.0

    def schedule(self, now):
        """Due times for one datagram: [] when it is lost, two when it is duplicated; and whether it was reordered."""
        imp, rng = self.impairment, self.rng
        # draw every number every time, so one datagram's fate never shifts the next one's
        lose, jitter, reorder, dup, dup_jitter = (rng.random(), rng.uniform(-imp.jitter, imp.jitter), rng.random(),
                                                  rng.random(), rng.random())
        if lose < imp.loss:
            return [], False
        due = now + max(0.0, imp.delay + jitter)
        reordered = reorder < imp.reorder
        if reordered:
            due += imp.reorder_gap
        else:
            due = max(due, self.last_due)
            self.last_due = due
        times = [due]
        if dup < imp.duplicate:
            times.append(due + dup_jitter * imp.jitter)
        return times, reordered


class Client:
    def __init__(self, index, addr, upstream, seed, up, down):
        self.index, self.addr, self.upstream = index, addr, upstream
        self.flows = {UP: Flow(seed, index, UP, up), DOWN: Flow(seed, index, DOWN, down)}
        self.last_seen = time.monotonic()


class NetSim:
    def __init__(self, listen, server, up, down, seed=1, stats_every=30.0, tcp_listen=None, tcp_server=None,
                 log=None, max_seconds=0.0, parent_pid=0):
        self.listen_addr, self.server = listen, server
        self.up, self.down, self.seed = up, down, seed
        self.stats_every, self.max_seconds, self.parent_pid = stats_every, max_seconds, parent_pid
        self.tcp_listen, self.tcp_server = tcp_listen, tcp_server
        self.log_file = log
        self.clients = {}
        self.by_socket = {}
        self.counters = {UP: Counters(), DOWN: Counters()}
        self.rejected = 0
        self.tcp_connections = self.tcp_failed = 0
        self.tcp_bytes = {UP: 0, DOWN: 0}
        self.queue = []
        self.sequence = itertools.count()
        self.stopping = threading.Event()
        self.done = threading.Event()
        self.lock = threading.RLock()  # the signal handler logs from the main thread
        self.sel = selectors.DefaultSelector()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._tune(self.sock)
        self.sock.bind(listen)
        self.sock.setblocking(False)
        self.listen_addr = self.sock.getsockname()
        self.sel.register(self.sock, selectors.EVENT_READ, None)
        self.tcp_sock = None
        if tcp_listen:
            self.tcp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.tcp_sock.bind(tcp_listen)
            self.tcp_sock.listen(16)
            self.tcp_sock.settimeout(0.25)
            self.tcp_listen = self.tcp_sock.getsockname()

    @staticmethod
    def _tune(sock):
        for option in (socket.SO_RCVBUF, socket.SO_SNDBUF):
            try:
                sock.setsockopt(socket.SOL_SOCKET, option, BUFFER)
            except OSError:
                pass

    def log(self, text):
        line = time.strftime("%H:%M:%S ") + text
        with self.lock:
            print(line, flush=True)
            if self.log_file:
                self.log_file.write(line + "\n")
                self.log_file.flush()

    def stats(self, final=False):
        head = "totals" if final else "stats"
        self.log(f"{head}: {len(self.clients)} client(s)" + (f", {self.rejected} datagram(s) from clients over the "
                                                                 f"limit of {MAX_CLIENTS}" if self.rejected else ""))
        for direction in (UP, DOWN):
            self.log("  " + self.counters[direction].line(direction))
        if self.tcp_sock:
            self.log(f"  tcp: {self.tcp_connections} connection(s), {self.tcp_failed} failed upstream, "
                     f"{self.tcp_bytes[UP]} bytes up, {self.tcp_bytes[DOWN]} bytes down")

    # --- UDP ---

    def _client(self, addr):
        client = self.clients.get(addr)
        if client is None:
            if len(self.clients) >= MAX_CLIENTS:
                return None
            upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._tune(upstream)
            upstream.bind((self.listen_addr[0] if self.listen_addr[0] != "0.0.0.0" else "", 0))
            upstream.connect(self.server)
            upstream.setblocking(False)
            client = Client(len(self.clients), addr, upstream, self.seed, self.up, self.down)
            self.clients[addr] = client
            self.by_socket[upstream] = client
            self.sel.register(upstream, selectors.EVENT_READ, client)
            self.log(f"client {client.index} {addr[0]}:{addr[1]} -> upstream port {upstream.getsockname()[1]}")
        client.last_seen = time.monotonic()
        return client

    def _enqueue(self, client, direction, data, now):
        counters = self.counters[direction]
        counters.received += 1
        counters.max_size = max(counters.max_size, len(data))
        times, reordered = client.flows[direction].schedule(now)
        if not times:
            counters.dropped += 1
            return
        counters.reordered += reordered
        counters.duplicated += len(times) - 1
        for due in times:
            heapq.heappush(self.queue, (due, next(self.sequence), client, direction, data, now))

    def _send_due(self, now):
        while self.queue and self.queue[0][0] <= now:
            _, _, client, direction, data, queued = heapq.heappop(self.queue)
            try:
                if direction == UP:
                    client.upstream.send(data)
                else:
                    self.sock.sendto(data, client.addr)
            except OSError:
                continue  # the far end is gone (port unreachable); like a lost datagram, but not counted as one
            counters = self.counters[direction]
            counters.forwarded += 1
            counters.bytes += len(data)
            hold = time.perf_counter() - queued
            counters.hold_sum += hold
            counters.hold_count += 1
            counters.hold_max = max(counters.hold_max, hold)

    def _drain(self, sock, client):
        while True:
            try:
                if client is None:
                    data, addr = sock.recvfrom(65535)
                else:
                    data = sock.recv(65535)
            except (BlockingIOError, InterruptedError):
                return
            except ConnectionResetError:
                continue  # Windows reports an earlier send's ICMP port unreachable here
            except OSError:
                return
            now = time.perf_counter()
            if client is None:
                target = self._client(addr)
                if target is None:
                    self.rejected += 1
                    continue
                self._enqueue(target, UP, data, now)
            else:
                self._enqueue(client, DOWN, data, now)

    # --- TCP pass-through ---

    def _pump(self, source, target, direction):
        try:
            while True:
                data = source.recv(65536)
                if not data:
                    break
                target.sendall(data)
                with self.lock:
                    self.tcp_bytes[direction] += len(data)
        except OSError:
            pass
        finally:
            try:
                target.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def _tcp_connection(self, conn, peer):
        try:
            upstream = socket.create_connection(self.tcp_server, timeout=5)
            upstream.settimeout(None)
        except OSError as error:
            self.tcp_failed += 1
            self.log(f"tcp {peer[0]}:{peer[1]}: upstream {self.tcp_server[0]}:{self.tcp_server[1]} failed: {error}")
            conn.close()
            return
        conn.settimeout(None)
        self.tcp_connections += 1
        back = threading.Thread(target=self._pump, args=(upstream, conn, DOWN), daemon=True)
        back.start()
        self._pump(conn, upstream, UP)
        back.join()
        conn.close()
        upstream.close()

    def _tcp_accept(self):
        while not self.stopping.is_set():
            try:
                conn, peer = self.tcp_sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._tcp_connection, args=(conn, peer), daemon=True).start()

    # --- main loop ---

    def _parent_alive(self):
        if not self.parent_pid:
            return True
        if os.name == "nt":
            import ctypes
            kernel32 = ctypes.windll.kernel32
            handle = kernel32.OpenProcess(0x1000, False, self.parent_pid)  # PROCESS_QUERY_LIMITED_INFORMATION
            if not handle:
                return False
            code = ctypes.c_ulong()
            ok = kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
            kernel32.CloseHandle(handle)
            return bool(ok) and code.value == 259  # STILL_ACTIVE
        try:
            os.kill(self.parent_pid, 0)
            return True
        except OSError:
            return False

    def run(self):
        if os.name == "nt":
            import ctypes
            ctypes.windll.winmm.timeBeginPeriod(1)  # 1 ms timer for select(), only while this process runs
        start = time.perf_counter()
        next_stats = start + self.stats_every if self.stats_every > 0 else float("inf")
        next_parent = start + 1.0
        self.log(f"listening on udp {self.listen_addr[0]}:{self.listen_addr[1]} -> server {self.server[0]}:{self.server[1]}"
                 + (f"; tcp {self.tcp_listen[0]}:{self.tcp_listen[1]} -> {self.tcp_server[0]}:{self.tcp_server[1]}"
                    if self.tcp_sock else ""))
        self.log(f"  up (client to server): {self.up.describe()}")
        self.log(f"  down (server to client): {self.down.describe()}")
        self.log(f"  seed {self.seed}")
        if self.tcp_sock:
            threading.Thread(target=self._tcp_accept, daemon=True).start()
        try:
            while not self.stopping.is_set():
                now = time.perf_counter()
                self._send_due(now)
                timeout = 0.25
                if self.queue:
                    timeout = min(timeout, max(0.0, self.queue[0][0] - time.perf_counter()))
                for key, _ in self.sel.select(timeout):
                    self._drain(key.fileobj, key.data)
                now = time.perf_counter()
                if now >= next_stats:
                    next_stats = now + self.stats_every
                    self.stats()
                if now >= next_parent:
                    next_parent = now + 1.0
                    if not self._parent_alive():
                        self.log(f"parent process {self.parent_pid} is gone; stopping")
                        break
                    if self.max_seconds and now - start >= self.max_seconds:
                        self.log(f"ran {self.max_seconds:g} s; stopping")
                        break
        finally:
            self.stopping.set()
            self.stats(final=True)
            self.close()
            if os.name == "nt":
                import ctypes
                ctypes.windll.winmm.timeEndPeriod(1)
            self.done.set()

    def stop(self):
        self.stopping.set()

    def close(self):
        for client in self.clients.values():
            client.upstream.close()
        self.sock.close()
        if self.tcp_sock:
            self.tcp_sock.close()
        self.sel.close()


def build(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--listen", default="127.0.0.1:41200", help="HOST:PORT clients send to (default %(default)s)")
    ap.add_argument("--server", default="127.0.0.1:41000", help="HOST:PORT of the real server (default %(default)s)")
    ap.add_argument("--delay", default="0", help="one-way delay in ms, or UP/DOWN")
    ap.add_argument("--jitter", default="0", help="+- ms around the delay, or UP/DOWN")
    ap.add_argument("--loss", default="0", help="percent of datagrams dropped, or UP/DOWN")
    ap.add_argument("--reorder", default="0", help="percent of datagrams held back and overtaken, or UP/DOWN")
    ap.add_argument("--duplicate", default="0", help="percent of datagrams delivered twice, or UP/DOWN")
    ap.add_argument("--seed", default="1", help="random seed (default %(default)s)")
    ap.add_argument("--stats-every", type=float, default=30.0, help="seconds between counter lines (0: only at the end)")
    ap.add_argument("--tcp-listen", help="HOST:PORT for a plain TCP pass-through (e.g. the save download)")
    ap.add_argument("--tcp-server", help="HOST:PORT the TCP pass-through connects to")
    ap.add_argument("--log", help="also append the log to this file")
    ap.add_argument("--max-seconds", type=float, default=0.0, help="stop after this long (0: never)")
    ap.add_argument("--parent-pid", type=int, default=0, help="stop when this process exits")
    a = ap.parse_args(argv)
    if bool(a.tcp_listen) != bool(a.tcp_server):
        ap.error("--tcp-listen and --tcp-server go together")
    try:
        values = {name: pair(getattr(a, name), name) for name in ("delay", "jitter", "loss", "reorder", "duplicate")}
        up = Impairment(*(values[n][0] for n in ("delay", "jitter", "loss", "reorder", "duplicate")))
        down = Impairment(*(values[n][1] for n in ("delay", "jitter", "loss", "reorder", "duplicate")))
    except ValueError as error:
        ap.error(str(error))
    log = open(a.log, "a", encoding="utf-8") if a.log else None
    return NetSim(address(a.listen), address(a.server), up, down, seed=a.seed, stats_every=a.stats_every,
                  tcp_listen=address(a.tcp_listen) if a.tcp_listen else None,
                  tcp_server=address(a.tcp_server) if a.tcp_server else None,
                  log=log, max_seconds=a.max_seconds, parent_pid=a.parent_pid)


def main(argv=None):
    sim = build(argv)

    def stop(signum, frame):
        sim.log(f"signal {signum}; stopping")
        sim.stop()

    for name in ("SIGINT", "SIGTERM", "SIGBREAK"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), stop)
    sim.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
