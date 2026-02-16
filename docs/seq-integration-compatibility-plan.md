# seq Integration Compatibility Plan

This document describes how to integrate Karabiner `send_user_command` with seq while preserving the current seq flow.

## Goal

Add a low-latency JSON datagram path without breaking existing:

- Karabiner config usage of `seqSocket(...)`
- seqd command protocol on `/tmp/seqd.sock`
- macro names and behavior in `/Users/nikiv/config/i/kar/config.ts`

## Compatibility contract

1. Keep legacy transport as-is:
   - direct commands to `/tmp/seqd.sock` or `/tmp/seqd.sock.dgram`
2. Add new transport as optional:
   - Karabiner -> `send_user_command` JSON -> receiver socket
3. Map new payloads to existing seqd command lines:
   - `{"type":"run","name":"X"}` -> `RUN X`
   - `{"type":"open_app_toggle","app":"Safari"}` -> `OPEN_APP_TOGGLE Safari`
4. Never require migration of existing macros for correctness.

## Bridge role

`seq-user-command-bridge` (in this repo) is the adapter between the new Karabiner payload format and current seqd protocol.

Input:

- UNIX datagram JSON payloads at:
  - `~/.local/share/karabiner/tmp/karabiner_user_command_receiver.sock`

Output:

- seqd dgram/stream command lines:
  - `/tmp/seqd.sock.dgram` (preferred)
  - `/tmp/seqd.sock` (fallback)

## Suggested rollout

1. Baseline
   - Keep all macros on existing `seqSocket(...)`.
2. Pilot
   - Move 5-10 low-risk macros to `send_user_command` payloads.
3. Measure
   - Compare success/failure and p95 latency vs legacy path.
4. Expand
   - Migrate incrementally only if parity is proven.
5. Long-term
   - Keep legacy path available until explicit deprecation decision.

## Failure strategy

- If bridge is down:
  - legacy `seqSocket(...)` path still works.
- If seqd dgram is unavailable:
  - bridge automatically falls back to stream socket.
- If payload is unknown:
  - bridge ignores it and logs an error (no crash).

## Operational commands

Build:

```bash
make build-bridge
```

Run:

```bash
make run-bridge
```

Test one command:

```bash
python3 - <<'PY'
import json, os, socket
path = os.path.expanduser("~/.local/share/karabiner/tmp/karabiner_user_command_receiver.sock")
msg = {"v": 1, "type": "run", "name": "open Safari new tab"}
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.sendto(json.dumps(msg).encode("utf-8"), path)
PY
```
