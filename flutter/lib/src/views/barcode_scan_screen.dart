import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  final _controller = MobileScannerController();
  final _manualController = TextEditingController();
  bool _handled = false;

  @override
  void dispose() {
    _manualController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Widget _manualEntry(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _manualController,
            decoration: const InputDecoration(
              labelText: 'Barcode digits (EAN)',
              hintText: 'e.g. 5901234123457',
            ),
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _submitManual(),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _submitManual,
            icon: const Icon(Icons.check),
            label: const Text('Use barcode'),
          ),
        ],
      ),
    );
  }

  void _submitManual() {
    final v = _manualController.text.trim();
    if (v.isEmpty) return;
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scan barcode')),
        body: Center(child: _manualEntry(context)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan barcode'),
        actions: [
          IconButton(
            tooltip: 'Toggle torch',
            onPressed: () => _controller.toggleTorch(),
            icon: const Icon(Icons.flashlight_on),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_handled) return;
              final barcode = capture.barcodes.isNotEmpty
                  ? capture.barcodes.first.rawValue?.trim()
                  : null;
              if (barcode == null || barcode.isEmpty) return;
              _handled = true;
              Navigator.of(context).pop(barcode);
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Card(
              margin: const EdgeInsets.all(12),
              child: _manualEntry(context),
            ),
          ),
        ],
      ),
    );
  }
}
