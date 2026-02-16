#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import socket
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
  p = argparse.ArgumentParser(
    description="Benchmark direct seqd dgram vs user_command->bridge->seqd dgram latency."
  )
  p.add_argument("--bridge-bin", default=".build/debug/seq-user-command-bridge")
  p.add_argument("--iterations", type=int, default=300)
  p.add_argument("--warmup", type=int, default=40)
  p.add_argument("--timeout-s", type=float, default=2.0)
  p.add_argument("--json-out", default="")
  p.add_argument("--build-if-missing", action="store_true")
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


def percentile(values: list[float], p: float) -> float:
  if not values:
    return 0.0
  if len(values) == 1:
    return values[0]
  idx = int(round((p / 100.0) * (len(values) - 1)))
  idx = max(0, min(idx, len(values) - 1))
  return values[idx]


def summarize(name: str, values_us: list[float]) -> dict[str, float | int | str]:
  sorted_values = sorted(values_us)
  return {
    "name": name,
    "count": len(sorted_values),
    "min_us": sorted_values[0] if sorted_values else 0.0,
    "p50_us": percentile(sorted_values, 50),
    "p90_us": percentile(sorted_values, 90),
    "p95_us": percentile(sorted_values, 95),
    "p99_us": percentile(sorted_values, 99),
    "max_us": sorted_values[-1] if sorted_values else 0.0,
    "mean_us": statistics.fmean(sorted_values) if sorted_values else 0.0,
  }


def bench_direct_dgram(
  listener: socket.socket,
  seq_dgram_sock: Path,
  iterations: int,
  warmup: int,
  timeout_s: float,
) -> list[float]:
  sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
  values: list[float] = []
  try:
    total = iterations + warmup
    for i in range(total):
      line = f"RUN bench-direct-{i}\n".encode("utf-8")
      t0 = time.perf_counter_ns()
      sender.sendto(line, str(seq_dgram_sock))
      listener.settimeout(timeout_s)
      got, _ = listener.recvfrom(4096)
      t1 = time.perf_counter_ns()
      if got != line:
        raise RuntimeError(f"direct mismatch at {i}: {got!r}")
      if i >= warmup:
        values.append((t1 - t0) / 1000.0)
  finally:
    sender.close()
  return values


def bench_bridge_dgram(
  listener: socket.socket,
  receiver_sock: Path,
  iterations: int,
  warmup: int,
  timeout_s: float,
) -> list[float]:
  sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
  values: list[float] = []
  try:
    total = iterations + warmup
    for i in range(total):
      expected = f"RUN bench-bridge-{i}\n".encode("utf-8")
      payload = {"v": 1, "type": "run", "name": f"bench-bridge-{i}"}
      t0 = time.perf_counter_ns()
      sender.sendto(json.dumps(payload, separators=(",", ":")).encode("utf-8"), str(receiver_sock))
      listener.settimeout(timeout_s)
      got, _ = listener.recvfrom(4096)
      t1 = time.perf_counter_ns()
      if got != expected:
        raise RuntimeError(f"bridge mismatch at {i}: {got!r}")
      if i >= warmup:
        values.append((t1 - t0) / 1000.0)
  finally:
    sender.close()
  return values


def print_summary(row: dict[str, float | int | str]) -> None:
  print(
    f"{row['name']:<28} "
    f"n={row['count']:<4} "
    f"p50={row['p50_us']:.1f}us "
    f"p95={row['p95_us']:.1f}us "
    f"p99={row['p99_us']:.1f}us "
    f"mean={row['mean_us']:.1f}us"
  )


def main() -> int:
  args = parse_args()
  bridge_bin = ensure_bridge_binary(Path(args.bridge_bin), args.build_if_missing)

  with tempfile.TemporaryDirectory(prefix="bridge-bench-") as td:
    tmp = Path(td)
    receiver_sock = tmp / "kar.sock"
    seq_dgram_sock = tmp / "seqd.sock.dgram"
    seq_stream_sock = tmp / "seqd.sock"

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
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
      ],
      stdout=subprocess.PIPE,
      stderr=subprocess.PIPE,
      text=True,
    )

    try:
      if not wait_for_socket(receiver_sock, args.timeout_s):
        _out, err = bridge.communicate(timeout=1.0)
        raise RuntimeError("bridge receiver socket not created\n" + (err or ""))

      direct = bench_direct_dgram(
        listener=listener,
        seq_dgram_sock=seq_dgram_sock,
        iterations=args.iterations,
        warmup=args.warmup,
        timeout_s=args.timeout_s,
      )
      bridged = bench_bridge_dgram(
        listener=listener,
        receiver_sock=receiver_sock,
        iterations=args.iterations,
        warmup=args.warmup,
        timeout_s=args.timeout_s,
      )

      rows = [summarize("direct_dgram", direct), summarize("bridge_via_user_command", bridged)]
      print_summary(rows[0])
      print_summary(rows[1])

      ratio = (rows[1]["p95_us"] / rows[0]["p95_us"]) if rows[0]["p95_us"] else 0.0
      print(f"p95 overhead ratio (bridge/direct): {ratio:.2f}x")

      result = {
        "iterations": args.iterations,
        "warmup": args.warmup,
        "results": rows,
        "p95_overhead_ratio": ratio,
      }
      if args.json_out:
        out = Path(args.json_out)
        out.write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(f"json: {out}")

      return 0
    finally:
      listener.close()
      bridge.terminate()
      try:
        _out, _err = bridge.communicate(timeout=1.0)
      except subprocess.TimeoutExpired:
        bridge.kill()
        bridge.communicate(timeout=1.0)


if __name__ == "__main__":
  raise SystemExit(main())
