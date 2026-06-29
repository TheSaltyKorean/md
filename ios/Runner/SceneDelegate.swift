import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var channel: FlutterMethodChannel?
  private var pendingFiles: [[String: Any?]] = []
  private var dartReady = false

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
          self?.dartReady = true // Dart's handler is now registered.
          reply(self?.pendingFiles.isEmpty == false ? self?.pendingFiles : nil)
          self?.pendingFiles = []
        } else {
          reply(FlutterMethodNotImplemented)
        }
      }
    }
    // Cold-start URLs: Dart hasn't registered its handler yet, so queue them all
    // for the getInitialFile pull rather than invoking openFile (which drops).
    for context in connectionOptions.urlContexts {
      pendingFiles.append(args(for: context.url))
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      let payload = args(for: context.url)
      // Only push once Dart has registered its handler; otherwise queue it for
      // the getInitialFile pull so an open during startup isn't dropped.
      if dartReady, let channel = channel {
        channel.invokeMethod("openFile", arguments: payload)
      } else {
        pendingFiles.append(payload)
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
