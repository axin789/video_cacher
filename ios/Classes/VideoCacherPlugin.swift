import CommonCrypto
import Flutter
import Foundation

/// 只做一件事：把 HLS 分片的 AES-128-CBC 解密交给系统 CommonCrypto，吃到
/// ARMv8 的 AES 指令。本插件不捆绑任何二进制。
///
/// `kCCOptionPKCS7Padding` 与纯 Dart 兜底（pointycastle PKCS7Padding）语义
/// 一致，含尾块填充剔除。
public class VideoCacherPlugin: NSObject, FlutterPlugin {
  private static let channelName = "video_cacher/crypto"
  private static let methodDecrypt = "aesCbcDecrypt"

  /// 解密跑在后台队列，2-10MB 的分片不占用平台主线程。
  private static let queue = DispatchQueue(
    label: "video_cacher.crypto",
    qos: .userInitiated,
    attributes: .concurrent
  )

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(VideoCacherPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == VideoCacherPlugin.methodDecrypt else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
      let key = (args["key"] as? FlutterStandardTypedData)?.data,
      let iv = (args["iv"] as? FlutterStandardTypedData)?.data,
      let cipher = (args["data"] as? FlutterStandardTypedData)?.data
    else {
      result(FlutterError(code: "bad_args", message: "aesCbcDecrypt 需要 key/iv/data", details: nil))
      return
    }
    guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
      result(
        FlutterError(
          code: "bad_args",
          message: "key/iv 需 16 字节: \(key.count)/\(iv.count)",
          details: nil))
      return
    }

    VideoCacherPlugin.queue.async {
      do {
        let plain = try VideoCacherPlugin.decrypt(cipher, key: key, iv: iv)
        // FlutterResult 必须回到平台线程上调用。
        DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: plain)) }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "decrypt_failed", message: "\(error)", details: nil))
        }
      }
    }
  }

  private struct CryptoError: Error, CustomStringConvertible {
    let status: CCCryptorStatus
    var description: String { "CCCrypt status \(status)" }
  }

  private static func decrypt(_ cipher: Data, key: Data, iv: Data) throws -> Data {
    if cipher.isEmpty { return Data() }
    // 容量先取成局部量：闭包里再读 out.count 会与 out 的独占写访问重叠。
    let capacity = cipher.count + kCCBlockSizeAES128
    var out = Data(count: capacity)
    var moved = 0
    let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBuf in
      cipher.withUnsafeBytes { inBuf in
        key.withUnsafeBytes { keyBuf in
          iv.withUnsafeBytes { ivBuf in
            CCCrypt(
              CCOperation(kCCDecrypt),
              CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionPKCS7Padding),
              keyBuf.baseAddress, key.count,
              ivBuf.baseAddress,
              inBuf.baseAddress, cipher.count,
              outBuf.baseAddress, capacity,
              &moved
            )
          }
        }
      }
    }
    guard status == kCCSuccess else { throw CryptoError(status: status) }
    out.removeSubrange(moved..<capacity)
    return out
  }
}
