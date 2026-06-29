import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var channel: FlutterMethodChannel?
  private var pendingFile: [String: Any?]?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      channel = FlutterMethodChannel(
        name: "markdown_studio/open_file",
        binaryMessenger: controller.binaryMessenger)
      channel?.setMethodCallHandler { [weak self] call, reply in
        if call.method == "getInitialFile" {
          reply(self?.pendingFile as Any?)
          self?.pendingFile = nil
        } else {
          reply(FlutterMethodNotImplemented)
        }
      }
    }
    return result
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let content = try? String(contentsOf: url, encoding: .utf8)
    let args: [String: Any?] = ["content": content, "name": url.lastPathComponent]
    if let channel = channel {
      channel.invokeMethod("openFile", arguments: args)
    } else {
      pendingFile = args
    }
    return true
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
