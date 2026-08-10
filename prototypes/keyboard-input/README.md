# PROTOTYPE: Keyboard Input Probe

This throwaway Swift CLI answers issue #10: can the macOS implementation observe an AFA
trigger, suppress it only while ready, inject one calibrated target semantic, avoid recursion,
and pass the original input through when not ready?

It does not click, move the pointer, activate the game, or inspect game data. A first TCC request
can display system permission UI before a trial; after permissions are granted, the probe itself
has no foreground UI. The target must already be frontmost because its full-screen runtime pauses
when backgrounded.

## Build

```bash
swift build --package-path prototypes/keyboard-input
```

## Commands

Inspect current target identity and TCC state:

```bash
swift run --package-path prototypes/keyboard-input keyboard-input-probe status
```

Observe numeric key codes without suppression or injection. While the target remains frontmost,
press exactly one known-safe semantic key once and wait for the command to finish:

```bash
swift run --package-path prototypes/keyboard-input keyboard-input-probe watch --seconds 5
```

Replay the observed output key through the PID route first:

```bash
swift run --package-path prototypes/keyboard-input keyboard-input-probe inject \
  --output KEY_CODE --route pid
```

Only if PID posting fails semantically, and only with a key harmless in every application that
might become frontmost, compare the session route. Session down/up can be redirected or split by
a focus change because CoreGraphics provides no atomic target-and-post operation:

```bash
swift run --package-path prototypes/keyboard-input keyboard-input-probe inject \
  --output KEY_CODE --route session
```

Bridge a separate, game-unbound AFA trigger to the calibrated output for ten seconds. By default
the physical trigger passes through, so the first trial cannot swallow it. CoreGraphics posting
has no delivery return value: `postingAttempts` is not a success count, and the user remains the
semantic oracle.

```bash
swift run --package-path prototypes/keyboard-input keyboard-input-probe bridge \
  --trigger TRIGGER_KEY_CODE --output OUTPUT_KEY_CODE --route pid --seconds 10
```

Only after direct injection and the default bridge both produce exactly one confirmed action,
repeat the PID bridge with explicit suppression:

```bash
swift run --package-path prototypes/keyboard-input keyboard-input-probe bridge \
  --trigger TRIGGER_KEY_CODE --output OUTPUT_KEY_CODE --route pid --suppress --seconds 10
```

Suppression means "all detectable readiness checks passed and a post was attempted," not that
delivery was acknowledged. Session-route suppression is intentionally rejected because a focus
change can redirect its down/up pair. Synthetic tagging is directly observable on the session
route; PID-routed events enter downstream of the session tap, so that route avoids recursion by
placement in addition to carrying the tag. Even PID suppression cannot detect a silently ignored
post; it is a controlled prototype trial, not a proven fail-open production contract. The probe
records interrupted handled presses and posts one extra target-PID key-up at teardown as a
best-effort cleanup, but neither operation turns the `Void` posting API into an acknowledgement.

`watch` and `bridge` need Input Monitoring. `inject` and `bridge` need Accessibility/PostEvent.
If the first request opens System Settings or returns denied, grant the displayed executable or
terminal host, then rerun from the beginning.

## Safety Matrix

- Use a disposable game context where any mistaken candidate key has no irreversible effect.
- Confirm target identity and frontmost state before every command.
- Compare PID and session routes; retain only a route that produces exactly one intended action.
- Treat pointer and frontmost before/after samples as observations; they cannot rule out transient
  changes. Reject any route with an observed persistent change.
- Use a trigger distinct from the output first. Exercise equal trigger/output tagging with a
  non-suppressing session bridge only while the target remains frontmost.
- Hold the trigger to exercise repeat suppression, then release and confirm no stuck key.
- Start `bridge` while the target is frontmost, then switch away: later trigger events must pass
  and `postingAttempts` must not increase.
- Omit each permission and confirm startup exits before creating an active path. If permission is
  revoked during a run, subsequent trigger downs must fail readiness and pass; a tap-disabled
  notification must reset press state before re-enabling.
- The prototype selects one safe semantic to choose the route. All four release semantics are
  later acceptance coverage, not four separate design experiments.
