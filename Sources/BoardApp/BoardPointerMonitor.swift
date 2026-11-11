// Pointer observation adapted from Desk; see LICENSE.
import SwiftUI
import AppKit

/// Observes only this window. It never becomes a responder or consumes an event.
/// Coordinates use a top-left origin in the monitor's local bounds.
struct BoardWorkspacePointerMonitor: NSViewRepresentable {
    var onPointer: (CGPoint?) -> Void
    var onEditing: (Bool) -> Void
    var focusRegion: CGRect
    var pointerRegion: CGRect
    var onInteraction: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        let view = BoardWorkspacePointerView(frame: .zero)
        view.configure(onPointer: onPointer, onEditing: onEditing, focusRegion: focusRegion,
                       pointerRegion: pointerRegion, onInteraction: onInteraction)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? BoardWorkspacePointerView)?.configure(onPointer: onPointer, onEditing: onEditing,
                                                    focusRegion: focusRegion, pointerRegion: pointerRegion,
                                                    onInteraction: onInteraction)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? BoardWorkspacePointerView)?.invalidate()
    }
}

private final class BoardWorkspacePointerView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var onPointer: (CGPoint?) -> Void = { _ in }
    private var onEditing: (Bool) -> Void = { _ in }
    private var onInteraction: (Bool) -> Void = { _ in }
    private var focusRegion = CGRect.zero
    private var pointerRegion = CGRect.zero
    private weak var monitoredWindow: NSWindow?
    private weak var editingControl: NSControl?
    private var holdsMouseMovement = false
    private var eventMonitor: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var pointerTrackingArea: NSTrackingArea?
    private var capturedButtons = Set<Int>()
    private var trackingMenus = Set<ObjectIdentifier>()
    private var invalidated = false

    private var pointer: CGPoint?
    private var editing = false
    private var interacting = false
    private var deliveredPointer: CGPoint?
    private var deliveredEditing = false
    private var deliveredInteraction = false
    private var deliveredInitialState = false
    private var deliveryPending = false
    private var samplePending = false
    private var samplePointerRequested = false
    private var pointerDeliveryRequested = false
    private var forceFocusSample = false
    private var lastFocusSignature: FocusSignature?
    private var trackedBounds: CGRect?
    private var trackedVisibleRect: CGRect?

    private struct FocusSignature: Equatable {
        var responder: ObjectIdentifier?
        var fieldDelegate: ObjectIdentifier?
        var control: ObjectIdentifier?
        var region: CGRect
        var editable: Bool
        var enabled: Bool
        var available: Bool
    }

    func configure(onPointer: @escaping (CGPoint?) -> Void, onEditing: @escaping (Bool) -> Void,
                   focusRegion: CGRect, pointerRegion: CGRect, onInteraction: @escaping (Bool) -> Void) {
        self.onPointer = onPointer
        self.onEditing = onEditing
        self.onInteraction = onInteraction
        if self.pointerRegion != pointerRegion {
            self.pointerRegion = pointerRegion
            scheduleSample(includePointer: true)
        }
        if self.focusRegion != focusRegion {
            self.focusRegion = focusRegion
            scheduleSample(includePointer: false, forceFocus: true)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard monitoredWindow !== window else { return }
        removeObservers()
        monitoredWindow = window
        guard let window else {
            pointer = nil; editing = false; interacting = false
            scheduleDelivery()
            return
        }
        BoardWindowMouseMovement.acquire(window)
        holdsMouseMovement = true
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                         .mouseEntered, .mouseExited, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                         .leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observe(event)
            return event
        }
        observeNotification(NSWindow.didResignKeyNotification, object: window) { view, _ in view.windowLostFocus() }
        observeNotification(NSWindow.willCloseNotification, object: window) { view, _ in view.windowLostFocus() }
        observeNotification(NSWindow.didBecomeKeyNotification, object: window) { view, _ in view.scheduleSample(includePointer: true, forceFocus: true) }
        // This also notices first-responder changes made by Tab or programmatic focus,
        // before the field has emitted its first text-editing notification.
        observeNotification(NSWindow.didUpdateNotification, object: window) { view, _ in
            if view.focusSignature() != view.lastFocusSignature { view.scheduleSample(includePointer: false) }
        }
        for name in [NSControl.textDidBeginEditingNotification, NSText.didBeginEditingNotification] {
            observeNotification(name) { view, notification in
                guard let controlView = notification.object as? NSView, controlView.window === view.monitoredWindow else { return }
                if let control = controlView as? NSControl { view.editingControl = control }
                view.scheduleSample(includePointer: false, forceFocus: true)
            }
        }
        for name in [NSControl.textDidEndEditingNotification, NSText.didEndEditingNotification] {
            observeNotification(name) { view, notification in
                guard let controlView = notification.object as? NSView, controlView.window === view.monitoredWindow else { return }
                if controlView === view.editingControl { view.editingControl = nil }
                view.scheduleSample(includePointer: false, forceFocus: true)
            }
        }
        observeNotification(NSMenu.didBeginTrackingNotification) { view, notification in
            guard !view.focusRegion.isEmpty, view.monitoredWindow?.isKeyWindow == true,
                  let menu = notification.object as? NSMenu else { return }
            view.trackingMenus.insert(ObjectIdentifier(menu))
            view.interacting = true
            view.scheduleDelivery()
        }
        observeNotification(NSMenu.didEndTrackingNotification) { view, notification in
            guard let menu = notification.object as? NSMenu,
                  view.trackingMenus.remove(ObjectIdentifier(menu)) != nil else { return }
            // Menu tracking may consume the opening button's mouse-up. Retire
            // that capture only when every nested menu has finished tracking.
            if view.trackingMenus.isEmpty, NSEvent.pressedMouseButtons == 0 { view.capturedButtons.removeAll() }
            view.interacting = !view.capturedButtons.isEmpty || !view.trackingMenus.isEmpty
            view.scheduleDelivery()
            view.scheduleSample(includePointer: true)
        }
        scheduleSample(includePointer: true, forceFocus: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !invalidated else { return }
        if pointerTrackingArea == nil {
            let area = NSTrackingArea(rect: .zero,
                                     options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
                                     owner: self, userInfo: nil)
            pointerTrackingArea = area
            addTrackingArea(area)
        }
        // AppKit maintains an inVisibleRect area's extent; retain it across layouts.
        let visible = visibleRect
        if trackedBounds != bounds || trackedVisibleRect != visible {
            trackedBounds = bounds
            trackedVisibleRect = visible
            scheduleSample(includePointer: true, forceFocus: true)
        }
    }

    override func mouseEntered(with event: NSEvent) { observe(event) }
    override func mouseMoved(with event: NSEvent) { observe(event) }
    override func mouseExited(with event: NSEvent) { pointer = nil; scheduleDelivery() }

    private func observe(_ event: NSEvent) {
        guard !invalidated else { return }
        let mouseUp = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
        // A release can be delivered to another window after a drag started here.
        // It only ends an interaction already captured in this window.
        if mouseUp, capturedButtons.remove(event.buttonNumber) != nil {
            interacting = !capturedButtons.isEmpty || !trackingMenus.isEmpty
            scheduleDelivery()
        }
        guard let window = monitoredWindow, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mouseDown = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        if mouseDown || mouseUp { pointerDeliveryRequested = true }
        if mouseDown {
            if interacting || (bounds.contains(point) && focusRegion.contains(point)) {
                capturedButtons.insert(event.buttonNumber)
                interacting = true
                scheduleDelivery()
            }
            scheduleSample(includePointer: false, forceFocus: true)
        } else if event.type == .keyDown {
            if event.keyCode == 53 { endInteraction() }
            scheduleSample(includePointer: false, forceFocus: true)
            return
        }
        guard window.isKeyWindow else { updatePointer(nil); return }
        if event.type == .mouseExited, event.trackingArea === pointerTrackingArea {
            updatePointer(nil)
        } else {
            updatePointer(bounds.contains(point) && pointerRegion.contains(point) ? point : nil)
        }
    }

    private func updatePointer(_ point: CGPoint?) {
        // Most movement belongs to the workspace. Once outside this dock's
        // local neighbourhood it produces no main-queue deliveries at all.
        guard pointer != point || pointerDeliveryRequested || !deliveredInitialState else { return }
        pointer = point
        scheduleDelivery()
    }

    private func scheduleSample(includePointer: Bool, forceFocus: Bool = false) {
        samplePointerRequested = samplePointerRequested || includePointer
        forceFocusSample = forceFocusSample || forceFocus
        guard !invalidated, !samplePending else { return }
        samplePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.invalidated else { return }
            self.samplePending = false
            let samplePointer = self.samplePointerRequested
            self.samplePointerRequested = false
            let sampleFocus = self.forceFocusSample
            self.forceFocusSample = false
            guard let window = self.monitoredWindow, window.isKeyWindow else { self.windowLostFocus(); return }
            if samplePointer {
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                self.pointer = self.bounds.contains(point) && self.pointerRegion.contains(point) ? point : nil
            }
            let signature = self.focusSignature()
            if sampleFocus || signature != self.lastFocusSignature {
                self.lastFocusSignature = signature
                self.editing = self.isEditingInsideRegion(window: window)
            }
            self.scheduleDelivery()
        }
    }

    private func focusSignature() -> FocusSignature? {
        guard !focusRegion.isEmpty, let window = monitoredWindow, window.isKeyWindow else { return nil }
        let responder = window.firstResponder
        let textView = responder as? NSTextView
        let delegate = textView?.isFieldEditor == true ? textView?.delegate : nil
        let control = (delegate as? NSControl) ?? (textView?.isFieldEditor == true ? editingControl : responder as? NSControl)
        let editable = textView?.isEditable ?? (responder as? NSTextField)?.isEditable ?? false
        let target = (delegate as? NSView) ?? control ?? (responder as? NSView)
        let available = target.map { $0.window === window && !$0.isHiddenOrHasHiddenAncestor } ?? false
        return FocusSignature(responder: responder.map(ObjectIdentifier.init),
                              fieldDelegate: delegate.map { ObjectIdentifier($0 as AnyObject) },
                              control: control.map(ObjectIdentifier.init), region: focusRegion,
                              editable: editable, enabled: control?.isEnabled ?? true, available: available)
    }

    private func isEditingInsideRegion(window: NSWindow) -> Bool {
        guard !focusRegion.isEmpty, !focusRegion.isNull else { return false }
        let target: NSView
        if let textView = window.firstResponder as? NSTextView, textView.isEditable {
            if textView.isFieldEditor, let delegate = textView.delegate as? NSView, delegate.window === window {
                target = delegate
            } else if textView.isFieldEditor, let control = editingControl, control.currentEditor() === textView {
                target = control
            } else { target = textView }
        } else if let field = window.firstResponder as? NSTextField, field.isEditable, field.isEnabled {
            target = field
        } else { return false }
        guard target.window === window, !target.isHiddenOrHasHiddenAncestor else { return false }
        if let control = target as? NSControl, !control.isEnabled { return false }
        let visibleBounds = target.visibleRect
        guard !visibleBounds.isEmpty else { return false }
        let localBounds = convert(visibleBounds, from: target)
        // Full containment avoids treating a wide editor behind an overlay as a
        // drawer editor merely because its bounds intersect the drawer.
        return focusRegion.insetBy(dx: -0.5, dy: -0.5).contains(localBounds)
    }

    private func endInteraction() {
        capturedButtons.removeAll()
        interacting = !trackingMenus.isEmpty
        scheduleDelivery()
    }

    private func windowLostFocus() {
        pointer = nil
        editing = false
        editingControl = nil
        lastFocusSignature = nil
        trackingMenus.removeAll()
        endInteraction()
    }

    private func scheduleDelivery() {
        guard !invalidated, !deliveryPending else { return }
        deliveryPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.invalidated else { return }
            self.deliveryPending = false
            let initial = !self.deliveredInitialState
            self.deliveredInitialState = true
            if initial || self.deliveredInteraction != self.interacting {
                self.deliveredInteraction = self.interacting
                self.onInteraction(self.interacting)
            }
            if initial || self.deliveredEditing != self.editing {
                self.deliveredEditing = self.editing
                self.onEditing(self.editing)
            }
            if initial || self.pointerDeliveryRequested || self.deliveredPointer != self.pointer {
                self.pointerDeliveryRequested = false
                self.deliveredPointer = self.pointer
                self.onPointer(self.pointer)
            }
        }
    }

    private func observeNotification(_ name: Notification.Name, object: Any? = nil,
                                     action: @escaping (BoardWorkspacePointerView, Notification) -> Void) {
        notificationObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] notification in
            guard let self, !self.invalidated else { return }
            action(self, notification)
        })
    }

    private func removeObservers() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        notificationObservers.removeAll()
        if holdsMouseMovement, let monitoredWindow { BoardWindowMouseMovement.release(monitoredWindow) }
        holdsMouseMovement = false
        editingControl = nil
        lastFocusSignature = nil
        pointer = nil
        editing = false
        capturedButtons.removeAll()
        trackingMenus.removeAll()
        interacting = false
    }

    func invalidate() {
        invalidated = true
        removeObservers()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea); self.pointerTrackingArea = nil }
        monitoredWindow = nil
    }

    deinit { removeObservers() }
}

/// Multiple proximity surfaces share one window setting. The first observer
/// remembers it, and only the last observer restores it, regardless of exit order.
private enum BoardWindowMouseMovement {
    private final class Request: NSObject {
        let originalSetting: Bool
        var observers = 1
        init(originalSetting: Bool) { self.originalSetting = originalSetting }
    }

    // Weak keys do not keep closed windows alive. All callers are NSView lifecycle
    // methods on the main thread; this registry does not observe or publish state.
    private static let requests = NSMapTable<NSWindow, Request>.weakToStrongObjects()

    static func acquire(_ window: NSWindow) {
        if let request = requests.object(forKey: window) {
            request.observers += 1
        } else {
            requests.setObject(Request(originalSetting: window.acceptsMouseMovedEvents), forKey: window)
        }
        window.acceptsMouseMovedEvents = true
    }

    static func release(_ window: NSWindow) {
        guard let request = requests.object(forKey: window) else { return }
        request.observers -= 1
        guard request.observers == 0 else { return }
        requests.removeObject(forKey: window)
        window.acceptsMouseMovedEvents = request.originalSetting
    }
}
