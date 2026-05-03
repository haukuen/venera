import Flutter
import UIKit
import UniformTypeIdentifiers
import Foundation

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  var flutterResult: FlutterResult?
  var directoryPath: URL!

  private var directoryPicker: DirectoryPicker?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
          fatalError("rootViewController is not of type FlutterViewController")
    }

    let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: controller.binaryMessenger)
    methodChannel.setMethodCallHandler(self.handleMethodCall)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "getProxy" {
      if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary?,
        let dict = proxySettings.object(forKey: kCFNetworkProxiesHTTPProxy) as? NSDictionary,
        let host = dict.object(forKey: kCFNetworkProxiesHTTPProxy) as? String,
        let port = dict.object(forKey: kCFNetworkProxiesHTTPPort) as? Int {
        let proxyConfig = "\(host):\(port)"
        result(proxyConfig)
      } else {
        result("")
      }
    } else if call.method == "setScreenOn" {
      if let arguments = call.arguments as? Bool {
        let screenOn = arguments
        UIApplication.shared.isIdleTimerDisabled = screenOn
      }
      result(nil as Any?)
    } else if call.method == "getDirectoryPath" {
      self.flutterResult = result
      self.getDirectoryPath()
    } else if call.method == "stopAccessingSecurityScopedResource" {
      self.directoryPath?.stopAccessingSecurityScopedResource()
      self.directoryPath = nil
      result(nil as Any?)
    } else if call.method == "selectDirectory" {
      self.directoryPicker = DirectoryPicker()
      self.directoryPicker?.selectDirectory(result: result)
    } else if call.method == "getVeneraClipboardLink" {
      if #available(iOS 16.0, *) {
        UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { (pasteboardResult: Result<Set<UIPasteboard.DetectionPattern>, Error>) in
          switch pasteboardResult {
          case .success(let patterns):
            if !patterns.isEmpty {
              let text = UIPasteboard.general.string ?? ""
              if text.contains("venera://") {
                result(text)
              } else {
                result(nil as Any?)
              }
            } else {
              result(nil as Any?)
            }
          case .failure:
            result(nil as Any?)
          }
        }
      } else {
        let text = UIPasteboard.general.string ?? ""
        if text.contains("venera://") {
          result(text)
        } else {
          result(nil as Any?)
        }
      }
    } else {
      result(FlutterMethodNotImplemented)
    }
  }

  func getDirectoryPath() {
    let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    documentPicker.delegate = self
    documentPicker.allowsMultipleSelection = false
    documentPicker.directoryURL = nil
    documentPicker.modalPresentationStyle = .formSheet

    if let rootViewController = window?.rootViewController {
      rootViewController.present(documentPicker, animated: true, completion: nil)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    self.directoryPath = urls.first
    if self.directoryPath == nil {
      flutterResult?(nil as Any?)
      return
    }

    let success = self.directoryPath.startAccessingSecurityScopedResource()

    if success {
      flutterResult?(self.directoryPath.path)
    } else {
      flutterResult?(nil as Any?)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    flutterResult?(nil as Any?)
  }
}
