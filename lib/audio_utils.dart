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

  // Basic RIFF/WAVE check
  String _tag(int off) => String.fromCharCodes(bytes.sublist(off, off + 4));
  if (_tag(0) != 'RIFF' || _tag(8) != 'WAVE') {
    throw FormatException('Not a RIFF/WAVE file: $path');
  }

  int fmtSampleRate = 0;
  int fmtChannels = 0;
  int fmtBitsPerSample = 0;
  int dataOffset = -1;
  int dataLength = -1;

  int p = 12; // first chunk after RIFF header
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
    if (p.isOdd) p++; // pad byte
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

/// Trims a WAV (PCM16 mono @ 16k) to [startSec, endSec) and writes a new WAV.
/// Throws if format is not PCM16 mono. If start/end out of bounds, clamps.
Future<void> trimWav16kMonoPcm({
  required String inputPath,
  required double startSec,
  required double endSec,
  required String outputPath,
}) async {
  final inFile = File(inputPath);
  if (!await inFile.exists()) {
    throw Exception('Input WAV not found: $inputPath');
  }

  final info = await parseWavInfo(inputPath);
  if (info.channels != 1 || info.bitsPerSample != 16) {
    throw UnsupportedError(
        'Expected PCM16 mono WAV. Got ${info.bitsPerSample} bits, ${info.channels} ch');
  }

  final bytes = await inFile.readAsBytes();
  final bytesPerSample = info.bitsPerSample ~/ 8; // 2
  final frameSize = info.channels * bytesPerSample; // 2
  final totalFrames = info.dataLength ~/ frameSize;

  final s = (startSec.isNaN ? 0.0 : startSec).clamp(0.0, double.infinity);
  final e = (endSec.isNaN ? info.durationSec : endSec)
      .clamp(0.0, info.durationSec);
  if (e <= s) {
    // empty -> write silent 10ms to avoid zero-sized data
    await _writePcm16MonoWav(outputPath, sampleRate: info.sampleRate, samples: Int16List(160));
    return;
  }

  final startFrame = (s * info.sampleRate).floor().clamp(0, totalFrames);
  final endFrame = (e * info.sampleRate).ceil().clamp(0, totalFrames);
  final frames = (endFrame - startFrame).clamp(0, totalFrames);
  final startByte = info.dataOffset + startFrame * frameSize;
  final endByte = startByte + frames * frameSize;

  final slice = bytes.sublist(startByte, endByte);
  final samples = Int16List.view(Uint8List.fromList(slice).buffer);

  await _writePcm16MonoWav(outputPath,
      sampleRate: info.sampleRate, samples: samples);
}

Future<void> _writePcm16MonoWav(String path,
    {required int sampleRate, required Int16List samples}) async {
  final dataBytes = Uint8List.view(samples.buffer);
  final fmtChunkSize = 16;
  final audioFormat = 1; // PCM
  final channels = 1;
  final bitsPerSample = 16;
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

  // RIFF header
  _putStr('RIFF');
  _putU32(riffChunkSize);
  _putStr('WAVE');

  // fmt  chunk
  _putStr('fmt ');
  _putU32(fmtChunkSize);
  _putU16(audioFormat);
  _putU16(channels);
  _putU32(sampleRate);
  _putU32(byteRate);
  _putU16(blockAlign);
  _putU16(bitsPerSample);

  // data chunk
  _putStr('data');
  _putU32(dataChunkSize);
  out.add(dataBytes);

  await File(path).writeAsBytes(out.toBytes(), flush: true);
}
