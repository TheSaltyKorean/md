import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var channel: FlutterMethodChannel?
  private var pendingFile: [String: Any?]?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
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
    if let url = connectionOptions.urlContexts.first?.url {
      handle(url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if let url = URLContexts.first?.url {
      handle(url)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  private func handle(_ url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let content = try? String(contentsOf: url, encoding: .utf8)
    let args: [String: Any?] = ["content": content, "name": url.lastPathComponent]
    if let channel = channel {
      channel.invokeMethod("openFile", arguments: args)
    } else {
      pendingFile = args
    }
  }
}
