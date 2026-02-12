package com.enyxd.transcript

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * Native Android audio converter using MediaCodec.
 * Converts various audio formats to 16kHz mono PCM WAV for Whisper.
 * Uses streaming to handle long audio files without running out of memory.
 */
class AudioConverter {
    
    companion object {
        private const val TAG = "AudioConverter"
        private const val TARGET_SAMPLE_RATE = 16000
        private const val TARGET_CHANNELS = 1
        private const val BITS_PER_SAMPLE = 16
        private const val TIMEOUT_US = 10000L
        
        // Throttling: yield every N output buffers to reduce CPU heat
        private const val YIELD_EVERY_BUFFERS = 50
        private const val YIELD_DURATION_MS = 5L
    }

    /**
     * Convert audio/video file to 16kHz mono WAV using streaming.
     * @param inputPath Path to input audio/video file
     * @param outputPath Path for output WAV file
     * @return true if successful
     */
    fun convertToWav16kMono(inputPath: String, outputPath: String): Boolean {
        Log.d(TAG, "Converting: $inputPath -> $outputPath")
        
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var outputFile: RandomAccessFile? = null
        
        try {
            extractor.setDataSource(inputPath)
            
            // Find audio track
            val audioTrackIndex = findAudioTrack(extractor)
            if (audioTrackIndex < 0) {
                Log.e(TAG, "No audio track found")
                return false
            }
            
            extractor.selectTrack(audioTrackIndex)
            val format = extractor.getTrackFormat(audioTrackIndex)
            
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return false
            val inputSampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val inputChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            
            Log.d(TAG, "Input: mime=$mime, sampleRate=$inputSampleRate, channels=$inputChannels")
            
            // Create decoder
            decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(format, null, null, 0)
            decoder.start()
            
            // Open output file and write placeholder header
            outputFile = RandomAccessFile(outputPath, "rw")
            outputFile.setLength(0)
            writeWavHeaderPlaceholder(outputFile)
            
            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var totalOutputBytes = 0L
            var bufferCount = 0
            
            // Resampler state for streaming
            val resampler = StreamingResampler(inputSampleRate, TARGET_SAMPLE_RATE, inputChannels)
            
            while (!outputDone) {
                // Feed input
                if (!inputDone) {
                    val inputBufferIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (inputBufferIndex >= 0) {
                        val inputBuffer = decoder.getInputBuffer(inputBufferIndex)!!
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        
                        if (sampleSize < 0) {
                            decoder.queueInputBuffer(
                                inputBufferIndex, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                            inputDone = true
                        } else {
                            val presentationTimeUs = extractor.sampleTime
                            decoder.queueInputBuffer(
                                inputBufferIndex, 0, sampleSize, presentationTimeUs, 0
                            )
                            extractor.advance()
                        }
                    }
                }
                
                // Get output and process in streaming fashion
                val outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                if (outputBufferIndex >= 0) {
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                    
                    if (bufferInfo.size > 0) {
                        val outputBuffer = decoder.getOutputBuffer(outputBufferIndex)!!
                        val chunk = ByteArray(bufferInfo.size)
                        outputBuffer.get(chunk)
                        
                        // Process chunk through resampler and write directly to file
                        val processed = resampler.process(chunk)
                        if (processed.isNotEmpty()) {
                            outputFile.write(processed)
                            totalOutputBytes += processed.size
                        }
                        
                        // Throttle: yield periodically to prevent CPU overheating
                        bufferCount++
                        if (bufferCount % YIELD_EVERY_BUFFERS == 0) {
                            Thread.sleep(YIELD_DURATION_MS)
                        }
                    }
                    
                    decoder.releaseOutputBuffer(outputBufferIndex, false)
                }
            }
            
            // Flush any remaining samples from resampler
            val remaining = resampler.flush()
            if (remaining.isNotEmpty()) {
                outputFile.write(remaining)
                totalOutputBytes += remaining.size
            }
            
            decoder.stop()
            decoder.release()
            decoder = null
            
            // Update WAV header with actual size
            updateWavHeader(outputFile, totalOutputBytes)
            outputFile.close()
            outputFile = null
            
            Log.d(TAG, "Conversion complete: ${File(outputPath).length()} bytes")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Conversion failed", e)
            return false
        } finally {
            try { decoder?.release() } catch (_: Exception) {}
            try { outputFile?.close() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
    }
    
    private fun findAudioTrack(extractor: MediaExtractor): Int {
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) {
                return i
            }
        }
        return -1
    }
    
    private fun writeWavHeaderPlaceholder(file: RandomAccessFile) {
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        
        // RIFF header with placeholder sizes
        header.put("RIFF".toByteArray())
        header.putInt(0)  // placeholder for file size - 8
        header.put("WAVE".toByteArray())
        
        // fmt chunk
        header.put("fmt ".toByteArray())
        header.putInt(16)  // chunk size
        header.putShort(1)  // PCM format
        header.putShort(TARGET_CHANNELS.toShort())
        header.putInt(TARGET_SAMPLE_RATE)
        header.putInt(TARGET_SAMPLE_RATE * TARGET_CHANNELS * BITS_PER_SAMPLE / 8)  // byte rate
        header.putShort((TARGET_CHANNELS * BITS_PER_SAMPLE / 8).toShort())  // block align
        header.putShort(BITS_PER_SAMPLE.toShort())
        
        // data chunk
        header.put("data".toByteArray())
        header.putInt(0)  // placeholder for data size
        
        file.write(header.array())
    }
    
    private fun updateWavHeader(file: RandomAccessFile, dataSize: Long) {
        val dataSizeInt = dataSize.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        
        // Update RIFF chunk size (file size - 8)
        file.seek(4)
        file.writeInt(Integer.reverseBytes(36 + dataSizeInt))
        
        // Update data chunk size
        file.seek(40)
        file.writeInt(Integer.reverseBytes(dataSizeInt))
    }
    
    /**
     * Streaming resampler that processes chunks without loading entire file into memory.
     * Optimized to pre-allocate buffers and avoid dynamic lists.
     */
    private class StreamingResampler(
        private val inputRate: Int,
        private val outputRate: Int,
        private val inputChannels: Int
    ) {
        private val ratio = inputRate.toDouble() / outputRate.toDouble()
        private var srcPosition = 0.0
        private var lastSample: Short = 0
        
        // Pre-allocated work buffer for mono conversion (reused each call)
        private var monoBuffer = ShortArray(0)
        // Pre-allocated output buffer (reused each call)
        private var outputBuffer = ByteArray(0)
        
        /**
         * Process a chunk of input PCM data (16-bit little-endian).
         * Returns resampled mono 16kHz output.
         */
        fun process(input: ByteArray): ByteArray {
            if (input.isEmpty()) return ByteArray(0)
            
            // Convert bytes to shorts directly
            val numShorts = input.size / 2
            val inputSamples = ShortArray(numShorts)
            val bb = ByteBuffer.wrap(input).order(ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until numShorts) {
                inputSamples[i] = bb.short
            }
            
            // Mix to mono in-place if needed
            val monoSamples = if (inputChannels > 1) {
                val numFrames = numShorts / inputChannels
                ensureMonoBuffer(numFrames)
                for (frame in 0 until numFrames) {
                    var sum = 0
                    for (ch in 0 until inputChannels) {
                        sum += inputSamples[frame * inputChannels + ch]
                    }
                    monoBuffer[frame] = (sum / inputChannels).toShort()
                }
                monoBuffer.copyOf(numFrames)
            } else {
                inputSamples
            }
            
            // Resample
            return resampleChunk(monoSamples)
        }
        
        fun flush(): ByteArray = ByteArray(0)
        
        private fun ensureMonoBuffer(size: Int) {
            if (monoBuffer.size < size) {
                monoBuffer = ShortArray(size)
            }
        }
        
        private fun resampleChunk(input: ShortArray): ByteArray {
            if (input.isEmpty()) return ByteArray(0)
            
            if (inputRate == outputRate) {
                // No resampling needed
                val output = ByteArray(input.size * 2)
                val buffer = ByteBuffer.wrap(output).order(ByteOrder.LITTLE_ENDIAN)
                for (sample in input) {
                    buffer.putShort(sample)
                }
                return output
            }
            
            // Pre-calculate exact output size for this chunk
            val maxOutputSamples = ceil((input.size - srcPosition) / ratio).toInt() + 1
            val outputSamples = ShortArray(maxOutputSamples)
            var outputIndex = 0
            
            while (srcPosition < input.size - 1 && outputIndex < maxOutputSamples) {
                val srcIndex = srcPosition.toInt()
                val frac = srcPosition - srcIndex
                
                val sample1 = if (srcIndex >= 0 && srcIndex < input.size) input[srcIndex] else lastSample
                val sample2 = if (srcIndex + 1 < input.size) input[srcIndex + 1] else sample1
                
                val interpolated = (sample1 + frac * (sample2 - sample1)).roundToInt()
                    .coerceIn(-32768, 32767).toShort()
                outputSamples[outputIndex++] = interpolated
                
                srcPosition += ratio
            }
            
            // Adjust position for next chunk
            srcPosition -= input.size
            if (input.isNotEmpty()) {
                lastSample = input.last()
            }
            
            // Convert to bytes - only the samples we actually produced
            val output = ByteArray(outputIndex * 2)
            val buffer = ByteBuffer.wrap(output).order(ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until outputIndex) {
                buffer.putShort(outputSamples[i])
            }
            return output
        }
    }
}
