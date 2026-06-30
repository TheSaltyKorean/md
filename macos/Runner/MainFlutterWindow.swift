import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Portrait by default — these are documents, which read taller than wide —
    // but never taller/wider than the visible screen area, so the bottom of the
    // window can't start off-screen on shorter laptop displays.
    var width: CGFloat = 900
    var height: CGFloat = 1180
    if let visible = (self.screen ?? NSScreen.main)?.visibleFrame {
      width = min(width, visible.width - 20)
      height = min(height, visible.height - 20)
    }
    self.setContentSize(NSSize(width: width, height: height))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
