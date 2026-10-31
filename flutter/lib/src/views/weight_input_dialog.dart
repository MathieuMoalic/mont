import 'package:flutter/material.dart';

/// Parses a body-mass text field, accepting a comma as decimal separator.
double? parseWeightKg(String raw) {
  final v = raw.trim().replaceAll(',', '.');
  return double.tryParse(v);
}

String _fmtKg(double v) =>
    v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

/// Body-mass entry dialog shared by the Health tab chart and the Morning tab
/// weigh-in. Returns the entered kg, or null when cancelled. Stays open with
/// a hint when the value is not a valid positive number.
Future<double?> showWeightInputDialog(
  BuildContext context, {
  double? initialKg,
}) => showDialog<double>(
  context: context,
  builder: (_) => _WeightInputDialog(initialKg: initialKg),
);

class _WeightInputDialog extends StatefulWidget {
  final double? initialKg;

  const _WeightInputDialog({this.initialKg});

  @override
  State<_WeightInputDialog> createState() => _WeightInputDialogState();
}

class _WeightInputDialogState extends State<_WeightInputDialog> {
  late final TextEditingController _kgCtrl;

  @override
  void initState() {
    super.initState();
    _kgCtrl = TextEditingController(
      text: widget.initialKg == null ? '' : _fmtKg(widget.initialKg!),
    );
  }

  @override
  void dispose() {
    // Runs after the dialog's exit animation, so the field is gone and the
    // controller is safe to free.
    _kgCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final kg = parseWeightKg(_kgCtrl.text);
    if (kg == null || kg <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid body mass (kg)')),
      );
      return;
    }
    Navigator.pop(context, kg);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Log body mass'),
      content: TextFormField(
        controller: _kgCtrl,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          labelText: 'Body mass (kg)',
          suffixText: 'kg',
        ),
        onFieldSubmitted: (_) {
          final kg = parseWeightKg(_kgCtrl.text);
          if (kg != null && kg > 0) Navigator.pop(context, kg);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
