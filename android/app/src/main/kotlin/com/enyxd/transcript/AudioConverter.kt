package com.enyxd.transcript

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * Native Android audio converter using MediaCodec.
 * Converts various audio formats to 16kHz mono PCM WAV for local ASR.
 *
 * Updated:
 * ✅ Respect BufferInfo.offset/size (prevents corrupted PCM)
 * ✅ Handle INFO_OUTPUT_FORMAT_CHANGED (reads sr/ch/pcmEncoding)
 * ✅ Support PCM_FLOAT output (float -> PCM16)
 * ✅ Reduce allocations (no copyOf; reuse buffers)
 * ✅ Faster streaming write via FileOutputStream; patch header with RandomAccessFile
 */
class AudioConverter {

  companion object {
    private const val TAG = "AudioConverter"

    private const val TARGET_SAMPLE_RATE = 16000
    private const val TARGET_CHANNELS = 1
    private const val BITS_PER_SAMPLE = 16
    private const val TIMEOUT_US = 10_000L

    private const val YIELD_EVERY_BUFFERS = 80
  }

  fun convertToWav16kMono(inputPath: String, outputPath: String): Boolean {
    Log.d(TAG, "Converting: $inputPath -> $outputPath")

    val extractor = MediaExtractor()
    var decoder: MediaCodec? = null
    var outStream: FileOutputStream? = null
    var headerPatcher: RandomAccessFile? = null

    try {
      extractor.setDataSource(inputPath)

      val audioTrackIndex = findAudioTrack(extractor)
      if (audioTrackIndex < 0) {
        Log.e(TAG, "No audio track found")
        return false
      }

      extractor.selectTrack(audioTrackIndex)
      val inFormat = extractor.getTrackFormat(audioTrackIndex)
      val mime = inFormat.getString(MediaFormat.KEY_MIME) ?: run {
        Log.e(TAG, "Missing MIME")
        return false
      }

      val guessSr = safeGetInt(inFormat, MediaFormat.KEY_SAMPLE_RATE, TARGET_SAMPLE_RATE)
      val guessCh = safeGetInt(inFormat, MediaFormat.KEY_CHANNEL_COUNT, 1)

      Log.d(TAG, "Input track: mime=$mime, sampleRate=$guessSr, channels=$guessCh")

      decoder = MediaCodec.createDecoderByType(mime)
      decoder.configure(inFormat, null, null, 0)
      decoder.start()

      File(outputPath).parentFile?.mkdirs()
      outStream = FileOutputStream(outputPath)
      outStream.write(buildWavHeaderPlaceholder())
      headerPatcher = RandomAccessFile(outputPath, "rw")

      val bufferInfo = MediaCodec.BufferInfo()

      var inputDone = false
      var outputDone = false
      var totalOutputBytes = 0L
      var buffersSeen = 0

      var outSampleRate = guessSr
      var outChannels = guessCh
      var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT

      val resampler = StreamingResampler(
        inputRate = outSampleRate,
        outputRate = TARGET_SAMPLE_RATE,
        inputChannels = outChannels,
        pcmEncoding = pcmEncoding
      )

      while (!outputDone) {
        // Feed input
        if (!inputDone) {
          val inIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
          if (inIndex >= 0) {
            val inBuf = decoder.getInputBuffer(inIndex)!!
            val sampleSize = extractor.readSampleData(inBuf, 0)
            if (sampleSize < 0) {
              decoder.queueInputBuffer(
                inIndex, 0, 0, 0,
                MediaCodec.BUFFER_FLAG_END_OF_STREAM
              )
              inputDone = true
            } else {
              decoder.queueInputBuffer(
                inIndex,
                0,
                sampleSize,
                extractor.sampleTime,
                0
              )
              extractor.advance()
            }
          }
        }

        // Drain output
        val outIndex = decoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
        when (outIndex) {
          MediaCodec.INFO_TRY_AGAIN_LATER -> {
            // nothing yet
          }

          MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
            val fmt = decoder.outputFormat
            val sr = safeGetInt(fmt, MediaFormat.KEY_SAMPLE_RATE, outSampleRate)
            val ch = safeGetInt(fmt, MediaFormat.KEY_CHANNEL_COUNT, outChannels)
            val enc = if (fmt.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
              safeGetInt(fmt, MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            } else {
              AudioFormat.ENCODING_PCM_16BIT
            }

            Log.d(TAG, "Output format changed: sr=$sr ch=$ch enc=$enc")
            outSampleRate = sr
            outChannels = ch
            pcmEncoding = enc

            resampler.updateInputFormat(outSampleRate, outChannels, pcmEncoding)
          }

          MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> {
            // no-op (deprecated)
          }

          else -> {
            if (outIndex >= 0) {
              if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                outputDone = true
              }

              if (bufferInfo.size > 0) {
                val outBuf = decoder.getOutputBuffer(outIndex)!!
                // ✅ Respect offset + size
                outBuf.position(bufferInfo.offset)
                outBuf.limit(bufferInfo.offset + bufferInfo.size)

                val (outBytes, outLen) = resampler.process(outBuf)
                if (outLen > 0) {
                  outStream.write(outBytes, 0, outLen)
                  totalOutputBytes += outLen.toLong()
                }

                buffersSeen++
                if (buffersSeen % YIELD_EVERY_BUFFERS == 0) {
                  Thread.yield()
                }
              }

              decoder.releaseOutputBuffer(outIndex, false)
            }
          }
        }
      }

      // flush (usually 0 for this linear resampler)
      val (rem, remLen) = resampler.flush()
      if (remLen > 0) {
        outStream.write(rem, 0, remLen)
        totalOutputBytes += remLen.toLong()
      }

      outStream.flush()
      outStream.close()
      outStream = null

      updateWavHeader(headerPatcher, totalOutputBytes)
      headerPatcher.close()
      headerPatcher = null

      decoder.stop()
      decoder.release()
      decoder = null
      extractor.release()

      Log.d(TAG, "Conversion complete: ${File(outputPath).length()} bytes (data=$totalOutputBytes)")
      return true
    } catch (e: Exception) {
      Log.e(TAG, "Conversion failed", e)
      return false
    } finally {
      try { decoder?.release() } catch (_: Exception) {}
      try { extractor.release() } catch (_: Exception) {}
      try { outStream?.close() } catch (_: Exception) {}
      try { headerPatcher?.close() } catch (_: Exception) {}
    }
  }

  private fun findAudioTrack(extractor: MediaExtractor): Int {
    for (i in 0 until extractor.trackCount) {
      val format = extractor.getTrackFormat(i)
      val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
      if (mime.startsWith("audio/")) return i
    }
    return -1
  }

  private fun safeGetInt(fmt: MediaFormat, key: String, def: Int): Int {
    return try {
      if (fmt.containsKey(key)) fmt.getInteger(key) else def
    } catch (_: Exception) {
      def
    }
  }

  // -------- WAV header helpers --------

  private fun buildWavHeaderPlaceholder(): ByteArray {
    val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)

    header.put("RIFF".toByteArray())
    header.putInt(0) // placeholder (file size - 8)
    header.put("WAVE".toByteArray())

    header.put("fmt ".toByteArray())
    header.putInt(16)
    header.putShort(1) // PCM
    header.putShort(TARGET_CHANNELS.toShort())
    header.putInt(TARGET_SAMPLE_RATE)
    header.putInt(TARGET_SAMPLE_RATE * TARGET_CHANNELS * BITS_PER_SAMPLE / 8)
    header.putShort((TARGET_CHANNELS * BITS_PER_SAMPLE / 8).toShort())
    header.putShort(BITS_PER_SAMPLE.toShort())

    header.put("data".toByteArray())
    header.putInt(0) // placeholder data size

    return header.array()
  }

  private fun updateWavHeader(file: RandomAccessFile, dataSize: Long) {
    val dataSizeInt = dataSize.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()

    file.seek(4)
    file.writeInt(Integer.reverseBytes(36 + dataSizeInt))

    file.seek(40)
    file.writeInt(Integer.reverseBytes(dataSizeInt))
  }

  // -------- Resampler --------

  private class StreamingResampler(
    inputRate: Int,
    private val outputRate: Int,
    inputChannels: Int,
    pcmEncoding: Int
  ) {
    private var inputRate = if (inputRate > 0) inputRate else outputRate
    private var inputChannels = if (inputChannels > 0) inputChannels else 1
    private var pcmEncoding = pcmEncoding

    private var ratio = this.inputRate.toDouble() / outputRate.toDouble()
    private var srcPosition = 0.0
    private var lastSample: Short = 0

    // reused buffers
    private var pcm16Shorts = ShortArray(0) // interleaved
    private var monoShorts = ShortArray(0)
    private var outShorts = ShortArray(0)
    private var outBytes = ByteArray(0)
    private var floatScratch = FloatArray(0)

    fun updateInputFormat(inputRate: Int, inputChannels: Int, pcmEncoding: Int) {
      this.inputRate = if (inputRate > 0) inputRate else this.inputRate
      this.inputChannels = if (inputChannels > 0) inputChannels else this.inputChannels
      this.pcmEncoding = pcmEncoding
      ratio = this.inputRate.toDouble() / outputRate.toDouble()
    }

    fun process(buf: ByteBuffer): Pair<ByteArray, Int> {
      if (!buf.hasRemaining()) return outBytes to 0

      val frames: Int
      val shortsLen: Int

      when (pcmEncoding) {
        AudioFormat.ENCODING_PCM_16BIT -> {
          val sb = buf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
          shortsLen = sb.remaining()
          ensurePcm16(shortsLen)
          sb.get(pcm16Shorts, 0, shortsLen)
          frames = shortsLen / inputChannels
        }

        AudioFormat.ENCODING_PCM_FLOAT -> {
          val fb = buf.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
          val nFloats = fb.remaining()
          ensureFloat(nFloats)
          fb.get(floatScratch, 0, nFloats)

          ensurePcm16(nFloats)
          for (i in 0 until nFloats) {
            val f = floatScratch[i].coerceIn(-1f, 1f)
            pcm16Shorts[i] = (f * 32767f).toInt().coerceIn(-32768, 32767).toShort()
          }
          shortsLen = nFloats
          frames = shortsLen / inputChannels
        }

        else -> {
          // Best-effort assume PCM16
          val sb = buf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
          shortsLen = sb.remaining()
          ensurePcm16(shortsLen)
          sb.get(pcm16Shorts, 0, shortsLen)
          frames = shortsLen / inputChannels
        }
      }

      if (frames <= 0) return outBytes to 0

      // Downmix to mono into monoShorts[0..frames)
      ensureMono(frames)
      if (inputChannels <= 1) {
        System.arraycopy(pcm16Shorts, 0, monoShorts, 0, frames)
      } else {
        var idx = 0
        for (f in 0 until frames) {
          var sum = 0
          for (c in 0 until inputChannels) sum += pcm16Shorts[idx++].toInt()
          monoShorts[f] = (sum / inputChannels).toShort()
        }
      }

      // Resample mono -> outShorts
      val outCount = resampleInto(monoShorts, frames)
      if (outCount <= 0) return outBytes to 0

      // shorts -> bytes (LE) into outBytes
      ensureOutBytes(outCount * 2)
      ByteBuffer.wrap(outBytes, 0, outCount * 2)
        .order(ByteOrder.LITTLE_ENDIAN)
        .asShortBuffer()
        .put(outShorts, 0, outCount)

      return outBytes to (outCount * 2)
    }

    fun flush(): Pair<ByteArray, Int> = outBytes to 0

    private fun resampleInto(input: ShortArray, len: Int): Int {
      if (len <= 0) return 0

      if (inputRate == outputRate) {
        ensureOutShorts(len)
        System.arraycopy(input, 0, outShorts, 0, len)
        lastSample = input[len - 1]
        return len
      }

      val maxOut = ceil((len - srcPosition) / ratio).toInt() + 2
      ensureOutShorts(maxOut)

      var outIdx = 0
      while (srcPosition < len - 1 && outIdx < maxOut) {
        val si = srcPosition.toInt()
        val frac = srcPosition - si

        val s1 = if (si in 0 until len) input[si] else lastSample
        val s2 = if (si + 1 < len) input[si + 1] else s1

        val interp = (s1 + frac * (s2 - s1)).roundToInt()
          .coerceIn(-32768, 32767)
          .toShort()

        outShorts[outIdx++] = interp
        srcPosition += ratio
      }

      srcPosition -= len
      lastSample = input[len - 1]
      return outIdx
    }

    private fun ensurePcm16(n: Int) {
      if (pcm16Shorts.size < n) pcm16Shorts = ShortArray(n)
    }

    private fun ensureMono(n: Int) {
      if (monoShorts.size < n) monoShorts = ShortArray(n)
    }

    private fun ensureOutShorts(n: Int) {
      if (outShorts.size < n) outShorts = ShortArray(n)
    }

    private fun ensureOutBytes(n: Int) {
      if (outBytes.size < n) outBytes = ByteArray(n)
    }

    private fun ensureFloat(n: Int) {
      if (floatScratch.size < n) floatScratch = FloatArray(n)
    }
  }
}
