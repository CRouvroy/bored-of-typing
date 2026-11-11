#!/usr/bin/env python3
"""Test the actual pointer monitor with inert offscreen AppKit events.
No real app window, camera, saved board, or global input is used.
"""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
SDK = subprocess.check_output([str(ROOT / "scripts/macos-sdk")], text=True).strip()
source = (ROOT / 'Sources/BoardApp/BoardPointerMonitor.swift').read_text()
source += r'''
private final class FixtureWindow: NSWindow {
    var fixtureIsKey = true
    override var isKeyWindow: Bool { fixtureIsKey }
}
extension BoardWorkspacePointerView {
    fileprivate func fixtureEvent(_ event: NSEvent) { observe(event) }
}
@main struct CheckDockInteractions {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = FixtureWindow(contentRect: CGRect(x: -10000, y: -10000, width: 320, height: 240),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        let view = BoardWorkspacePointerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var held = false
        view.configure(onPointer: { _ in }, onEditing: { _ in },
                       focusRegion: CGRect(x: 10, y: 10, width: 200, height: 200),
                       pointerRegion: CGRect(x: 10, y: 10, width: 200, height: 200),
                       onInteraction: { held = $0 })
        window.contentView = view
        func flush() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        func post(_ name: Notification.Name, _ menu: NSMenu) {
            NotificationCenter.default.post(name: name, object: menu)
            flush()
        }
        func mouse(_ type: NSEvent.EventType) {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: 100, y: 100),
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            view.fixtureEvent(event)
            flush()
        }
        flush()
        precondition(!held)
        let menu = NSMenu(title: "Fixture"), nested = NSMenu(title: "Nested"), unrelated = NSMenu(title: "Unrelated")
        post(NSMenu.didBeginTrackingNotification, menu)
        precondition(held, "Keyboard menu must hold the dock open")
        post(NSMenu.didBeginTrackingNotification, nested)
        post(NSMenu.didEndTrackingNotification, menu)
        precondition(held, "Nested menu must retain the hold")
        post(NSMenu.didEndTrackingNotification, unrelated)
        precondition(held, "Unrelated menu completion must not clear the hold")
        post(NSMenu.didEndTrackingNotification, nested)
        precondition(!held, "Last menu completion releases the hold")
        mouse(.leftMouseDown)
        precondition(held)
        post(NSMenu.didBeginTrackingNotification, menu)
        mouse(.leftMouseUp)
        precondition(held, "Mouse-up must not collapse an open native menu")
        post(NSMenu.didEndTrackingNotification, menu)
        precondition(!held)
        post(NSMenu.didBeginTrackingNotification, menu)
        window.fixtureIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        flush()
        precondition(!held)
        post(NSMenu.didEndTrackingNotification, menu)
        precondition(!held)
        view.invalidate()
        print("Dock interactions passed: keyboard menu, nested menus, mouse-up, focus loss")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='BoardDockInteractions-') as directory:
    work = Path(directory)
    swift, binary = work / 'Check.swift', work / 'check'
    swift.write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-target', 'arm64-apple-macosx26.0', '-parse-as-library', '-sdk',
                    SDK, str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
