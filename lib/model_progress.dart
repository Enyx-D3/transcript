class ModelProgress {
  final bool downloading;
  final int received;
  final int total;
  final String? error;

  const ModelProgress({
    required this.downloading,
    required this.received,
    required this.total,
    this.error,
  });

  double get percent =>
      total <= 0 ? 0.0 : (received / total).clamp(0, 1).toDouble();

  static const idle = ModelProgress(downloading: false, received: 0, total: 0);
}
