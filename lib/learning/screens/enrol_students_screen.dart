import 'dart:async';
import 'package:flutter/material.dart';

import '../../data_collection/api/data_collection_api.dart' show ApiException, AuthExpiredException;
import '../../data_collection/screens/sync_ui.dart';
import '../../data_collection/sync/sync_runner.dart';
import '../../theme/brand_colors.dart';
import '../db/learning_store.dart';
import '../learning_setup.dart';
import '../models/learning_models.dart';
import '../widgets/learning_widgets.dart';

// Add students to a class: find someone already registered in the CRM
// (search needs a connection; name, phone and district are shown because
// names repeat), or add a new student, which works offline and becomes a
// beneficiary profile in the CRM when it uploads.
class EnrolStudentsScreen extends StatefulWidget {
  const EnrolStudentsScreen({super.key, required this.cohortUuid});

  final String cohortUuid;

  @override
  State<EnrolStudentsScreen> createState() => _EnrolStudentsScreenState();
}

class _EnrolStudentsScreenState extends State<EnrolStudentsScreen> {
  final _search = TextEditingController();
  final _setup = LearningSetup();
  LearningCohort? _cohort;
  List<Map<String, dynamic>> _results = [];
  String? _searchMessage;
  bool _searching = false;
  Timer? _debounce;
  int _added = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final c = await (await LearningStore.open()).cohort(widget.cohortUuid);
    if (mounted) setState(() => _cohort = c);
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _runSearch(q.trim()));
  }

  Future<void> _runSearch(String q) async {
    if (q.length < 2) {
      setState(() {
        _results = [];
        _searchMessage = null;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final sync = await SyncRunner.learningSync();
      if (sync == null) throw AuthExpiredException();
      final results = await sync.api.searchBeneficiaries(q);
      if (mounted) {
        setState(() {
          _results = results;
          _searchMessage = results.isEmpty ? 'No one found. Add them as a new student below.' : null;
        });
      }
    } on AuthExpiredException {
      if (mounted) await promptReauth(context);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _results = [];
          _searchMessage = e.transient
              ? 'Searching needs internet. You can still add a new student — it uploads later.'
              : e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  bool _alreadyIn(Map<String, dynamic> b) =>
      _cohort?.roster.any((s) => s.beneficiaryId != null && s.beneficiaryId == b['id']) ?? false;

  Future<void> _addExisting(Map<String, dynamic> b) async {
    await _setup.enrolExisting(_cohort!, b);
    _added++;
    await _reload();
    _show('${b['full_name']} added to the class.');
  }

  Future<void> _addNew() async {
    final student = await showModalBottomSheet<NewStudent>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _NewStudentSheet(initialName: _search.text.trim()),
    );
    if (student == null) return;
    await _setup.enrolNew(_cohort!, student);
    _added++;
    await _reload();
    _show('${student.fullName} added to the class.');
  }

  void _show(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final c = _cohort;
    final roster = c?.roster.where((s) => s.isActive).toList() ?? const <LearningStudent>[];
    return Scaffold(
      backgroundColor: const Color(0xFFF7F6F3),
      appBar: AppBar(
        title: const Text('Add students'),
        backgroundColor: const Color(0xFFF7F6F3),
        surfaceTintColor: Colors.transparent,
        actions: [
          if (_added > 0) TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
        ],
      ),
      body: c == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                TextField(
                  controller: _search,
                  onChanged: _onQuery,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searching ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : null,
                    hintText: 'Search registered youth by name or phone',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                if (_searchMessage != null)
                  Padding(padding: const EdgeInsets.only(top: 8), child: Text(_searchMessage!, style: const TextStyle(color: inkSecondary))),
                for (final b in _results)
                  Card(
                    elevation: 0,
                    color: Colors.white,
                    margin: const EdgeInsets.only(top: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: hairline)),
                    child: ListTile(
                      title: Text('${b['full_name']}', style: const TextStyle(fontWeight: FontWeight.w600, color: brandInk)),
                      subtitle: Text(
                        [
                          if (b['phone_number'] != null) '${b['phone_number']}',
                          if (b['location'] != null) '${b['location']}',
                          if (b['gender'] != null) '${b['gender']}',
                          if (b['age'] != null) '${b['age']} yrs',
                        ].join(' · '),
                        style: const TextStyle(color: inkSecondary),
                      ),
                      trailing: _alreadyIn(b)
                          ? const StatusPill(icon: Icons.check, label: 'In class', color: statusGood)
                          : FilledButton.tonal(onPressed: () => _addExisting(b), child: const Text('Add')),
                    ),
                  ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _addNew,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add a new student'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
                const SizedBox(height: 24),
                Text('In this class (${roster.length})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: brandInk)),
                const SizedBox(height: 8),
                if (roster.isEmpty) const Text('No students yet.', style: TextStyle(color: inkMuted)),
                for (final s in roster)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      const Icon(Icons.person_outline, size: 18, color: inkMuted),
                      const SizedBox(width: 8),
                      Expanded(child: Text(s.name, style: const TextStyle(color: brandInk))),
                      Text([if (s.phone != null) s.phone!, if (s.location != null) s.location!].join(' · '), style: const TextStyle(fontSize: 12, color: inkMuted)),
                    ]),
                  ),
              ],
            ),
    );
  }
}

class _NewStudentSheet extends StatefulWidget {
  const _NewStudentSheet({required this.initialName});

  final String initialName;

  @override
  State<_NewStudentSheet> createState() => _NewStudentSheetState();
}

class _NewStudentSheetState extends State<_NewStudentSheet> {
  late final _name = TextEditingController(text: RegExp(r'\d').hasMatch(widget.initialName) ? '' : widget.initialName);
  final _age = TextEditingController();
  final _phone = TextEditingController();
  final _location = TextEditingController();
  final _ref = TextEditingController();
  String? _gender;
  String? _nameError;

  @override
  void dispose() {
    for (final c in [_name, _age, _phone, _location, _ref]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter the student\'s full name');
      return;
    }
    String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    Navigator.pop(
      context,
      NewStudent(fullName: name, gender: _gender, age: int.tryParse(_age.text.trim()), phone: opt(_phone), location: opt(_location), studentRef: opt(_ref)),
    );
  }

  @override
  Widget build(BuildContext context) {
    const border = OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)));
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('New student', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: brandInk)),
            const SizedBox(height: 4),
            const Text('They will be registered as a beneficiary in the CRM.', style: TextStyle(color: inkSecondary)),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: 'Full name', errorText: _nameError, border: border),
              onChanged: (_) => setState(() => _nameError = null),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: SegmentedButton<String>(
                  emptySelectionAllowed: true,
                  showSelectedIcon: false,
                  segments: const [ButtonSegment(value: 'F', label: Text('Female')), ButtonSegment(value: 'M', label: Text('Male'))],
                  selected: {if (_gender != null) _gender!},
                  onSelectionChanged: (v) => setState(() => _gender = v.isEmpty ? null : v.first),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 90,
                child: TextField(controller: _age, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Age', border: border)),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone (optional)', border: border)),
            const SizedBox(height: 12),
            TextField(controller: _location, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'District / area (optional)', border: border)),
            const SizedBox(height: 12),
            TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Student number (optional)', border: border)),
            const SizedBox(height: 20),
            FilledButton(onPressed: _save, style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)), child: const Text('Add to class')),
          ],
        ),
      ),
    );
  }
}
