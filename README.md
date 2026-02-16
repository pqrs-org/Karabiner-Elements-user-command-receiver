# Karabiner-Elements-user-command-receiver

This Swift package provides a receiver for Karabiner-Elements `send_user_command` commands.
By integrating this package to build your own server, you can execute arbitrary processing from Karabiner-Elements with low latency.

## seq integration (additive, backward compatible)

This repo now includes an optional bridge executable:

- `seq-user-command-bridge`

It listens on Karabiner's user-command socket and forwards commands to existing `seqd` sockets.
This is additive only: current `seqSocket(...)` macros and `/tmp/seqd.sock` usage continue to work unchanged.

Bridge behavior:

- receives JSON datagrams on `~/.local/share/karabiner/tmp/karabiner_user_command_receiver.sock`
- converts payloads into existing seqd command lines (`RUN ...`, `OPEN_APP_TOGGLE ...`)
- forwards to seqd using dgram first (`/tmp/seqd.sock.dgram`) with stream fallback (`/tmp/seqd.sock`)

Pilot Karabiner snippets:

- `docs/karabiner/seq-pilot-5-legacy.json`
- `docs/karabiner/seq-pilot-5-user-command-template.json`
- `docs/karabiner/pilot-5-usage.md`
- `docs/maintainer-seq-integration-test-kit.md`

Supported payload examples:

```json
{"v":1,"type":"run","name":"open Safari new tab"}
{"v":1,"type":"open_app_toggle","app":"Safari"}
{"command":"RUN New Linear task"}
{"line":"OPEN_APP_TOGGLE Arc"}
```

## What this is

- A Swift package exposing `KEUserCommandReceiver`.
- It binds a UNIX datagram socket (`AF_UNIX` + `SOCK_DGRAM`), receives JSON payloads, and calls your handler.
- Included `Example/ExampleApp` is a minimal SwiftUI app that starts/stops the receiver and shows received JSON.

Default socket path used by the example:

`~/.local/share/karabiner/tmp/karabiner_user_command_receiver.sock`

## Running locally

### 1. Build package

```bash
make build
```

### 1b. Build bridge executable

```bash
make build-bridge
```

### 2. Build example app (no signing required)

```bash
make build-example
```

This build is configured with:

- `CODE_SIGNING_ALLOWED=NO`
- `CODE_SIGNING_REQUIRED=NO`

so it works without your personal "Mac Development" certificate.

### 3. Run example app

Open in Xcode:

```bash
make xcode-example
```

Then run `ExampleApp`, press `Start` in the UI.

### 4. Send a test command

```bash
make send-command
```

This sends:

```json
{"type":"test","value":1}
```

to the default socket path via Python stdlib (`socket.AF_UNIX` + `SOCK_DGRAM`), so no `socat` install is needed.

### 5. Run seq bridge

```bash
make run-bridge
```

Then send a v1 payload:

```bash
python3 - <<'PY'
import json, os, socket
path = os.path.expanduser("~/.local/share/karabiner/tmp/karabiner_user_command_receiver.sock")
msg = {"v": 1, "type": "run", "name": "open Safari new tab"}
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.sendto(json.dumps(msg).encode("utf-8"), path)
PY
```
