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
    // Cold-start URL: Dart hasn't registered its handler yet, so queue it for
    // the getInitialFile pull rather than invoking openFile (which would drop).
    if let url = connectionOptions.urlContexts.first?.url {
      pendingFile = args(for: url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if let url = URLContexts.first?.url {
      let payload = args(for: url)
      if let channel = channel {
        channel.invokeMethod("openFile", arguments: payload)
      } else {
        pendingFile = payload
      }
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  private func args(for url: URL) -> [String: Any?] {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let content = try? String(contentsOf: url, encoding: .utf8)
    return ["content": content, "name": url.lastPathComponent]
  }
}
