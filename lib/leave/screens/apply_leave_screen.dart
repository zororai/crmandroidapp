import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data_collection/api/data_collection_api.dart' show ApiException;
import '../../learning/widgets/learning_widgets.dart' show inkMuted, inkSecondary;
import '../api/leave_api.dart';
import '../models/leave_models.dart';
import '../widgets/leave_widgets.dart';

// Apply for leave. The working-day count updates as dates change, using the
// server's count (which knows public holidays); offline it falls back to
// counting weekdays and says so. The server re-checks everything on submit.
class ApplyLeaveScreen extends StatefulWidget {
  const ApplyLeaveScreen({super.key, this.balances = const []});

  final List<LeaveBalance> balances;

  @override
  State<ApplyLeaveScreen> createState() => _ApplyLeaveScreenState();
}

class _ApplyLeaveScreenState extends State<ApplyLeaveScreen> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();

  List<LeaveType> _types = [];
  LeaveType? _type;
  DateTimeRange? _range;
  int? _days;
  bool _daysEstimated = false;
  bool _countingDays = false;
  Uint8List? _attachment;
  String? _attachmentName;

  bool _loading = true;
  Object? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadTypes();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _loadTypes() async {
    try {
      final types = await leaveCall(context, () async => (await createLeaveApi()).types());
      if (!mounted || types == null) return;
      setState(() {
        _types = types;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  LeaveBalance? get _balance => _type == null ? null : widget.balances.where((b) => b.type.id == _type!.id).firstOrNull;

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _range,
      helpText: 'First and last day of leave',
    );
    if (picked == null) return;
    setState(() {
      _range = picked;
      _days = null;
    });
    _countDays();
  }

  Future<void> _countDays() async {
    final range = _range;
    if (range == null) return;
    setState(() => _countingDays = true);
    int days;
    var estimated = false;
    try {
      days = await (await createLeaveApi()).workingDays(range.start, range.end);
    } catch (_) {
      days = countWeekdays(range.start, range.end);
      estimated = true;
    }
    if (!mounted || range != _range) return;
    setState(() {
      _days = days;
      _daysEstimated = estimated;
      _countingDays = false;
    });
  }

  Future<void> _pickAttachment(ImageSource source) async {
    final file = await ImagePicker().pickImage(source: source, imageQuality: 80, maxWidth: 2000);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) {
      if (mounted) showLeaveSnack(context, 'That photo is over 5 MB. Try again with a smaller one.');
      return;
    }
    setState(() {
      _attachment = bytes;
      _attachmentName = file.name;
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_range == null) {
      showLeaveSnack(context, 'Pick the dates of your leave.');
      return;
    }
    if (_type!.requiresAttachment && _attachment == null) {
      showLeaveSnack(context, '${_type!.name} leave needs a supporting document. Add a photo of it.');
      return;
    }

    setState(() => _sending = true);
    try {
      final created = await leaveCall(
        context,
        () async => (await createLeaveApi()).apply(LeaveApplication(
          typeId: _type!.id,
          start: _range!.start,
          end: _range!.end,
          reason: _reason.text,
          attachmentBytes: _attachment,
          attachmentName: _attachmentName,
        )),
      );
      if (created == null || !mounted) return;
      showLeaveSnack(context, 'Leave request sent. ${created.days == 0 ? '' : '${daysLabel(created.days)}. '}Your manager has been told.');
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) showLeaveSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: leaveBackground,
      appBar: AppBar(title: const Text('Apply for leave'), backgroundColor: leaveBackground, surfaceTintColor: Colors.transparent),
      body: RefreshIndicator(
        onRefresh: _loadTypes,
        child: LeaveStateView(
          loading: _loading,
          error: _error,
          isEmpty: _types.isEmpty,
          emptyIcon: Icons.beach_access_outlined,
          emptyText: 'No leave types are open for applications. Ask your administrator.',
          onRetry: () {
            setState(() => _loading = true);
            _loadTypes();
          },
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<LeaveType>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: 'Leave type', border: OutlineInputBorder(), filled: true, fillColor: Colors.white),
                  items: [for (final t in _types) DropdownMenuItem(value: t, child: Text(t.name))],
                  onChanged: (t) => setState(() => _type = t),
                  validator: (t) => t == null ? 'Pick a leave type.' : null,
                ),
                if (_balance != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _balance!.available == null
                        ? 'Unpaid leave: no limit.'
                        : '${formatDays(_balance!.available!)} day(s) available${_balance!.pending > 0 ? ' after your pending requests' : ''}.',
                    style: const TextStyle(fontSize: 12, color: inkSecondary),
                  ),
                ],
                if (_type?.requiresAttachment == true) ...[
                  const SizedBox(height: 6),
                  const Text('Needs a supporting document (e.g. a doctor\'s note).', style: TextStyle(fontSize: 12, color: inkSecondary)),
                ],
                const SizedBox(height: 16),
                _DatesField(range: _range, onTap: _pickDates),
                const SizedBox(height: 8),
                _DayCount(days: _days, counting: _countingDays, estimated: _daysEstimated, hasRange: _range != null),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _reason,
                  maxLines: 3,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: 'Reason (optional)', border: OutlineInputBorder(), filled: true, fillColor: Colors.white),
                ),
                const SizedBox(height: 8),
                _AttachmentField(
                  name: _attachmentName,
                  onCamera: () => _pickAttachment(ImageSource.camera),
                  onGallery: () => _pickAttachment(ImageSource.gallery),
                  onRemove: () => setState(() {
                    _attachment = null;
                    _attachmentName = null;
                  }),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _sending ? null : _submit,
                  icon: _sending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send),
                  label: Text(_sending ? 'Sending…' : 'Send request'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DatesField extends StatelessWidget {
  const _DatesField({required this.range, required this.onTap});

  final DateTimeRange? range;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Dates',
            border: OutlineInputBorder(),
            filled: true,
            fillColor: Colors.white,
            suffixIcon: Icon(Icons.date_range),
          ),
          child: Text(
            range == null ? 'Tap to pick the first and last day' : formatDateRange(range!.start, range!.end),
            style: TextStyle(color: range == null ? inkMuted : null),
          ),
        ),
      );
}

class _DayCount extends StatelessWidget {
  const _DayCount({required this.days, required this.counting, required this.estimated, required this.hasRange});

  final int? days;
  final bool counting;
  final bool estimated;
  final bool hasRange;

  @override
  Widget build(BuildContext context) {
    if (!hasRange) return const SizedBox.shrink();
    if (counting || days == null) {
      return const Row(children: [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 8),
        Text('Counting working days…', style: TextStyle(color: inkSecondary)),
      ]);
    }
    return Text(
      days == 0
          ? 'These dates are all weekends or public holidays.'
          : '${daysLabel(days!)}${estimated ? ' (weekends only — public holidays will be taken off when you send it)' : ', not counting weekends and public holidays'}',
      style: TextStyle(fontWeight: FontWeight.w600, color: days == 0 ? Theme.of(context).colorScheme.error : null),
    );
  }
}

class _AttachmentField extends StatelessWidget {
  const _AttachmentField({required this.name, required this.onCamera, required this.onGallery, required this.onRemove});

  final String? name;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    if (name != null) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.attach_file),
        title: Text(name!, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: const Text('Supporting document'),
        trailing: IconButton(tooltip: 'Remove', icon: const Icon(Icons.close), onPressed: onRemove),
      );
    }
    return Wrap(spacing: 8, children: [
      OutlinedButton.icon(onPressed: onCamera, icon: const Icon(Icons.photo_camera_outlined), label: const Text('Photo of document')),
      OutlinedButton.icon(onPressed: onGallery, icon: const Icon(Icons.photo_library_outlined), label: const Text('From gallery')),
    ]);
  }
}
