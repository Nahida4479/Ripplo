import 'package:flutter_zxing/scanner.dart';
import 'package:material_ui/material_ui.dart';

class QrScanner extends StatefulWidget {
  const QrScanner({super.key, required this.onCode, required this.onError});

  final ValueChanged<String> onCode;
  final VoidCallback onError;

  @override
  State<QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<QrScanner> {
  late final ScannerController _controller = ScannerController(
    formats: {BarcodeFormat.qrCode},
    detection: DetectionMode.continuous,
    scanWindow: const ScanWindow.full(),
  );
  bool _failed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _error(BuildContext context, ScannerException error) {
    if (!_failed) {
      _failed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onError();
      });
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) => BarcodeScanner(
    controller: _controller,
    onDetect: (capture) => widget.onCode(capture.barcode.text),
    overlayBuilder: (context, layout) => const SizedBox.shrink(),
    placeholderBuilder: (context) => const SizedBox.shrink(),
    errorBuilder: _error,
    tapToFocus: true,
    pinchToZoom: false,
  );
}
