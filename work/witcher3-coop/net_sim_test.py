"""Tests of net_sim.py without the game: a local UDP echo server behind the simulator (delay, jitter, loss,
order, duplication, reordering, seeding, several clients, the TCP pass-through and the command line).

    python -I net_sim_test.py

With NET_SIM_SERVER_JAR (the built WitcherServer.jar) and NET_SIM_JAVA (java.exe) set, it also runs a real
server on free loopback ports: a leader talks to it directly, a member through the simulator, as the game test
harness wires them (`ServerThroughSimulator`).
"""
import os
import select
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import net_sim  # noqa: E402


class Echo:
    """UDP echo server on a free loopback port, in a thread."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.1)
        self.addr = self.sock.getsockname()
        self.sources = set()
        self.running = True
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while self.running:
            try:
                data, addr = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                if not self.running:
                    return
                continue
            self.sources.add(addr)
            self.sock.sendto(data, addr)

    def close(self):
        self.running = False
        self.thread.join()
        self.sock.close()


def simulator(server, delay="0", jitter="0", loss="0", reorder="0", duplicate="0", seed="7", verbose=False, **extra):
    values = {n: net_sim.pair(v, n) for n, v in
              (("delay", delay), ("jitter", jitter), ("loss", loss), ("reorder", reorder), ("duplicate", duplicate))}
    order = ("delay", "jitter", "loss", "reorder", "duplicate")
    sim = net_sim.NetSim(("127.0.0.1", 0), server, net_sim.Impairment(*(values[n][0] for n in order)),
                         net_sim.Impairment(*(values[n][1] for n in order)), seed=seed, stats_every=0, **extra)
    if not verbose:
        sim.log = lambda text: None
    threading.Thread(target=sim.run, daemon=True).start()
    return sim


def exchange(sim_addr, count, spacing=0.002, settle=1.0):
    """Sends `count` numbered datagrams through the simulator; returns (send times, [(seq, rtt)] in arrival order)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    sock.setblocking(False)
    sent, got = {}, []

    def receive(until):
        while True:
            wait = until - time.perf_counter()
            if wait <= 0 or not select.select([sock], [], [], wait)[0]:
                return
            try:
                while True:
                    data = sock.recv(65535)
                    seq = int(data.split(b" ")[0])
                    got.append((seq, time.perf_counter() - sent[seq]))
            except (BlockingIOError, ConnectionResetError):
                pass

    for seq in range(count):
        sent[seq] = time.perf_counter()
        sock.sendto(b"%d payload" % seq, sim_addr)
        receive(sent[seq] + spacing)
    receive(time.perf_counter() + settle)
    sock.close()
    return sent, got


class RelayTest(unittest.TestCase):
    def setUp(self):
        self.echo = Echo()
        self.sims = []

    def tearDown(self):
        for sim in self.sims:
            sim.stop()
            sim.done.wait(5)
        self.echo.close()

    def sim(self, **kw):
        s = simulator(self.echo.addr, **kw)
        self.sims.append(s)
        return s

    def test_pass_through(self):
        sim = self.sim()
        sent, got = exchange(sim.listen_addr, 300, settle=0.3)
        self.assertEqual([s for s, _ in got], list(range(300)))
        self.assertLess(statistics.median(r for _, r in got), 0.010)

    def test_delay_and_jitter(self):
        # 40 ms +-10 each way: round trips between 60 and 100 ms (plus scheduling), averaging about 80
        sim = self.sim(delay="40", jitter="10")
        sent, got = exchange(sim.listen_addr, 400, spacing=0.005)
        rtts = [r for _, r in got]
        self.assertEqual(len(got), 400)
        self.assertGreaterEqual(min(rtts), 0.060 - 0.001)
        self.assertLess(max(rtts), 0.100 + 0.030)
        self.assertAlmostEqual(statistics.mean(rtts), 0.080, delta=0.012)
        self.assertGreater(statistics.pstdev(rtts), 0.004)  # the jitter shows
        self.assertEqual([s for s, _ in got], sorted(s for s, _ in got), "jitter alone must not reorder")
        up = sim.counters["up"]
        self.assertAlmostEqual(up.hold_sum / up.hold_count, 0.040, delta=0.006)

    def test_asymmetric_delay(self):
        sim = self.sim(delay="10/50")
        sent, got = exchange(sim.listen_addr, 100, spacing=0.005)
        self.assertAlmostEqual(statistics.median(r for _, r in got), 0.060, delta=0.010)
        self.assertAlmostEqual(sim.counters["up"].hold_sum / sim.counters["up"].hold_count, 0.010, delta=0.004)
        self.assertAlmostEqual(sim.counters["down"].hold_sum / sim.counters["down"].hold_count, 0.050, delta=0.004)

    def test_loss_rate(self):
        # 10 % each way: about 19 % of round trips lost
        sim = self.sim(loss="10")
        sent, got = exchange(sim.listen_addr, 3000, spacing=0.0003, settle=0.5)
        lost = 1 - len(got) / 3000
        self.assertAlmostEqual(lost, 0.19, delta=0.03)
        up, down = sim.counters["up"], sim.counters["down"]
        self.assertEqual(up.received, 3000)
        self.assertAlmostEqual(up.dropped / up.received, 0.10, delta=0.02)
        self.assertAlmostEqual(down.dropped / down.received, 0.10, delta=0.02)
        self.assertEqual(up.forwarded + up.dropped, up.received)
        self.assertEqual(len(got), down.forwarded)

    def test_seed_repeats(self):
        lost = []
        for seed in ("3", "3", "4"):
            sim = self.sim(delay="5", jitter="3", loss="5", seed=seed)
            sent, got = exchange(sim.listen_addr, 500, spacing=0.001, settle=0.3)
            lost.append(sorted(set(range(500)) - {s for s, _ in got}))
        self.assertEqual(lost[0], lost[1], "the same seed must lose the same datagrams")
        self.assertNotEqual(lost[0], lost[2])

    def test_duplicate(self):
        sim = self.sim(duplicate="20")
        sent, got = exchange(sim.listen_addr, 1000, spacing=0.0005, settle=0.3)
        seqs = [s for s, _ in got]
        dups = len(seqs) - len(set(seqs))
        self.assertEqual(set(seqs), set(range(1000)))
        self.assertAlmostEqual(dups / 1000, 1.2 * 1.2 - 1, delta=0.06)  # 20 % more copies each way
        self.assertEqual(dups, sim.counters["up"].duplicated + sim.counters["down"].duplicated)

    def test_reorder(self):
        sim = self.sim(delay="5", reorder="10/0")
        sent, got = exchange(sim.listen_addr, 500, spacing=0.002, settle=0.5)
        seqs = [s for s, _ in got]
        self.assertEqual(sorted(seqs), list(range(500)))
        late = sum(1 for i in range(1, len(seqs)) if seqs[i] < max(seqs[:i]))
        self.assertGreater(late, 20)
        self.assertAlmostEqual(sim.counters["up"].reordered / 500, 0.10, delta=0.04)
        self.assertEqual(sim.counters["down"].reordered, 0)

    def test_clients_get_own_replies(self):
        sim = self.sim(delay="3")
        socks = []
        for _ in range(3):
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.bind(("127.0.0.1", 0))
            socks.append(s)
        try:
            for i, s in enumerate(socks):
                for n in range(20):
                    s.sendto(b"%d from-%d" % (n, i), sim.listen_addr)
            time.sleep(0.3)
            for i, s in enumerate(socks):
                s.settimeout(0.2)
                replies = [s.recv(100) for _ in range(20)]
                self.assertTrue(all(r.endswith(b"from-%d" % i) for r in replies))
        finally:
            for s in socks:
                s.close()
        self.assertEqual(len(sim.clients), 3)
        self.assertEqual(len(self.echo.sources), 3, "one upstream endpoint per client")
        self.assertEqual(sim.counters["up"].max_size, len(b"19 from-2"))

    def test_large_datagram(self):
        sim = self.sim()
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        s.settimeout(1)
        payload = b"0 " + b"x" * 60000
        s.sendto(payload, sim.listen_addr)
        self.assertEqual(s.recv(65535), payload)
        s.close()
        self.assertEqual(sim.counters["down"].max_size, len(payload))

    def test_tcp_pass_through(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)

        def serve():
            conn, _ = listener.accept()
            data = b""
            while not data.endswith(b"\n"):
                data += conn.recv(100)
            conn.sendall(b"HTTP/1.0 200 OK\r\n\r\n" + data.upper() * 1000)
            conn.close()

        threading.Thread(target=serve, daemon=True).start()
        sim = self.sim(delay="20", loss="50", tcp_listen=("127.0.0.1", 0), tcp_server=listener.getsockname())
        with socket.create_connection(sim.tcp_listen, timeout=5) as c:
            c.sendall(b"get /session\n")
            body = b""
            while True:
                part = c.recv(65536)
                if not part:
                    break
                body += part
        listener.close()
        self.assertEqual(body, b"HTTP/1.0 200 OK\r\n\r\n" + b"GET /SESSION\n" * 1000)
        time.sleep(0.1)
        self.assertEqual(sim.tcp_connections, 1)
        self.assertEqual(sim.tcp_bytes["up"], len(b"get /session\n"))

    def test_tcp_upstream_down(self):
        free = socket.socket()
        free.bind(("127.0.0.1", 0))
        closed_port = free.getsockname()
        free.close()
        sim = self.sim(tcp_listen=("127.0.0.1", 0), tcp_server=closed_port)
        with socket.create_connection(sim.tcp_listen, timeout=5) as c:
            c.settimeout(10)
            self.assertEqual(c.recv(10), b"")
        time.sleep(0.1)
        self.assertEqual(sim.tcp_failed, 1)


class CommandLineTest(unittest.TestCase):
    def test_pair(self):
        self.assertEqual(net_sim.pair("80", "delay"), (80.0, 80.0))
        self.assertEqual(net_sim.pair("60/100", "delay"), (60.0, 100.0))
        for bad in ("1/2/3", "-1", "x"):
            with self.assertRaises(ValueError):
                net_sim.pair(bad, "delay")

    def test_process_logs_and_stops(self):
        # as the harness runs it: its own process group, stopped with Ctrl+Break, totals at the end
        echo = Echo()
        port = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        port.bind(("127.0.0.1", 0))
        listen = port.getsockname()
        port.close()
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "net-sim.log")
            flags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
            out = open(log, "w")
            proc = subprocess.Popen([sys.executable, "-I", net_sim.__file__, "--listen", "%s:%d" % listen,
                                     "--server", "%s:%d" % echo.addr, "--delay", "10", "--loss", "0/100",
                                     "--stats-every", "0.5", "--parent-pid", str(os.getpid())],
                                    stdout=out, stderr=subprocess.STDOUT, creationflags=flags)
            try:
                time.sleep(1.0)
                sent, got = exchange(listen, 50, settle=0.3)
                self.assertEqual(got, [])  # everything lost on the way back
                time.sleep(0.6)
                proc.send_signal(subprocess.signal.CTRL_BREAK_EVENT if os.name == "nt" else subprocess.signal.SIGINT)
                self.assertEqual(proc.wait(5), 0)
            finally:
                if proc.poll() is None:
                    proc.kill()
                echo.close()
                out.close()
            with open(log, encoding="utf-8") as f:
                text = f.read()
        self.assertIn("listening on udp", text)
        self.assertIn("stats: 1 client(s)", text)
        self.assertIn("totals: 1 client(s)", text)
        self.assertIn("up: received 50, forwarded 50, dropped 0", text)
        self.assertIn("down: received 50, forwarded 0, dropped 50 (100.00%)", text)
        self.assertIn("max datagram 10 bytes", text)

    def test_bad_arguments(self):
        result = subprocess.run([sys.executable, "-I", net_sim.__file__, "--loss", "150"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("at most 100", result.stderr)


def free_port_pair():
    """A UDP port p whose TCP p + 1 is free too (the server shares saves on its game port + 1)."""
    for _ in range(50):
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.bind(("127.0.0.1", 0))
        port = u.getsockname()[1]
        t = socket.socket()
        try:
            t.bind(("127.0.0.1", port + 1))
            return port
        except OSError:
            continue
        finally:
            u.close()
            t.close()
    raise RuntimeError("no free port pair")


@unittest.skipUnless(os.environ.get("NET_SIM_SERVER_JAR") and os.environ.get("NET_SIM_JAVA"),
                     "set NET_SIM_SERVER_JAR and NET_SIM_JAVA to test against the real server")
class ServerThroughSimulator(unittest.TestCase):
    """The real Witcher Online server: a leader direct, a member through the simulator at 80 ms +-20 ms and 2 %
    loss each way, the TCP save share through the pass-through."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        saves = os.path.join(self.dir.name, "gamesaves")
        os.makedirs(saves)
        with open(os.path.join(saves, "QuickSave.sav"), "wb") as f:
            f.write(b"SAVE" * 1000)
        self.port = free_port_pair()
        self.server_log = open(os.path.join(self.dir.name, "server.log"), "w")
        self.server = subprocess.Popen([os.environ["NET_SIM_JAVA"], "-jar", os.environ["NET_SIM_SERVER_JAR"], str(self.port),
                                        "--save-dir", saves, "--host-name", "BotA"], cwd=self.dir.name,
                                       stdin=subprocess.PIPE, stdout=self.server_log, stderr=subprocess.STDOUT)
        self.sim = simulator(("127.0.0.1", self.port), delay="80", jitter="20", loss="2", seed="1",
                             tcp_listen=("127.0.0.1", 0), tcp_server=("127.0.0.1", self.port + 1), verbose=True)
        self.leader = self.peer(("127.0.0.1", self.port))
        self.member = self.peer(self.sim.listen_addr)
        deadline = time.time() + 20
        while time.time() < deadline:
            if self.ask(self.leader, b"MOVE\t ", 0.3) == b"ERROR\tINVALID_USERNAME":
                return
        raise AssertionError("server did not start")

    def tearDown(self):
        self.sim.stop()
        self.sim.done.wait(5)
        try:
            self.server.stdin.write(b"stop\n")
            self.server.stdin.close()
            self.server.wait(5)
        except (OSError, subprocess.TimeoutExpired):
            # with --save-dir the server keeps running after `stop` (SaveShare's HTTP server); run_test.py kills it too
            self.server.kill()
            self.server.wait()
        self.server_log.close()
        self.leader.close()
        self.member.close()
        self.dir.cleanup()

    @staticmethod
    def peer(addr):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        s.connect(addr)
        return s

    @staticmethod
    def ask(sock, message, timeout):
        sock.settimeout(timeout)
        try:
            sock.send(message)
            return sock.recv(8192)
        except (socket.timeout, ConnectionResetError):
            return None

    def test_member_round_trips(self):
        # the server's reply to a bad MOVE is a request and answer: 200 of them, one at a time
        rtts, lost = [], 0
        for _ in range(200):
            start = time.perf_counter()
            reply = self.ask(self.member, b"MOVE\t ", 0.5)
            if reply is None:
                lost += 1
                time.sleep(0.2)  # let a late reply pass
                self.member.settimeout(0.01)
                try:
                    while True:
                        self.member.recv(8192)
                except (socket.timeout, ConnectionResetError):
                    pass
                continue
            self.assertEqual(reply, b"ERROR\tINVALID_USERNAME")
            rtts.append(time.perf_counter() - start)
        print(f"\nmember round trips: {len(rtts)} answered, {lost} lost; median {statistics.median(rtts) * 1000:.1f} ms, "
              f"min {min(rtts) * 1000:.1f}, max {max(rtts) * 1000:.1f}")
        self.assertAlmostEqual(statistics.median(rtts), 0.160, delta=0.025)
        self.assertGreaterEqual(min(rtts), 0.120 - 0.001)
        self.assertLessEqual(lost, 20)  # about 4 % expected

    def test_leader_state_reaches_member(self):
        # the server relays the latest message per co-op channel to the other player
        self.member.send(b"COOP\tBotB\thit\t1")
        seen = {}
        channels = "en hurt jr fx np nq cv dn tr ss lt lc rw".split()
        start = time.perf_counter()
        deadline = start + 8
        self.member.settimeout(0.05)
        n = 0
        while time.perf_counter() < deadline and len(seen) < len(channels):
            n += 1
            for channel in channels:
                if channel not in seen:
                    self.leader.send(b"COOP\tBotA\t%s\tstate-%d" % (channel.encode(), n))
            self.member.send(b"COOP\tBotB\thit\t%d" % n)
            try:
                while True:
                    fields = self.member.recv(65535).split(b"\t")
                    if len(fields) > 4 and fields[0] == b"COOP" and fields[2] == b"BotA":
                        seen.setdefault(fields[3].decode(), time.perf_counter() - start)
            except (socket.timeout, ConnectionResetError):
                pass
        print(f"\nchannels seen by the member: {len(seen)}/{len(channels)}, last after {max(seen.values()) * 1000:.0f} ms")
        self.assertEqual(sorted(seen), sorted(channels))
        self.assertGreater(self.sim.counters["down"].hold_count, 0)

    def test_save_share_over_tcp(self):
        import urllib.request
        with urllib.request.urlopen("http://127.0.0.1:%d/session" % self.sim.tcp_listen[1], timeout=10) as reply:
            body = reply.read().decode()
        print(f"\n/session through the pass-through: {body.strip()[:120]!r}")
        self.assertIn("QuickSave", body)
        self.assertEqual(self.sim.tcp_connections, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
