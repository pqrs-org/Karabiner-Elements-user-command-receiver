#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
  p = argparse.ArgumentParser(
    description=(
      "Smoke test seq-user-command-bridge with a mock seqd datagram socket."
    )
  )
  p.add_argument(
    "--bridge-bin",
    default=".build/debug/seq-user-command-bridge",
    help="Path to bridge binary.",
  )
  p.add_argument(
    "--timeout-s",
    type=float,
    default=2.0,
    help="Socket timeout in seconds.",
  )
  p.add_argument(
    "--build-if-missing",
    action="store_true",
    help="Run `make build-bridge` if --bridge-bin does not exist.",
  )
  p.add_argument("--verbose", action="store_true")
  return p.parse_args()


def ensure_bridge_binary(path: Path, build_if_missing: bool) -> Path:
  if path.exists():
    return path
  if not build_if_missing:
    raise FileNotFoundError(f"bridge binary not found: {path}")
  res = subprocess.run(
    ["make", "build-bridge"],
    check=False,
    capture_output=True,
    text=True,
  )
  if res.returncode != 0:
    raise RuntimeError("failed to build bridge:\n" + res.stdout + "\n" + res.stderr)
  if not path.exists():
    raise FileNotFoundError(f"bridge binary not found after build: {path}")
  return path


def wait_for_socket(path: Path, timeout_s: float) -> bool:
  deadline = time.time() + timeout_s
  while time.time() < deadline:
    if path.exists():
      return True
    time.sleep(0.01)
  return False


def send_payload(path: Path, payload: object) -> None:
  s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
  try:
    s.sendto(json.dumps(payload, separators=(",", ":")).encode("utf-8"), str(path))
  finally:
    s.close()


def recv_line(sock: socket.socket, timeout_s: float) -> str:
  sock.settimeout(timeout_s)
  data, _ = sock.recvfrom(4096)
  return data.decode("utf-8", errors="replace")


def main() -> int:
  args = parse_args()
  bridge_bin = ensure_bridge_binary(Path(args.bridge_bin), args.build_if_missing)

  with tempfile.TemporaryDirectory(prefix="bridge-smoke-") as td:
    tmp = Path(td)
    receiver_sock = tmp / "kar.sock"
    seq_dgram_sock = tmp / "seqd.sock.dgram"
    seq_stream_sock = tmp / "seqd.sock"

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
      listener.bind(str(seq_dgram_sock))
      bridge = subprocess.Popen(
        [
          str(bridge_bin),
          "--receiver-socket",
          str(receiver_sock),
          "--seq-dgram-socket",
          str(seq_dgram_sock),
          "--seq-stream-socket",
          str(seq_stream_sock),
          "--verbose",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
      )
      try:
        if not wait_for_socket(receiver_sock, args.timeout_s):
          stderr = bridge.communicate(timeout=1.0)[1]
          print("error: bridge receiver socket was not created", file=sys.stderr)
          if stderr:
            print(stderr, file=sys.stderr)
          return 2

        cases: list[tuple[object, str]] = [
          ({"v": 1, "type": "run", "name": "open Safari new tab"}, "RUN open Safari new tab\n"),
          ({"v": 1, "type": "open_app_toggle", "app": "Safari"}, "OPEN_APP_TOGGLE Safari\n"),
          ({"command": "RUN New Linear task"}, "RUN New Linear task\n"),
          ({"line": "PING"}, "PING\n"),
        ]

        for i, (payload, expected) in enumerate(cases, start=1):
          send_payload(receiver_sock, payload)
          actual = recv_line(listener, args.timeout_s)
          if actual != expected:
            print(f"error: case {i} mismatch", file=sys.stderr)
            print(f"expected: {expected!r}", file=sys.stderr)
            print(f"actual:   {actual!r}", file=sys.stderr)
            return 3
          if args.verbose:
            print(f"ok case {i}: {expected.rstrip()}")

        print("ok: bridge smoke test passed")
        return 0
      finally:
        bridge.terminate()
        try:
          _out, err = bridge.communicate(timeout=1.0)
        except subprocess.TimeoutExpired:
          bridge.kill()
          _out, err = bridge.communicate(timeout=1.0)
        if args.verbose and err:
          print(err.rstrip())
    finally:
      listener.close()


if __name__ == "__main__":
  raise SystemExit(main())
