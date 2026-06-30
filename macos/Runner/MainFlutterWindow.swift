import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Portrait by default — these are documents, which read taller than wide —
    // but never taller/wider than the visible screen area. The window's title
    // bar is added on top of the content size, so account for that chrome
    // (frameRect(forContentRect:)) before clamping, or the full frame can still
    // overflow the visible area on shorter laptop displays.
    var content = NSSize(width: 900, height: 1180)
    if let visible = (self.screen ?? NSScreen.main)?.visibleFrame {
      let frame = self.frameRect(
        forContentRect: NSRect(origin: .zero, size: content))
      let chromeW = frame.width - content.width
      let chromeH = frame.height - content.height
      content = NSSize(
        width: max(200, min(content.width, visible.width - chromeW - 20)),
        height: max(200, min(content.height, visible.height - chromeH - 20)))
    }
    self.setContentSize(content)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
