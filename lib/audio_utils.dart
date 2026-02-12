import 'dart:io';
import 'dart:typed_data';

class WavInfo {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int dataOffset;
  final int dataLength;
  const WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataLength,
  });

  double get durationSec {
    final bytesPerSample = bitsPerSample ~/ 8;
    final frameSize = channels * bytesPerSample;
    if (frameSize == 0) return 0;
    final totalFrames = dataLength ~/ frameSize;
    return totalFrames / sampleRate;
  }
}

Future<WavInfo> parseWavInfo(String path) async {
  final f = File(path);
  final bytes = await f.readAsBytes();
  final bd = ByteData.sublistView(bytes);

  String _tag(int off) => String.fromCharCodes(bytes.sublist(off, off + 4));
  if (_tag(0) != 'RIFF' || _tag(8) != 'WAVE') {
    throw FormatException('Not a RIFF/WAVE file: $path');
  }

  int fmtSampleRate = 0;
  int fmtChannels = 0;
  int fmtBitsPerSample = 0;
  int dataOffset = -1;
  int dataLength = -1;

  int p = 12;
  while (p + 8 <= bytes.length) {
    final id = _tag(p);
    final size = bd.getUint32(p + 4, Endian.little);
    final chunkStart = p + 8;
    if (id == 'fmt ') {
      final audioFormat = bd.getUint16(chunkStart + 0, Endian.little);
      fmtChannels = bd.getUint16(chunkStart + 2, Endian.little);
      fmtSampleRate = bd.getUint32(chunkStart + 4, Endian.little);
      fmtBitsPerSample = bd.getUint16(chunkStart + 14, Endian.little);
      if (audioFormat != 1) {
        throw UnsupportedError('Only PCM (format 1) is supported');
      }
    } else if (id == 'data') {
      dataOffset = chunkStart;
      dataLength = size;
    }
    p = chunkStart + size;
    if (p.isOdd) p++;
  }

  if (fmtSampleRate == 0 ||
      fmtChannels == 0 ||
      fmtBitsPerSample == 0 ||
      dataOffset < 0 ||
      dataLength <= 0) {
    throw FormatException('Malformed WAV, missing fmt/data chunks');
  }

  return WavInfo(
    sampleRate: fmtSampleRate,
    channels: fmtChannels,
    bitsPerSample: fmtBitsPerSample,
    dataOffset: dataOffset,
    dataLength: dataLength,
  );
}

Future<double> readWavDuration(String path) async {
  final info = await parseWavInfo(path);
  return info.durationSec;
}

Future<Int16List> readPcm16MonoSamples(String path) async {
  final info = await parseWavInfo(path);
  if (info.channels != 1 || info.bitsPerSample != 16) {
    throw UnsupportedError('Expected PCM16 mono WAV');
  }
  final numSamples = info.dataLength ~/ 2;
  final samples = Int16List(numSamples);
  final raf = File(path).openSync(mode: FileMode.read);
  try {
    raf.setPositionSync(info.dataOffset);
    // Read in ~1 MB chunks to avoid loading entire file into memory
    const chunkSamples = 512 * 1024; // 512 K samples = 1 MB
    int offset = 0;
    int remaining = numSamples;
    while (remaining > 0) {
      final toRead = remaining < chunkSamples ? remaining : chunkSamples;
      final bytes = raf.readSync(toRead * 2);
      final bd = ByteData.view(bytes.buffer);
      for (int i = 0; i < toRead; i++) {
        samples[offset++] = bd.getInt16(i * 2, Endian.little);
      }
      remaining -= toRead;
    }
    return samples;
  } finally {
    raf.closeSync();
  }
}

Future<void> writePcm16MonoWav(String path,
    {required int sampleRate, required Int16List samples}) async {
  final dataBytes = Uint8List.view(samples.buffer);
  const fmtChunkSize = 16;
  const audioFormat = 1; // PCM
  const channels = 1;
  const bitsPerSample = 16;
  final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
  final blockAlign = channels * (bitsPerSample ~/ 8);
  final dataChunkSize = dataBytes.lengthInBytes;
  final riffChunkSize = 4 + (8 + fmtChunkSize) + (8 + dataChunkSize);

  final out = BytesBuilder();
  void _putStr(String s) => out.add(s.codeUnits);
  void _putU32(int v) {
    final bd = ByteData(4)..setUint32(0, v, Endian.little);
    out.add(bd.buffer.asUint8List());
  }
  void _putU16(int v) {
    final bd = ByteData(2)..setUint16(0, v, Endian.little);
    out.add(bd.buffer.asUint8List());
  }

  _putStr('RIFF');
  _putU32(riffChunkSize);
  _putStr('WAVE');

  _putStr('fmt ');
  _putU32(fmtChunkSize);
  _putU16(audioFormat);
  _putU16(channels);
  _putU32(sampleRate);
  _putU32(byteRate);
  _putU16(blockAlign);
  _putU16(bitsPerSample);

  _putStr('data');
  _putU32(dataChunkSize);
  out.add(dataBytes);

  await File(path).writeAsBytes(out.toBytes(), flush: true);
}

/// Trim a 16 kHz mono PCM16 WAV to [startSec, endSec).
/// Uses RandomAccessFile to avoid loading the entire file into memory.
Future<void> trimWav16kMonoPcm({
  required String inputPath,
  required double startSec,
  required double endSec,
  required String outputPath,
  WavInfo? preParsedInfo,
}) async {
  final info = preParsedInfo ?? await parseWavInfo(inputPath);
  if (info.channels != 1 || info.bitsPerSample != 16) {
    throw UnsupportedError('Expected PCM16 mono WAV');
  }

  final bytesPerSample = info.bitsPerSample ~/ 8;
  final frameSize = info.channels * bytesPerSample;
  final totalFrames = info.dataLength ~/ frameSize;

  final s = (startSec.isNaN ? 0.0 : startSec).clamp(0.0, info.durationSec);
  final e = (endSec.isNaN ? info.durationSec : endSec).clamp(0.0, info.durationSec);
  if (e <= s) {
    await writePcm16MonoWav(outputPath,
        sampleRate: info.sampleRate, samples: Int16List(160));
    return;
  }

  final startFrame = (s * info.sampleRate).floor().clamp(0, totalFrames);
  final endFrame = (e * info.sampleRate).ceil().clamp(0, totalFrames);
  final frames = (endFrame - startFrame).clamp(0, totalFrames);
  final startByte = info.dataOffset + startFrame * frameSize;
  final bytesToRead = frames * frameSize;

  // Use RandomAccessFile to read only the slice we need
  final raf = await File(inputPath).open(mode: FileMode.read);
  try {
    await raf.setPosition(startByte);
    final slice = await raf.read(bytesToRead);
    final samples = Int16List.view(Uint8List.fromList(slice).buffer);
    await writePcm16MonoWav(outputPath, sampleRate: info.sampleRate, samples: samples);
  } finally {
    await raf.close();
  }
}

Wave readWaveSimple(String path) {
  final raf = File(path).openSync(mode: FileMode.read);
  
  try {
    final fileLen = raf.lengthSync();
    if (fileLen < 44) {
      throw Exception('File too small to be a WAV file');
    }
    
    // Read only the header (first 44 bytes minimum)
    final headerBytes = raf.readSync(44);
    
    // Check for "RIFF" header
    if (String.fromCharCodes(headerBytes.sublist(0, 4)) != 'RIFF') {
      throw Exception('Not a RIFF file');
    }
    
    // Check for "WAVE" format
    if (String.fromCharCodes(headerBytes.sublist(8, 12)) != 'WAVE') {
      throw Exception('Not a WAVE file');
    }
    
    // Find "fmt " chunk - read chunks until we find it
    raf.setPositionSync(12);
    int fmtOffset = -1;
    int numChannels = 0;
    int sampleRate = 0;
    int bitsPerSample = 0;
    int audioFormat = 0;
    
    while (raf.positionSync() < fileLen - 8) {
      final chunkHeader = raf.readSync(8);
      final chunkId = String.fromCharCodes(chunkHeader.sublist(0, 4));
      final chunkSize = ByteData.view(chunkHeader.buffer).getUint32(4, Endian.little);
      
      if (chunkId == 'fmt ') {
        fmtOffset = raf.positionSync();
        final fmtData = raf.readSync(chunkSize);
        final bd = ByteData.view(fmtData.buffer);
        audioFormat = bd.getUint16(0, Endian.little);
        numChannels = bd.getUint16(2, Endian.little);
        sampleRate = bd.getUint32(4, Endian.little);
        bitsPerSample = bd.getUint16(14, Endian.little);
        break;
      } else {
        raf.setPositionSync(raf.positionSync() + chunkSize);
      }
    }
    
    if (fmtOffset < 0) {
      throw Exception('fmt chunk not found');
    }
    
    if (audioFormat != 1) {
      throw Exception('Only PCM format is supported');
    }
    
    // Find "data" chunk
    raf.setPositionSync(12);
    int dataOffset = -1;
    int dataSize = 0;
    
    while (raf.positionSync() < fileLen - 8) {
      final chunkHeader = raf.readSync(8);
      final chunkId = String.fromCharCodes(chunkHeader.sublist(0, 4));
      final chunkSize = ByteData.view(chunkHeader.buffer).getUint32(4, Endian.little);
      
      if (chunkId == 'data') {
        dataOffset = raf.positionSync();
        dataSize = chunkSize;
        break;
      } else {
        raf.setPositionSync(raf.positionSync() + chunkSize);
      }
    }
    
    if (dataOffset < 0) {
      throw Exception('data chunk not found');
    }
    
    // Read audio data in chunks to avoid loading entire raw bytes at once
    final numSamples = dataSize ~/ (numChannels * (bitsPerSample ~/ 8));
    final samples = Float32List(numSamples);
    
    raf.setPositionSync(dataOffset);
    
    // Process in chunks of ~1MB to reduce peak memory
    final bytesPerFrame = numChannels * (bitsPerSample ~/ 8);
    final framesPerChunk = (1024 * 1024) ~/ bytesPerFrame; // ~1MB per chunk
    int sampleIndex = 0;
    int framesRemaining = numSamples;
    
    while (framesRemaining > 0) {
      final framesToRead = framesRemaining < framesPerChunk ? framesRemaining : framesPerChunk;
      final chunkBytes = raf.readSync(framesToRead * bytesPerFrame);
      final bd = ByteData.view(chunkBytes.buffer);
      
      if (bitsPerSample == 16) {
        for (int i = 0; i < framesToRead; i++) {
          double sum = 0;
          for (int c = 0; c < numChannels; c++) {
            final sample = bd.getInt16((i * numChannels + c) * 2, Endian.little);
            sum += sample / 32768.0;
          }
          samples[sampleIndex++] = sum / numChannels;
        }
      } else if (bitsPerSample == 32) {
        for (int i = 0; i < framesToRead; i++) {
          double sum = 0;
          for (int c = 0; c < numChannels; c++) {
            final sample = bd.getFloat32((i * numChannels + c) * 4, Endian.little);
            sum += sample;
          }
          samples[sampleIndex++] = sum / numChannels;
        }
      } else {
        throw Exception('Unsupported bits per sample: $bitsPerSample');
      }
      
      framesRemaining -= framesToRead;
    }
    
    return Wave(samples: samples, sampleRate: sampleRate);
  } finally {
    raf.closeSync();
  }
}

/// Wave class that matches sherpa_onnx's Wave class structure
class Wave {
  final Float32List samples;
  final int sampleRate;
  
  Wave({required this.samples, required this.sampleRate});
}