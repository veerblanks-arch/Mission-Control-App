import AppKit

final class TouchBarHostWindowController: NSWindowController {
    init(contentController: MainTouchBarController) {
        let window = TouchBarHostPanel(contentViewController: contentController)
        window.title = "Droppy Touch Bar"
        window.styleMask = [.titled, .closable, .miniaturizable, .utilityWindow]
        window.setContentSize(NSSize(width: 360, height: 96))
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.hostedTouchBar = contentController.makeTouchBar()
        window.touchBar = window.hostedTouchBar
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class TouchBarHostPanel: NSPanel {
    var hostedTouchBar: NSTouchBar?

    override func makeTouchBar() -> NSTouchBar? {
        hostedTouchBar
    }
}
