import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "LocalFlow AX Test"
let field = NSTextField(frame: NSRect(x: 30, y: 95, width: 320, height: 30))
field.placeholderString = "Safe test field"
field.setAccessibilityLabel("Safe test field")
let other = NSTextField(frame: NSRect(x: 30, y: 40, width: 320, height: 30))
other.placeholderString = "Other field"
window.contentView?.addSubview(field)
window.contentView?.addSubview(other)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(other)
app.activate(ignoringOtherApps: true)
app.run()
