import AppKit
import Carbon.HIToolbox
import Foundation
import StashCore

/// Wraps Carbon's `RegisterEventHotKey` for whichever combination the user recorded.
///
/// Route verified on this machine on a bare CLT build with no entitlements:
/// `InstallEventHandler` and `RegisterEventHotKey` both return status 0.
/// `NSEvent.addGlobalMonitorForEvents` is deliberately not used — it requires
/// Accessibility permission, and the shortcut must work without it.
///
/// `@unchecked Sendable`: `deinit` calls `unregister()`, which touches Carbon's C API —
/// not actor-isolated work, and a `deinit` can never call a `@MainActor` method, so this
/// class cannot itself be `@MainActor` (the same trap `AppInventory` and `CollapseTimer`
/// hit elsewhere in this codebase). It's safe as `@unchecked Sendable` because every
/// stored property is a Carbon handle or a plain closure touched only from
/// `register()`/`unregister()`/`deinit`, all of which are, in practice, only ever called
/// from the main thread (app launch, a checkbox in the settings window, and app
/// teardown) — there is no concurrent mutation to guard against.
final class GlobalHotKey: @unchecked Sendable {

    /// 'STSH' packed into the `OSType` Carbon expects for `EventHotKeyID.signature`.
    fileprivate static let signature: OSType = {
        "STSH".utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()

    // `nonisolated(unsafe)`: only ever written from `register()`/`unregister()` and read
    // from the Carbon callback, both of which run on the main thread in practice — same
    // opt-out `StashTests/Harness.swift` uses for its own global mutable state.
    fileprivate nonisolated(unsafe) static var activeInstance: GlobalHotKey?

    private let onTrigger: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    deinit {
        unregister()
    }

    /// The `OSStatus` the last `RegisterEventHotKey` returned. Kept so a failure can be
    /// reported as a number rather than as "it didn't work" — `-9878`
    /// (`eventHotKeyExistsErr`) means another app already holds the combination.
    private(set) var lastRegisterStatus: OSStatus = noErr

    /// Registers `combo`. Returns `false` if the combination is already claimed by another
    /// app, or if installing the event handler otherwise fails — never a crash, never a
    /// silent no-op. The caller (`AppDelegate`) reports that back up to the settings
    /// model, which restores the previous combination, so the recorder field never shows
    /// a shortcut that was never actually registered.
    @discardableResult
    func register(_ combo: HotKeyCombo) -> Bool {
        unregister()
        Self.activeInstance = self

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard installStatus == noErr else {
            Self.activeInstance = nil
            return false
        }
        eventHandlerRef = handlerRef

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(combo.keyCode),
            Self.carbonModifiers(from: combo.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        lastRegisterStatus = registerStatus
        guard registerStatus == noErr, let ref else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
            eventHandlerRef = nil
            Self.activeInstance = nil
            return false
        }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }

    /// Cocoa modifier bits to Carbon's. The two sets are unrelated integers; there is no
    /// shared header, so this mapping is written out rather than cast. Lives with the
    /// Carbon call, not with the storage type `HotKeyCombo`.
    private static func carbonModifiers(from cocoa: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: cocoa)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Called from the C callback below, already on the main run loop in practice. Hops
    /// to the main queue explicitly anyway rather than leaning on that — the same
    /// `DispatchQueue.main.async` idiom `AppDelegate.rebuild()` uses to call back into
    /// `@MainActor` code from a plain, non-isolated callback closure.
    fileprivate func fire() {
        DispatchQueue.main.async { [onTrigger] in
            onTrigger()
        }
    }
}

/// The Carbon callback is a plain C function pointer — it cannot capture `self`, so it
/// reaches back into Swift through the file-private `GlobalHotKey.activeInstance`
/// singleton instead. This must be a top-level (or static, non-capturing) function: a
/// Swift closure that captures context cannot be used where Carbon expects an
/// `EventHandlerUPP`.
private func globalHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let instance = GlobalHotKey.activeInstance else {
        return OSStatus(eventNotHandledErr)
    }
    instance.fire()
    return noErr
}
