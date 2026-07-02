import AppKit

private var retainedAppDelegate: AppDelegate?

@main
enum TouchBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedAppDelegate = delegate

        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
