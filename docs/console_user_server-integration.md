# console_user_server Integration Guide

This repository contains a receiver library for Karabiner-Elements `send_user_command`.
It does not implement `console_user_server` itself, but it is designed to receive payloads that are routed through it.

## What `console_user_server` does

In Karabiner-Elements, `console_user_server` is the user-session side service.
Its job is to execute user-context operations that should not run in privileged CoreService context.

For `send_user_command`, this typically means:

1. Karabiner event processing decides a `send_user_command` should fire.
2. The command is forwarded to `console_user_server`.
3. `console_user_server` sends the command payload to a local UNIX socket endpoint.
4. A user process (your app/server) receives and handles the payload.

## How this package interacts with it

`KEUserCommandReceiver` in `Sources/KarabinerElementsUserCommandReceiver/KarabinerElementsUserCommandReceiver.swift`:

- binds an `AF_UNIX` + `SOCK_DGRAM` socket at a path you provide,
- receives datagrams in a loop,
- parses each datagram as JSON using `JSONSerialization`,
- calls your `onJSON` handler with the parsed object.

Default path used by the example app:

`~/.local/share/karabiner/tmp/karabiner_user_command_receiver.sock`

This path is where Karabiner-Elements sends user command datagrams when configured for this receiver.

## Message format

- Transport: UNIX domain datagram (`SOCK_DGRAM`)
- Payload: JSON bytes
- Newline handling: trailing `\n` and `\r\n` are tolerated before JSON parse
- JSON type: object, array, scalar are all accepted (`.fragmentsAllowed`)

Example payload:

```json
{"type":"test","value":1}
```

## Runtime lifecycle

- `start()`:
  - validates and binds socket path,
  - optionally applies receive buffer size (`SO_RCVBUF`),
  - starts a detached receive loop task.
- `stop()`:
  - cancels the receive task,
  - closes the socket fd,
  - unlinks the socket file path.

## Security boundary model

The important separation is:

- privileged event pipeline: key processing and low-level device work,
- user-context dispatch (`console_user_server`): sends data as the logged-in user,
- your receiver app: runs as that same user.

This avoids a privileged component sending arbitrary traffic directly to external process endpoints.

## How to run and verify

1. Build:

```bash
make build-example
```

2. Start the example app:

```bash
open Example/build/Debug/ExampleApp.app
```

Press `Start` in the app UI.

3. Send a test payload:

```bash
make send-command
```

4. Confirm the app log shows the received JSON.

## Practical notes

- Keep UNIX socket paths short; very long paths can exceed `sockaddr_un.sun_path` limits.
- If your process restarts, ensure stale socket files are cleaned up (this package already unlinks on start/stop).
- Keep payloads compact; datagrams are best for small messages.
