package com.enyxd.transcript

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * Native Android audio converter using MediaCodec.
 * Converts various audio formats to 16kHz mono PCM WAV for Whisper.
 */
class AudioConverter {
    
    companion object {
        private const val TAG = "AudioConverter"
        private const val TARGET_SAMPLE_RATE = 16000
        private const val TARGET_CHANNELS = 1
        private const val BITS_PER_SAMPLE = 16
        private const val TIMEOUT_US = 10000L
    }

    /**
     * Convert audio/video file to 16kHz mono WAV.
     * @param inputPath Path to input audio/video file
     * @param outputPath Path for output WAV file
     * @return true if successful
     */
    fun convertToWav16kMono(inputPath: String, outputPath: String): Boolean {
        Log.d(TAG, "Converting: $inputPath -> $outputPath")
        
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var outputStream: FileOutputStream? = null
        
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
            
            // Collect all decoded PCM data
            val pcmData = mutableListOf<ByteArray>()
            var totalPcmBytes = 0
            
            val bufferInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            
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
                
                // Get output
                val outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                if (outputBufferIndex >= 0) {
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                    
                    if (bufferInfo.size > 0) {
                        val outputBuffer = decoder.getOutputBuffer(outputBufferIndex)!!
                        val chunk = ByteArray(bufferInfo.size)
                        outputBuffer.get(chunk)
                        pcmData.add(chunk)
                        totalPcmBytes += chunk.size
                    }
                    
                    decoder.releaseOutputBuffer(outputBufferIndex, false)
                }
            }
            
            decoder.stop()
            decoder.release()
            decoder = null
            
            Log.d(TAG, "Decoded $totalPcmBytes bytes of PCM")
            
            // Combine all chunks
            val allPcm = ByteArray(totalPcmBytes)
            var offset = 0
            for (chunk in pcmData) {
                System.arraycopy(chunk, 0, allPcm, offset, chunk.size)
                offset += chunk.size
            }
            
            // Convert to 16kHz mono
            val converted = resampleAndMix(allPcm, inputSampleRate, inputChannels)
            
            // Write WAV file
            outputStream = FileOutputStream(outputPath)
            writeWavFile(outputStream, converted, TARGET_SAMPLE_RATE, TARGET_CHANNELS)
            outputStream.close()
            outputStream = null
            
            Log.d(TAG, "Conversion complete: ${File(outputPath).length()} bytes")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Conversion failed", e)
            return false
        } finally {
            try { decoder?.release() } catch (_: Exception) {}
            try { outputStream?.close() } catch (_: Exception) {}
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
    
    /**
     * Resample to 16kHz and mix to mono if needed.
     * Input is assumed to be 16-bit PCM (little-endian).
     */
    private fun resampleAndMix(
        input: ByteArray, 
        inputSampleRate: Int, 
        inputChannels: Int
    ): ByteArray {
        // Convert bytes to shorts
        val shortBuffer = ByteBuffer.wrap(input).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val inputSamples = ShortArray(shortBuffer.remaining())
        shortBuffer.get(inputSamples)
        
        // Mix to mono if stereo
        val monoSamples = if (inputChannels > 1) {
            val numFrames = inputSamples.size / inputChannels
            ShortArray(numFrames) { frame ->
                var sum = 0
                for (ch in 0 until inputChannels) {
                    sum += inputSamples[frame * inputChannels + ch]
                }
                (sum / inputChannels).toShort()
            }
        } else {
            inputSamples
        }
        
        // Resample if needed
        val resampled = if (inputSampleRate != TARGET_SAMPLE_RATE) {
            resample(monoSamples, inputSampleRate, TARGET_SAMPLE_RATE)
        } else {
            monoSamples
        }
        
        // Convert back to bytes
        val outputBytes = ByteArray(resampled.size * 2)
        val outBuffer = ByteBuffer.wrap(outputBytes).order(ByteOrder.LITTLE_ENDIAN)
        for (sample in resampled) {
            outBuffer.putShort(sample)
        }
        
        return outputBytes
    }
    
    /**
     * Simple linear interpolation resampling.
     */
    private fun resample(input: ShortArray, fromRate: Int, toRate: Int): ShortArray {
        if (fromRate == toRate) return input
        
        val ratio = fromRate.toDouble() / toRate.toDouble()
        val outputLength = (input.size / ratio).toInt()
        val output = ShortArray(outputLength)
        
        for (i in 0 until outputLength) {
            val srcPos = i * ratio
            val srcIndex = srcPos.toInt()
            val frac = srcPos - srcIndex
            
            val sample1 = input[srcIndex]
            val sample2 = if (srcIndex + 1 < input.size) input[srcIndex + 1] else sample1
            
            output[i] = (sample1 + frac * (sample2 - sample1)).roundToInt().coerceIn(-32768, 32767).toShort()
        }
        
        return output
    }
    
    /**
     * Write WAV file header and data.
     */
    private fun writeWavFile(
        output: FileOutputStream, 
        pcmData: ByteArray, 
        sampleRate: Int, 
        channels: Int
    ) {
        val byteRate = sampleRate * channels * BITS_PER_SAMPLE / 8
        val blockAlign = channels * BITS_PER_SAMPLE / 8
        
        val buffer = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        
        // RIFF header
        buffer.put("RIFF".toByteArray())
        buffer.putInt(36 + pcmData.size)  // file size - 8
        buffer.put("WAVE".toByteArray())
        
        // fmt chunk
        buffer.put("fmt ".toByteArray())
        buffer.putInt(16)  // chunk size
        buffer.putShort(1)  // PCM format
        buffer.putShort(channels.toShort())
        buffer.putInt(sampleRate)
        buffer.putInt(byteRate)
        buffer.putShort(blockAlign.toShort())
        buffer.putShort(BITS_PER_SAMPLE.toShort())
        
        // data chunk
        buffer.put("data".toByteArray())
        buffer.putInt(pcmData.size)
        
        output.write(buffer.array())
        output.write(pcmData)
    }
}
