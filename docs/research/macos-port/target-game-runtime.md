# Target Game Runtime Surface on macOS

**Scope.** Research for [Nightchamp/arknights-frame-assistant#13](https://github.com/Nightchamp/arknights-frame-assistant/issues/13), “确认目标游戏的 macOS 运行表面”. The local evidence is limited to read-only metadata under `/Applications/明日方舟.app`; the game was not launched, binaries were not reverse engineered, and no user container, preferences, keychain, or other user data was inspected. Internet discovery used `agent-reach`'s GitHub and Exa routes, and factual platform claims below cite Apple first-party documentation checked on 2026-08-08.

## Executive Finding

- `/Applications/明日方舟.app` is an installation wrapper. Its `WrappedBundle` symlink resolves to `Wrapper/Arknights.app`, which is the signed inner application bundle and contains the executable `Arknights`.
- The inner application is an arm64 **iOS App on Mac**, not a native AppKit app, Mac Catalyst build, simulator build, virtual machine, or compatibility-layer executable. Its bundle ID is `com.hypergryph.arknights`; its platform metadata says `iPhoneOS`, and its signature authority says `Apple iPhone OS Application Signing`.
- The likely macOS-visible application identity is one application process with bundle ID `com.hypergryph.arknights`, executable name `Arknights`, and localized/display name `明日方舟`. The exact PID, process name presented by each API, and whether `NSRunningApplication.bundleURL` resolves to the outer wrapper or inner bundle require a live prototype.
- The likely game-content window is one UIKit-backed, landscape, fixed-size window when windowed. `UIRequiresFullScreen=true` opts out of iPad multitasking/resizable-window behavior, while `UISupportsTrueScreenSizeOnMac=true` enables native Mac display resolution in full-screen mode. The app does not declare `UILaunchToFullScreenByDefaultOnMac`, so metadata does not request first launch directly into full screen.
- A sandbox data container and a `com.hypergryph.arknights` defaults domain are likely, but their existence and exact host paths were deliberately not inspected. No App Groups entitlement is present, so there is no locally evidenced shared filesystem group container.
- Static metadata is sufficient to choose the runtime family and primary bundle matcher. It is not sufficient to establish actual window-server records, Accessibility exposure, coordinate transforms, input-injection behavior, filesystem paths, or permission prompts. Those remain explicit live-prototype gates.

## Local Evidence Record

| ID | Read-only source | Relevant observation |
|---|---|---|
| L1 | `stat` and `readlink` on the outer path, `WrappedBundle`, `Wrapper`, and inner app | `WrappedBundle` is a symbolic link to `Wrapper/Arknights.app`; the other three paths are directories. |
| L2 | Targeted values from `Wrapper/Arknights.app/Info.plist` using `plutil` | Bundle identity, iPhoneOS platform, OS/device requirements, and UIKit window declarations recorded below. |
| L3 | `codesign -dvvv` and read-only entitlement display for `Wrapper/Arknights.app` | Signed identifier, arm64 format, iPhone OS signing authority, team/application identifiers, and active entitlements. |
| L4 | `mdls` for the outer and inner paths | Spotlight presents the outer path as an application bundle with bundle ID `com.hypergryph.arknights`; the nested path was not independently indexed with a bundle ID. |
| L5 | Directory and filename enumeration under the target only | The outer root contains `Wrapper` and `WrappedBundle`; the inner root has no `Settings.bundle`; no nested `.appex` or `.xpc` bundle was found. |

The observations are specific to the installed build present on 2026-08-08. `Wrapper/iTunesMetadata.plist` was not inspected because it is unnecessary for this question and may contain account-associated installation metadata.

## Observed Local Facts

### Outer and inner bundle relationship

| Surface | Observed fact | Confidence |
|---|---|---|
| User-facing install path | `/Applications/明日方舟.app` is a directory with `Wrapper/` and `WrappedBundle`. It has no root `Info.plist`. | High (L1, L5) |
| Wrapper link | `/Applications/明日方舟.app/WrappedBundle` is a symlink to `Wrapper/Arknights.app`. | High (L1) |
| Signed application bundle | `/Applications/明日方舟.app/Wrapper/Arknights.app` contains `Info.plist`, `_CodeSignature/`, resources, frameworks, and executable `Arknights`. | High (L2, L3, L5) |
| Spotlight identity | `mdls` reports the outer path as `com.apple.application-bundle`, display name `明日方舟.app`, and bundle ID `com.hypergryph.arknights`. | High (L4) |
| Nested Spotlight identity | `mdls` returned no indexed bundle ID for the nested app path, although its own `Info.plist` and code signature both identify it as `com.hypergryph.arknights`. | High for the observation; no broader implication (L2-L4) |

The outer path is therefore the Finder/Spotlight installation surface, while the inner path is the actual signed iOS bundle. Static evidence does not establish which URL a running-process API returns after LaunchServices resolves the wrapper.

### Bundle, process, and signing identity

| Key or surface | Observed value |
|---|---|
| `CFBundleIdentifier` / code-signing identifier | `com.hypergryph.arknights` |
| `CFBundleDisplayName` | `明日方舟` |
| `CFBundleName` | `Arknights` |
| `CFBundleExecutable` | `Arknights` |
| `CFBundlePackageType` | `APPL` |
| Version | `CFBundleShortVersionString=2.7.61`, `CFBundleVersion=59` |
| Binary format reported by `codesign` | App bundle with thin arm64 Mach-O executable |
| Signing authority | `Apple iPhone OS Application Signing` |
| Team and application identifiers | Team `2384J485EN`; application identifier `2384J485EN.com.hypergryph.arknights` |
| Nested helper surfaces | No `.appex` or `.xpc` bundle found under the app |

The active signing entitlements include production push notifications, associated domain `applinks:ak.hypergryph.com`, increased memory limit, and keychain access group `2384J485EN.com.hypergryph.arknights`. They do **not** include `com.apple.security.application-groups`. The keychain access group is not a public filesystem container and was not inspected.

### Platform, device, and OS metadata

| Metadata | Observed value | Bounded interpretation |
|---|---|---|
| `CFBundleSupportedPlatforms` | `iPhoneOS` | Built for the iOS platform rather than macOS. |
| `DTPlatformName` / `DTSDKName` | `iphoneos` / `iphoneos26.1` | Built with the iPhoneOS SDK. |
| `LSRequiresIPhoneOS` | `true` | Requests the iPhone/iOS environment. |
| `MinimumOSVersion` | `13.0` | iOS/iPadOS deployment floor, not a macOS minimum. |
| `UIDeviceFamily` | `1`, `2` | The bundle declares iPhone and iPad device families. |
| `UIRequiredDeviceCapabilities` | `arm64`, `metal` | Requires 64-bit ARM and Metal. |
| Local `UISupportedDevices` array | 96 identifiers: `MacFamily20,1`, `RealityFamily22,1`, and 94 iPad identifiers; no iPhone identifier | Describes this installed/thinned variant. It should not be treated as a complete product support matrix. |
| Supported orientations | `UIInterfaceOrientationLandscapeRight`, `UIInterfaceOrientationLandscapeLeft` | Landscape-only content declaration. |

Apple documents `MinimumOSVersion` as the minimum for iOS, iPadOS, tvOS, visionOS, and watchOS, and points macOS apps to `LSMinimumSystemVersion`; therefore `13.0` cannot be reinterpreted as “macOS 13” ([Apple: `MinimumOSVersion`](https://developer.apple.com/documentation/bundleresources/information-property-list/minimumosversion)). Apple also defines `UIRequiredDeviceCapabilities` as install/run requirements and specifically defines `arm64` and `metal` as compilation and graphics requirements ([Apple: `UIRequiredDeviceCapabilities`](https://developer.apple.com/documentation/bundleresources/information-property-list/uirequireddevicecapabilities)).

### Static window declarations

| Metadata | Observed value or absence |
|---|---|
| `UIRequiresFullScreen` | `true` |
| `UISupportsTrueScreenSizeOnMac` | `true` |
| `UILaunchToFullScreenByDefaultOnMac` | Absent |
| `UIApplicationSceneManifest` | Absent |
| `UIStatusBarHidden` | `true` |
| Launch resources | Separate iPhone and iPad launch storyboards |
| `Settings.bundle` | Not present |

The missing scene manifest is evidence that this bundle does not statically declare the modern scene-based lifecycle or multiple-window support. It is not proof that macOS will never create an auxiliary system window, alert, Open/Save panel, or Settings window.

## Apple-Documented Facts

### Runtime type

Apple states that iOS Apps on Mac run an **unmodified** iPhone/iPad app on Apple silicon, using the same frameworks and infrastructure as Mac Catalyst without recompiling for the Mac platform ([Running your iOS apps in macOS](https://developer.apple.com/documentation/apple-silicon/running-your-ios-apps-in-macos)). Apple separately describes this as the exact same iOS binary, running natively, built against the iOS SDK, and not running in Simulator ([WWDC20: iPad and iPhone apps on Apple silicon Macs](https://developer.apple.com/videos/play/wwdc2020/10114/)).

Apple's `ProcessInfo.isiOSAppOnMac` is `true` only for an iPhone or iPad app running on a Mac and remains `false` for Mac Catalyst apps ([Apple: `isiOSAppOnMac`](https://developer.apple.com/documentation/foundation/processinfo/isiosapponmac)). Combined with the local iPhoneOS and signing metadata, this classifies the target as iOS App on Mac rather than Catalyst.

### macOS-visible application identity

Apple's supported `NSRunningApplication` surface exposes a process identifier and, when available, `bundleIdentifier`, `bundleURL`, `executableURL`, and localized application name. Apple defines `bundleIdentifier` as the app's `CFBundleIdentifier`, `bundleURL` as the application bundle URL, and `executableURL` as the executable URL ([Apple: `NSRunningApplication.bundleIdentifier`](https://developer.apple.com/documentation/appkit/nsrunningapplication/bundleidentifier), [`bundleURL`](https://developer.apple.com/documentation/appkit/nsrunningapplication/bundleurl), [`executableURL`](https://developer.apple.com/documentation/appkit/nsrunningapplication/executableurl), and [`localizedName`](https://developer.apple.com/documentation/appkit/nsrunningapplication/localizedname)).

Those APIs establish which fields macOS can expose, but static inspection cannot establish the exact outer/inner URL values or localization chosen for a live process.

### Window and input model

Apple documents these iOS-on-Mac behaviors:

- An iPad app that supports iPad multitasking receives resizable macOS windows; an iPad app that does not support multitasking runs in a fixed-size window, and an iPhone-only app always runs in a fixed-size window ([Running your iOS apps in macOS](https://developer.apple.com/documentation/apple-silicon/running-your-ios-apps-in-macos)).
- `UIRequiresFullScreen=true` opts an iPad app out of multitasking and dynamic resizing ([Apple: `UIRequiresFullScreen`](https://developer.apple.com/documentation/bundleresources/information-property-list/uirequiresfullscreen)). Apple's Mac full-screen sample explicitly says such apps do not support resizable windows on Mac and normally appear in a window when launched on macOS ([Providing an edge-to-edge, full-screen experience](https://developer.apple.com/documentation/apple-silicon/providing-an-edge-to-edge-full-screen-experience-in-your-ipad-app-running-on-a-mac)).
- `UISupportsTrueScreenSizeOnMac=true` declares support for arbitrary Mac screen sizes and resolutions. For a full-screen-only iPad design, it allows the full-screen `UIWindowScene` to match the launch display's resolution and avoids content scaling there; it does not itself request launch into full screen ([Apple: `UISupportsTrueScreenSizeOnMac`](https://developer.apple.com/documentation/bundleresources/information-property-list/uisupportstruescreensizeonmac); [full-screen sample](https://developer.apple.com/documentation/apple-silicon/providing-an-edge-to-edge-full-screen-experience-in-your-ipad-app-running-on-a-mac)).
- macOS maps touch events to mouse events but supports only one such event at a time. The system also adds Touch Alternatives to the app's Settings window for keyboard, mouse, and trackpad equivalents ([Adapting iOS code to run in the macOS environment](https://developer.apple.com/documentation/apple-silicon/adapting-ios-code-to-run-in-the-macos-environment); [Running your iOS apps in macOS](https://developer.apple.com/documentation/apple-silicon/running-your-ios-apps-in-macos)).

For observation from another macOS process, Apple documents `CGWindowListCopyWindowInfo` as returning window-server information for the current user session, including required window ID, owner PID, layer, and bounds; owner name and window name are optional ([Apple: `CGWindowListCopyWindowInfo`](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)), [required keys](https://developer.apple.com/documentation/coregraphics/required-window-list-keys), [optional keys](https://developer.apple.com/documentation/coregraphics/optional-window-list-keys)). This means PID and bounds are the appropriate primary correlation surfaces; a title string is not guaranteed.

### Containers and preferences

Apple says iOS and iPadOS apps receive container directories automatically and should locate Documents, Application Support, Caches, and other standard directories using Foundation APIs rather than constructing paths ([Apple: Files and directories](https://developer.apple.com/documentation/technologyoverviews/files-and-directories)). For iOS Apps on Mac specifically, Apple warns not to assume fixed file paths and says `Bundle` and `FileManager` return locations appropriate to the current system ([Running your iOS apps in macOS](https://developer.apple.com/documentation/apple-silicon/running-your-ios-apps-in-macos)).

For sandboxed apps on macOS, Apple documents the host container area as `~/Library/Containers` and says macOS 14 and later associates a container with an app's code signature. Access by another app can require user authorization ([Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)). This supports `~/Library/Containers` as a discovery root, but does not guarantee the leaf name or stable physical layout for this iOS-on-Mac installation.

Apple's preferences guide says the application defaults domain is tied to the bundle identifier. Its system-managed database is currently named `<ApplicationBundleIdentifier>.plist` under `$HOME/Library/Preferences`, where `$HOME` may be the app's sandbox home, and it should not be modified directly ([Apple: About the User Defaults System](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html)).

## Implications for the macOS Assistant

| Design question | Implication from current evidence |
|---|---|
| Primary app matcher | Use bundle ID `com.hypergryph.arknights` as the stable identity. Do not make the localized title the primary key. |
| Expected process | Expect one main application PID whose executable image is likely `Arknights` and localized name likely `明日方舟`. No bundled extension/XPC helper is statically evident. |
| Bundle path handling | Accept that Finder/Spotlight exposes the outer wrapper while the signed executable lives in the inner bundle. Match identity first and treat returned paths as runtime data rather than hard-coding one layer. |
| Runtime branch | Treat the game as UIKit/iOS-on-Mac. Do not design against AppKit view internals, Catalyst-only assumptions, Rosetta, a simulator, or a VM. |
| Game-content window | Expect one principal landscape UIKit window, fixed-size while windowed. Correlate windows by owner PID and window-server metadata, not by a required title. |
| Full screen | The user can plausibly enter native-resolution full screen because `UISupportsTrueScreenSizeOnMac=true`; metadata does not request default full-screen launch. Windowed and full-screen geometry must both be measured. |
| Coordinates | Recompute from the current window bounds and current display. Apple explicitly says not to assume a fixed app-window size, location, or equality with screen resolution. |
| Input | Hardware mouse events are mapped into the iOS touch model and Touch Alternatives exist, but that does not establish that synthetic events from an assistant behave identically or what permissions they require. |
| Preferences candidate | The likely defaults domain is `com.hypergryph.arknights`; the likely physical database name is `com.hypergryph.arknights.plist` inside the app's sandbox-home `Library/Preferences`. Existence and contents were not inspected. |
| Container candidates | Expect a default sandbox container with standard `Documents`, `Library/Application Support`, `Library/Caches`, and `Library/Preferences` subdirectories. The exact host leaf path is not established. |
| Shared containers | No App Groups entitlement is present, so no shared filesystem group container can be inferred. The keychain access group is separate and out of scope. |
| Filesystem integration | Do not rely on another app's container or preferences as an integration seam. Paths are not promised, contents may be sensitive, and macOS may require user authorization for cross-container access. |

The `Data/` directory observed inside the signed inner bundle is installation content, not evidence of the app's writable user-data container.

## Unknowns Requiring a Live Prototype

The following facts cannot be established within the permitted static/documentation-only scope:

1. The live PID, `NSRunningApplication.localizedName`, process name, activation policy, executable URL, and whether `bundleURL` reports the outer wrapper or inner app.
2. The actual number of window-server records, owner name, optional title, layer, bounds, window ID, on-screen state, full-screen transition behavior, and whether auxiliary Settings or modal windows appear.
3. Whether the current macOS release still presents the `UIRequiresFullScreen` build as strictly non-resizable in every window-management mode; Apple now marks the key deprecated for iOS/iPadOS 26.
4. The content-to-window coordinate transform, backing scale, safe-area offsets, title-bar/content-frame relationship, behavior across displays, and geometry before, during, and after full screen.
5. The Accessibility tree, AX role/subrole, whether Unity content exposes useful descendants, and which observations require Accessibility or Screen Recording consent.
6. Whether public synthetic keyboard/mouse event APIs are accepted by the game, how macOS maps those events to UIKit touch handling, and the required user permissions. Hardware-event mapping alone does not answer injection behavior.
7. The existence, exact leaf name, and layout of the game's sandbox container; the existence and schema of its defaults domain; and whether macOS prompts when a separate assistant attempts metadata-only access. No user filesystem was inspected.
8. Any runtime-created child processes or system-owned panels. Their absence from the bundle is not proof that none appear at runtime.
9. The minimum supported macOS release for this App Store variant. `MinimumOSVersion=13.0` is an iOS/iPadOS requirement and supplies no macOS floor.
10. How App Store thinning produced the local 96-entry `UISupportedDevices` array and whether another delivered build has a different list.

## Resolution

The research question is resolved far enough to set the architecture boundary: target `com.hypergryph.arknights` as an arm64 iOS App on Mac, expect a principal fixed-size UIKit game window plus native-resolution full-screen behavior, and use public macOS process/window APIs rather than bundle-path, title, or filesystem assumptions. Process URL normalization, window/coordinate measurement, Accessibility exposure, input delivery, and container visibility must remain prototype acceptance criteria rather than implementation assumptions.
