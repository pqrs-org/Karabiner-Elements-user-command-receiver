# Pilot 5 Macro Rollout (Legacy + User Command)

This folder provides a safe pilot rollout for 5 seq macros with explicit transport mode selection.

Files:

- `seq-pilot-5-legacy.json`
- `seq-pilot-5-user-command-template.json`

## Why this layout

- Legacy path remains importable and stable.
- User-command path is isolated to pilot keys and can be switched on/off via variable.
- No existing `seqSocket(...)` production mappings need to be removed.

## Key bindings in this pack

Mode toggles:

- `right_command + right_option + f18` -> set `seq_transport_mode = 0` (legacy)
- `right_command + right_option + f19` -> set `seq_transport_mode = 1` (user_command)

Pilot macros:

- `right_command + right_option + f13` -> `open Safari new tab`
- `right_command + right_option + f14` -> `open Comet new tab`
- `right_command + right_option + f15` -> `New Linear task`
- `right_command + right_option + f16` -> `arc: localhost:3000`
- `right_command + right_option + f17` -> `open: Spotify (or search)`

## Import strategy

1. Import `seq-pilot-5-legacy.json` first.
2. Validate all 5 pilot macros work in legacy mode (`f18` toggle).
3. Import `seq-pilot-5-user-command-template.json`.
4. Start bridge:
   - `make run-bridge` from this repo.
5. Toggle to user-command mode (`f19`) and test the same 5 keys.
6. Toggle back to legacy (`f18`) immediately if anything regresses.

## Important template note

`seq-pilot-5-user-command-template.json` assumes this payload wrapper:

```json
{
  "send_user_command": {
    "json": { "v": 1, "type": "run", "name": "..." }
  }
}
```

If upstream Karabiner final syntax differs, edit only the wrapper fields in that file; keep the inner payload values unchanged.

## Suggested success criteria before expanding

- Zero command failures across 100+ invocations per pilot macro.
- p95 latency equal or better than legacy mapping.
- No regressions in existing non-pilot `seqSocket(...)` mappings.
