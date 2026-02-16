# Maintainer seq Integration Test Kit

This test kit is for maintainers to validate that Karabiner user-command integration works on top of seq and to compare latency overhead with a reproducible local benchmark.

## What this tests

1. Functional correctness:
   - JSON payload received by `seq-user-command-bridge`
   - Correct translation to seqd command lines
   - Correct forwarding to seqd datagram socket
2. Transport latency overhead:
   - `direct_dgram` vs `bridge_via_user_command`
   - reports p50/p95/p99 in microseconds

This kit is transport-focused. It does not include app activation/UI frame latency.

## Prerequisites

- macOS
- Python 3
- Swift toolchain
- This repo checked out

## Quick start

```bash
python3 tools/bridge_smoke_test.py --build-if-missing --verbose
python3 tools/bridge_latency_bench.py --build-if-missing --iterations 300 --warmup 40
```

## Scripts

- `tools/bridge_smoke_test.py`
  - validates 4 payload shapes:
    - `{"v":1,"type":"run","name":"..."}`
    - `{"v":1,"type":"open_app_toggle","app":"..."}`
    - `{"command":"RUN ..."}`
    - `{"line":"PING"}`
- `tools/bridge_latency_bench.py`
  - benchmarks:
    - direct send to mock seqd dgram
    - send to receiver socket then bridge-forward to mock seqd dgram

## Example benchmark run with JSON output

```bash
python3 tools/bridge_latency_bench.py \
  --build-if-missing \
  --iterations 500 \
  --warmup 80 \
  --json-out /tmp/bridge_bench.json
```

## How to interpret

- `bridge_via_user_command` should remain close to `direct_dgram`.
- Focus on `p95_us` and `p99_us` for stability.
- `p95_overhead_ratio` near `1.0x` is ideal.

## Live seq check (optional)

After transport validation, run bridge against real seqd:

Terminal A:

```bash
cd ~/code/seq
f deploy
cd ~/repos/pqrs-org/Karabiner-Elements-user-command-receiver
make run-bridge
```

Terminal B:

```bash
cd ~/code/seq
python3 tools/kar_user_command_send.py --run "open Safari new tab"
```

Expected: bridge logs forwarding and seq executes macro as normal.

## Troubleshooting

`bind(dgram) failed errno=2` for receiver path usually means the parent directory does not exist.

Create it first:

```bash
mkdir -p ~/.local/share/karabiner/tmp
```

Then re-run:

```bash
make run-bridge
```
