import AppKit
import CoreGraphics
import Foundation

private let targetBundleIdentifier = "com.hypergryph.arknights"

private struct PointRecord: Encodable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }
}

private struct RectRecord: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }
}

private struct RelativePointRecord: Encodable {
    let x: Double
    let y: Double
    let insideWindow: Bool
}

private struct WindowRecord: Encodable {
    let id: UInt32
    let ownerPID: Int32
    let ownerName: String?
    let name: String?
    let layer: Int
    let bounds: RectRecord
    let isOnScreen: Bool?
    let alpha: Double?
    let sharingState: Int?

    fileprivate let cgBounds: CGRect

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerPID
        case ownerName
        case name
        case layer
        case bounds
        case isOnScreen
        case alpha
        case sharingState
    }

    init?(dictionary: [String: Any]) {
        guard
            let id = dictionary[kCGWindowNumber as String] as? NSNumber,
            let ownerPID = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
            let layer = dictionary[kCGWindowLayer as String] as? NSNumber,
            let boundsValue = dictionary[kCGWindowBounds as String]
        else {
            return nil
        }
        guard let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary) else {
            return nil
        }

        self.id = id.uint32Value
        self.ownerPID = ownerPID.int32Value
        ownerName = dictionary[kCGWindowOwnerName as String] as? String
        name = dictionary[kCGWindowName as String] as? String
        self.layer = layer.intValue
        self.bounds = RectRecord(bounds)
        isOnScreen = (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
        alpha = (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
        sharingState = (dictionary[kCGWindowSharingState as String] as? NSNumber)?.intValue
        cgBounds = bounds
    }
}

private struct DisplayRecord: Encodable {
    let id: UInt32
    let isMain: Bool
    let bounds: RectRecord
    let pixelWidth: Int
    let pixelHeight: Int
    let pointPixelScaleX: Double
    let pointPixelScaleY: Double

    fileprivate let cgBounds: CGRect

    private enum CodingKeys: String, CodingKey {
        case id
        case isMain
        case bounds
        case pixelWidth
        case pixelHeight
        case pointPixelScaleX
        case pointPixelScaleY
    }

    init(id: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        self.id = id
        isMain = id == CGMainDisplayID()
        self.bounds = RectRecord(bounds)
        pixelWidth = mode?.pixelWidth ?? CGDisplayPixelsWide(id)
        pixelHeight = mode?.pixelHeight ?? CGDisplayPixelsHigh(id)
        pointPixelScaleX = bounds.width > 0 ? Double(pixelWidth) / bounds.width : 0
        pointPixelScaleY = bounds.height > 0 ? Double(pixelHeight) / bounds.height : 0
        cgBounds = bounds
    }
}

private struct AppRecord: Encodable {
    let bundleIdentifier: String?
    let localizedName: String?
    let pid: Int32
    let isActive: Bool
    let bundleURL: String?
    let executableURL: String?
}

private struct GeometrySample: Encodable {
    let timestamp: String
    let targetBundleIdentifier: String
    let targetApplications: [AppRecord]
    let frontmostApplication: AppRecord?
    let targetWindows: [WindowRecord]
    let selectedWindow: WindowRecord?
    let displays: [DisplayRecord]
    let selectedDisplay: DisplayRecord?
    let selectedWindowMatchesDisplay: Bool?
    let pointer: PointRecord?
    let pointerRelativeToSelectedWindow: RelativePointRecord?
    let notes: [String]
}

private struct MoveResult: Encodable {
    let sample: GeometrySample
    let requestedRelativePoint: RelativePointRecord
    let originalPointer: PointRecord
    let targetPoint: PointRecord
    let observedAtTarget: PointRecord?
    let placementErrorPoints: Double?
    let observedBeforeRestore: PointRecord?
    let observedAfterRestore: PointRecord?
    let restorationSkippedDueToPointerMovement: Bool
    let restoreTolerancePoints: Double
    let restoreErrorPoints: Double?
    let restoreWithinTolerance: Bool?
}

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case targetNotRunning
    case targetNotFrontmost
    case targetWindowUnavailable
    case postEventPermissionDenied
    case pointerUnavailable

    var description: String {
        switch self {
        case let .invalidArguments(message): message
        case .targetNotRunning: "Target game is not running."
        case .targetNotFrontmost: "Target game was not frontmost when the delayed sample ran."
        case .targetWindowUnavailable: "No unambiguous layer-zero target window was available."
        case .postEventPermissionDenied: "PostEvent permission was denied. Enable this terminal/probe under Privacy & Security > Accessibility, then retry."
        case .pointerUnavailable: "The current pointer location could not be read."
        }
    }
}

private func appRecord(_ application: NSRunningApplication) -> AppRecord {
    AppRecord(
        bundleIdentifier: application.bundleIdentifier,
        localizedName: application.localizedName,
        pid: application.processIdentifier,
        isActive: application.isActive,
        bundleURL: application.bundleURL?.path,
        executableURL: application.executableURL?.path
    )
}

private func activeDisplays() -> [DisplayRecord] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else {
        return []
    }

    var identifiers = Array(repeating: CGDirectDisplayID(), count: Int(count))
    guard CGGetActiveDisplayList(count, &identifiers, &count) == .success else {
        return []
    }

    return identifiers.prefix(Int(count)).map(DisplayRecord.init)
}

private func targetWindows(pid: Int32) -> [WindowRecord] {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let dictionaries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    return dictionaries
        .compactMap(WindowRecord.init)
        .filter { $0.ownerPID == pid && $0.cgBounds.width > 0 && $0.cgBounds.height > 0 }
}

private func overlapArea(_ first: CGRect, _ second: CGRect) -> Double {
    let intersection = first.intersection(second)
    return intersection.isNull ? 0 : intersection.width * intersection.height
}

private func approximatelyEqual(_ first: CGRect, _ second: CGRect, tolerance: Double = 2) -> Bool {
    abs(first.minX - second.minX) <= tolerance
        && abs(first.minY - second.minY) <= tolerance
        && abs(first.width - second.width) <= tolerance
        && abs(first.height - second.height) <= tolerance
}

private func pointerLocation() -> CGPoint? {
    CGEvent(source: nil)?.location
}

private func makeSample() -> GeometrySample {
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleIdentifier)
    let frontmost = NSWorkspace.shared.frontmostApplication.map(appRecord)
    let targetApplicationRecords = applications.map(appRecord)
    let displays = activeDisplays()
    var notes: [String] = []

    guard let application = applications.first(where: { $0.processIdentifier == frontmost?.pid }) ?? applications.first else {
        return GeometrySample(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            targetBundleIdentifier: targetBundleIdentifier,
            targetApplications: [],
            frontmostApplication: frontmost,
            targetWindows: [],
            selectedWindow: nil,
            displays: displays,
            selectedDisplay: nil,
            selectedWindowMatchesDisplay: nil,
            pointer: pointerLocation().map(PointRecord.init),
            pointerRelativeToSelectedWindow: nil,
            notes: ["Target application was not running."]
        )
    }

    let windows = targetWindows(pid: application.processIdentifier)
    let layerZeroWindows = windows.filter { $0.layer == 0 }
    let onScreenLayerZeroWindows = layerZeroWindows.filter { $0.isOnScreen == true }
    let preferredWindows = onScreenLayerZeroWindows.isEmpty ? layerZeroWindows : onScreenLayerZeroWindows
    let selectedWindow = preferredWindows.max {
        $0.cgBounds.width * $0.cgBounds.height < $1.cgBounds.width * $1.cgBounds.height
    }
    let selectedDisplay: DisplayRecord? = selectedWindow.flatMap { window -> DisplayRecord? in
        guard let display = displays.max(by: {
            overlapArea(window.cgBounds, $0.cgBounds) < overlapArea(window.cgBounds, $1.cgBounds)
        }), overlapArea(window.cgBounds, display.cgBounds) > 0 else {
            return nil
        }
        return display
    }
    let pointer = pointerLocation()
    let relativePointer = selectedWindow.flatMap { window in
        pointer.map { point in
            RelativePointRecord(
                x: (point.x - window.cgBounds.minX) / window.cgBounds.width,
                y: (point.y - window.cgBounds.minY) / window.cgBounds.height,
                insideWindow: window.cgBounds.contains(point)
            )
        }
    }

    if applications.count > 1 {
        notes.append("Multiple target applications matched the bundle identifier.")
    }
    if frontmost?.pid != application.processIdentifier {
        notes.append("Target application was not frontmost at sample time.")
    }
    if layerZeroWindows.isEmpty {
        notes.append("No layer-zero target window was available.")
    } else if onScreenLayerZeroWindows.count > 1 {
        notes.append("Multiple on-screen layer-zero target windows existed; the largest was selected for diagnostics only.")
    } else if onScreenLayerZeroWindows.isEmpty {
        notes.append("No on-screen layer-zero target window existed; an off-screen window was selected for diagnostics only.")
    }
    if selectedWindow?.isOnScreen == false {
        notes.append("Selected target window reported isOnScreen=false.")
    }
    if let selectedWindow, let selectedDisplay,
       !approximatelyEqual(selectedWindow.cgBounds, selectedDisplay.cgBounds) {
        notes.append("Selected target window bounds did not match the selected display bounds.")
    }
    notes.append("Public APIs do not expose a stable Space identifier; frontmost state and window/display geometry are the supported correlation signals.")

    return GeometrySample(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        targetBundleIdentifier: targetBundleIdentifier,
        targetApplications: targetApplicationRecords,
        frontmostApplication: frontmost,
        targetWindows: windows,
        selectedWindow: selectedWindow,
        displays: displays,
        selectedDisplay: selectedDisplay,
        selectedWindowMatchesDisplay: selectedWindow.flatMap { window in
            selectedDisplay.map { approximatelyEqual(window.cgBounds, $0.cgBounds) }
        },
        pointer: pointer.map(PointRecord.init),
        pointerRelativeToSelectedWindow: relativePointer,
        notes: notes
    )
}

private func argumentValue(_ name: String, arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func numericArgument(_ name: String, arguments: [String], default defaultValue: Double) throws -> Double {
    guard let value = argumentValue(name, arguments: arguments) else {
        return defaultValue
    }
    guard let number = Double(value), number.isFinite else {
        throw ProbeError.invalidArguments("Invalid numeric value for \(name): \(value)")
    }
    return number
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

private func postMouseMove(to point: CGPoint) {
    CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    )?.post(tap: .cgSessionEventTap)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "sample"
    guard command == "sample" || command == "move" else {
        throw ProbeError.invalidArguments("Usage: fullscreen-geometry-probe [sample|move] [--delay seconds] [--x 0..<1 --y 0..<1 --hold-ms milliseconds]")
    }
    let delay = try numericArgument("--delay", arguments: arguments, default: 8)
    guard delay >= 0 else {
        throw ProbeError.invalidArguments("--delay must be zero or greater.")
    }

    let relativeX = try numericArgument("--x", arguments: arguments, default: 0.5)
    let relativeY = try numericArgument("--y", arguments: arguments, default: 0.5)
    let holdMilliseconds = try numericArgument("--hold-ms", arguments: arguments, default: 300)
    if command == "move" {
        guard relativeX >= 0, relativeX < 1, relativeY >= 0, relativeY < 1, holdMilliseconds >= 0 else {
            throw ProbeError.invalidArguments("--x and --y must be in the half-open range 0..<1; --hold-ms must be zero or greater.")
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleIdentifier).isEmpty else {
            throw ProbeError.targetNotRunning
        }
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            throw ProbeError.postEventPermissionDenied
        }
    }

    if delay > 0 {
        fputs("Sampling in \(delay) seconds. Switch to the target game now.\n", stderr)
        Thread.sleep(forTimeInterval: delay)
    }

    let sample = makeSample()
    guard command == "move" else {
        try printJSON(sample)
        return
    }

    guard sample.targetApplications.count == 1, let target = sample.targetApplications.first else {
        throw ProbeError.targetNotRunning
    }
    guard sample.frontmostApplication?.pid == target.pid else {
        throw ProbeError.targetNotFrontmost
    }
    let moveCandidates = sample.targetWindows.filter { window in
        window.layer == 0
            && window.isOnScreen == true
            && (window.alpha ?? 1) > 0
            && sample.displays.contains { approximatelyEqual(window.cgBounds, $0.cgBounds) }
    }
    guard
        moveCandidates.count == 1,
        let window = sample.selectedWindow,
        window.id == moveCandidates[0].id,
        sample.selectedDisplay != nil,
        sample.selectedWindowMatchesDisplay == true
    else {
        throw ProbeError.targetWindowUnavailable
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
        throw ProbeError.targetNotFrontmost
    }
    guard let originalPointer = pointerLocation() else {
        throw ProbeError.pointerUnavailable
    }

    let targetPoint = CGPoint(
        x: window.cgBounds.minX + window.cgBounds.width * relativeX,
        y: window.cgBounds.minY + window.cgBounds.height * relativeY
    )
    postMouseMove(to: targetPoint)
    Thread.sleep(forTimeInterval: 0.1)
    let observedAtTarget = pointerLocation()
    Thread.sleep(forTimeInterval: holdMilliseconds / 1_000)
    let observedBeforeRestore = pointerLocation()
    let restoreTolerance = 2.0
    let placementError = observedAtTarget.map {
        Double(hypot($0.x - targetPoint.x, $0.y - targetPoint.y))
    }
    let pointerMoved: Bool
    if let observedAtTarget, let observedBeforeRestore {
        pointerMoved = hypot(
            observedBeforeRestore.x - observedAtTarget.x,
            observedBeforeRestore.y - observedAtTarget.y
        ) > restoreTolerance
    } else {
        pointerMoved = true
    }
    let observedAfterRestore: CGPoint?
    if pointerMoved {
        observedAfterRestore = observedBeforeRestore
    } else {
        postMouseMove(to: originalPointer)
        Thread.sleep(forTimeInterval: 0.1)
        observedAfterRestore = pointerLocation()
    }
    let restoreError = observedAfterRestore.map {
        Double(hypot($0.x - originalPointer.x, $0.y - originalPointer.y))
    }
    let restoreWithinTolerance = pointerMoved ? nil : restoreError.map { $0 <= restoreTolerance }

    try printJSON(MoveResult(
        sample: sample,
        requestedRelativePoint: RelativePointRecord(
            x: relativeX,
            y: relativeY,
            insideWindow: window.cgBounds.contains(targetPoint)
        ),
        originalPointer: PointRecord(originalPointer),
        targetPoint: PointRecord(targetPoint),
        observedAtTarget: observedAtTarget.map(PointRecord.init),
        placementErrorPoints: placementError,
        observedBeforeRestore: observedBeforeRestore.map(PointRecord.init),
        observedAfterRestore: observedAfterRestore.map(PointRecord.init),
        restorationSkippedDueToPointerMovement: pointerMoved,
        restoreTolerancePoints: restoreTolerance,
        restoreErrorPoints: restoreError,
        restoreWithinTolerance: restoreWithinTolerance
    ))
}

do {
    try run()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(2)
}
