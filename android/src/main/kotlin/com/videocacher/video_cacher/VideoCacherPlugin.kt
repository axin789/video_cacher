package com.videocacher.video_cacher

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 只做一件事：把 HLS 分片的 AES-128-CBC 解密交给系统加密库（Conscrypt →
 * BoringSSL），吃到 ARMv8 的 AES 指令。本插件不捆绑任何二进制。
 *
 * `AES/CBC/PKCS5Padding`：JCE 的 PKCS5 对 16 字节分组即 PKCS7，与纯 Dart
 * 兜底（pointycastle PKCS7Padding）语义完全一致，含尾块填充剔除。
 */
class VideoCacherPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null

    /** 解密跑在后台线程，2-10MB 的分片不占用平台主线程。 */
    private var worker: ExecutorService? = null
    private val platformThread = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        worker = Executors.newFixedThreadPool(2)
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        worker?.shutdown()
        worker = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != METHOD_DECRYPT) {
            result.notImplemented()
            return
        }
        val key = call.argument<ByteArray>("key")
        val iv = call.argument<ByteArray>("iv")
        val data = call.argument<ByteArray>("data")
        if (key == null || iv == null || data == null) {
            result.error("bad_args", "aesCbcDecrypt 需要 key/iv/data", null)
            return
        }
        if (key.size != 16 || iv.size != 16) {
            result.error("bad_args", "key/iv 需 16 字节: ${key.size}/${iv.size}", null)
            return
        }
        val executor = worker
        if (executor == null) {
            result.error("detached", "插件已从引擎分离", null)
            return
        }
        executor.execute {
            try {
                val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    SecretKeySpec(key, "AES"),
                    IvParameterSpec(iv),
                )
                val plain = cipher.doFinal(data)
                // MethodChannel.Result 必须回到平台线程上调用。
                platformThread.post { result.success(plain) }
            } catch (e: Throwable) {
                platformThread.post {
                    result.error("decrypt_failed", e.message ?: e.toString(), null)
                }
            }
        }
    }

    private companion object {
        const val CHANNEL = "video_cacher/crypto"
        const val METHOD_DECRYPT = "aesCbcDecrypt"
    }
}
