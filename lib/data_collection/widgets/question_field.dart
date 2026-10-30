import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../engine/form_engine.dart';
import '../expression/evaluator.dart';
import '../media/location_capture.dart';
import '../models/form_schema.dart';

// Human-readable answer, for the review screen and read-only views.
String displayAnswer(FormNode n, dynamic value) {
  if (isEmptyValue(value)) return '—';
  String choiceLabel(String name) => n.choices.firstWhere((c) => c.name == name, orElse: () => FormChoice(name, name)).label;
  switch (n.type) {
    case 'select_one':
      return choiceLabel(xString(value));
    case 'select_multiple':
      return xString(value).split(' ').where((s) => s.isNotEmpty).map(choiceLabel).join(', ');
    case 'geopoint':
      final g = parseGeopoint(xString(value));
      if (g == null) return xString(value);
      final (lat, lng, acc) = g;
      return '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}${acc != null ? ' (±${acc.round()} m)' : ''}';
    case 'photo':
      return 'Photo attached';
    case 'datetime':
      return xString(value).replaceFirst('T', ' ');
    default:
      return xString(value);
  }
}

// One question, rendered by type. Stateless: the screen owns the answers
// (FormEngine), the text controllers and the async capture actions, so
// widgets can be rebuilt/recycled freely by the ListView.
class QuestionField extends StatelessWidget {
  const QuestionField({
    super.key,
    required this.node,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
    this.error,
    this.readOnly = false,
    this.controller,
    this.photoPath,
    this.busy = false,
    this.onPickPhoto,
    this.onCaptureLocation,
  });

  final FormNode node;
  final String label; // with ${…} already filled in
  final String? hint;
  final dynamic value;
  final String? error;
  final bool readOnly;
  final TextEditingController? controller; // text/integer/decimal
  final String? photoPath; // file path or data: URI of the current photo
  final bool busy; // GPS fix or photo in progress
  final ValueChanged<dynamic> onChanged;
  final ValueChanged<ImageSource>? onPickPhoto;
  final VoidCallback? onCaptureLocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNote = node.type == 'note';

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: label, style: TextStyle(fontWeight: isNote ? FontWeight.normal : FontWeight.w600)),
            if (node.required != null && !isNote) const TextSpan(text: ' *', style: TextStyle(color: Colors.red)),
          ])),
          if (hint != null && hint!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(hint!, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          if (!isNote) ...[
            const SizedBox(height: 6),
            readOnly || node.readOnly
                ? Text(displayAnswer(node, value), style: theme.textTheme.bodyLarge)
                : _input(context),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(error!, style: TextStyle(fontSize: 12, color: theme.colorScheme.error)),
            ),
        ],
      ),
    );
  }

  Widget _input(BuildContext context) {
    switch (node.type) {
      case 'text':
        final multiline = node.appearance?.contains('multiline') ?? false;
        return TextField(
          controller: controller,
          maxLines: multiline ? 4 : 1,
          keyboardType: multiline ? TextInputType.multiline : TextInputType.text,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          onChanged: onChanged,
        );

      case 'integer':
      case 'decimal':
        // Stored as a number when it parses; otherwise the raw text, so
        // validation can say what's wrong.
        return TextField(
          controller: controller,
          keyboardType: TextInputType.numberWithOptions(decimal: node.type == 'decimal', signed: true),
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          onChanged: (text) {
            final t = text.trim();
            onChanged(node.type == 'integer' ? (int.tryParse(t) ?? t) : (num.tryParse(t) ?? t));
          },
        );

      case 'select_one':
        if ((node.appearance?.contains('minimal') ?? false) || node.choices.length > 12) {
          return DropdownButtonFormField<String>(
            initialValue: node.choices.any((c) => c.name == value) ? value as String : null,
            isExpanded: true,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
            items: [for (final c in node.choices) DropdownMenuItem(value: c.name, child: Text(c.label))],
            onChanged: onChanged,
          );
        }
        return Column(
          children: [
            for (final c in node.choices)
              RadioListTile<String>(
                value: c.name,
                groupValue: value as String?,
                onChanged: onChanged,
                title: Text(c.label),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            if (value != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => onChanged(null), child: const Text('Clear answer')),
              ),
          ],
        );

      case 'select_multiple':
        final selected = xString(value).split(' ').where((s) => s.isNotEmpty).toList();
        return Column(
          children: [
            for (final c in node.choices)
              CheckboxListTile(
                value: selected.contains(c.name),
                onChanged: (checked) {
                  final next = [...selected]..remove(c.name);
                  if (checked == true) next.add(c.name);
                  // Keep the form's choice order, not the tap order.
                  final ordered = node.choices.map((x) => x.name).where(next.contains);
                  onChanged(ordered.join(' '));
                },
                title: Text(c.label),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
          ],
        );

      case 'date':
      case 'time':
      case 'datetime':
        return _DateTimeInput(type: node.type, value: value as String?, onChanged: onChanged);

      case 'geopoint':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isEmptyValue(value)) Text(displayAnswer(node, value)),
            const SizedBox(height: 4),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: busy ? null : onCaptureLocation,
                icon: busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.my_location, size: 18),
                label: Text(busy ? 'Getting location…' : (isEmptyValue(value) ? 'Record location' : 'Record again')),
              ),
              if (!isEmptyValue(value) && !busy) TextButton(onPressed: () => onChanged(null), child: const Text('Clear')),
            ]),
          ],
        );

      case 'photo':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (photoPath != null) _PhotoThumbnail(path: photoPath!),
            const SizedBox(height: 4),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: busy ? null : () => onPickPhoto?.call(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: Text(photoPath == null ? 'Take photo' : 'Retake'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => onPickPhoto?.call(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('Gallery'),
              ),
              if (photoPath != null && !busy) TextButton(onPressed: () => onChanged(null), child: const Text('Remove')),
            ]),
            if (busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          ],
        );

      case 'unsupported':
        return Text('This question type (${node.sourceType}) isn\'t supported on this device yet.',
            style: const TextStyle(color: Colors.grey));

      default:
        return Text(displayAnswer(node, value));
    }
  }
}

class _DateTimeInput extends StatelessWidget {
  const _DateTimeInput({required this.type, required this.value, required this.onChanged});

  final String type;
  final String? value;
  final ValueChanged<dynamic> onChanged;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final existing = value == null ? null : DateTime.tryParse(type == 'time' ? '1970-01-01T$value' : value!);

    DateTime? date;
    if (type != 'time') {
      date = await showDatePicker(context: context, initialDate: existing ?? now, firstDate: DateTime(1900), lastDate: DateTime(now.year + 10));
      if (date == null) return;
    }
    TimeOfDay? time;
    if (type != 'date') {
      if (!context.mounted) return;
      time = await showTimePicker(context: context, initialTime: existing != null ? TimeOfDay.fromDateTime(existing) : TimeOfDay.now());
      if (time == null) return;
    }

    final hhmm = time == null ? '' : '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    onChanged(switch (type) {
      'date' => DateFormat('yyyy-MM-dd').format(date!),
      'time' => hhmm,
      _ => '${DateFormat('yyyy-MM-dd').format(date!)}T$hhmm:00',
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = value?.replaceFirst('T', ' ');
    return OutlinedButton.icon(
      onPressed: () => _pick(context),
      icon: Icon(type == 'time' ? Icons.access_time : Icons.calendar_today, size: 18),
      label: Text(shown ?? 'Select ${type == 'datetime' ? 'date & time' : type}'),
      style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft),
    );
  }
}

// Decoded at thumbnail size so full-resolution photos never sit in memory.
class _PhotoThumbnail extends StatelessWidget {
  const _PhotoThumbnail({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    const size = 160.0;
    final cacheWidth = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final Widget image = path.startsWith('data:')
        ? Image.memory(base64Decode(path.substring(path.indexOf(',') + 1)), cacheWidth: cacheWidth, fit: BoxFit.cover)
        : kIsWeb
            ? const Icon(Icons.image_outlined)
            : Image.file(File(path), cacheWidth: cacheWidth, fit: BoxFit.cover);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(width: size, height: size, child: image),
    );
  }
}
