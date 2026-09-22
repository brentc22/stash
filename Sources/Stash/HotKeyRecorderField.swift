import AppKit
import StashCore
import SwiftUI

/// Captures one key combination from the keyboard while the settings window has focus.
///
/// Uses `NSEvent.addLocalMonitorForEvents` — **local**, never global. A local monitor only
/// sees events already delivered to this process and therefore needs no Accessibility
/// permission; the global variant does, and Stash's whole premise is that hiding and
/// showing works without asking for one. The window has focus while recording, so local
/// is not a compromise here, it is simply the right tool.
///
/// `@unchecked Sendable`: `deinit` removes the monitor, and a `deinit` can never call a
/// `@MainActor` method, so this class cannot be `@MainActor` — the same trap `AppInventory`
/// and `CollapseTimer` hit. Safe because every stored property is only ever touched from
/// `start()`/`stop()` and from the monitor's own callback, all of which run on the main
/// thread: AppKit delivers local monitor callbacks there, and the two entry points are
/// SwiftUI button actions.
final class HotKeyRecorder: ObservableObject, @unchecked Sendable {

    @Published private(set) var isRecording = false
    /// Modifiers currently held down, so the field can show ⌃⌥ building up before the
    /// letter lands. Only meaningful while `isRecording`.
    @Published private(set) var heldModifiers: NSEvent.ModifierFlags = []

    private var monitor: Any?
    private var onResult: ((HotKeyCombo?) -> Void)?

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Starts recording. `onResult` gets the recorded combination, or `nil` when the user
    /// pressed Escape to cancel — in which case the caller must keep the old one.
    func start(onResult: @escaping (HotKeyCombo?) -> Void) {
        stop()
        self.onResult = onResult
        isRecording = true
        heldModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        heldModifiers = []
        onResult = nil
    }

    /// Returns `nil` to swallow the event: while recording, a keystroke is input for this
    /// field and must not also reach the rest of the window (Escape would close it, ⌘W
    /// would trigger a menu item).
    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(HotKeyCombo.allowedModifiers)

        switch event.type {
        case .flagsChanged:
            heldModifiers = modifiers
            return nil
        case .keyDown:
            // Escape on its own cancels; Escape *with* modifiers is a legitimate
            // combination someone may want to record.
            if event.keyCode == HotKeyCombo.escapeKeyCode && modifiers.isEmpty {
                let callback = onResult
                stop()
                callback?(nil)
                return nil
            }
            let combo = HotKeyCombo(keyCode: event.keyCode, modifiers: modifiers.rawValue)
            let callback = onResult
            stop()
            callback?(combo)
            return nil
        default:
            return event
        }
    }
}

/// The shortcut field itself: shows the current combination, goes into recording mode on
/// click, and carries a round clear button beside it.
struct HotKeyRecorderField: View {

    let combo: HotKeyCombo?
    /// Called only with a combination the user actually pressed. A recording cancelled
    /// with Escape reports nothing at all — the old combination simply stays.
    let onRecord: (HotKeyCombo) -> Void
    let onClear: () -> Void

    @StateObject private var recorder = HotKeyRecorder()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    recorder.start { recorded in
                        // `nil` is Escape: cancelled, keep what was there.
                        if let recorded { onRecord(recorded) }
                    }
                }
            } label: {
                Text(fieldText)
                    .font(.system(size: recorder.isRecording ? 11.5 : 14))
                    .foregroundStyle(recorder.isRecording ? AnyShapeStyle(Color.accentColor)
                                                          : AnyShapeStyle(.primary))
                    .frame(minWidth: 104, minHeight: 28)
                    .padding(.horizontal, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(recorder.isRecording ? Color.accentColor.opacity(0.14)
                                                       : Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(recorder.isRecording ? Color.accentColor
                                                               : Color(nsColor: .separatorColor))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sneltoets opnemen")

            Button {
                recorder.stop()
                onClear()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Sneltoets wissen")
            .accessibilityLabel("Sneltoets wissen")
            .disabled(combo == nil)
            .opacity(combo == nil ? 0.4 : 1)
        }
        // The monitor must not outlive the window: a stale local monitor would keep
        // swallowing keystrokes after the field is gone.
        .onDisappear { recorder.stop() }
    }

    private var fieldText: String {
        guard recorder.isRecording else {
            return combo?.displayString ?? "Geen"
        }
        let held = HotKeyCombo.modifierString(for: recorder.heldModifiers)
        return held.isEmpty ? "Druk nu een toetscombinatie…" : held + "…"
    }
}
