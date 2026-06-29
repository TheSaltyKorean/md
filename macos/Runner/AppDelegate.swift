import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var channel: FlutterMethodChannel?
  private var pendingPaths: [String] = []
  private var dartReady = false

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
          self?.dartReady = true // Dart's handler is now registered.
          let files = self?.pendingPaths.map { ["path": $0] } ?? []
          result(files.isEmpty ? nil : files)
          self?.pendingPaths = []
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    // Only push once Dart has registered its handler; otherwise queue every path
    // for the getInitialFile pull so launch-time multi-selects aren't dropped.
    if dartReady, let channel = channel {
      channel.invokeMethod("openFile", arguments: ["path": filename])
    } else {
      pendingPaths.append(filename)
    }
    return true
  }
}
