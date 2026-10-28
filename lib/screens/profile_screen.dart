import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api/api_client.dart';
import '../db/repository.dart';
import 'signature_pad.dart';

// Youth Enterprise Graduate Model: Beneficiary Profiling Tool — one screen
// mirroring the paper form's sections. Option keys (the first value in each
// pair) must match the Rule::in lists in BeneficiaryProfileController.
const _genders = [('F', 'Female'), ('M', 'Male'), ('Other', 'Other')];
const _educationLevels = [
  ('none', 'None'), ('primary', 'Primary'), ('secondary', 'Secondary'), ('tertiary', 'Tertiary'), ('other', 'Other'),
];
const _statuses = [
  ('in_school', 'In school'), ('out_of_school', 'Out of school'), ('unemployed', 'Unemployed'),
  ('self_employed', 'Self-employed'), ('employed', 'Employed'),
];
const _vulnerability = [
  ('adolescent_girl', 'Adolescent girl/young woman (15–30 yrs)'),
  ('disability', 'Person with disability'),
  ('rural_underserved', 'Lives in rural/underserved area'),
  ('orphan_single_parent_child_headed', 'Orphaned/single parent/child-headed'),
  ('early_marriage_gbv_risk', 'At risk of early marriage/GBV'),
  ('minority_group', 'Member of minority/vulnerable group'),
];
const _skills = [
  ('tailoring', 'Tailoring'), ('ict_digital', 'ICT/Digital'), ('agriculture', 'Agriculture'),
  ('handicrafts', 'Handicrafts'), ('hair_dressing', 'Hair dressing'), ('cosmetology', 'Cosmetology'),
  ('mechanics', 'Mechanics'), ('building', 'Building'), ('carpentry', 'Carpentry'),
  ('food_processing', 'Food Processing'), ('nurse_aide', 'Nurse aide'), ('teaching', 'Teaching'),
  ('hotel_catering', 'Hotel and Catering'), ('baking', 'Baking'), ('welding', 'Welding'),
  ('graphic_design', 'Graphic Designing'),
];
const _entrepreneurship = [
  ('none', 'None'), ('small_business', 'Small Business'), ('informal_trade', 'Informal Trade'), ('other', 'Other'),
];
const _financialServices = [
  ('bank', 'Bank'), ('mobile_money', 'Mobile Money'), ('savings_group', 'Savings Group'), ('none', 'None'),
];
const _literacy = [('low', 'Low'), ('medium', 'Moderate'), ('high', 'High')];
const _lowMediumHigh = [('low', 'Low'), ('medium', 'Medium'), ('high', 'High')];
const _leadership = [('none', 'None'), ('community', 'Community-based'), ('school', 'School-based'), ('other', 'Other')];
const _communication = [('sms', 'SMS'), ('call', 'Call'), ('whatsapp', 'WhatsApp')];

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _repo = Repository();
  final _signatureController = SignaturePadController();

  final _fullNameController = TextEditingController();
  final _ageController = TextEditingController();
  final _locationController = TextEditingController();
  final _phoneController = TextEditingController();
  final _altContactController = TextEditingController();
  final _caregiverNameController = TextEditingController();
  final _caregiverContactController = TextEditingController();
  final _dependentsController = TextEditingController();
  final _incomeSourceController = TextEditingController();
  final _monthlyIncomeController = TextEditingController();
  final _businessIdeaController = TextEditingController();
  final _signedDateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _phoneFocusNode = FocusNode();

  // Single-choice answers and yes/no answers, keyed by API field name.
  final _choices = <String, String?>{};
  final _yesNo = <String, bool?>{};
  final _vulnerabilitySelected = <String>{};
  final _skillsSelected = <String>{};
  final _financialSelected = <String>{};

  bool? _consentGiven;
  String _phoneLookupResult = '';

  @override
  void initState() {
    super.initState();
    _phoneFocusNode.addListener(() {
      if (!_phoneFocusNode.hasFocus) _checkPhoneNumber();
    });
  }

  Future<void> _checkPhoneNumber() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) return;

    final local = await _repo.findLocalProfilesByPhone(phone);
    if (local.isNotEmpty) {
      setState(() {
        _phoneLookupResult = 'Profiled offline already: ${local.first['fullName']} (${local.first['capturedAt']})';
      });
      return;
    }

    try {
      final results = await ApiClient.searchProfilesByPhone(phone);
      setState(() {
        _phoneLookupResult = results.isNotEmpty
            ? 'Already profiled on server: ${results.first['full_name']}'
            : 'No existing profile for this number.';
      });
    } catch (e) {
      setState(() => _phoneLookupResult = 'Offline — could not check server profiles.');
    }
  }

  String? _text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    final fullName = _text(_fullNameController);
    if (fullName == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name is required')));
      return;
    }

    final age = int.tryParse(_ageController.text.trim());
    final answers = <String, dynamic>{
      'consent_given': _consentGiven,
      'full_name': fullName,
      'age': age,
      'gender': _choices['gender'],
      'location': _text(_locationController),
      'phone_number': _text(_phoneController),
      'alternative_contact': _text(_altContactController),
      'caregiver_name': _isMinor ? _text(_caregiverNameController) : null,
      'caregiver_contact': _isMinor ? _text(_caregiverContactController) : null,
      'education_level': _choices['education_level'],
      'current_status': _choices['current_status'],
      'household_head': _yesNo['household_head'],
      'dependents': int.tryParse(_dependentsController.text.trim()),
      'vulnerability': _vulnerabilitySelected.toList(),
      'current_income_source': _text(_incomeSourceController),
      'average_monthly_income': num.tryParse(_monthlyIncomeController.text.trim()),
      'skill_interests': _skillsSelected.toList(),
      'entrepreneurship_experience': _choices['entrepreneurship_experience'],
      'business_idea': _text(_businessIdeaController),
      'financial_services_access': _financialSelected.toList(),
      'financial_literacy': _choices['financial_literacy'],
      'needs_startup_capital': _yesNo['needs_startup_capital'],
      'interested_in_savings': _yesNo['interested_in_savings'],
      'decision_making_confidence': _choices['decision_making_confidence'],
      'leadership_experience': _choices['leadership_experience'],
      'has_mentorship_access': _yesNo['has_mentorship_access'],
      'interested_in_stem': _yesNo['interested_in_stem'],
      'needs_safe_spaces': _yesNo['needs_safe_spaces'],
      'has_market_access': _yesNo['has_market_access'],
      'member_of_youth_group': _yesNo['member_of_youth_group'],
      'interested_in_incubation': _yesNo['interested_in_incubation'],
      'scaling_potential': _choices['scaling_potential'],
      'consent_to_participate': _yesNo['consent_to_participate'],
      'preferred_communication': _choices['preferred_communication'],
      'signed_date': _text(_signedDateController),
    };

    final signaturePng = await _signatureController.exportPng();
    await _repo.captureProfile(answers: answers, signaturePng: signaturePng);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Profile saved: $fullName')));
    _clearForm();
  }

  void _clearForm() {
    setState(() {
      for (final c in [
        _fullNameController, _ageController, _locationController, _phoneController, _altContactController,
        _caregiverNameController, _caregiverContactController, _dependentsController, _incomeSourceController,
        _monthlyIncomeController, _businessIdeaController,
      ]) {
        c.clear();
      }
      _signedDateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
      _choices.clear();
      _yesNo.clear();
      _vulnerabilitySelected.clear();
      _skillsSelected.clear();
      _financialSelected.clear();
      _consentGiven = null;
      _phoneLookupResult = '';
      _signatureController.clear();
    });
  }

  bool get _isMinor {
    final age = int.tryParse(_ageController.text.trim());
    return age != null && age < 18;
  }

  // ── Form building blocks ──

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      );

  Widget _field(TextEditingController c, String label, {TextInputType? keyboard, FocusNode? focusNode, ValueChanged<String>? onChanged}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: c,
          focusNode: focusNode,
          keyboardType: keyboard,
          onChanged: onChanged,
          decoration: InputDecoration(labelText: label),
        ),
      );

  Widget _question(String label, Widget options) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text(label), const SizedBox(height: 4), options],
        ),
      );

  // Tapping the selected chip again clears the answer, so a mis-tap can be undone.
  Widget _single(String label, String key, List<(String, String)> options) => _question(
        label,
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final (value, text) in options)
              ChoiceChip(
                label: Text(text),
                selected: _choices[key] == value,
                onSelected: (on) => setState(() => _choices[key] = on ? value : null),
              ),
          ],
        ),
      );

  Widget _multi(String label, Set<String> selected, List<(String, String)> options) => _question(
        label,
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final (value, text) in options)
              FilterChip(
                label: Text(text),
                selected: selected.contains(value),
                onSelected: (on) => setState(() => on ? selected.add(value) : selected.remove(value)),
              ),
          ],
        ),
      );

  Widget _yesNoChips(bool? value, ValueChanged<bool?> onChanged) => Wrap(
        spacing: 8,
        children: [
          ChoiceChip(label: const Text('Yes'), selected: value == true, onSelected: (on) => onChanged(on ? true : null)),
          ChoiceChip(label: const Text('No'), selected: value == false, onSelected: (on) => onChanged(on ? false : null)),
        ],
      );

  Widget _yesNoQuestion(String label, String key) =>
      _question(label, _yesNoChips(_yesNo[key], (v) => setState(() => _yesNo[key] = v)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Beneficiary Profiling')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Youth Enterprise Graduate Model',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Read the introduction to the participant: they have the right to choose whether or not to '
              'provide their information, and are free to withdraw at any time without any negative consequences.',
              style: TextStyle(color: Colors.grey),
            ),
            _question(
              'Do you consent to provide your information?',
              _yesNoChips(_consentGiven, (v) => setState(() => _consentGiven = v)),
            ),
            if (_consentGiven == false)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No consent — do not collect any information.', style: TextStyle(color: Colors.red)),
              ),
            if (_consentGiven == true) ..._formBody(),
          ],
        ),
      ),
    );
  }

  List<Widget> _formBody() => [
        _section('Basic Information'),
        _field(_fullNameController, 'Name'),
        _field(_ageController, 'Age', keyboard: TextInputType.number, onChanged: (_) => setState(() {})),
        _single('Gender', 'gender', _genders),
        const SizedBox(height: 8),
        _field(_locationController, 'Location (District/Ward/Village)'),
        _field(_phoneController, 'Contact (Phone)', keyboard: TextInputType.phone, focusNode: _phoneFocusNode),
        if (_phoneLookupResult.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_phoneLookupResult, style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.grey)),
          ),
        _field(_altContactController, 'Alternative contact'),
        if (_isMinor) ...[
          _field(_caregiverNameController, 'Caregiver/Parent name'),
          _field(_caregiverContactController, 'Caregiver/Parent contact', keyboard: TextInputType.phone),
        ],
        _single('Education level', 'education_level', _educationLevels),
        _single('Current status', 'current_status', _statuses),
        _yesNoQuestion('Household head', 'household_head'),
        const SizedBox(height: 8),
        _field(_dependentsController, 'Dependents', keyboard: TextInputType.number),

        _section('Section 1: Vulnerability & Target Group'),
        _multi('Tick all that apply', _vulnerabilitySelected, _vulnerability),

        _section('Section 2: Skills & Livelihoods'),
        _field(_incomeSourceController, 'Current income source'),
        _field(_monthlyIncomeController, 'Average monthly income', keyboard: const TextInputType.numberWithOptions(decimal: true)),
        _multi('Skill interests', _skillsSelected, _skills),
        _single('Entrepreneurship experience', 'entrepreneurship_experience', _entrepreneurship),
        const SizedBox(height: 8),
        _field(_businessIdeaController, 'Business idea / interest area'),

        _section('Section 3: Financial Inclusion & Support Needs'),
        _multi('Access to financial services', _financialSelected, _financialServices),
        _single('Financial literacy level', 'financial_literacy', _literacy),
        _yesNoQuestion('Need start-up capital', 'needs_startup_capital'),
        _yesNoQuestion('Interested in savings/microfinance', 'interested_in_savings'),

        _section('Section 4: Empowerment & Personal Development'),
        _single('Confidence in decision-making', 'decision_making_confidence', _lowMediumHigh),
        _single('Leadership experience', 'leadership_experience', _leadership),
        _yesNoQuestion('Access to mentorship/role models', 'has_mentorship_access'),
        _yesNoQuestion('Interest in digital/STEM training', 'interested_in_stem'),
        _yesNoQuestion('Need safe mentorship/learning spaces', 'needs_safe_spaces'),

        _section('Section 5: Market Linkages & Growth'),
        _yesNoQuestion('Access to local markets', 'has_market_access'),
        _yesNoQuestion('Member of youth/cooperative groups', 'member_of_youth_group'),
        _yesNoQuestion('Interest in business incubation/mentorship', 'interested_in_incubation'),
        _single('Business scaling potential', 'scaling_potential', _lowMediumHigh),

        _section('Section 6: Consent & Communication'),
        _yesNoQuestion('Consent to participate', 'consent_to_participate'),
        _single('Preferred communication', 'preferred_communication', _communication),
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
        _field(_signedDateController, 'Date (yyyy-MM-dd)'),
        const SizedBox(height: 16),
        FilledButton(onPressed: _save, child: const Text('Save and Profile Next Beneficiary')),
      ];
}
