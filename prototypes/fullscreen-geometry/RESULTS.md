# Prototype Results

Date: 2026-08-10

Environment:

- macOS 26.5.1, Apple Silicon
- One active Retina display: 1470x918 global points, 2940x1836 current-mode pixels
- Target bundle identifier: `com.hypergryph.arknights`

## Verdict

Target identity and full-screen geometry are feasible with public APIs. Temporary global
pointer movement and restoration are not reliable while this iOS-on-Mac target is full-screen.
The first release must not use cursor warping as the implementation contract for its required
pause-selection actions. Issue #15 must test a target-directed route that does not depend on
moving the global pointer; failure of that route reopens the required action scope from #2.

## Observations

### Launch and identity

- The observed launch opened a window at `(169, 90, 1131, 738)` points rather than entering
  full-screen automatically. The user manually entered native full-screen.
- `NSRunningApplication` consistently resolved one process by bundle identifier.
- Runtime `bundleURL` and `executableURL` were under a private translocation path, so neither
  path is a durable identity. The bundle identifier plus current process lifetime is required.
- The user confirmed that the game automatically pauses whenever its full-screen Space loses
  foreground status. AFA must therefore remain a background runtime component and must not
  activate its own UI while executing an action.

### Full-screen geometry

- Once full-screen and frontmost, the main game window was exactly `(0, 0, 1470, 918)` points,
  matching the active display bounds.
- The current display mode was correctly observed as 2940x1836 pixels, a 2x scale.
- The process also owned several layer-zero helper windows, including a 1470x32 on-screen
  window and multiple 1470x30 or 500x500 records. "Exactly one layer-zero window" is therefore
  not a valid selection rule.
- In the tested single-display environment, the safe full-screen selector is: current target
  PID, on-screen, visible, layer zero, and the only window whose bounds match an active display
  within the probe's two-point tolerance. Geometry-dependent movement must be refused when
  selection is ambiguous; a later input handler must then pass through the original input.
- Current pointer positions normalized correctly against the selected full-screen bounds,
  including explicit inside/outside classification.

### Pointer move and restore

Two center-point trials were run without clicks or key events:

1. With a 300 ms hold, the synthetic move initially landed exactly at `(735, 459)`. Before
   restoration, the target/input system had moved it to approximately `(674, 456)`. The probe
   correctly treated that as external movement and skipped restoration.
2. With a zero-length hold, the requested center move was observed around `(401, 117)`, a
   placement error of about 478 points. The attempted restore ended around `(248, 21)` instead
   of the original `(1037, 369)`, an error of about 862 points.

The cause may be the target's full-screen pointer capture or Touch Alternatives input
translation, but the product conclusion does not depend on identifying the private mechanism:
global cursor placement/restoration fails the observable contract and is not a supported
fallback.

### Remaining matrix disposition

- **Target not frontmost:** sampled before activation. The process and its window records were
  still discoverable, but the probe reported the target as inactive and movement remained
  disallowed. The user confirmed that the full-screen game pauses when it loses foreground.
- **Relaunch/PID refresh:** not executed because it would terminate the user's active game
  session. The implementation treats PID/window IDs as per-launch values, and #10 must repeat
  identity resolution when it creates the actual input harness.
- **Non-edge move:** not executed. Center placement/restoration already failed under both a
  300 ms hold and immediate restore, so another global pointer warp cannot establish the
  required reliable fallback and would add user-visible disruption without changing the
  decision.
- **Additional displays/resolutions:** unavailable in the current environment. The conclusion
  is limited to the tested single-display setup; future support requires the same exact
  window/display correlation test on each supported configuration.

## Handoff to Issues #10 and #15

Issue #15 owns the pointer-delivery question and must keep the game frontmost throughout each
trial. It must verify:

- Whether `CGEventPostToPid` or another public target-directed event route can deliver a mouse
  down/up at a target coordinate without moving the global cursor.
- Whether the game interprets such an event as the intended UIKit touch/click.
- Whether the route works in the actual paused-game selection, skill, and retreat contexts
  required by #2, after an initial disposable-context safety check.
- Whether frontmost identity remains the target before and after every action.
- Whether a failed action leaves the original pointer and physical button/key state unchanged.

Issue #10 remains a separate keyboard-route prototype. It must use one safe calibrated semantic
to choose the supported posting route, verify event-tap consumption and failure-open passthrough,
prevent synthetic-event recursion, and prove no stuck keys without changing foreground focus.
All four required semantics (`pauseBattle`, `changeSpeed`, `releaseSkill`, `retreatChar`) are
release acceptance coverage after the keyboard route is selected, not four separate #10 design
experiments.

No screen capture, game-private data, private API, click, or keyboard event was used by this
prototype.
