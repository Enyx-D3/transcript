class ModelDownloadState {
  final bool downloading;
  final String stage;
  final int received;
  final int total;
  final String? error;

  const ModelDownloadState({
    required this.downloading,
    required this.stage,
    required this.received,
    required this.total,
    this.error,
  });

  const ModelDownloadState.idle()
      : downloading = false,
        stage = 'idle',
        received = 0,
        total = 0,
        error = null;

  const ModelDownloadState.ready()
      : downloading = false,
        stage = 'ready',
        received = 1,
        total = 1,
        error = null;

  double get percent => total <= 0 ? 0.0 : (received / total).clamp(0, 1).toDouble();
}
