// lib/segmentation_installer.dart
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

const kSegTarUrl =
  'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2';

/// Downloads the tar.bz2 and extracts either model.onnx (default) or model.int8.onnx.
/// Returns the absolute path to the extracted ONNX file.
Future<String> installSegmentationModel({bool useInt8 = false}) async {
  final docs = await getApplicationDocumentsDirectory();
  final segDir = Directory('${docs.path}/models/segmentation');
  await segDir.create(recursive: true);

  // where we want the final file
  final outPath = '${segDir.path}/${useInt8 ? 'model.int8.onnx' : 'model.onnx'}';
  final outFile = File(outPath);
  if (await outFile.exists() && (await outFile.length()) > 0) {
    return outFile.path; // already installed
  }

  // download archive to temp
  final tmpDir = await getTemporaryDirectory();
  final tarPath = '${tmpDir.path}/pyannote-seg-3.0.tar.bz2';
  final r = await http.get(Uri.parse(kSegTarUrl));
  if (r.statusCode != 200) {
    throw Exception('HTTP ${r.statusCode} while downloading segmentation model');
  }
  await File(tarPath).writeAsBytes(r.bodyBytes, flush: true);

  // decode .bz2 -> .tar
  final bzBytes = r.bodyBytes;
  final tarBytes = BZip2Decoder().decodeBytes(bzBytes);

  // decode .tar and extract the needed ONNX
  final archive = TarDecoder().decodeBytes(tarBytes);
  final wantedName = useInt8 ? 'model.int8.onnx' : 'model.onnx';

  ArchiveFile? file;
  for (final f in archive.files) {
    final name = f.name.split('/').last; // handle inner folders
    if (!f.isFile) continue;
    if (name == wantedName) { file = f; break; }
  }
  if (file == null) {
    // fallback: if user asked for int8 and it's missing, try full model
    if (useInt8) {
      for (final f in archive.files) {
        final name = f.name.split('/').last;
        if (f.isFile && name == 'model.onnx') { file = f; break; }
      }
    }
  }
  if (file == null) {
    throw Exception('Could not find ${wantedName} inside tarball');
  }

  await outFile.writeAsBytes(file.content as List<int>, flush: true);
  return outFile.path;
}
