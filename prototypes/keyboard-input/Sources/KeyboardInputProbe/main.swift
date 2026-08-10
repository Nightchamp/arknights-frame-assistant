import AppKit
import CoreGraphics
import Foundation

private let targetBundleIdentifier = "com.hypergryph.arknights"
private let syntheticTag: Int64 = 0x4146415F50524F42

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case listenPermissionDenied
    case postPermissionDenied
    case targetUnavailable
    case targetNotFrontmost
    case eventTapUnavailable
    case eventCreationFailed

    var description: String {
        switch self {
        case let .invalidArguments(message): message
        case .listenPermissionDenied:
            "ListenEvent permission was denied. Grant Input Monitoring, then rerun."
        case .postPermissionDenied:
            "PostEvent permission was denied. Grant Accessibility, then rerun."
        case .targetUnavailable:
            "Exactly one running target application is required."
        case .targetNotFrontmost:
            "The target game must remain frontmost for this trial."
        case .eventTapUnavailable:
            "The requested CoreGraphics event tap could not be created."
        case .eventCreationFailed:
            "A synthetic keyboard event could not be created."
        }
    }
}

private enum PostingRoute: String, Encodable {
    case pid
    case session
}

private enum TapMode {
    case watch
    case bridge(
        trigger: CGKeyCode,
        output: CGKeyCode,
        route: PostingRoute,
        suppress: Bool
    )
}

private struct AppRecord: Encodable {
    let bundleIdentifier: String?
    let localizedName: String?
    let pid: Int32
    let isActive: Bool
    let bundleURL: String?
}

private struct PointRecord: Encodable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }
}

private struct PermissionRecord: Encodable {
    let listenEvent: Bool
    let postEvent: Bool
}

private struct StatusRecord: Encodable {
    let timestamp: String
    let permissions: PermissionRecord
    let frontmostApplication: AppRecord?
    let targetApplications: [AppRecord]
}

private struct KeyEventRecord: Encodable {
    let uptime: Double
    let type: String
    let keyCode: Int64
    let autorepeatEvent: Bool
    let sourceUserData: Int64
    let sourcePID: Int64
    let targetPID: Int64
    let frontmostPID: Int32?
    let disposition: String
}

private struct TapSummary: Encodable {
    let mode: String
    let route: PostingRoute?
    let suppressionEnabled: Bool?
    let targetPID: Int32
    let triggerKeyCode: UInt16?
    let outputKeyCode: UInt16?
    let durationSeconds: Double
    let permissions: PermissionRecord
    let observedEvents: Int
    let passedEvents: Int
    let suppressedEvents: Int
    let postingAttempts: Int
    let syntheticEventsSeen: Int
    let disabledEvents: Int
    let abandonedHandledPresses: Int
    let cleanupUpAttempts: Int
    let triggerWasDownAtDeadline: Bool
    let triggerWasDownAtTeardown: Bool
    let runLoopResult: String
    let elapsedSeconds: Double
    let frontmostAfterRun: AppRecord?
    let events: [KeyEventRecord]
}

private struct DirectResult: Encodable {
    let route: PostingRoute
    let targetPID: Int32
    let outputKeyCode: UInt16
    let frontmostBefore: AppRecord
    let frontmostAfter: AppRecord?
    let pointerBefore: PointRecord?
    let pointerAfter: PointRecord?
    let pointerDeltaPoints: Double?
    let frontmostUnchanged: Bool
    let postingAttempted: Bool
}

private func appRecord(_ application: NSRunningApplication) -> AppRecord {
    AppRecord(
        bundleIdentifier: application.bundleIdentifier,
        localizedName: application.localizedName,
        pid: application.processIdentifier,
        isActive: application.isActive,
        bundleURL: application.bundleURL?.path
    )
}

private func currentPermissions() -> PermissionRecord {
    PermissionRecord(
        listenEvent: CGPreflightListenEventAccess(),
        postEvent: CGPreflightPostEventAccess()
    )
}

private func targetApplication() throws -> NSRunningApplication {
    let applications = NSRunningApplication.runningApplications(
        withBundleIdentifier: targetBundleIdentifier
    )
    guard applications.count == 1, let application = applications.first else {
        throw ProbeError.targetUnavailable
    }
    return application
}

private func revalidateTarget(pid: Int32) throws {
    let applications = NSRunningApplication.runningApplications(
        withBundleIdentifier: targetBundleIdentifier
    )
    guard applications.count == 1, applications.first?.processIdentifier == pid else {
        throw ProbeError.targetUnavailable
    }
}

private func frontmostApplication() -> AppRecord? {
    NSWorkspace.shared.frontmostApplication.map(appRecord)
}

private func requireTargetFrontmost(pid: Int32) throws -> AppRecord {
    guard let frontmost = NSWorkspace.shared.frontmostApplication,
          frontmost.processIdentifier == pid else {
        throw ProbeError.targetNotFrontmost
    }
    return appRecord(frontmost)
}

private func requestListenPermission() throws {
    guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
        throw ProbeError.listenPermissionDenied
    }
}

private func requestPostPermission() throws {
    guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
        throw ProbeError.postPermissionDenied
    }
}

private func pointerLocation() -> CGPoint? {
    CGEvent(source: nil)?.location
}

private func makeKeyboardEvent(keyCode: CGKeyCode, keyDown: Bool) throws -> CGEvent {
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let event = CGEvent(
              keyboardEventSource: source,
              virtualKey: keyCode,
              keyDown: keyDown
          ) else {
        throw ProbeError.eventCreationFailed
    }
    event.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    return event
}

private func attemptKeyTap(keyCode: CGKeyCode, route: PostingRoute, targetPID: Int32) throws {
    let down = try makeKeyboardEvent(keyCode: keyCode, keyDown: true)
    let up = try makeKeyboardEvent(keyCode: keyCode, keyDown: false)
    switch route {
    case .pid:
        down.postToPid(targetPID)
        up.postToPid(targetPID)
    case .session:
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}

private func attemptCleanupKeyUp(keyCode: CGKeyCode, targetPID: Int32) throws {
    let up = try makeKeyboardEvent(keyCode: keyCode, keyDown: false)
    up.postToPid(targetPID)
}

private final class TapContext: @unchecked Sendable {
    let mode: TapMode
    let targetPID: Int32
    let durationSeconds: Double
    var tap: CFMachPort?
    var events: [KeyEventRecord] = []
    var passedEvents = 0
    var suppressedEvents = 0
    var postingAttempts = 0
    var syntheticEventsSeen = 0
    var disabledEvents = 0
    var abandonedHandledPresses = 0
    var cleanupUpAttempts = 0
    var triggerDown = false
    var handledPress = false

    init(mode: TapMode, targetPID: Int32, durationSeconds: Double) {
        self.mode = mode
        self.targetPID = targetPID
        self.durationSeconds = durationSeconds
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            disabledEvents += 1
            if handledPress {
                abandonedHandledPresses += 1
            }
            triggerDown = false
            handledPress = false
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let userData = event.getIntegerValueField(.eventSourceUserData)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let baseRecord = (
            uptime: ProcessInfo.processInfo.systemUptime,
            type: type == .keyDown ? "keyDown" : "keyUp",
            keyCode: keyCode,
            autorepeatEvent: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            sourceUserData: userData,
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
            targetPID: event.getIntegerValueField(.eventTargetUnixProcessID),
            frontmostPID: frontmostPID
        )

        if userData == syntheticTag {
            syntheticEventsSeen += 1
            append(baseRecord, disposition: "synthetic-pass")
            passedEvents += 1
            return Unmanaged.passUnretained(event)
        }

        switch mode {
        case .watch:
            guard frontmostPID == targetPID else {
                passedEvents += 1
                return Unmanaged.passUnretained(event)
            }
            append(baseRecord, disposition: "watch-pass")
            passedEvents += 1
            return Unmanaged.passUnretained(event)

        case let .bridge(trigger, output, route, suppress):
            guard keyCode == Int64(trigger) else {
                passedEvents += 1
                return Unmanaged.passUnretained(event)
            }

            if type == .keyDown {
                if triggerDown || baseRecord.autorepeatEvent {
                    if handledPress {
                        append(baseRecord, disposition: "repeat-suppress")
                        suppressedEvents += 1
                        return nil
                    }
                    append(baseRecord, disposition: "repeat-pass")
                    passedEvents += 1
                    return Unmanaged.passUnretained(event)
                }

                triggerDown = true
                guard isReady(frontmostPID: frontmostPID) else {
                    handledPress = false
                    append(baseRecord, disposition: "not-ready-pass")
                    passedEvents += 1
                    return Unmanaged.passUnretained(event)
                }

                do {
                    try attemptKeyTap(keyCode: output, route: route, targetPID: targetPID)
                    postingAttempts += 1
                    handledPress = suppress
                    if suppress {
                        append(baseRecord, disposition: "ready-post-attempt-suppress")
                        suppressedEvents += 1
                        return nil
                    }
                    append(baseRecord, disposition: "ready-post-attempt-pass")
                    passedEvents += 1
                    return Unmanaged.passUnretained(event)
                } catch {
                    handledPress = false
                    append(baseRecord, disposition: "event-creation-failed-pass")
                    passedEvents += 1
                    return Unmanaged.passUnretained(event)
                }
            }

            let suppressUp = handledPress
            triggerDown = false
            handledPress = false
            if suppressUp {
                append(baseRecord, disposition: "handled-up-suppress")
                suppressedEvents += 1
                return nil
            }
            append(baseRecord, disposition: "unhandled-up-pass")
            passedEvents += 1
            return Unmanaged.passUnretained(event)
        }
    }

    private func isReady(frontmostPID: Int32?) -> Bool {
        guard
            frontmostPID == targetPID,
            CGPreflightListenEventAccess(),
            CGPreflightPostEventAccess()
        else {
            return false
        }
        let targets = NSRunningApplication.runningApplications(
            withBundleIdentifier: targetBundleIdentifier
        )
        return targets.count == 1 && targets.first?.processIdentifier == targetPID
    }

    private func append(
        _ record: (
            uptime: Double,
            type: String,
            keyCode: Int64,
            autorepeatEvent: Bool,
            sourceUserData: Int64,
            sourcePID: Int64,
            targetPID: Int64,
            frontmostPID: Int32?
        ),
        disposition: String
    ) {
        guard events.count < 100 else {
            return
        }
        events.append(KeyEventRecord(
            uptime: record.uptime,
            type: record.type,
            keyCode: record.keyCode,
            autorepeatEvent: record.autorepeatEvent,
            sourceUserData: record.sourceUserData,
            sourcePID: record.sourcePID,
            targetPID: record.targetPID,
            frontmostPID: record.frontmostPID,
            disposition: disposition
        ))
    }
}

private func tapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
    return context.handle(type: type, event: event)
}

private func runTap(mode: TapMode, durationSeconds: Double, targetPID: Int32) throws -> TapSummary {
    guard CGPreflightListenEventAccess() else {
        throw ProbeError.listenPermissionDenied
    }
    if case .bridge = mode, !CGPreflightPostEventAccess() {
        throw ProbeError.postPermissionDenied
    }

    let context = TapContext(mode: mode, targetPID: targetPID, durationSeconds: durationSeconds)
    let opaqueContext = Unmanaged.passUnretained(context).toOpaque()
    let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    let options: CGEventTapOptions = switch mode {
    case .watch: .listenOnly
    case .bridge: .defaultTap
    }

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: options,
        eventsOfInterest: eventMask,
        callback: tapCallback,
        userInfo: opaqueContext
    ) else {
        throw ProbeError.eventTapUnavailable
    }
    context.tap = tap

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    let startedAt = ProcessInfo.processInfo.systemUptime
    let runLoopResult = CFRunLoopRunInMode(.defaultMode, durationSeconds, false)
    let triggerWasDownAtDeadline = context.triggerDown
    let graceDeadline = ProcessInfo.processInfo.systemUptime + 2
    while context.triggerDown && ProcessInfo.processInfo.systemUptime < graceDeadline {
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
    }
    let triggerWasDownAtTeardown = context.triggerDown
    CGEvent.tapEnable(tap: tap, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
    if context.handledPress {
        context.abandonedHandledPresses += 1
    }
    context.triggerDown = false
    context.handledPress = false

    if case let .bridge(_, output, _, _) = mode, context.postingAttempts > 0 {
        let targets = NSRunningApplication.runningApplications(
            withBundleIdentifier: targetBundleIdentifier
        )
        let cleanupReady = CGPreflightPostEventAccess()
            && targets.count == 1
            && targets.first?.processIdentifier == targetPID
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        if cleanupReady,
           (try? attemptCleanupKeyUp(keyCode: output, targetPID: targetPID)) != nil {
            context.cleanupUpAttempts += 1
        }
    }

    let summaryMode: String
    let route: PostingRoute?
    let suppressionEnabled: Bool?
    let triggerKeyCode: UInt16?
    let outputKeyCode: UInt16?
    switch mode {
    case .watch:
        summaryMode = "watch"
        route = nil
        suppressionEnabled = nil
        triggerKeyCode = nil
        outputKeyCode = nil
    case let .bridge(trigger, output, postingRoute, suppress):
        summaryMode = "bridge"
        route = postingRoute
        suppressionEnabled = suppress
        triggerKeyCode = trigger
        outputKeyCode = output
    }

    return TapSummary(
        mode: summaryMode,
        route: route,
        suppressionEnabled: suppressionEnabled,
        targetPID: targetPID,
        triggerKeyCode: triggerKeyCode,
        outputKeyCode: outputKeyCode,
        durationSeconds: durationSeconds,
        permissions: currentPermissions(),
        observedEvents: context.events.count,
        passedEvents: context.passedEvents,
        suppressedEvents: context.suppressedEvents,
        postingAttempts: context.postingAttempts,
        syntheticEventsSeen: context.syntheticEventsSeen,
        disabledEvents: context.disabledEvents,
        abandonedHandledPresses: context.abandonedHandledPresses,
        cleanupUpAttempts: context.cleanupUpAttempts,
        triggerWasDownAtDeadline: triggerWasDownAtDeadline,
        triggerWasDownAtTeardown: triggerWasDownAtTeardown,
        runLoopResult: String(describing: runLoopResult),
        elapsedSeconds: ProcessInfo.processInfo.systemUptime - startedAt,
        frontmostAfterRun: frontmostApplication(),
        events: context.events
    )
}

private func argumentValue(_ name: String, arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func numericArgument(
    _ name: String,
    arguments: [String],
    default defaultValue: Double
) throws -> Double {
    guard let value = argumentValue(name, arguments: arguments) else {
        return defaultValue
    }
    guard let number = Double(value), number.isFinite else {
        throw ProbeError.invalidArguments("Invalid value for \(name): \(value)")
    }
    return number
}

private func keyCodeArgument(_ name: String, arguments: [String]) throws -> CGKeyCode {
    guard let value = argumentValue(name, arguments: arguments),
          let number = UInt16(value), number <= 255 else {
        throw ProbeError.invalidArguments("\(name) requires an integer key code from 0 through 255.")
    }
    return number
}

private func routeArgument(arguments: [String]) throws -> PostingRoute {
    let value = argumentValue("--route", arguments: arguments) ?? "pid"
    guard let route = PostingRoute(rawValue: value) else {
        throw ProbeError.invalidArguments("--route must be pid or session.")
    }
    return route
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard let output = String(data: data, encoding: .utf8) else {
        throw ProbeError.invalidArguments("Could not encode UTF-8 output.")
    }
    print(output)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "status"
    let delay = try numericArgument("--delay", arguments: arguments, default: 0)
    let duration = try numericArgument("--seconds", arguments: arguments, default: 10)
    guard delay >= 0, duration > 0 else {
        throw ProbeError.invalidArguments("--delay must be nonnegative and --seconds must be positive.")
    }

    if command == "status" {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: targetBundleIdentifier
        )
        try printJSON(StatusRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            permissions: currentPermissions(),
            frontmostApplication: frontmostApplication(),
            targetApplications: applications.map(appRecord)
        ))
        return
    }

    let target = try targetApplication()
    switch command {
    case "watch":
        try requestListenPermission()
        if delay > 0 {
            fputs("Watching in \(delay) seconds. Keep the target game frontmost.\n", stderr)
            Thread.sleep(forTimeInterval: delay)
        }
        guard CGPreflightListenEventAccess() else {
            throw ProbeError.listenPermissionDenied
        }
        try revalidateTarget(pid: target.processIdentifier)
        _ = try requireTargetFrontmost(pid: target.processIdentifier)
        try printJSON(runTap(
            mode: .watch,
            durationSeconds: duration,
            targetPID: target.processIdentifier
        ))

    case "inject":
        let output = try keyCodeArgument("--output", arguments: arguments)
        let route = try routeArgument(arguments: arguments)
        try requestPostPermission()
        if delay > 0 {
            fputs("Injecting in \(delay) seconds. Keep the target game frontmost.\n", stderr)
            Thread.sleep(forTimeInterval: delay)
        }
        guard CGPreflightPostEventAccess() else {
            throw ProbeError.postPermissionDenied
        }
        try revalidateTarget(pid: target.processIdentifier)
        let frontmostBefore = try requireTargetFrontmost(pid: target.processIdentifier)
        let pointerBefore = pointerLocation()
        try attemptKeyTap(keyCode: output, route: route, targetPID: target.processIdentifier)
        Thread.sleep(forTimeInterval: 0.2)
        let pointerAfter = pointerLocation()
        let frontmostAfter = frontmostApplication()
        let pointerDelta = pointerBefore.flatMap { before in
            pointerAfter.map { after in
                Double(hypot(after.x - before.x, after.y - before.y))
            }
        }
        try printJSON(DirectResult(
            route: route,
            targetPID: target.processIdentifier,
            outputKeyCode: output,
            frontmostBefore: frontmostBefore,
            frontmostAfter: frontmostAfter,
            pointerBefore: pointerBefore.map(PointRecord.init),
            pointerAfter: pointerAfter.map(PointRecord.init),
            pointerDeltaPoints: pointerDelta,
            frontmostUnchanged: frontmostAfter?.pid == target.processIdentifier,
            postingAttempted: true
        ))

    case "bridge":
        let trigger = try keyCodeArgument("--trigger", arguments: arguments)
        let output = try keyCodeArgument("--output", arguments: arguments)
        let route = try routeArgument(arguments: arguments)
        let suppress = arguments.contains("--suppress")
        if suppress && route != .pid {
            throw ProbeError.invalidArguments("--suppress is limited to the pid route because session posting can cross a focus change.")
        }
        try requestListenPermission()
        try requestPostPermission()
        if delay > 0 {
            fputs("Bridging in \(delay) seconds. Keep the target game frontmost.\n", stderr)
            Thread.sleep(forTimeInterval: delay)
        }
        guard CGPreflightListenEventAccess() else {
            throw ProbeError.listenPermissionDenied
        }
        guard CGPreflightPostEventAccess() else {
            throw ProbeError.postPermissionDenied
        }
        try revalidateTarget(pid: target.processIdentifier)
        _ = try requireTargetFrontmost(pid: target.processIdentifier)
        try printJSON(runTap(
            mode: .bridge(
                trigger: trigger,
                output: output,
                route: route,
                suppress: suppress
            ),
            durationSeconds: duration,
            targetPID: target.processIdentifier
        ))

    default:
        throw ProbeError.invalidArguments(
            "Usage: keyboard-input-probe status | watch [--seconds N] | inject --output KEY [--route pid|session] | bridge --trigger KEY --output KEY [--route pid|session] [--suppress] [--seconds N]"
        )
    }
}

do {
    try run()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(2)
}
