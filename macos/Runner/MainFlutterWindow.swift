import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    disableVmServiceForHeadlessMode()
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  private func disableVmServiceForHeadlessMode() {
    guard CommandLine.arguments.dropFirst().contains("--headless") else {
      return
    }
    let environment = ProcessInfo.processInfo.environment
    let currentCount = Int(environment["FLUTTER_ENGINE_SWITCHES"] ?? "0") ?? 0
    let nextIndex = currentCount + 1
    setenv("FLUTTER_ENGINE_SWITCHES", String(nextIndex), 1)
    setenv(
      "FLUTTER_ENGINE_SWITCH_\(nextIndex)",
      "disable-vm-service=true",
      1
    )
  }
}
