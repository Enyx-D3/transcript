package com.enyxd.transcript

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.enyxd.transcript/audio_converter"
    private val audioConverter = AudioConverter()
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "convertToWav16kMono" -> {
                    val inputPath = call.argument<String>("inputPath")
                    val outputPath = call.argument<String>("outputPath")
                    
                    if (inputPath == null || outputPath == null) {
                        result.error("INVALID_ARGS", "inputPath and outputPath required", null)
                        return@setMethodCallHandler
                    }
                    
                    CoroutineScope(Dispatchers.Main).launch {
                        try {
                            val success = withContext(Dispatchers.IO) {
                                audioConverter.convertToWav16kMono(inputPath, outputPath)
                            }
                            if (success) {
                                result.success(outputPath)
                            } else {
                                result.error("CONVERSION_FAILED", "Audio conversion failed", null)
                            }
                        } catch (e: Exception) {
                            result.error("EXCEPTION", e.message, e.stackTraceToString())
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}

