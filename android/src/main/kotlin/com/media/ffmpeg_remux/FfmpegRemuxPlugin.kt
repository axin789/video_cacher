package com.media.ffmpeg_remux

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class FfmpegRemuxPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    private lateinit var appContext: Context

    // 后台任务控制
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var remuxJob: Job? = null
    private val isRunning = AtomicBoolean(false)

    // 用来在转码时轮询输出文件大小（不改 native 的情况下最小成本“进度”）
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pollRunnable: Runnable? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, "ffmpeg_remux/methods")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "ffmpeg_remux/progress")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        scope.cancel()
    }

    // EventChannel
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // MethodChannel
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "remux" -> {
                val input = call.argument<String>("input") ?: ""
                val output = call.argument<String>("output") ?: ""

                if (input.isBlank() || output.isBlank()) {
                    result.error("ARGS", "input/output is blank", null)
                    return
                }

                if (isRunning.get()) {
                    result.error("BUSY", "remux is running", null)
                    return
                }

                startRemux(input, output, result)
            }

            "cancel" -> {
                cancelRemux()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun startRemux(input: String, output: String, result: MethodChannel.Result) {
        isRunning.set(true)

        // 先发一个开始事件
        sendProgress(progressMap {
            put("state", "started")
            put("output", output)
            put("bytes", 0L)
        })

        // 开始轮询输出文件大小
        startPollingOutputSize(output)

        remuxJob = scope.launch {
            val ret = withContext(Dispatchers.IO) {
                try {
                    FFmpegNative.remux(input, output)
                } catch (e: Throwable) {
                    android.util.Log.e("ffmpeg_remux", "JNI/Remux crashed", e)  //打印堆栈
                    // 用一个更“明确”的错误码，方便你区分：这是 Kotlin/Java 层异常，不是 ffmpeg ret
                    -9999
                }
            }
//            val ret = withContext(Dispatchers.IO) {
//                try {
//                    FFmpegNative.remux(input, output)
//                } catch (e: Throwable) {
//                    -1
//                }
//            }

            stopPolling()

            isRunning.set(false)

            // 发结束事件
            val bytes = File(output).takeIf { it.exists() }?.length() ?: 0L
            sendProgress(progressMap {
                put("state", if (ret == 0) "done" else "error")
                put("output", output)
                put("ret", ret)
                put("bytes", bytes)
            })

            // Method 返回给 Flutter
            result.success(
                mapOf(
                    "ret" to ret,
                    "output" to output
                )
            )
        }
    }

    private fun progressMap(block: HashMap<String, Any?>.() -> Unit): HashMap<String, Any?> {
        return HashMap<String, Any?>().apply(block)
    }

    private fun cancelRemux() {
        stopPolling()
        remuxJob?.cancel()
        remuxJob = null
        isRunning.set(false)

        sendProgress(progressMap {
            put("state", "cancelled")
        })
    }

    private fun startPollingOutputSize(output: String) {
        stopPolling()

        val outFile = File(output)
        pollRunnable = object : Runnable {
            override fun run() {
                if (!isRunning.get()) return
                val bytes = if (outFile.exists()) outFile.length() else 0L
                sendProgress(progressMap {
                    put("state", "running")
                    put("output", output)
                    put("bytes", bytes)
                })

                mainHandler.postDelayed(this, 500)
            }
        }
        mainHandler.post(pollRunnable!!)
    }

    private fun stopPolling() {
        pollRunnable?.let { mainHandler.removeCallbacks(it) }
        pollRunnable = null
    }

    private fun sendProgress(payload: Map<String, Any?>) {
        // EventSink 必须在主线程调用
        mainHandler.post {
            eventSink?.success(payload)
        }
    }
}

/**
 * 这一层负责 loadLibrary + JNI 调用。
 */
internal object FFmpegNative {
    init {
        System.loadLibrary("avutil")
        System.loadLibrary("avcodec")
        System.loadLibrary("avformat")
        System.loadLibrary("ffmpeg-remux")
    }

    external fun remuxM3u8ToMp4(inputPath: String, outputPath: String): Int

    fun remux(input: String, output: String): Int {
        return remuxM3u8ToMp4(input, output)
    }
}