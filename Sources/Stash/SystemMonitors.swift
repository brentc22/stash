import AppKit
import CoreGraphics
import Darwin
import Network
import StashCore

/// Gathers `PresentationSignals` from the OS. Polls every two seconds: there is no
/// notification for "screen sharing started" or "joined a call", and the three reads are
/// cheap (a session dictionary, the display list, the process list).
// @MainActor: `onChange` drives AppDelegate, and the timer is scheduled on the main run loop.
@MainActor
final class PresentationMonitor {

    private(set) var signals = PresentationSignals()
    /// Receives the signals from before the change.
    var onChange: ((PresentationSignals) -> Void)?
    private var timer: Timer?

    /// Process names that exist only while a call is live. Zoom starts `CptHost` when a
    /// meeting begins and ends it when the meeting does — its main app stays running in
    /// between, so the app alone would say nothing.
    private static let callProcessNames: Set<String> = ["CptHost"]

    /// Starts or stops polling. Stopping resets the signals, so a stale "in a call" can
    /// never outlive the setting that was reading it.
    func setRunning(_ running: Bool) {
        guard running != (timer != nil) else { return }
        if running {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            // Read once without `onChange`: this runs inside `rebuild()`, which goes on to
            // use the fresh signals itself — a callback here would re-enter it.
            signals = Self.current()
        } else {
            timer?.invalidate()
            timer = nil
            signals = PresentationSignals()
        }
    }

    private static func current() -> PresentationSignals {
        PresentationSignals(screenShared: isScreenShared(), mirroring: isMirroring(), inCall: isInCall())
    }

    private func poll() {
        let next = Self.current()
        guard next != signals else { return }
        let previous = signals
        signals = next
        onChange?(previous)
    }

    /// Screen Sharing (VNC) viewers watching this Mac. The session dictionary is the only
    /// place macOS exposes it.
    private static func isScreenShared() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsShared"] as? Bool) ?? false
    }

    /// Any active display mirroring another — a projector or TV in mirror mode.
    private static func isMirroring() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    private static func isInCall() -> Bool {
        let size = proc_listallpids(nil, 0)
        guard size > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(size))
        let filled = proc_listallpids(&pids, size * Int32(MemoryLayout<pid_t>.size))
        guard filled > 0 else { return false }
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            if callProcessNames.contains(String(cString: name)) { return true }
        }
        return false
    }
}

/// Whether a Wi-Fi connection is up. `NWPathMonitor` restricted to the Wi-Fi interface
/// reports `.satisfied` exactly when there is one — no location permission needed,
/// unlike reading the SSID through CoreWLAN.
@MainActor
final class WiFiMonitor {

    private(set) var isConnected = false
    var onChange: (() -> Void)?
    private var monitor: NWPathMonitor?

    func setRunning(_ running: Bool) {
        guard running != (monitor != nil) else { return }
        if running { start() } else { stop() }
    }

    private func start() {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self, self.isConnected != connected else { return }
                self.isConnected = connected
                self.onChange?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.brentc22.Stash.wifi"))
        self.monitor = monitor
    }

    private func stop() {
        monitor?.cancel()
        monitor = nil
        isConnected = false
    }
}
