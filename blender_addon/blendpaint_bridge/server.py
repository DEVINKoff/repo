"""Network layer of the BlendPaint bridge. No bpy here: runs in background threads.

Frame format (both directions), big-endian:
    u32 header_len | u32 payload_len | header (UTF-8 JSON) | payload (raw bytes)
"""
import json
import queue
import socket
import struct
import threading
import time

PROTOCOL_VERSION = 1
DEFAULT_PORT = 47800
_HDR = struct.Struct(">II")
MAX_HEADER = 16 * 1024 * 1024
MAX_PAYLOAD = 1024 * 1024 * 1024


def _recv_exact(sock, n):
    buf = bytearray(n)
    view = memoryview(buf)
    got = 0
    while got < n:
        r = sock.recv_into(view[got:], n - got)
        if r == 0:
            raise ConnectionError("peer closed")
        got += r
    return bytes(buf)


class Client:
    def __init__(self, sock, addr, server):
        self.sock = sock
        self.addr = addr
        self.server = server
        self.out = queue.Queue()
        self.alive = True
        self.bytes_pending = 0
        self._lock = threading.Lock()
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        except OSError:
            pass
        self.reader = threading.Thread(target=self._read_loop, daemon=True, name="BlendPaintRead")
        self.writer = threading.Thread(target=self._write_loop, daemon=True, name="BlendPaintWrite")
        self.reader.start()
        self.writer.start()

    def send(self, header, payload=b""):
        if not self.alive:
            return
        hb = json.dumps(header, separators=(",", ":")).encode("utf-8")
        with self._lock:
            self.bytes_pending += len(payload)
        self.out.put((hb, payload))

    def close(self):
        if not self.alive:
            return
        self.alive = False
        self.out.put(None)
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        self.server._on_client_closed(self)

    def _write_loop(self):
        try:
            while self.alive:
                item = self.out.get()
                if item is None:
                    break
                hb, payload = item
                self.sock.sendall(_HDR.pack(len(hb), len(payload)) + hb)
                if payload:
                    mv = memoryview(payload)
                    step = 1 << 20
                    for i in range(0, len(mv), step):
                        self.sock.sendall(mv[i:i + step])
                with self._lock:
                    self.bytes_pending -= len(payload)
        except OSError:
            pass
        finally:
            self.close()

    def _read_loop(self):
        try:
            while self.alive:
                hl, pl = _HDR.unpack(_recv_exact(self.sock, _HDR.size))
                if hl > MAX_HEADER or pl > MAX_PAYLOAD:
                    raise ConnectionError("frame too large")
                header = json.loads(_recv_exact(self.sock, hl).decode("utf-8"))
                payload = _recv_exact(self.sock, pl) if pl else b""
                self.server._dispatch(self, header, payload)
        except (OSError, ConnectionError, ValueError):
            pass
        finally:
            self.close()


class BridgeServer:
    """TCP server. Only one iPad at a time; a new connection replaces the old one."""

    def __init__(self, on_message, on_connect, port=DEFAULT_PORT):
        self.port = port
        self.on_message = on_message      # called in network thread: (client, header, payload)
        self.on_connect = on_connect      # called in network thread: (client)
        self.client = None
        self.pending = []
        self.sock = None
        self.running = False
        self.error = ""
        self.connected_since = 0.0

    def start(self):
        if self.running:
            return True
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("0.0.0.0", self.port))
            s.listen(2)
            s.settimeout(0.5)
        except OSError as e:
            self.error = str(e)
            return False
        self.sock = s
        self.running = True
        self.error = ""
        threading.Thread(target=self._accept_loop, daemon=True, name="BlendPaintAccept").start()
        return True

    def stop(self):
        self.running = False
        if self.client:
            self.client.close()
        for c in list(self.pending):
            c.close()
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def _accept_loop(self):
        while self.running:
            try:
                conn, addr = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            conn.settimeout(None)
            # A connection only becomes the active client after it says hello
            # (the iPad's LAN scan opens and closes probe connections).
            self.pending.append(Client(conn, addr, self))

    def _on_client_closed(self, client):
        if self.client is client:
            self.client = None
        if client in self.pending:
            self.pending.remove(client)

    def _dispatch(self, client, header, payload):
        t = header.get("type")
        if t == "ping":
            client.send({"type": "pong", "t": header.get("t", 0)})
            return
        if client is not self.client:
            if t != "hello":
                return
            if client in self.pending:
                self.pending.remove(client)
            old = self.client
            self.client = client
            self.connected_since = time.time()
            if old:
                old.close()
            try:
                self.on_connect(client)
            except Exception as e:  # noqa
                print("BlendPaint on_connect error:", e)
        try:
            self.on_message(client, header, payload)
        except Exception as e:  # noqa
            print("BlendPaint message error:", e)

    @property
    def connected(self):
        return self.client is not None and self.client.alive

    def send(self, header, payload=b""):
        c = self.client
        if c and c.alive:
            c.send(header, payload)


def local_ips():
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ips.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except OSError:
        pass
    return ips
