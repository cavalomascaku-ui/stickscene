package com.stickscene.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var videoPlugin: VideoExportPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val plugin = VideoExportPlugin()
        videoPlugin = plugin
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VideoExportPlugin.CHANNEL
        ).setMethodCallHandler(plugin)
    }

    override fun onDestroy() {
        // A cancelled export must not leave a half-written MP4 behind.
        videoPlugin?.onMethodCall(
            io.flutter.plugin.common.MethodCall("cancelExport", null),
            object : MethodChannel.Result {
                override fun success(result: Any?) = Unit
                override fun error(code: String, message: String?, details: Any?) = Unit
                override fun notImplemented() = Unit
            }
        )
        videoPlugin = null
        super.onDestroy()
    }
}