package com.flutterplaza.flutterplaza_code_push

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.util.zip.ZipFile

/** SHA-256 of the packaged native library for the running ABI. */
class FlutterplazaCodePushPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var context: Context

  /** False after detach; late async replies are dropped instead of hitting
   * a torn-down messenger (hot-restart / engine-destroy race). */
  @Volatile private var attached = false

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "flutterplaza_code_push")
    channel.setMethodCallHandler(this)
    attached = true
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    attached = false
    channel.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "getAppLibHash" -> {
        // Hash off the platform thread; deliver the result back on it.
        val handler = Handler(Looper.getMainLooper())
        Thread {
          val hash = runCatching { computeAppLibHash() }.getOrNull()
          handler.post {
            if (!attached) return@post
            try {
              result.success(hash)
            } catch (_: Exception) {
              // Messenger torn down between the check and the reply; the
              // Dart side times out and falls back on its own.
            }
          }
        }.start()
      }
      else -> result.notImplemented()
    }
  }

  /**
   * SHA-256 (lowercase hex) of lib/<abi>/libapp.so as packaged in the
   * installed APK or its splits, or null if it can't be located. Reads the
   * archived bytes directly so the digest is stable regardless of whether
   * native libs are extracted on install.
   *
   * ABIs are tried in [Build.SUPPORTED_ABIS] order — the same preference
   * order the system uses when it picks which packaged ABI to run — so the
   * entry hashed is the one the process actually loaded (e.g. a 32-bit-only
   * APK on a 64-bit device hashes the armeabi-v7a entry, not a nonexistent
   * arm64 one). Each archive is tried independently: one unreadable APK
   * doesn't abort the scan of the rest.
   *
   * Work is bounded: the read loop stops early once the plugin detaches
   * or [HASH_BUDGET_MS] elapses (the Dart caller has given up by then),
   * so an abandoned request can't keep streaming a large APK on slow
   * storage indefinitely.
   */
  private fun computeAppLibHash(): String? {
    val deadline = SystemClock.elapsedRealtime() + HASH_BUDGET_MS
    val info = context.applicationInfo
    val apks = buildList {
      info.sourceDir?.let { add(it) }
      info.splitSourceDirs?.let { addAll(it) }
    }
    for (abi in Build.SUPPORTED_ABIS) {
      val entryName = "lib/$abi/libapp.so"
      for (apk in apks) {
        val hash = runCatching { hashZipEntry(apk, entryName, deadline) }.getOrNull()
        if (hash != null) return hash
      }
    }
    return null
  }

  /** Streams SHA-256 over [entryName] inside [apkPath]; null if absent,
   * or if the plugin detaches / [deadline] passes mid-read. */
  private fun hashZipEntry(apkPath: String, entryName: String, deadline: Long): String? {
    ZipFile(apkPath).use { zip ->
      val entry = zip.getEntry(entryName) ?: return null
      val digest = MessageDigest.getInstance("SHA-256")
      zip.getInputStream(entry).use { input ->
        val buf = ByteArray(64 * 1024)
        while (true) {
          if (!attached || SystemClock.elapsedRealtime() > deadline) return null
          val n = input.read(buf)
          if (n < 0) break
          digest.update(buf, 0, n)
        }
      }
      return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }
  }

  private companion object {
    /** Slightly past the Dart caller's 10 s timeout: once this elapses
     * the reply can no longer be used, so the stream is abandoned. */
    const val HASH_BUDGET_MS = 12_000L
  }
}
