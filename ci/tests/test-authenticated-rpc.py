from __future__ import annotations

from contextlib import contextmanager
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/helpers/with-authenticated-rpc.py"
SPEC = importlib.util.spec_from_file_location("authenticated_rpc", SCRIPT)
rpc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rpc)
TOKEN = "synthetic-bearer-" + "a" * 43


@contextmanager
def upstream(status=200, response=None, redirect=None, delay=0):
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            calls.append((self.path, self.headers.get("Authorization"), body))
            parsed = json.loads(body)
            payload = response if response is not None else json.dumps({"jsonrpc": "2.0", "id": 1, "result": "0x1"}).encode()
            probe = isinstance(parsed, dict) and parsed.get("method") == "eth_chainId"
            time.sleep(delay)
            self.send_response(200 if probe else status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            if redirect:
                self.send_header("Location", redirect)
            self.end_headers()
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", calls
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def post(url, body):
    connection = http.client.HTTPConnection(url.removeprefix("http://"), timeout=3)
    try:
        connection.request("POST", "/", body=body)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


class AuthenticatedRpcTest(unittest.TestCase):
    def test_batch_header_and_payload_are_forwarded_once(self):
        batch = b'[{"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":[]}]'
        result = b'[{"jsonrpc":"2.0","id":1,"result":"0x1234"}]'
        with upstream(response=result) as (url, calls), rpc.Adapter(url, TOKEN) as adapter:
            self.assertEqual(post(adapter.url, batch), (200, result))
            self.assertEqual(calls, [("/", "Bearer " + TOKEN, batch)])

    def test_redirect_never_contacts_second_origin(self):
        with upstream() as (other, other_calls), upstream(status=307, redirect=other) as (url, calls):
            with rpc.Adapter(url, TOKEN) as adapter:
                status, _ = post(adapter.url, b'{"method":"eth_call"}')
            self.assertEqual(status, 307)
            self.assertEqual(len(calls), 1)
            self.assertEqual(other_calls, [])

    def test_http_and_rpc_errors_preserve_status_without_secret_echo(self):
        for status in (200, 403, 429, 503):
            body = json.dumps({"error": {"code": -32000, "message": TOKEN}}).encode()
            with self.subTest(status=status), upstream(status=status, response=body) as (url, _):
                with rpc.Adapter(url, TOKEN) as adapter:
                    actual_status, payload = post(adapter.url, b'{"method":"eth_call"}')
                self.assertEqual(actual_status, status)
                self.assertNotIn(TOKEN.encode(), payload)
                self.assertEqual(json.loads(payload)["error"]["code"], -32000)

    def test_timeout_and_large_responses(self):
        large = json.dumps({"result": "a" * 2_000_000}).encode()
        with upstream(response=large) as (url, _), rpc.Adapter(url, TOKEN) as adapter:
            self.assertEqual(post(adapter.url, b'{"method":"eth_getLogs"}'), (200, large))
        with upstream(delay=0.15) as (url, calls), rpc.Adapter(url, TOKEN, timeout=0.03) as adapter:
            self.assertEqual(post(adapter.url, b'{"method":"eth_call"}'), (502, b'{"error":"RPC upstream transport failed"}'))
            self.assertEqual(len(calls), 1)
        with socket.socket() as unavailable:
            unavailable.bind(("127.0.0.1", 0))
            url = f"http://127.0.0.1:{unavailable.getsockname()[1]}"
            with rpc.Adapter(url, TOKEN, timeout=0.05) as adapter:
                status, payload = post(adapter.url, b'{"method":"eth_call"}')
            self.assertEqual(status, 502)
            self.assertNotIn(TOKEN.encode(), payload)

    def test_existing_chain_and_anvil_identity_contracts(self):
        adapter = rpc.Adapter("https://rpc.example/", TOKEN)
        for status, document, error in (
            (403, {}, "eth_chainId returned HTTP 403"),
            (200, [], "invalid RPC response"),
            (200, {"error": {"message": TOKEN}}, "eth_chainId returned an RPC error"),
            (200, {"result": "0x1"}, "expected chain 0x7a6a"),
        ):
            with self.subTest(document=document), mock.patch.object(adapter, "request", return_value=(status, "application/json", json.dumps(document).encode())):
                with self.assertRaisesRegex(RuntimeError, error) as failure:
                    adapter.probe("0x7a6a", anvil=True)
                self.assertNotIn(TOKEN, str(failure.exception))
        chain = (200, "application/json", b'{"result":"0x7a6a"}')
        for status, version, error in (
            (200, {"result": "anvil/v1.4"}, None),
            (503, {}, "web3_clientVersion returned HTTP 503"),
            (200, [], "invalid RPC response"),
            (200, {"result": "other-client"}, "did not identify Anvil"),
        ):
            with self.subTest(version=version), mock.patch.object(adapter, "request", side_effect=[chain, (status, "application/json", json.dumps(version).encode())]):
                if error:
                    with self.assertRaisesRegex(RuntimeError, error):
                        adapter.probe("0x7a6a", anvil=True)
                else:
                    adapter.probe("0x7a6a", anvil=True)

    def test_concurrent_adapters_keep_separate_bearers_and_close(self):
        with upstream() as (url, calls):
            with rpc.Adapter(url, TOKEN) as first, rpc.Adapter(url, "second-token") as second:
                first_url = first.url
                self.assertNotEqual(first.url, second.url)
                post(first.url, b'{"method":"eth_call"}')
                post(second.url, b'{"method":"eth_call"}')
            self.assertEqual([call[1] for call in calls], ["Bearer " + TOKEN, "Bearer second-token"])
            with self.assertRaises(OSError):
                post(first_url, b'{}')

    def test_wrapper_cwd_exit_status_and_secret_free_child(self):
        with upstream() as (url, _), tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "MAINNET_RPC_URL": url, "MAINNET_RPC_BEARER": TOKEN}
            code = "import os,sys; print(os.getcwd()); print(os.environ['MAINNET_RPC_URL']); assert 'MAINNET_RPC_BEARER' not in os.environ; sys.exit(23)"
            result = subprocess.run([sys.executable, str(SCRIPT), "--cwd", directory, "--", sys.executable, "-c", code], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertIn(str(Path(directory).resolve()), result.stdout)
            self.assertIn("http://127.0.0.1:", result.stdout)
            self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_missing_bearer_does_not_start_child_or_ssh(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {key: value for key, value in os.environ.items() if key != "MAINNET_RPC_BEARER"}
            result = subprocess.run([sys.executable, str(SCRIPT), "--env-file", str(Path(directory) / "missing.env"), "--", "does-not-exist"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("missing MAINNET_RPC_BEARER", result.stderr)
            self.assertNotIn("does-not-exist", result.stderr)

    def test_environment_is_parsed_without_shell_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "credentials.env"
            path.write_text("MAINNET_RPC_BEARER='$(touch should-not-exist)'\n")
            self.assertEqual(rpc.read_environment(path)["MAINNET_RPC_BEARER"], "$(touch should-not-exist)")

    def test_signal_and_persistent_stop_remove_owned_listener(self):
        for use_socket in (False, True):
            with self.subTest(socket=use_socket), upstream() as (url, _), tempfile.TemporaryDirectory(prefix="rpc-", dir="/tmp") as directory:
                control = Path(directory) / "stop.sock"
                marker = Path(directory) / "url"
                code = "import os,time; from pathlib import Path; Path(os.environ['MARKER']).write_text(os.environ['MAINNET_RPC_URL']); time.sleep(60)"
                args = [sys.executable, str(SCRIPT)]
                if use_socket:
                    args.extend(["--control-socket", str(control)])
                args.extend(["--", sys.executable, "-c", code])
                env = {**os.environ, "MAINNET_RPC_URL": url, "MAINNET_RPC_BEARER": TOKEN, "MARKER": str(marker)}
                process = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 5
                    while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue(marker.exists())
                    local_url = marker.read_text()
                    if use_socket:
                        subprocess.run([sys.executable, str(SCRIPT), "--stop", str(control)], check=True)
                    else:
                        process.send_signal(signal.SIGTERM)
                    out, err = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 130, err)
                    self.assertNotIn(TOKEN, out + err)
                    self.assertFalse(control.exists())
                    with self.assertRaises(OSError):
                        post(local_url, b'{}')
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate()


if __name__ == "__main__":
    unittest.main()
