import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../db/repository.dart';
import 'signature_pad.dart';

// One screen per beneficiary row on the paper register: full name, sex,
// age, district, phone number, ID/DOB, signature. Typing a phone number
// shows whether this person was already captured — checking the local
// offline copy first so it works with no signal, then also checking the
// server if online.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.activityUuid, required this.activityName});

  final String activityUuid;
  final String activityName;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _repo = Repository();
  final _signatureController = SignaturePadController();

  final _fullNameController = TextEditingController();
  final _ageController = TextEditingController();
  final _districtController = TextEditingController();
  final _phoneController = TextEditingController();
  final _idOrDobController = TextEditingController();
  final _phoneFocusNode = FocusNode();

  String _sex = 'M';
  String _phoneLookupResult = '';

  @override
  void initState() {
    super.initState();
    _phoneFocusNode.addListener(() {
      if (!_phoneFocusNode.hasFocus) _checkPhoneNumber();
    });
  }

  // The "show me the entered number" lookup: local offline cache first,
  // then the server if reachable.
  Future<void> _checkPhoneNumber() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) return;

    final local = await _repo.findLocalByPhone(phone);
    if (local.isNotEmpty) {
      setState(() {
        _phoneLookupResult = 'Captured offline already: ${local.first['fullName']} (${local.first['capturedAt']})';
      });
      return;
    }

    try {
      final results = await ApiClient.searchByPhone(phone);
      setState(() {
        _phoneLookupResult = results.isNotEmpty
            ? 'Found on server: ${results.first['full_name']}, last seen ${results.first['activity_date']}'
            : 'No previous record found for this number.';
      });
    } catch (e) {
      setState(() => _phoneLookupResult = 'Offline — could not check server history.');
    }
  }

  Future<void> _saveAndClearForm() async {
    final fullName = _fullNameController.text.trim();
    if (fullName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Full name is required')));
      return;
    }

    final signaturePng = await _signatureController.exportPng();

    await _repo.captureAttendance(
      activityUuid: widget.activityUuid,
      fullName: fullName,
      sex: _sex,
      age: int.tryParse(_ageController.text.trim()),
      district: _districtController.text.trim().isEmpty ? null : _districtController.text.trim(),
      phoneNumber: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
      idNumberOrDob: _idOrDobController.text.trim().isEmpty ? null : _idOrDobController.text.trim(),
      signaturePng: signaturePng,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved: $fullName')));
    _clearForm();
  }

  void _clearForm() {
    setState(() {
      _fullNameController.clear();
      _ageController.clear();
      _districtController.clear();
      _phoneController.clear();
      _idOrDobController.clear();
      _phoneLookupResult = '';
      _signatureController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.activityName)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(controller: _fullNameController, decoration: const InputDecoration(labelText: 'Full name')),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('Male'),
                    value: 'M',
                    groupValue: _sex,
                    onChanged: (v) => setState(() => _sex = v!),
                  ),
                ),
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('Female'),
                    value: 'F',
                    groupValue: _sex,
                    onChanged: (v) => setState(() => _sex = v!),
                  ),
                ),
              ],
            ),
            TextField(
              controller: _ageController,
              decoration: const InputDecoration(labelText: 'Age'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(controller: _districtController, decoration: const InputDecoration(labelText: 'District')),
            const SizedBox(height: 8),
            TextField(
              controller: _phoneController,
              focusNode: _phoneFocusNode,
              decoration: const InputDecoration(labelText: 'Phone number'),
              keyboardType: TextInputType.phone,
            ),
            if (_phoneLookupResult.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_phoneLookupResult, style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.grey)),
              ),
            const SizedBox(height: 8),
            TextField(controller: _idOrDobController, decoration: const InputDecoration(labelText: 'ID number / date of birth')),
            const SizedBox(height: 16),
            const Text('Signature'),
            const SizedBox(height: 4),
            Container(
              height: 150,
              decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
              child: SignaturePad(controller: _signatureController),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _signatureController.clear()),
                child: const Text('Clear Signature'),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _saveAndClearForm, child: const Text('Save and Add Next Beneficiary')),
          ],
        ),
      ),
    );
  }
}
