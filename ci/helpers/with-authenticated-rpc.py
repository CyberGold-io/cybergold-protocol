#!/usr/bin/env python3
"""Keep an HTTPS bearer in a local adapter while running a URL-only RPC client.

The adapter has no RPC policy, retries, logs, or redirect handling. Upstream
HTTP/RPC failures remain the caller's failures. Only the adapter receives the
selected bearer; its child receives a loopback URL.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import socketserver
import subprocess
import sys
import threading
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[2]
TARGETS = {
    "mainnet": ("local-mainnet-tooling.env", "MAINNET_RPC_URL", "MAINNET_RPC_BEARER", "https://rpc-mainnet.cybergold.io/", "0x1"),
    "fork-full": ("local-fork-full.env", "DISTANT_FORKNET_RPC_URL", "CYBERGOLD_LOCAL_FORK_FULL_TOKEN", "https://rpc-fork.cybergold.io/", "0x7a6a"),
}


def read_environment(path: Path) -> dict[str, str]:
    """Read the same simple quoted assignments written by the credential installer."""
    result = {}
    if path.exists():
        for line in path.read_text().splitlines():
            words = shlex.split(line, comments=True)
            if words and words[0] == "export":
                words.pop(0)
            if words:
                name, value = words[0].split("=", 1)
                result[name] = value
    return result


class Adapter:
    def __init__(self, upstream: str, bearer: str, timeout: float = 70):
        self.upstream = upstream
        self.bearer = bearer
        self.timeout = timeout
        self.server = None
        self.thread = None

    def request(self, body: bytes) -> tuple[int, str, bytes]:
        parsed = urlsplit(self.upstream)
        connection_type = {"https": http.client.HTTPSConnection, "http": http.client.HTTPConnection}[parsed.scheme]
        connection = connection_type(parsed.hostname, parsed.port, timeout=self.timeout)
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        try:
            connection.request("POST", path, body=body, headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer " + self.bearer,
            })
            response = connection.getresponse()
            payload = response.read()
            # An upstream diagnostic may echo a request header. Never return it
            # to Forge/Cast logs. Ordinary RPC results/errors stay intact.
            payload = payload.replace(self.bearer.encode(), b"<redacted-rpc-bearer>")
            content_type = response.getheader("Content-Type", "application/json").replace(self.bearer, "<redacted>")
            return response.status, content_type, payload
        finally:
            connection.close()

    def probe(self, expected_chain: str, *, anvil: bool = False) -> None:
        status, _, payload = self.request(json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": [],
        }).encode())
        if status != 200:
            raise RuntimeError(f"eth_chainId returned HTTP {status}")
        document = json.loads(payload)
        if not isinstance(document, dict):
            raise RuntimeError("eth_chainId returned an invalid RPC response")
        if "error" in document:
            raise RuntimeError("eth_chainId returned an RPC error")
        if document.get("result") != expected_chain:
            raise RuntimeError(f"eth_chainId did not return expected chain {expected_chain}")
        if anvil:
            status, _, payload = self.request(json.dumps({
                "jsonrpc": "2.0", "id": 2, "method": "web3_clientVersion", "params": [],
            }).encode())
            document = json.loads(payload)
            if status != 200:
                raise RuntimeError(f"web3_clientVersion returned HTTP {status}")
            if not isinstance(document, dict):
                raise RuntimeError("web3_clientVersion returned an invalid RPC response")
            if "anvil" not in str(document.get("result", "")).lower():
                raise RuntimeError("web3_clientVersion did not identify Anvil")

    def __enter__(self):
        adapter = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                try:
                    body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                    status, content_type, payload = adapter.request(body)
                except (OSError, ValueError, KeyError, http.client.HTTPException):
                    status, content_type, payload = 502, "application/json", b'{"error":"RPC upstream transport failed"}'
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                try:
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


@contextmanager
def stop_socket(path: Path | None, stop: threading.Event):
    """A persistent fork's run directory addresses its supervisor, not a stale PID."""
    if path is None:
        yield
        return

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            if self.rfile.readline() == b"stop\n":
                stop.set()

    server = socketserver.UnixStreamServer(str(path), Handler)
    os.chmod(path, 0o600)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
        path.unlink(missing_ok=True)


def stop_child(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    if process.poll() is None:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def run(command: list[str], adapter: Adapter, environment: dict[str, str], export_name: str,
        cwd: str | None = None, control: Path | None = None) -> int:
    stop = threading.Event()
    previous = {}
    for signum in (signal.SIGINT, signal.SIGTERM):
        previous[signum] = signal.signal(signum, lambda *_args: stop.set())
    process = None
    try:
        with adapter, stop_socket(control, stop):
            environment[export_name] = adapter.url
            command = [adapter.url if arg == "{RPC_URL}" else arg for arg in command]
            process = subprocess.Popen(command, cwd=cwd, env=environment, start_new_session=True)
            while process.poll() is None and not stop.wait(0.1):
                pass
            if stop.is_set():
                stop_child(process)
                return 130
            return process.returncode if process.returncode >= 0 else 128 - process.returncode
    finally:
        if process is not None:
            stop_child(process)
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=TARGETS, default="mainnet")
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--cwd")
    parser.add_argument("--control-socket", type=Path)
    parser.add_argument("--control-run-dir", type=Path)
    parser.add_argument("--stop", type=Path, help="stop the persistent fork supervisor at this socket")
    parser.add_argument("--stop-run-dir", type=Path, help="stop the fork started by this run")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    run_dir = args.stop_run_dir or args.control_run_dir
    if run_dir is not None:
        # macOS Unix socket paths are short. A deterministic local name lets
        # the operator address this run without relying on a reusable PID.
        digest = hashlib.sha256(str(run_dir.resolve()).encode()).hexdigest()[:32]
        path = Path("/tmp") / f"cg-rpc-{digest}.sock"
        if args.stop_run_dir is not None:
            args.stop = path
        else:
            args.control_socket = path
    if args.stop is not None:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.connect(str(args.stop))
            connection.sendall(b"stop\n")
        return 0
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command after -- is required")
    filename, url_name, token_name, default_url, chain = TARGETS[args.target]
    env_file = args.env_file or ROOT / "env" / filename
    environment = read_environment(env_file)
    environment.update(os.environ)
    bearer = environment.pop(token_name, "")
    if not bearer:
        print(f"Authenticated RPC: missing {token_name} (configure {filename})", file=sys.stderr)
        return 1
    upstream = environment.get(url_name) or default_url
    environment["CYBERGOLD_RPC_TARGET"] = args.target
    environment["CYBERGOLD_RPC_ENV_FILE"] = str(env_file.resolve())
    environment["CYBERGOLD_RPC_UPSTREAM_URL"] = upstream
    adapter = Adapter(upstream, bearer)
    try:
        adapter.probe(chain, anvil=args.target == "fork-full")
        return run(command, adapter, environment, url_name, args.cwd, args.control_socket)
    except (OSError, ValueError, KeyError, http.client.HTTPException):
        print("Authenticated RPC: transport, configuration or command failed", file=sys.stderr)
        return 1
    except RuntimeError as error:
        print(f"Authenticated RPC: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
