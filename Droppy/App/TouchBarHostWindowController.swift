import AppKit

final class TouchBarHostWindowController: NSWindowController {
    init(contentController: NSViewController) {
        let window = NSPanel(contentViewController: contentController)
        window.title = "Droppy Touch Bar"
        window.styleMask = [.titled, .closable, .miniaturizable, .utilityWindow]
        window.setContentSize(NSSize(width: 360, height: 96))
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
