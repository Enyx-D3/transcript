// lib/model_bootstrap.dart
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'segmentation_installer.dart';

class ModelPaths {
  final String segOnnx, embOnnx;
  ModelPaths({required this.segOnnx, required this.embOnnx});
}

Future<ModelPaths> ensureDiarizationModels() async {
  final docs = await getApplicationDocumentsDirectory();
  final embDir = Directory('${docs.path}/models/embedding')..createSync(recursive: true);

  // 1) Segmentation: download & extract pyannote seg model
  final segOnnxPath = await installSegmentationModel(useInt8: false);

  // 2) Embedding: NeMo titanet-small (speaker-recognition-models)
  final embUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recognition-models/nemo_en_titanet_small.onnx';
  final embOnnxFile = File('${embDir.path}/embedding.onnx');
  if (!await embOnnxFile.exists() || (await embOnnxFile.length()) == 0) {
    final r = await http.get(Uri.parse(embUrl));
    if (r.statusCode != 200) throw Exception('Failed to download embedding model');
    await embOnnxFile.writeAsBytes(r.bodyBytes, flush: true);
  }

  return ModelPaths(segOnnx: segOnnxPath, embOnnx: embOnnxFile.path);
}
