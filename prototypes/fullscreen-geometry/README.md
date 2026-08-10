# PROTOTYPE: Full-screen Geometry Probe

This throwaway Swift CLI answers GitHub issue #6: can public macOS APIs identify the
full-screen target window, correlate it to a display, normalize the current pointer, and
temporarily move and restore the pointer without using screen capture or game-private data?

The completed runtime verdict and measurements are in [`RESULTS.md`](RESULTS.md).

It is not production code. It never clicks and never sends a game key.

## Build

```bash
swift build --package-path prototypes/fullscreen-geometry
```

## Sample geometry

1. Start `明日方舟.app` and enter its native full-screen Space.
2. Run the command below.
3. Return to the game before the eight-second delay expires and leave the pointer over a
   recognizable game position.
4. Return to Terminal and inspect the JSON.

```bash
swift run --package-path prototypes/fullscreen-geometry fullscreen-geometry-probe sample --delay 8
```

The useful fields are:

- `targetApplications`: bundle, PID, outer/inner runtime URLs, and active state.
- `selectedWindow`: the largest layer-zero target window and its global point bounds.
- `selectedDisplay`: the display with the largest intersection and its point/pixel scale.
- `selectedWindowMatchesDisplay`: whether full-screen window bounds equal display bounds.
- `pointerRelativeToSelectedWindow`: normalized pointer coordinates and containment.

Global coordinates and normalized window coordinates use a top-left origin with Y increasing
downward. An outside pointer intentionally produces normalized values below `0` or above `1`
and `insideWindow=false`.

## Move and restore

This explicit mode requests PostEvent permission and moves the pointer to a normalized
window position for 300 ms before restoring it. It still does not click.

```bash
swift run --package-path prototypes/fullscreen-geometry fullscreen-geometry-probe move \
  --x 0.5 --y 0.5 --hold-ms 300 --delay 8
```

If macOS denies posting, grant Terminal or the built probe under **System Settings >
Privacy & Security > Accessibility**, then rerun. The JSON reports the requested target,
observed target, placement error, restored point, and restore error in global points.

Do not move the physical pointer during the hold. The probe compares the end-of-hold location
to the actual observed post-warp location, not the requested target. If it detects movement of
more than two points, it leaves the pointer where the user moved it and reports
`restorationSkippedDueToPointerMovement=true`. Otherwise, passing restoration error is at most
two global points.

## Validation Matrix

Record one JSON sample for each available case. The no-target command is:

```bash
swift run --package-path prototypes/fullscreen-geometry fullscreen-geometry-probe sample --delay 0
```

It should exit successfully with empty target arrays and the note `Target application was not
running.` Then cover:

- Target not running.
- Target running but not frontmost.
- Target frontmost in its full-screen Space.
- Target relaunched, confirming that PID and window ID are refreshed.
- Each available display or resolution.
- Pointer inside and outside the selected target bounds.
- `move` at center and one non-edge point, confirming restoration error and no click.

The prototype passes only if target identity is unambiguous, full-screen window/display
geometry is stable for the supported environment, inside points normalize into `0..<1`,
outside points remain outside and are flagged as such, and pointer restoration error is at
most two global points when the user leaves the pointer untouched. Space identity itself is
not part of the contract because public APIs do not expose a stable Space identifier.
