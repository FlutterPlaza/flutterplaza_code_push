package com.flutterplaza.flutterplaza_code_push

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.util.zip.ZipFile

/** SHA-256 of the packaged native library for the running ABI. */
class FlutterplazaCodePushPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var context: Context

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "flutterplaza_code_push")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "getAppLibHash" -> {
        // Hash off the platform thread; deliver the result back on it.
        val handler = Handler(Looper.getMainLooper())
        Thread {
          val hash = runCatching { computeAppLibHash() }.getOrNull()
          handler.post { result.success(hash) }
        }.start()
      }
      else -> result.notImplemented()
    }
  }

  /**
   * Streams SHA-256 over lib/<abi>/libapp.so as packaged in the installed
   * APK (or the matching split), returning lowercase hex, or null if it
   * can't be located. Reads the archived bytes directly so the digest is
   * stable regardless of whether native libs are extracted on install.
   */
  private fun computeAppLibHash(): String? {
    val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: return null
    val entryName = "lib/$abi/libapp.so"
    val info = context.applicationInfo
    val apks = buildList {
      info.sourceDir?.let { add(it) }
      info.splitSourceDirs?.let { addAll(it) }
    }
    for (apk in apks) {
      ZipFile(apk).use { zip ->
        val entry = zip.getEntry(entryName) ?: return@use
        val digest = MessageDigest.getInstance("SHA-256")
        zip.getInputStream(entry).use { input ->
          val buf = ByteArray(64 * 1024)
          while (true) {
            val n = input.read(buf)
            if (n < 0) break
            digest.update(buf, 0, n)
          }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
      }
    }
    return null
  }
}
