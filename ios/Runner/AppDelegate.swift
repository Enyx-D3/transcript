import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let audioConverter = AudioConverter()
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Setup audio converter method channel
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(
      name: "com.enyxd.transcript/audio_converter",
      binaryMessenger: controller.binaryMessenger
    )
    
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "convertToWav16kMono" else {
        result(FlutterMethodNotImplemented)
        return
      }
      
      guard let args = call.arguments as? [String: Any],
            let inputPath = args["inputPath"] as? String,
            let outputPath = args["outputPath"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "inputPath and outputPath required", details: nil))
        return
      }
      
      self?.audioConverter.convertToWav16kMono(inputPath: inputPath, outputPath: outputPath) { convertResult in
        DispatchQueue.main.async {
          switch convertResult {
          case .success(let path):
            result(path)
          case .failure(let error):
            result(FlutterError(code: "CONVERSION_FAILED", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

