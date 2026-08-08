# macOS Target Game Window Control and Capture Research

**Scope.** Research for [Nightchamp/arknights-frame-assistant#12](https://github.com/Nightchamp/arknights-frame-assistant/issues/12), "调研目标游戏窗口控制与画面采集能力". The question is which supported macOS APIs can identify, locate, activate, control, and capture the target game window in the native game environment, including iPhone/iPad app behavior, scaling, multiple displays, and TCC permissions. Sources and the installed target metadata were checked on 2026-08-08. The game was not launched or modified.

## Executive Finding

- **Identification, lifecycle tracking, geometry, and capture are feasible with supported APIs.** Use the stable bundle identifier `com.hypergryph.arknights` to find an `NSRunningApplication`, use its lifetime-scoped PID to correlate AppKit, Accessibility, Core Graphics, and ScreenCaptureKit records, and use ScreenCaptureKit for images.
- **Activation is supported but is a request, not an absolute focus guarantee.** `NSRunningApplication.activate(options:)` is the app-level operation. If a specific game window must be raised, use the Accessibility `kAXRaiseAction` only after verifying that the window exposes it.
- **Window movement and resizing are conditional capabilities.** Accessibility exposes position and size attributes, but clients must query whether each attribute is settable. The installed game declares `UIRequiresFullScreen=true`, which opts an iPad app out of dynamic resizing; resizing should therefore not be treated as a product guarantee.
- **Automatic capture and window control require separate user grants.** Automatic PID-based enumeration and capture of another app uses Screen Recording TCC. On macOS 14+, `SCContentSharingPicker` can instead grant session-scoped access to content the user explicitly selects without prior broad Screen Recording permission. Accessibility trust is independently required for inspecting or manipulating another app through AX APIs, and full cross-app AX control is incompatible with App Sandbox. The first implementation should request each permission only when its corresponding feature is used and should degrade each feature independently.
- **Points-to-pixels and multi-display behavior are manageable, but must be explicit.** Accessibility and Core Graphics window geometry use a top-left screen origin and points. Capture dimensions are pixels. ScreenCaptureKit supplies scaling and content-rectangle metadata, and its desktop-independent window filter follows a window across displays.
- **The remaining risk is target-specific runtime behavior, not a missing public API.** A prototype must verify which AX attributes/actions this iPhone/iPad game window exposes and what ScreenCaptureKit returns when the game is covered, minimized, offscreen, in a different Space, or full-screen.

## Installed Target Characteristics

The following values were read from `/Applications/明日方舟.app/Wrapper/Arknights.app/Info.plist`; the matching wrapped-bundle plist contains the same relevant values:

| Key | Installed value | Engineering significance |
|---|---|---|
| `CFBundleIdentifier` | `com.hypergryph.arknights` | Stable application identity to use for discovery. |
| `CFBundleSupportedPlatforms` | `iPhoneOS` | The target is an iPhone/iPad app package, not an AppKit game. |
| `LSRequiresIPhoneOS` | `true` | Confirms the iOS application environment on Mac. |
| `UIDeviceFamily` | iPhone and iPad | The package supports both device families. |
| `UIRequiresFullScreen` | `true` | Opts out of iPad multitasking and dynamic resizing. |
| `UISupportsTrueScreenSizeOnMac` | `true` | Allows native Mac display size and resolution in full-screen mode. |
| `UILaunchToFullScreenByDefaultOnMac` | absent | The manifest does not itself request a full-screen launch; user state restoration can still affect launch state. |

Apple documents that an iPad app with `UIRequiresFullScreen=true` does not support resizable windows on Mac. In ordinary full-screen compatibility behavior, the system chooses a fixed compatible iPad size. With `UISupportsTrueScreenSizeOnMac=true`, full-screen content can instead use the launch display's full size and native pixel mapping; that full-screen scene size remains based on the display active at launch and does not change if the window later moves to a display with a different resolution ([Apple Silicon full-screen guidance](https://developer.apple.com/documentation/apple-silicon/providing-an-edge-to-edge-full-screen-experience-in-your-ipad-app-running-on-a-mac)).

**Implication.** Expect one fixed-size primary game window in normal windowed operation and a launch-display-dependent size in full-screen operation. This is a strong selection signal, but actual window count, title, role, allowed positions, and AX writability remain runtime observations rather than plist guarantees.

## Application Identity and Lifecycle

### Documented facts

- [`NSRunningApplication.runningApplications(withBundleIdentifier:)`](https://developer.apple.com/documentation/appkit/nsrunningapplication/runningapplications(withbundleidentifier:)) returns running applications matching a bundle identifier. `NSRunningApplication` exposes the bundle identifier, bundle URL, and [`processIdentifier`](https://developer.apple.com/documentation/appkit/nsrunningapplication/processidentifier).
- A PID is useful only for the current process lifetime. Apple explicitly advises against using `processIdentifier` to compare process identity; the PID may also be `-1` for an app without a process.
- [`NSWorkspace.didLaunchApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didlaunchapplicationnotification) and [`didTerminateApplicationNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/didterminateapplicationnotification) report application lifecycle changes through `NSWorkspace.notificationCenter` and include the affected `NSRunningApplication`.
- ScreenCaptureKit represents an application as `SCRunningApplication`, which exposes `bundleIdentifier`, `applicationName`, and `processID`; each `SCWindow` exposes a Window Server `windowID`, `frame`, optional `title`, and optional `owningApplication` ([`SCShareableContent`](https://developer.apple.com/documentation/screencapturekit/scshareablecontent)).
- Core Graphics window dictionaries include required `kCGWindowNumber`, `kCGWindowBounds`, `kCGWindowSharingState`, and `kCGWindowOwnerPID` values. Owner and window names are optional ([required keys](https://developer.apple.com/documentation/coregraphics/required-window-list-keys), [optional keys](https://developer.apple.com/documentation/coregraphics/optional-window-list-keys)).

### Recommended identity chain

1. Treat `com.hypergryph.arknights` as the durable identity.
2. Resolve the current `NSRunningApplication` and retain that object for the current launch.
3. Use its PID to correlate `SCRunningApplication.processID`, `SCWindow.owningApplication`, Core Graphics `kCGWindowOwnerPID`, and `AXUIElementCreateApplication(pid)`.
4. Treat PID, `CGWindowID`/`SCWindow.windowID`, and all AX elements as ephemeral. Re-resolve them after termination, relaunch, window recreation, full-screen transitions, or stale-object errors.
5. Do not use the localized display name, executable path, PID, window title, or Window Server ID as the durable identity.

**Window correlation limitation.** The documented AX window attributes do not expose a Window Server `CGWindowID`. Do not use private AX-to-window-ID functions. If the target ever exposes multiple windows, correlate the AX main/focused window with `SCWindow` records using PID plus title and bounds, and fail as ambiguous rather than guessing when those values do not identify one candidate. For the expected single fixed-size game window, PID plus a nonempty visible frame should normally be sufficient, subject to prototype confirmation.

## Window Discovery, Geometry, and Tracking

### Supported API roles

| Need | Primary API | Role and limitation |
|---|---|---|
| Find the running game | `NSRunningApplication` | Bundle-ID lookup and current PID; does not identify a particular window. |
| Enumerate capturable windows automatically | `SCShareableContent` | Preferred source for PID-based `SCWindow` discovery. Requires broad capture authorization for other apps' content. |
| Let the user select capturable content | `SCContentSharingPicker` (macOS 14+) | Grants the current process access to the selected content for the session without prior broad Screen Recording permission; selection is explicit and cannot silently enforce the target bundle. |
| Inspect main/focused windows | Accessibility `AXUIElement` | `kAXWindowsAttribute`, `kAXMainWindowAttribute`, and `kAXFocusedWindowAttribute`; requires Accessibility trust. |
| Observe geometry/window changes | `AXObserver` | Subscribe to supported notifications such as main/focused-window changes, movement, and resize ([`AXObserverAddNotification`](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)). Notification support must be checked at runtime. |
| Lightweight Window Server inventory | `CGWindowListCopyWindowInfo` | Returns IDs, bounds, owner PID, layer, sharing state, and optional names; useful for diagnostics/correlation, not control ([documentation](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:))). |

Accessibility defines `kAXPositionAttribute` as the global screen position of an element's top-left corner. Its origin is the top-left of the display containing the menu bar, X increases rightward, Y increases downward, and units are points. `kAXSizeAttribute` is also measured in points. The specification says windows that users can directly move or resize *should* make the corresponding attributes writable, not that every window must do so ([AX attribute specification](https://developer.apple.com/documentation/applicationservices/axattributeconstants_h)).

Core Graphics `kCGWindowBounds` likewise uses screen space with the origin at the upper-left of the main display ([`kCGWindowBounds`](https://developer.apple.com/documentation/coregraphics/kcgwindowbounds)). By contrast, AppKit's default global screen coordinates use a lower-left origin. Any implementation that mixes `NSScreen`/`NSWindow` geometry with AX or Window Server geometry must perform an explicit Y-axis conversion rather than passing rectangles through unchanged ([Cocoa coordinate-system guidance](https://developer.apple.com/library/archive/documentation/General/Devpedia-CocoaApp-MOSX/CoordinateSystem.html)).

### Tracking strategy

- Resolve the application immediately from the bundle identifier and listen for launch/termination notifications.
- Once capture permission is available, enumerate `SCShareableContent` and choose windows whose `owningApplication.processID` matches the current game PID. Reject zero-area candidates and retain the chosen `SCWindow.windowID` only for that process/window lifetime.
- Once Accessibility permission is available, read `kAXMainWindowAttribute`, falling back to `kAXFocusedWindowAttribute` and then `kAXWindowsAttribute`. Subscribe to main-window, focused-window, moved, and resized notifications where supported.
- Refresh ScreenCaptureKit content after a window is recreated or capture reports a stale/no-source failure. Re-evaluate ambiguity whenever the candidate set changes.
- Keep polling as a bounded fallback because AX notification support is element-dependent. Polling should refresh state, not create a second identity rule.

## Activation and Window Control

### Documented facts

- [`NSRunningApplication.activate(options:)`](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:)) attempts to activate an application and reports success or failure. Current AppKit documentation describes activation as a request and does not guarantee that the system will honor it in every activation context.
- Accessibility clients can request an element action with [`AXUIElementPerformAction`](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction). `kAXRaiseAction` is the standard action to request that a window move to the front.
- Before setting position or size, the client must call [`AXUIElementIsAttributeSettable`](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable). Writable values are applied with [`AXUIElementSetAttributeValue`](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue) using an `AXValue` wrapping `CGPoint` or `CGSize`.
- AX access to another process is gated by [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions). Passing `kAXTrustedCheckOptionPrompt=true` may present the system permission prompt.

### Product capability boundary

| Capability | Supported path | Product guarantee |
|---|---|---|
| Bring the game application forward | `NSRunningApplication.activate(options:)` | Best effort; handle `false` and verify `isActive`/frontmost state. |
| Raise the selected game window | AX `kAXRaiseAction` | Only with Accessibility trust and only if the action is advertised/succeeds. |
| Read position and size | AX attributes or `SCWindow.frame`/CG bounds | Supported, subject to the corresponding permission and a live window. |
| Move the game window | Set AX position | Conditional; expose only after a runtime settable check and verify the resulting position. |
| Resize the game window | Set AX size | Not a baseline promise. `UIRequiresFullScreen=true` makes dynamic resizing unlikely by design. |
| Enter or leave full screen | System/user window behavior | No reliable generic AX full-screen state setter is documented for arbitrary third-party windows. Do not make this part of the initial control contract. |

**Implication.** Separate app activation from AX window manipulation. Basic features may activate the game without asking for Accessibility access. Features that promise positioning or raising must request Accessibility trust, detect support per live window, and report “unsupported by this game window” distinctly from “permission denied.”

## Capture Pipeline

### Preferred APIs

ScreenCaptureKit is the supported capture stack beginning in macOS 12.3. [`SCShareableContent`](https://developer.apple.com/documentation/screencapturekit/scshareablecontent) provides capturable displays, applications, and windows. A [`SCContentFilter(desktopIndependentWindow:)`](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:)) captures only the chosen `SCWindow`; Apple describes this filter as following the window when it moves across displays ([WWDC22: Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/)).

On macOS 14+, [`SCContentSharingPicker`](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker) provides a second authorization route. Apple documents that content selected through the system picker can be captured for the current session without the user first granting broad Screen Recording access ([WWDC23: Build a great ScreenCaptureKit experience](https://developer.apple.com/videos/play/wwdc2023/10053/)). This lowers first-run permission friction but requires explicit user selection and does not replace automatic bundle/PID-based target discovery. Architecture ticket #7 should choose whether it is an optional fallback or part of the baseline workflow.

Use one of two output paths:

- **Continuous recognition:** create `SCStream`, add an `.screen` output, and process each `CMSampleBuffer` delivered to `SCStreamOutput`. This is the natural path for repeated low-latency color, template, or state recognition ([capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)).
- **One-shot recognition or diagnostics on macOS 14+:** call `SCScreenshotManager.captureImage` for `CGImage` output or `captureSampleBuffer` for buffer output ([`SCScreenshotManager`](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager), [WWDC23](https://developer.apple.com/videos/play/wwdc2023/10136/)).

Configure `SCStreamConfiguration` explicitly:

- `width` and `height` are output dimensions in pixels.
- `sourceRect` is expressed in points in the display's logical coordinate system.
- `pixelFormat = kCVPixelFormatType_32BGRA` gives a direct packed format suitable for CPU color scans; other supported formats can be chosen if later profiling justifies them.
- `showsCursor = false` prevents cursor pixels from contaminating recognition.
- `minimumFrameInterval` should reflect the detector's required cadence rather than defaulting to the display refresh rate.
- On macOS 14+, `SCContentFilter.contentRect` is in points and `pointPixelScale` provides the point-to-pixel scale. On macOS 12.3/13, equivalent per-frame [`SCStreamFrameInfo`](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo) metadata includes content rectangle, content scale, and display scale.
- On macOS 14+, `ignoreGlobalClipSingleWindow=true` prevents a partially offscreen single-window capture from being clipped. This should be tested before enabling because it intentionally ignores the window's clipping in display context.

The legacy [`CGWindowListCreateImage`](https://developer.apple.com/documentation/coregraphics/cgwindowlistcreateimage(_:_:_:_:)) path is deprecated starting in macOS 14 and obsolete in the current SDK, which directs clients to ScreenCaptureKit. It also explicitly excludes windows with `kCGWindowSharingNone`. Keep `CGWindowListCopyWindowInfo` only as inventory/diagnostic support; do not build a new image pipeline on the legacy capture function.

### Frame validation and recognition input

For streaming, inspect the `SCStreamFrameInfo.status` attachment. [`SCFrameStatus`](https://developer.apple.com/documentation/screencapturekit/scframestatus) distinguishes newly generated `.started` and `.complete` frames from `.idle`, `.blank`, `.suspended`, and stopped states. The initial `.started` frame and subsequent `.complete` frames may update recognition; a detector should retain or invalidate its previous state according to an explicit timeout rather than treating every callback as a new image.

`CMSampleBuffer` can supply a `CVImageBuffer`/`CVPixelBuffer` for direct pixel access. If a detector later needs a system vision request, [`VNImageRequestHandler`](https://developer.apple.com/documentation/vision/vnimagerequesthandler/init(cvpixelbuffer:orientation:options:)) accepts a `CVPixelBuffer`. Therefore both the current Windows reference behavior's color-region checks and more advanced recognition have supported macOS image inputs; the recognition algorithm is not blocked by the capture API.

## Scaling and Multiple Displays

### Documented facts

- macOS UI geometry is normally expressed in points, while backing stores and capture output are pixels. The backing scale is per screen/window and can change when a window moves. Apple recommends coordinate conversion APIs over assuming one global scale ([High Resolution Guidelines](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/APIs/APIs.html)).
- ScreenCaptureKit output `width`/`height` and destination rectangles are pixels; source rectangles and filter content rectangles are points.
- A desktop-independent single-window filter follows a window across displays. On macOS 14+, `pointPixelScale` exposes the current relationship for the filter.
- The installed game's `UISupportsTrueScreenSizeOnMac=true` changes full-screen behavior: the full-screen scene uses the resolution of the display active at launch, and that scene size does not change merely because the window moves to a display with a different resolution.

### Required coordinate model

Maintain distinct types or clearly named values for:

1. AX/Window Server screen points, with top-left origin and downward-positive Y.
2. AppKit screen points, with lower-left origin and upward-positive Y.
3. Capture-surface pixels, with dimensions and content placement supplied by ScreenCaptureKit configuration/metadata.
4. Detector-normalized coordinates, preferably ratios within the captured game content rather than global screen coordinates.

Convert detector regions from normalized game-content coordinates into the current capture content rectangle and then into output pixels. Do not use the main display's scale for a game window on another display, and do not assume the captured surface is exactly `windowFrameInPoints * 2`.

## Permissions and Failure Modes

| State | Identification | Activation | AX geometry/control | Automatic capture | Picker-selected capture on macOS 14+ |
|---|---|---|---|---|---|
| No grants | Bundle-ID/PID discovery works | App-level activation can be attempted | Unavailable | Unavailable for another app's content | Available for the current session after explicit user selection |
| Screen Recording only | Works | Works as above | Unavailable | Available if the target window is shareable | Available |
| Accessibility only | Works | Works as above | Available according to exposed attributes/actions only in an unsandboxed app | Unavailable | Available after explicit user selection |
| Both grants | Works | Works as above | Available according to exposed attributes/actions only in an unsandboxed app | Available if the target window is shareable | Available |

- For automatic capture, use [`CGPreflightScreenCaptureAccess()`](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()) to check current screen-capture authorization and [`CGRequestScreenCaptureAccess()`](https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess()) when the user invokes the feature. ScreenCaptureKit reports `SCStreamError.Code.userDeclined` when authorization is refused ([ScreenCaptureKit error constants](https://developer.apple.com/documentation/screencapturekit/error-constants)). macOS exposes this grant in Privacy & Security under Screen & System Audio Recording ([Apple Support](https://support.apple.com/guide/mac-help/control-access-to-screen-recording-on-mac-mchld6aa7d23/mac)). On macOS 14+, an explicit `SCContentSharingPicker` selection is an alternative session-scoped route, not evidence of broad authorization.
- Check Accessibility trust separately with `AXIsProcessTrustedWithOptions`. A Screen Recording grant does not imply AX trust, and AX trust does not imply capture permission. If the application is sandboxed, do not promise cross-app AX geometry or control even when the user has granted Accessibility access.
- A shareability or content-protection failure is different from TCC denial. Core Graphics defines `kCGWindowSharingNone`, and Apple notes that some apps may prevent screenshots of their windows ([Apple Support](https://support.apple.com/guide/mac-help/take-a-screenshot-mh26782/mac)). The target game's behavior must be observed rather than inferred.
- Treat an absent `SCWindow`, `SCStreamError.userDeclined`, a stopped stream, `.blank` frames, AX permission failure, AX unsupported attributes/actions, and stale process/window references as distinct states. They imply different user guidance and recovery paths.

## Recommended End-to-End Design

1. Discover `NSRunningApplication` by `com.hypergryph.arknights`; subscribe to launch and termination changes.
2. Record the current application object and PID as one launch session. Clear all window and capture state when that session ends.
3. When automatic capture is needed, check/request Screen Recording access, enumerate `SCShareableContent`, and filter by the current PID. On macOS 14+, optionally offer `SCContentSharingPicker` as an explicit-selection fallback if architecture ticket #7 accepts that interaction.
4. Select one viable `SCWindow`. If more than one remains, use AX main/focused-window bounds and title only as documented correlation signals; surface ambiguity if they do not resolve it.
5. Build `SCContentFilter(desktopIndependentWindow:)`. Use `SCStream` for continuous detectors and `SCScreenshotManager` for isolated captures when the deployment target permits it.
6. Derive all detector regions from ScreenCaptureKit content/scale metadata. Process only valid newly generated `.started` or `.complete` frames.
7. Attempt app activation through `NSRunningApplication`. Request Accessibility trust only for features that need window raise, observation, movement, or conditional resize, and keep those features out of a sandboxed build.
8. Re-resolve the window after relaunch, full-screen transitions, candidate-set changes, or stale/no-source capture errors. Never persist PID, window ID, AX references, or pixel dimensions across launches.

This path uses only public, documented frameworks. It avoids private AX-to-Window-Server bridges and avoids the deprecated Core Graphics image-capture path.

## Prototype Validation Matrix

The documentation establishes API capability but cannot establish how the installed game implements its window. A user-approved runtime prototype should record the following without assuming success:

| Scenario | Measurements / pass condition |
|---|---|
| Initial windowed launch | Bundle-ID lookup resolves one process; PID matches one viable `SCWindow`; AX main/focused window correlation is unambiguous when trusted. |
| Relaunch | Old PID, window ID, AX objects, and stream are rejected/cleared; the new launch is resolved automatically. |
| Permission combinations | No grant, Screen Recording only, Accessibility only, both, and revoked-during-use states produce distinct feature availability and errors. |
| AX capability | Record supported attributes/actions and settable results for position and size in windowed and full-screen states; verify post-operation geometry rather than trusting a success code alone. |
| Focus/raise | Test activation from normal apps, full-screen Spaces, and after the helper receives a hotkey; record whether app activation and AX raise succeed independently. |
| Capture visibility | Test unobscured, partially/fully covered, minimized, hidden, offscreen, another Space, and full-screen. Record whether the window remains selectable and whether frames are complete, idle, blank, stale, or absent. |
| Multiple displays | Move between 1x and 2x displays, displays above/left of the menu-bar display, and displays with different resolutions. Compare AX/CG point geometry, ScreenCaptureKit content metadata, and output pixels. |
| Full-screen display choice | Launch on each display and verify the documented launch-display-dependent `UISupportsTrueScreenSizeOnMac` behavior. |
| Recognition suitability | Measure pixel format, content bounds, color stability, frame cadence, dropped/idle frames, CPU use, and end-to-end detector latency at the intended polling rate. |
| Shareability/protection | Record `kCGWindowSharingState`, ScreenCaptureKit enumeration, first-frame result, and capture errors to determine whether the game excludes or blanks its content. |

## Feasibility Decision

| Requirement | Decision | Residual condition |
|---|---|---|
| Reliably identify the target application | **Feasible** | Bundle identifier is stable; current PID must be refreshed per launch. |
| Reliably identify its main capture window | **Feasible for the expected single-window game** | Multi-window or title/bounds ambiguity must fail explicitly; confirm actual window inventory. |
| Track position and size | **Feasible** | Screen Recording provides `SCWindow.frame`; AX observation needs separate trust and runtime notification support. |
| Activate/raise | **Feasible as best effort** | Activation may be denied by system context; AX raise depends on trust and supported actions. |
| Move the window | **Conditionally feasible** | Requires a writable AX position attribute and runtime verification. |
| Resize the window | **Not a baseline capability** | The game opts out of dynamic resizing; expose only if AX reports size as settable and the operation works. |
| Capture pixels for recognition | **Feasible** | Automatic target selection requires Screen Recording permission; macOS 14+ can instead use explicit picker selection. Either path still requires a shareable, nonblank game window. |
| Handle Retina and multiple displays | **Feasible** | Keep points, AppKit coordinates, and pixels separate; consume per-filter/per-frame scale metadata. |

**Conclusion.** Proceed with a ScreenCaptureKit-based prototype. The public API surface is sufficient for the first macOS implementation's application discovery, window capture, and pixel recognition. Define activation as best effort, define movement as capability-detected, and exclude resize/full-screen control from the baseline contract. The prototype's release gate is successful target-specific capture across visibility/full-screen/multi-display scenarios plus a recorded AX capability profile; no architectural fallback to private or deprecated APIs is warranted.

## Primary Sources

| Source | What it establishes |
|---|---|
| [Issue #12](https://github.com/Nightchamp/arknights-frame-assistant/issues/12) | Research question and target scope. |
| [`NSRunningApplication`](https://developer.apple.com/documentation/appkit/nsrunningapplication) and [`NSWorkspace`](https://developer.apple.com/documentation/appkit/nsworkspace) | Bundle-ID application discovery, PID, activation, and lifecycle notifications. |
| [`AXUIElement.h`](https://developer.apple.com/documentation/applicationservices/axuielement_h), [AX attributes](https://developer.apple.com/documentation/applicationservices/axattributeconstants_h), and [`AXObserver`](https://developer.apple.com/documentation/applicationservices/axobserver) | Accessibility trust, windows, geometry, settable attributes, actions, and notifications. |
| [`CGWindowListCopyWindowInfo`](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)), [required window keys](https://developer.apple.com/documentation/coregraphics/required-window-list-keys), and [`kCGWindowBounds`](https://developer.apple.com/documentation/coregraphics/kcgwindowbounds) | Window Server inventory, owner PID, window ID, sharing state, bounds, and screen coordinates. |
| [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [`SCShareableContent`](https://developer.apple.com/documentation/screencapturekit/scshareablecontent), and [`SCContentFilter`](https://developer.apple.com/documentation/screencapturekit/sccontentfilter) | ScreenCaptureKit discovery, filtering, streaming, and frame output. |
| [WWDC22: Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/) and [WWDC23: What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/) | Desktop-independent window capture and the one-shot screenshot API. |
| [WWDC23: Build a great ScreenCaptureKit experience](https://developer.apple.com/videos/play/wwdc2023/10053/) and [`SCContentSharingPicker`](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker) | User-selected, session-scoped capture without prior broad Screen Recording permission on macOS 14+. |
| [Apple Silicon full-screen guidance](https://developer.apple.com/documentation/apple-silicon/providing-an-edge-to-edge-full-screen-experience-in-your-ipad-app-running-on-a-mac) | `UIRequiresFullScreen`, `UISupportsTrueScreenSizeOnMac`, fixed sizing, native pixels, and launch-display behavior. |
| [High Resolution Guidelines](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/APIs/APIs.html) | Points, backing pixels, per-display scaling, and conversion guidance. |
| [Screen Recording privacy settings](https://support.apple.com/guide/mac-help/control-access-to-screen-recording-on-mac-mchld6aa7d23/mac) and [screenshot limitations](https://support.apple.com/guide/mac-help/take-a-screenshot-mh26782/mac) | User-controlled capture permission and the possibility that an app prevents screenshots. |
