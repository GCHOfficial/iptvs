#!/usr/bin/env python3
"""Synthetic "live cut" MPEG-TS server for the stitched-handover test leg.

Reproduces the behaviour of the Stalker-style IPTV provider that the
"live-stitched-handover" Android work is built against: every live connection
is single-use and single-connection. On connect it ships a 20-30s backlog of
the live stream at several times real time (starting from "live minus
backlog"), settles into real-time delivery for 6-18s, then closes the body
cleanly. A fresh connection needs a fresh single-use "play_token", and opening
a new one kills whatever connection is currently open.

Two endpoints exist so the app's splice can be told apart from an app that
merely reconnects on every cut:

  GET /resolve          -> text/plain body: a fresh one-shot URL
                           (http://<host>/live.ts?token=<n>). Mints a new
                           token every call, exactly like a provider's
                           create_link.
  GET /live.ts?token=N  -> the rotating-URL channel. N must be unused; a
                           second use is 403. Opening this (or /stable.ts)
                           kills whatever connection currently holds the
                           server's one playback slot.
  GET /stable.ts        -> the same burst/hold/close behaviour, but the URL
                           never changes and no token is required. This is
                           the control case: the app's splice must never arm
                           for a source whose URL is static, even though the
                           connection itself still gets cut.
  GET /stats            -> JSON counters + a per-connection record list.

Usage
-----
Generate a fixture (needs ffmpeg; run once, reused by every server start):

    python3 tool/live_cut_server.py --make-ts /tmp/live_cut_fixture.ts --seconds 900

Serve it:

    python3 tool/live_cut_server.py --ts /tmp/live_cut_fixture.ts --port 8765

Self-test (no ffmpeg, no fixture file, runs in a few seconds):

    python3 tool/live_cut_server.py --self-test

On this dev box ffmpeg lives behind `mise exec conda:ffmpeg@9.0.2 -- ffmpeg`;
pass that whole invocation as a single `--ffmpeg` string is not supported by
subprocess argv splitting, so instead generate the fixture with:

    mise exec conda:ffmpeg@9.0.2 -- python3 tool/live_cut_server.py \\
        --make-ts /tmp/live_cut_fixture.ts --seconds 900

so `ffmpeg`/`ffprobe` resolve correctly on PATH inside that shell. CI's apt
`ffmpeg` needs no such wrapping.

Stdlib only (http.server/socketserver/threading) — no pip install, so the
emulator CI job needs nothing beyond `python3` and (for --make-ts) `ffmpeg`.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import random
import shutil
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

TS_PACKET = 188
SYNC_BYTE = 0x47

# One quantum of the per-connection send loop. Small enough that the
# single-connection kill (an `Event` checked once per quantum, belt-and-braces
# with a socket shutdown) lands promptly, and that the burst->real-time phase
# switch doesn't overshoot by much.
QUANTUM_SECONDS = 0.05


# ── TS fixture generation ────────────────────────────────────────────────────


def make_ts(path: str, seconds: float, ffmpeg: str = "ffmpeg") -> None:
    """Generates a long, constant-frame-rate H.264+AAC MPEG-TS fixture with an
    IDR every 1s (`-g 25 -keyint_min 25 -sc_threshold 0` at 25fps), so the
    server always has a keyframe within a second of any offset it starts
    streaming from. Audio is kept so the audio-cut path is exercised too.
    """
    base_cmd = [
        ffmpeg,
        "-y",
        "-f",
        "lavfi",
        "-i",
        f"testsrc2=size=640x360:rate=25:duration={seconds}",
        "-f",
        "lavfi",
        "-i",
        f"sine=frequency=440:duration={seconds}",
    ]
    encode_cmd = [
        "-c:v",
        "libx264",
        "-g",
        "25",
        "-keyint_min",
        "25",
        "-sc_threshold",
        "0",
        "-bf",
        "2",
        "-c:a",
        "aac",
        "-f",
        "mpegts",
        "-mpegts_flags",
        "+resend_headers",
        "-muxdelay",
        "0",
        path,
    ]
    # Burnt-in wall/frame counter is nice-to-have, not load-bearing, and
    # drawtext needs fontconfig + a findable font — not guaranteed on every
    # runner. Try it, fall back to a plain encode rather than failing the
    # whole fixture over cosmetics.
    vf = (
        "drawtext=text='%{pts\\:hms} frame %{n}':fontcolor=white:"
        "fontsize=28:x=10:y=10:box=1:boxcolor=black@0.5"
    )
    attempt = base_cmd + ["-vf", vf] + encode_cmd
    result = subprocess.run(attempt, capture_output=True)
    if result.returncode != 0:
        sys.stderr.write(
            "[live-cut] drawtext overlay failed (missing fontconfig/font?); "
            "retrying without the burnt-in counter\n"
        )
        sys.stderr.write(result.stderr.decode("utf-8", "replace")[-2000:] + "\n")
        subprocess.run(base_cmd + encode_cmd, check=True)
    # Sidecar so the server doesn't need ffprobe (or a re-passed --seconds) to
    # learn the fixture's duration later.
    with open(path + ".duration.json", "w") as f:
        json.dump({"seconds": seconds}, f)
    print(f"[live-cut] wrote {path} ({seconds:.0f}s)")


def _resolve_duration(ts_path: str, explicit_seconds: float | None, ffprobe: str) -> float:
    if explicit_seconds:
        return float(explicit_seconds)
    sidecar = ts_path + ".duration.json"
    if os.path.exists(sidecar):
        with open(sidecar) as f:
            return float(json.load(f)["seconds"])
    out = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            ts_path,
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return float(out.stdout.strip())


# ── Server ───────────────────────────────────────────────────────────────────


class LiveCutServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address,
        handler,
        *,
        ts_path: str,
        duration_seconds: float,
        burst_min: float,
        burst_max: float,
        hold_min: float,
        hold_max: float,
        rate: float,
        seed: int,
    ):
        super().__init__(address, handler)
        self.ts_path = ts_path
        file_bytes = os.path.getsize(ts_path)
        # Every offset this server ever hands out is a multiple of 188, so the
        # servable range is too.
        self.total_bytes = (file_bytes // TS_PACKET) * TS_PACKET
        if self.total_bytes < TS_PACKET:
            raise ValueError(f"{ts_path} is smaller than one TS packet")
        self.duration_seconds = duration_seconds
        self.bytes_per_sec = self.total_bytes / duration_seconds
        self.burst_min = burst_min
        self.burst_max = burst_max
        self.hold_min = hold_min
        self.hold_max = hold_max
        self.rate = rate
        self._rng = random.Random(seed)
        self.start_monotonic = time.monotonic()

        self.lock = threading.Lock()
        self._tokens: dict[int, bool] = {}  # token -> used
        self._next_token = 1
        self.connections_opened = 0
        self.tokens_minted = 0
        self.killed_by_single_connection = 0
        self.records: list[dict] = []
        self._active = None  # {"event": Event, "sock": socket}

    # -- live clock ----------------------------------------------------------

    def live_offset(self) -> int:
        """Byte offset of the live edge, snapped down to a packet boundary."""
        elapsed = time.monotonic() - self.start_monotonic
        pos = int(elapsed * self.bytes_per_sec)
        pos -= pos % TS_PACKET
        return max(0, min(pos, self.total_bytes - TS_PACKET))

    def live_window_exhausted(self) -> bool:
        return time.monotonic() - self.start_monotonic >= self.duration_seconds

    # -- tokens ----------------------------------------------------------------

    def mint_token(self) -> int:
        with self.lock:
            token = self._next_token
            self._next_token += 1
            self._tokens[token] = False
            self.tokens_minted += 1
        return token

    def claim_token(self, token: int) -> bool:
        """True exactly once per minted token; False for unknown/reused ones."""
        with self.lock:
            if token not in self._tokens or self._tokens[token]:
                return False
            self._tokens[token] = True
            return True

    def draw_burst_hold(self) -> tuple[float, float]:
        with self.lock:
            burst = self._rng.uniform(self.burst_min, self.burst_max)
            hold = self._rng.uniform(self.hold_min, self.hold_max)
        return burst, hold

    # -- single-connection slot ------------------------------------------------

    def begin_stream(self, sock: socket.socket) -> threading.Event:
        """Claims the server's one playback slot, killing whoever held it —
        the account is single-connection, so a new valid request always wins.
        """
        event = threading.Event()
        with self.lock:
            prev = self._active
            if prev is not None and not prev["event"].is_set():
                prev["event"].set()
                try:
                    prev["sock"].shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                self.killed_by_single_connection += 1
            self._active = {"event": event, "sock": sock}
            self.connections_opened += 1
        return event

    def end_stream(self, event: threading.Event) -> None:
        with self.lock:
            if self._active is not None and self._active["event"] is event:
                self._active = None

    def record_connection(self, record: dict) -> None:
        with self.lock:
            self.records.append(record)

    def stats_snapshot(self) -> dict:
        with self.lock:
            return {
                "connectionsOpened": self.connections_opened,
                "tokensMinted": self.tokens_minted,
                "killedBySingleConnection": self.killed_by_single_connection,
                "connections": list(self.records),
            }


class LiveCutHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: LiveCutServer  # narrows the type for readability below

    def log_message(self, fmt, *args):  # noqa: A002 - stdlib signature
        # Replaced by the one-line-per-connection log in `_handle_stream`.
        pass

    def do_GET(self):  # noqa: N802 - stdlib method name
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/resolve":
            return self._handle_resolve()
        if parsed.path == "/live.ts":
            return self._handle_stream(parsed, kind="rotating")
        if parsed.path == "/stable.ts":
            return self._handle_stream(parsed, kind="stable")
        if parsed.path == "/stats":
            return self._handle_stats()
        self.send_error(404)

    def _handle_resolve(self):
        token = self.server.mint_token()
        host = self.headers.get("Host") or f"127.0.0.1:{self.server.server_port}"
        url = f"http://{host}/live.ts?token={token}"
        body = url.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        print(f"[live-cut] resolve -> token={token}")

    def _handle_stream(self, parsed, kind: str):
        if self.server.live_window_exhausted():
            self.send_error(503, "live window exhausted")
            return
        token = None
        if kind == "rotating":
            qs = urllib.parse.parse_qs(parsed.query)
            raw = (qs.get("token") or [None])[0]
            if raw is None or not raw.isdigit() or not self.server.claim_token(int(raw)):
                self.send_error(403, "token missing, unknown, or already used")
                return
            token = int(raw)

        burst, hold = self.server.draw_burst_hold()
        record = {
            "kind": kind,
            "token": token,
            "burst": round(burst, 3),
            "hold": round(hold, 3),
            "bytes": 0,
            "startOffset": 0,
            "endOffset": 0,
        }
        event = self.server.begin_stream(self.connection)
        try:
            self._stream_body(record, event)
        finally:
            self.server.end_stream(event)
            self.server.record_connection(record)
            print(
                f"[live-cut] conn kind={kind} token={token} "
                f"burst={record['burst']}s hold={record['hold']}s "
                f"bytes={record['bytes']} "
                f"start_off={record['startOffset']} end_off={record['endOffset']}"
            )

    def _stream_body(self, record: dict, event: threading.Event) -> None:
        srv = self.server
        bps = srv.bytes_per_sec
        total = srv.total_bytes

        start_live = srv.live_offset()
        start_offset = max(0, start_live - int(record["burst"] * bps))
        start_offset -= start_offset % TS_PACKET
        pos = start_offset
        record["startOffset"] = pos

        try:
            self.send_response(200)
            self.send_header("Content-Type", "video/mp2t")
            self.send_header("Connection", "close")
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return
        self.close_connection = True

        phase_rate = srv.rate
        caught_up = False
        hold_deadline = None
        bytes_sent = 0
        try:
            with open(srv.ts_path, "rb") as f:
                while not event.is_set():
                    now_live = srv.live_offset()
                    if not caught_up and pos >= now_live:
                        caught_up = True
                        phase_rate = 1.0
                        hold_deadline = time.monotonic() + record["hold"]
                    if caught_up and time.monotonic() >= hold_deadline:
                        break  # clean close, as the real provider does

                    send_bytes = int(QUANTUM_SECONDS * phase_rate * bps)
                    send_bytes -= send_bytes % TS_PACKET
                    if send_bytes < TS_PACKET:
                        send_bytes = TS_PACKET
                    end = min(pos + send_bytes, total)
                    if end <= pos:
                        break  # ran off the end of the fixture
                    f.seek(pos)
                    chunk = f.read(end - pos)
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        break
                    bytes_sent += len(chunk)
                    pos += len(chunk)
                    time.sleep(QUANTUM_SECONDS)
        except FileNotFoundError:
            pass
        record["bytes"] = bytes_sent
        record["endOffset"] = pos

    def _handle_stats(self):
        body = json.dumps(self.server.stats_snapshot(), indent=2).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def start_server(args, duration: float) -> LiveCutServer:
    return LiveCutServer(
        ("0.0.0.0", args.port),
        LiveCutHandler,
        ts_path=args.ts,
        duration_seconds=duration,
        burst_min=args.burst_min,
        burst_max=args.burst_max,
        hold_min=args.hold_min,
        hold_max=args.hold_max,
        rate=args.rate,
        seed=args.seed,
    )


# ── Self-test (no ffmpeg, no server process, a few seconds) ────────────────


def _make_fake_ts(path: str, packet_count: int) -> None:
    with open(path, "wb") as f:
        for i in range(packet_count):
            pkt = bytearray(TS_PACKET)
            pkt[0] = SYNC_BYTE
            pkt[1:5] = struct.pack(">I", i)  # distinguishable, not load-bearing
            f.write(pkt)


class _SelfTestArgs:
    def __init__(self, ts_path: str):
        self.ts = ts_path
        self.port = 0
        self.burst_min = 2.0
        self.burst_max = 2.0
        self.hold_min = 3.0
        self.hold_max = 3.0
        self.rate = 4.0
        self.seed = 42


def run_self_test() -> None:
    tmpdir = tempfile.mkdtemp(prefix="livecut-selftest-")
    try:
        ts_path = os.path.join(tmpdir, "fixture.ts")
        _make_fake_ts(ts_path, packet_count=6000)  # ~1.1 MiB, packet-aligned
        duration = 20.0  # synthetic; only sets bytes_per_sec, no real playback

        server = start_server(_SelfTestArgs(ts_path), duration)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            resolve1 = (
                urllib.request.urlopen(base + "/resolve", timeout=5).read().decode().strip()
            )
            assert resolve1.startswith("http://"), resolve1

            reader_done = threading.Event()

            def _drain(url: str) -> None:
                try:
                    with urllib.request.urlopen(url, timeout=10) as resp:
                        while resp.read(4096):
                            pass
                except Exception:
                    pass  # the kill path below is *expected* to interrupt this
                finally:
                    reader_done.set()

            threading.Thread(target=_drain, args=(resolve1,), daemon=True).start()
            time.sleep(0.3)  # let the first connection start streaming

            resolve2 = (
                urllib.request.urlopen(base + "/resolve", timeout=5).read().decode().strip()
            )

            # Single-use: the first URL must now be refused outright.
            try:
                urllib.request.urlopen(resolve1, timeout=5)
                raise AssertionError("token reuse was not rejected with 403")
            except urllib.error.HTTPError as e:
                assert e.code == 403, f"expected 403 on token reuse, got {e.code}"

            # Opening the second token's stream is what kills the first.
            data2 = urllib.request.urlopen(resolve2, timeout=10).read()
            assert len(data2) > TS_PACKET, "second connection body too small"
            assert len(data2) % TS_PACKET == 0, "body is not packet-aligned"
            assert data2[0] == SYNC_BYTE
            assert all(
                data2[i] == SYNC_BYTE for i in range(0, len(data2), TS_PACKET)
            ), "sync byte missing at a 188-byte boundary"

            stable = urllib.request.urlopen(base + "/stable.ts", timeout=10).read()
            assert len(stable) >= TS_PACKET and stable[0] == SYNC_BYTE

            reader_done.wait(timeout=5)
            stats = json.loads(urllib.request.urlopen(base + "/stats", timeout=5).read())
            assert stats["tokensMinted"] >= 2, stats
            assert stats["killedBySingleConnection"] >= 1, stats

            print(
                "[live-cut] self-test OK:",
                json.dumps(
                    {
                        k: stats[k]
                        for k in (
                            "connectionsOpened",
                            "tokensMinted",
                            "killedBySingleConnection",
                        )
                    }
                ),
            )
        finally:
            server.shutdown()
            server.server_close()
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


# ── CLI ──────────────────────────────────────────────────────────────────────


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--ts", help="path to the MPEG-TS fixture to serve")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument(
        "--seconds",
        type=float,
        default=None,
        help="fixture duration; falls back to the --make-ts sidecar, then ffprobe",
    )
    p.add_argument("--burst-min", type=float, default=20.0)
    p.add_argument("--burst-max", type=float, default=30.0)
    p.add_argument("--rate", type=float, default=6.0)
    p.add_argument("--hold-min", type=float, default=6.0)
    p.add_argument("--hold-max", type=float, default=18.0)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument(
        "--make-ts", metavar="PATH", help="generate a synthetic fixture at PATH and exit"
    )
    p.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg binary (for --make-ts)")
    p.add_argument(
        "--ffprobe",
        default=None,
        help="ffprobe binary; defaults to --ffmpeg with 'ffmpeg' replaced by 'ffprobe'",
    )
    p.add_argument(
        "--self-test",
        action="store_true",
        help="run an in-process smoke test and exit; needs no ffmpeg or fixture",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    if args.self_test:
        run_self_test()
        return 0

    if args.make_ts:
        make_ts(args.make_ts, args.seconds or 900.0, ffmpeg=args.ffmpeg)
        return 0

    if not args.ts:
        parser.error("--ts is required unless --make-ts or --self-test is given")

    ffprobe = args.ffprobe or args.ffmpeg.replace("ffmpeg", "ffprobe")
    duration = _resolve_duration(args.ts, args.seconds, ffprobe)
    server = start_server(args, duration)
    print(
        f"[live-cut] serving {args.ts} ({duration:.1f}s, "
        f"{server.bytes_per_sec:.0f} B/s) on 0.0.0.0:{server.server_port} "
        f"burst=[{args.burst_min},{args.burst_max}]s rate={args.rate}x "
        f"hold=[{args.hold_min},{args.hold_max}]s seed={args.seed}"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
