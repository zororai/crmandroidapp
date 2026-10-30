import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../db/repository.dart';
import '../db/data_collection_store.dart';
import '../engine/form_engine.dart';
import '../media/location_capture.dart';
import '../media/media_files.dart';
import '../media/photo_capture.dart';
import '../models/form_schema.dart';
import '../models/submission.dart';
import '../sync/sync_coordinator.dart';
import '../widgets/question_field.dart';
import 'review_screen.dart';

const _uuidGenerator = Uuid();

// Fills one form, as a single scrolling page like the app's other forms.
// New submissions get their client_uuid on open; the row is created on the
// first answer and autosaved as a draft after every change.
class FormFillScreen extends StatefulWidget {
  const FormFillScreen({
    super.key,
    required this.formId,
    required this.formVersion,
    required this.formTitle,
    this.submissionUuid,
  });

  final int formId;
  final String formVersion;
  final String formTitle;
  final String? submissionUuid; // null = new submission

  @override
  State<FormFillScreen> createState() => _FormFillScreenState();
}

class _FormFillScreenState extends State<FormFillScreen> {
  final _repo = Repository();
  final _files = const MediaFiles();
  late DataCollectionStore _store;

  FormEngine? _engine;
  String? _loadError;
  late String _uuid;
  Submission? _existing;
  bool _created = false;
  bool _readOnly = false;
  bool _movedBackToDraft = false;
  int _userId = 0;
  String _userName = '';

  final _controllers = <String, TextEditingController>{};
  final _photoPaths = <String, String>{}; // fileName → path
  final _touched = <String>{};
  final _busy = <String>{};
  bool _showAllErrors = false;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    _store = await DataCollectionStore.open();
    final user = await _repo.getCurrentUser();
    _userId = user?['userId'] as int? ?? 0;
    _userName = user?['name'] as String? ?? '';

    if (widget.submissionUuid != null) {
      _existing = await _store.submission(widget.submissionUuid!);
    }
    final version = _existing?.formVersion ?? widget.formVersion;
    final schemaJson = await _store.schemaJson(widget.formId, version);
    if (schemaJson == null) {
      setState(() => _loadError = 'Version $version of this form is not on this device. Refresh the forms list while online.');
      return;
    }

    final schema = FormSchema.fromJson(jsonDecode(schemaJson) as Map<String, dynamic>);
    for (final m in _existing == null ? const <dynamic>[] : await _store.media(_existing!.clientUuid)) {
      _photoPaths[m.fileName] = m.path;
    }
    if (!mounted) return;
    setState(() {
      _uuid = _existing?.clientUuid ?? _uuidGenerator.v4();
      _created = _existing != null;
      _readOnly = _existing != null && !_existing!.isEditable;
      _engine = FormEngine(schema, data: _existing?.data);
    });
  }

  // ── Answers and autosave ──

  void _setAnswer(List<RepeatFrame> frames, FormNode node, dynamic value) {
    if (_readOnly) return;
    setState(() {
      _engine!.setValue(frames, node.name, value);
      _touched.add(fieldKey(frames, node.name));
    });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _save);
  }

  Future<void> _ensureCreated() async {
    if (_created) return;
    final now = DateTime.now();
    await _store.insertSubmission(Submission(
      clientUuid: _uuid,
      formId: widget.formId,
      formVersion: _engine!.schema.version.isEmpty ? widget.formVersion : _engine!.schema.version,
      formTitle: widget.formTitle,
      ownerUserId: _userId,
      ownerName: _userName,
      status: SubmissionStatus.draft,
      data: _engine!.data,
      startedAt: now,
      updatedAt: now,
    ));
    _created = true;
  }

  Future<void> _save() async {
    _saveTimer?.cancel();
    if (_readOnly || _engine == null) return;
    await _ensureCreated();
    await _store.saveDraftData(_uuid, _engine!.data, DateTime.now());

    final wasQueued = _existing != null && _existing!.status != SubmissionStatus.draft;
    if (wasQueued && !_movedBackToDraft && mounted) {
      _movedBackToDraft = true;
      _showMessage('Moved back to drafts. Finalize again to send it.');
    }
  }

  // ── Capture ──

  Future<void> _pickPhoto(List<RepeatFrame> frames, FormNode node, ImageSource source) async {
    final key = fieldKey(frames, node.name);
    setState(() => _busy.add(key));
    try {
      final photo = await PhotoCapture.pick(source);
      if (photo == null) return;
      await _ensureCreated();
      final fileName = '${_uuid}_${node.name}_${_uuidGenerator.v4().substring(0, 8)}.jpg';
      final path = await _files.save(fileName, photo.bytes, photo.mimeType);
      await _store.insertMedia(MediaRecord(
        fileName: fileName,
        clientUuid: _uuid,
        fieldName: node.name,
        path: path,
        mimeType: photo.mimeType,
        sizeBytes: photo.bytes.length,
      ));
      await _discardPhoto(_engine!.valueOf(frames, node.name) as String?);
      _photoPaths[fileName] = path;
      _setAnswer(frames, node, fileName);
    } on CaptureException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _discardPhoto(String? fileName) async {
    if (fileName == null) return;
    final media = await _store.mediaFile(fileName);
    if (media == null) return;
    await _store.deleteMedia(fileName);
    await _files.delete(media.path);
    _photoPaths.remove(fileName);
  }

  Future<void> _captureLocation(List<RepeatFrame> frames, FormNode node) async {
    final key = fieldKey(frames, node.name);
    setState(() => _busy.add(key));
    try {
      _setAnswer(frames, node, formatGeopoint(await LocationCapture.current()));
    } on CaptureException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  // ── Repeats ──

  void _addInstance(List<RepeatFrame> frames, FormNode repeat) {
    setState(() => _engine!.addRepeatInstance(frames, repeat));
    _save();
  }

  Future<void> _removeInstance(List<RepeatFrame> instanceFrames, FormNode repeat) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${repeat.label.isEmpty ? 'this entry' : repeat.label.toLowerCase()} ${instanceFrames.last.index + 1}?'),
        content: const Text('Its answers will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;

    final parent = instanceFrames.sublist(0, instanceFrames.length - 1);
    // Instances after this one shift down an index, so cached text fields
    // under this repeat would show the wrong values: rebuild them from data.
    for (final key in _controllers.keys.where((k) => k.contains('${repeat.name}[')).toList()) {
      _controllers.remove(key)!.dispose();
    }
    setState(() => _engine!.removeRepeatInstance(parent, repeat.name, instanceFrames.last.index));
    _save();
  }

  // ── Finalize ──

  Future<void> _review() async {
    await _save();
    if (!mounted) return;
    final finalize = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ReviewScreen(engine: _engine!, title: widget.formTitle)),
    );
    if (finalize == true) {
      await _finalize();
    } else {
      setState(() => _showAllErrors = true);
    }
  }

  Future<void> _finalize() async {
    final engine = _engine!;
    if (engine.validate().isNotEmpty) {
      setState(() => _showAllErrors = true);
      return;
    }
    await _ensureCreated();
    final payload = engine.payload();

    // Photos of questions that ended up hidden aren't part of the
    // submission; drop them now so they're never uploaded.
    final kept = engine.photoAnswers(payload).map((p) => p.$2).toSet();
    for (final m in await _store.media(_uuid)) {
      if (!kept.contains(m.fileName)) await _discardPhoto(m.fileName);
    }

    final location = engine.firstLocation(payload);
    await _store.finalize(_uuid, data: engine.data, payload: payload, lat: location?.$1, lng: location?.$2, now: DateTime.now());
    await SyncCoordinator.instance.onFinalized();
    if (!mounted) return;
    _showMessage('Finalized. It will be sent when the device is online.');
    Navigator.of(context).pop(true);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _saveTimer?.isActive == true) _save();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.formTitle)),
        body: _loadError != null
            ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_loadError!, textAlign: TextAlign.center)))
            : engine == null
                ? const Center(child: CircularProgressIndicator())
                : _buildForm(engine),
        bottomNavigationBar: engine == null || _readOnly
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          await _save();
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        child: const Text('Save & close'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: FilledButton(onPressed: _review, child: const Text('Review & finalize'))),
                  ]),
                ),
              ),
      ),
    );
  }

  Widget _buildForm(FormEngine engine) {
    final items = engine.renderItems();
    final (answered, total) = engine.progress();

    return Column(
      children: [
        if (!_readOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              Expanded(child: LinearProgressIndicator(value: total == 0 ? 0 : answered / total)),
              const SizedBox(width: 12),
              Text('$answered of $total', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ),
        if (_readOnly)
          _banner(context, 'This submission has been sent and can no longer be edited.'),
        if (_existing?.status == SubmissionStatus.failed && _existing?.errorReason != null && !_movedBackToDraft)
          _banner(context, 'The CRM rejected this submission: ${_existing!.errorReason}', error: true),
        if (engine.expressionErrors.isNotEmpty)
          _banner(context, 'This form has logic the app could not read, so some questions may show when they shouldn\'t. '
              'Tell the form designer: ${engine.expressionErrors.first}', error: true),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: items.length,
            itemBuilder: (context, i) => KeyedSubtree(key: ValueKey(items[i].key), child: _buildItem(engine, items[i])),
          ),
        ),
      ],
    );
  }

  Widget _banner(BuildContext context, String text, {bool error = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text),
    );
  }

  Widget _buildItem(FormEngine engine, RenderItem item) {
    final indent = EdgeInsets.only(left: (item.depth * 12).clamp(0, 36).toDouble());
    final node = item.node;

    switch (item.kind) {
      case RenderKind.group:
        return Padding(
          padding: indent.add(const EdgeInsets.only(top: 8, bottom: 12)),
          child: Text(engine.interpolate(node.label, item.frames), style: Theme.of(context).textTheme.titleLarge),
        );

      case RenderKind.repeatInstance:
        return Padding(
          padding: indent.add(const EdgeInsets.only(top: 8, bottom: 8)),
          child: Row(children: [
            Expanded(
              child: Text('${node.label.isEmpty ? node.name : node.label} ${item.frames.last.index + 1}',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (!_readOnly)
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _removeInstance(item.frames, node),
              ),
          ]),
        );

      case RenderKind.repeatAdd:
        if (_readOnly) return const SizedBox.shrink();
        return Padding(
          padding: indent.add(const EdgeInsets.only(bottom: 16)),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _addInstance(item.frames, node),
              icon: const Icon(Icons.add),
              label: Text('Add ${node.label.isEmpty ? 'entry' : node.label.toLowerCase()}'),
            ),
          ),
        );

      case RenderKind.question:
        final key = fieldKey(item.frames, node.name);
        final value = engine.valueOf(item.frames, node.name);
        final showError = _showAllErrors || _touched.contains(key);
        final controller = (node.type == 'text' || node.type == 'integer' || node.type == 'decimal')
            ? _controllers.putIfAbsent(key, () => TextEditingController(text: value == null ? '' : '$value'))
            : null;

        return Padding(
          padding: indent,
          child: QuestionField(
            node: node,
            label: engine.interpolate(node.label.isEmpty ? node.name : node.label, item.frames),
            hint: node.hint == null ? null : engine.interpolate(node.hint!, item.frames),
            value: value,
            error: showError ? engine.validateField(node, item.frames) : null,
            readOnly: _readOnly,
            controller: controller,
            photoPath: value is String ? _photoPaths[value] : null,
            busy: _busy.contains(key),
            onChanged: (v) {
              if (node.type == 'photo' && v == null) _discardPhoto(value as String?);
              _setAnswer(item.frames, node, v);
            },
            onPickPhoto: (source) => _pickPhoto(item.frames, node, source),
            onCaptureLocation: () => _captureLocation(item.frames, node),
          ),
        );
    }
  }
}
