// lib/model_bootstrap.dart
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Where the ONNX files end up on device (App Documents).
/// We copy them from assets on first run (or when version changes).
class ModelPaths {
  final String segOnnx; // pyannote segmentation
  final String embOnnx; // NeMo Titanet-small speaker embedding
  ModelPaths({required this.segOnnx, required this.embOnnx});
}

/// Bump this when you replace the bundled models in assets
const _kAssetModelVersion = 1;

/// Asset paths (placed under /assets in your repo; see pubspec.yaml below)
const _kSegAssetFull = 'assets/models/segmentation/model.onnx';
const _kSegAssetInt8 = 'assets/models/segmentation/model.int8.onnx'; // optional
const _kEmbAsset = 'assets/models/embedding/nemo_en_titanet_small.onnx';

/// Ensures both segmentation + embedding models exist on device by copying
/// from assets (no network). Returns absolute file paths for Sherpa-ONNX.
Future<ModelPaths> ensureDiarizationModels({bool useInt8Seg = false}) async {
  final docs = await getApplicationDocumentsDirectory();
  final root = Directory('${docs.path}/models');
  final segDir = Directory('${root.path}/segmentation')
    ..createSync(recursive: true);
  final embDir = Directory('${root.path}/embedding')
    ..createSync(recursive: true);

  // Simple versioning: re-copy when version bump
  final verFile = File('${root.path}/.asset_version');
  final needsRefresh =
      !await verFile.exists() ||
      (await verFile.readAsString()).trim() != 'v$_kAssetModelVersion';

  // Target filenames on device
  final segDst = File(
    '${segDir.path}/${useInt8Seg ? 'model.int8.onnx' : 'model.onnx'}',
  );
  final embDst = File('${embDir.path}/embedding.onnx');

  // Copy segmentation
  final segAsset = useInt8Seg ? _kSegAssetInt8 : _kSegAssetFull;
  await _ensureAssetCopied(segAsset, segDst, overwrite: needsRefresh);

  // Copy embedding
  await _ensureAssetCopied(_kEmbAsset, embDst, overwrite: needsRefresh);

  // Write version marker
  await verFile.writeAsString('v$_kAssetModelVersion', flush: true);

  return ModelPaths(segOnnx: segDst.path, embOnnx: embDst.path);
}

Future<void> _ensureAssetCopied(
  String assetPath,
  File dst, {
  bool overwrite = false,
}) async {
  if (!overwrite && await dst.exists() && (await dst.length()) > 0) return;
  final bytes = await rootBundle.load(assetPath);
  final data = bytes.buffer.asUint8List(
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );
  await dst.writeAsBytes(data, flush: true);
}
