import Flutter
import UIKit

@_silgen_name("remux_m3u8_to_mp4")
func remux_m3u8_to_mp4(_ inPath: UnsafePointer<CChar>, _ outPath: UnsafePointer<CChar>) -> Int32

public class FfmpegRemuxPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

  // MARK: Channels
  private static var eventSink: FlutterEventSink?
  private let workQueue = DispatchQueue(label: "ffmpeg_remux.queue", qos: .userInitiated)

  // taskId -> running flag
  private var running: Set<String> = []

  // taskId -> fake progress timer
  private var timers: [String: DispatchSourceTimer] = [:]

  // taskId -> last progress
  private var lastProgress: [String: Double] = [:]

  // MARK: Register
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "ffmpeg_remux", binaryMessenger: registrar.messenger())
    let instance = FfmpegRemuxPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    let event = FlutterEventChannel(name: "ffmpeg_remux/progress", binaryMessenger: registrar.messenger())
    event.setStreamHandler(instance)
  }

  // MARK: EventChannel
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    FfmpegRemuxPlugin.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    FfmpegRemuxPlugin.eventSink = nil
    return nil
  }

  // MARK: MethodChannel
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startRemux":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "BAD_ARGS", message: "args missing", details: nil))
        return
      }

      let taskId = (args["taskId"] as? String) ?? ""
      let inM3u8 = (args["inM3u8"] as? String) ?? ""
      let outPath = (args["outPath"] as? String) ?? ""

      if taskId.isEmpty || inM3u8.isEmpty || outPath.isEmpty {
        result(FlutterError(code: "BAD_ARGS", message: "taskId/inM3u8/outPath required", details: nil))
        return
      }

      // 已在跑就直接返回（避免重复启动）
      if running.contains(taskId) {
        result(0) // 0=accepted (already running)
        return
      }

      startRemux(taskId: taskId, inM3u8: inM3u8, outPath: outPath)
      result(0) // 0=accepted

    case "cancelRemux":
      guard let args = call.arguments as? [String: Any] else { result(nil); return }
      let taskId = (args["taskId"] as? String) ?? ""
      cancel(taskId: taskId)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Core
  private func startRemux(taskId: String, inM3u8: String, outPath: String) {
    running.insert(taskId)
    lastProgress[taskId] = 0.0

    // 发一个开始事件
    sendEvent(taskId: taskId, state: "running", progress: 0.0, ret: nil, outPath: outPath, message: nil)

    // 启动伪进度（涨到 0.9 为止）
    startFakeProgress(taskId: taskId, outPath: outPath)

    // 后台线程跑 C remux（不会堵 UI）
    workQueue.async { [weak self] in
      guard let self = self else { return }

      // 确保输出目录存在
      let outURL = URL(fileURLWithPath: outPath)
      let dirURL = outURL.deletingLastPathComponent()
      do {
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)
      } catch {
        DispatchQueue.main.async {
          self.finish(taskId: taskId, ret: -2, outPath: outPath, message: "createDirectory failed: \(error)")
        }
        return
      }

      // 已存在就删掉，避免 FFmpeg 写失败
      if FileManager.default.fileExists(atPath: outPath) {
        try? FileManager.default.removeItem(atPath: outPath)
      }

      // 调 C 函数
      let ret: Int32 = inM3u8.withCString { inC in
        outPath.withCString { outC in
          return remux_m3u8_to_mp4(inC, outC)
        }
      }

      DispatchQueue.main.async {
        self.finish(taskId: taskId, ret: Int(ret), outPath: outPath, message: nil)
      }
    }
  }

  private func finish(taskId: String, ret: Int, outPath: String, message: String?) {
    stopFakeProgress(taskId: taskId)

    running.remove(taskId)

    if ret == 0 {
      // 成功：进度置 1
      sendEvent(taskId: taskId, state: "completed", progress: 1.0, ret: 0, outPath: outPath, message: message)
    } else {
      // 失败：保留最后进度（通常 <=0.9）
      let p = lastProgress[taskId] ?? 0.0
      sendEvent(taskId: taskId, state: "failed", progress: p, ret: ret, outPath: outPath, message: message)
    }

    lastProgress.removeValue(forKey: taskId)
  }

  private func cancel(taskId: String) {
    // 说明：C remux 是阻塞执行，无法真正中断（除非你改 C 层加 interrupt_callback）
    // 这里做“软取消”：停伪进度 + 让 UI 认为取消
    stopFakeProgress(taskId: taskId)
    running.remove(taskId)

    sendEvent(taskId: taskId, state: "canceled", progress: lastProgress[taskId] ?? 0.0, ret: -9998, outPath: nil, message: "soft cancel")
    lastProgress.removeValue(forKey: taskId)
  }

  // MARK: Fake Progress
  private func startFakeProgress(taskId: String, outPath: String) {
    stopFakeProgress(taskId: taskId)

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(deadline: .now() + 0.2, repeating: 0.2)

    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      guard self.running.contains(taskId) else { return }

      let cur = self.lastProgress[taskId] ?? 0.0
      if cur >= 0.9 { return } // 最多到 0.9，等待真实完成再 1.0

      let next = min(0.9, cur + 0.02)
      self.lastProgress[taskId] = next
      self.sendEvent(taskId: taskId, state: "running", progress: next, ret: nil, outPath: outPath, message: nil)
    }

    timers[taskId] = timer
    timer.resume()
  }

  private func stopFakeProgress(taskId: String) {
    if let t = timers[taskId] {
      t.setEventHandler {}
      t.cancel()
    }
    timers.removeValue(forKey: taskId)
  }

  // MARK: Event emit
  private func sendEvent(taskId: String,
                         state: String,
                         progress: Double,
                         ret: Int?,
                         outPath: String?,
                         message: String?) {
    guard let sink = FfmpegRemuxPlugin.eventSink else { return }

    var map: [String: Any] = [
      "taskId": taskId,
      "state": state,                 // running / completed / failed / canceled
      "progress": progress            // 0~1
    ]
    if let r = ret { map["ret"] = r } else { map["ret"] = NSNull() }
    if let o = outPath { map["outPath"] = o } else { map["outPath"] = NSNull() }
    if let m = message { map["message"] = m } else { map["message"] = NSNull() }

    sink(map)
  }
}