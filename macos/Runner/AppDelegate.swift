import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var channel: FlutterMethodChannel?
  private var pendingPath: String?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      channel = FlutterMethodChannel(
        name: "markdown_studio/open_file",
        binaryMessenger: controller.engine.binaryMessenger)
      channel?.setMethodCallHandler { [weak self] call, result in
        if call.method == "getInitialFile" {
          if let path = self?.pendingPath {
            result(["path": path])
            self?.pendingPath = nil
          } else {
            result(nil)
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    if let channel = channel {
      channel.invokeMethod("openFile", arguments: ["path": filename])
    } else {
      pendingPath = filename
    }
    return true
  }
}
