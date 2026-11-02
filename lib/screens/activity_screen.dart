import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/api_client.dart';
import '../data_collection/api/data_collection_api.dart';
import '../data_collection/screens/forms_list_screen.dart';
import '../data_collection/screens/submissions_screen.dart';
import '../data_collection/screens/sync_ui.dart';
import '../data_collection/sync/sync_coordinator.dart';
import '../db/repository.dart';
import '../learning/screens/cohorts_screen.dart';
import '../learning/screens/performance_screen.dart';
import '../theme/brand_colors.dart';
import '../widgets/app_drawer.dart';
import 'capture_screen.dart';
import 'login_screen.dart';
import 'profile_screen.dart';

const _inkSecondary = Color(0xFF52514E);
const _inkMuted = Color(0xFF898781);
const _hairline = Color(0x1A0B0B0B);

// Home: the state of the app at a glance — connection, what's waiting to
// sync (and whether anything needs fixing), today's work, quick actions,
// and the latest attendance registers. New registers start from a sheet,
// then hand off to CaptureScreen for each beneficiary row.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  final _repo = Repository();

  String _firstName = '';
  HomeSummary? _summary;
  bool _online = true;
  bool _syncing = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  @override
  void initState() {
    super.initState();
    _loadState();
    Connectivity().checkConnectivity().then(_setConnectivity);
    _connectivity = Connectivity().onConnectivityChanged.listen(_setConnectivity);
    // Automatic syncs (startup, back online, background) change the numbers.
    SyncCoordinator.instance.lastReport.addListener(_loadState);
  }

  @override
  void dispose() {
    _connectivity?.cancel();
    SyncCoordinator.instance.lastReport.removeListener(_loadState);
    super.dispose();
  }

  void _setConnectivity(List<ConnectivityResult> results) {
    if (mounted) setState(() => _online = results.any((r) => r != ConnectivityResult.none));
  }

  Future<void> _loadState() async {
    final user = await _repo.getCurrentUser();
    final summary = await _repo.homeSummary();
    if (!mounted) return;
    setState(() {
      _firstName = ((user?['name'] as String?) ?? '').split(' ').first;
      _summary = summary;
    });
  }

  // ── Actions ──

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _loadState();
  }

  Future<void> _newRegister() async {
    final register = await showModalBottomSheet<({String name, String date, String? compiledBy, String? reviewedBy})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _NewRegisterSheet(),
    );
    if (register == null) return;

    final uuid = await _repo.startActivity(
      activityName: register.name,
      activityDate: register.date,
      compiledBy: register.compiledBy,
      reviewedBy: register.reviewedBy,
    );
    if (!mounted) return;
    await _push(CaptureScreen(activityUuid: uuid, activityName: register.name));
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await _repo.syncPending();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sync complete.')));
      }
    } on AuthExpiredException {
      if (mounted) await promptReauth(context);
    } catch (e) {
      // Typically no connectivity — not an error the user needs to see in
      // detail, just that it didn't go through this time.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sync failed (will retry later): $e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
      _loadState();
    }
  }

  Future<void> _logout() async {
    await _repo.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return Scaffold(
      backgroundColor: const Color(0xFFF7F6F3),
      appBar: AppBar(
        title: const Text('Home'),
        backgroundColor: const Color(0xFFF7F6F3),
        surfaceTintColor: Colors.transparent,
      ),
      drawer: AppDrawer(onLogout: _logout, onReturn: _loadState),
      body: summary == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadState,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  _greeting(),
                  const SizedBox(height: 16),
                  _statusCard(summary),
                  const SizedBox(height: 24),
                  _sectionTitle('Today'),
                  _todayTiles(summary),
                  const SizedBox(height: 24),
                  _sectionTitle('Start something'),
                  _quickActions(),
                  const SizedBox(height: 24),
                  _sectionTitle('Recent registers'),
                  _recentRegisters(summary),
                ],
              ),
            ),
    );
  }

  Widget _greeting() {
    final hour = DateTime.now().hour;
    final hello = hour < 12 ? 'Good morning' : (hour < 17 ? 'Good afternoon' : 'Good evening');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_firstName.isEmpty ? hello : '$hello, $_firstName',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: brandInk)),
        const SizedBox(height: 2),
        Text(DateFormat('EEEE, d MMMM yyyy').format(DateTime.now()), style: const TextStyle(color: _inkSecondary)),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: brandInk)),
      );

  // The one headline number on this screen: what's waiting to be sent.
  Widget _statusCard(HomeSummary s) {
    final server = ApiClient.baseUrl?.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'/api/?$'), '');

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _StatusPill(
              icon: _online ? Icons.wifi : Icons.wifi_off,
              label: _online ? 'Online' : 'Offline',
              color: _online ? statusGood : statusCritical,
            ),
            const SizedBox(width: 8),
            if (server != null)
              Expanded(
                child: Text(server, style: const TextStyle(fontSize: 12, color: _inkMuted), overflow: TextOverflow.ellipsis),
              ),
          ]),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                NumberFormat.compact().format(s.pending),
                style: const TextStyle(fontSize: 48, height: 1, fontWeight: FontWeight.w600, color: brandInk),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    s.pending == 0 ? 'items waiting to send — everything is sent' : 'item${s.pending == 1 ? '' : 's'} waiting to send',
                    style: const TextStyle(color: _inkSecondary),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.schedule, size: 16, color: _inkMuted),
            const SizedBox(width: 6),
            Text(
              s.lastSync == null ? 'Not synced yet on this device' : 'Last synced ${_relative(s.lastSync!)}',
              style: const TextStyle(fontSize: 13, color: _inkSecondary),
            ),
          ]),
          if (s.failed > 0) ...[
            const SizedBox(height: 12),
            _AlertRow(
              icon: Icons.error_outline,
              color: statusCritical,
              text: '${s.failed} form submission${s.failed == 1 ? '' : 's'} rejected by the CRM — needs correction',
              onTap: () => _push(const SubmissionsScreen()),
            ),
          ],
          if (!_online && s.pending > 0) ...[
            const SizedBox(height: 12),
            const _AlertRow(
              icon: Icons.info_outline,
              color: statusWarning,
              text: 'You\'re offline. Everything is saved and will send when you\'re back online.',
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _syncing ? null : _syncNow,
              icon: _syncing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sync),
              label: Text(_syncing ? 'Syncing…' : 'Sync now'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _todayTiles(HomeSummary s) {
    final tiles = [
      _StatTile(label: 'Attendance captured', value: s.attendancesToday, icon: Icons.how_to_reg_outlined),
      _StatTile(label: 'Profiles captured', value: s.profilesToday, icon: Icons.badge_outlined),
      _StatTile(label: 'Forms submitted', value: s.formsToday, icon: Icons.assignment_turned_in_outlined),
      _StatTile(
        label: 'Drafts in progress',
        value: s.drafts,
        icon: Icons.edit_note,
        onTap: s.drafts > 0 ? () => _push(const SubmissionsScreen()) : null,
      ),
    ];
    return _grid(tiles, height: 108);
  }

  Widget _quickActions() => _grid([
        _ActionCard(icon: Icons.school, label: 'Courses', onTap: () => _push(const CohortsScreen())),
        _ActionCard(icon: Icons.how_to_reg, label: 'New attendance register', onTap: _newRegister),
        _ActionCard(icon: Icons.badge, label: 'New beneficiary profile', onTap: () => _push(const ProfileScreen())),
        _ActionCard(icon: Icons.assignment, label: 'Fill a form', onTap: () => _push(const FormsListScreen())),
        _ActionCard(icon: Icons.inbox, label: 'My submissions', onTap: () => _push(const SubmissionsScreen())),
        _ActionCard(icon: Icons.insights, label: 'My performance', onTap: () => _push(const PerformanceScreen())),
      ], height: 116);

  // Two columns on phones, four on wide screens (tablets, Chrome). Fixed
  // tile height so two-line labels fit on small phones too.
  Widget _grid(List<Widget> children, {required double height}) => LayoutBuilder(
        builder: (context, constraints) => GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: constraints.maxWidth >= 720 ? 4 : 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            mainAxisExtent: height,
          ),
          children: children,
        ),
      );

  Widget _recentRegisters(HomeSummary s) {
    if (s.recentRegisters.isEmpty) {
      return const _Panel(
        child: Text('No attendance registers yet. Start one above.', style: TextStyle(color: _inkMuted)),
      );
    }
    return _Panel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (i, r) in s.recentRegisters.indexed) ...[
            if (i > 0) const Divider(height: 1, color: _hairline),
            ListTile(
              title: Text(r['activityName'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, color: brandInk)),
              subtitle: Text('${r['activityDate']} · ${r['attendees']} attendee${r['attendees'] == 1 ? '' : 's'}',
                  style: const TextStyle(color: _inkSecondary)),
              trailing: r['synced'] == 1
                  ? const _StatusPill(icon: Icons.cloud_done_outlined, label: 'Sent', color: statusGood)
                  : const _StatusPill(icon: Icons.cloud_upload_outlined, label: 'Not sent', color: statusWarning),
              onTap: () => _push(CaptureScreen(activityUuid: r['clientUuid'] as String, activityName: r['activityName'] as String? ?? '')),
            ),
          ],
        ],
      ),
    );
  }

  String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return DateFormat('d MMM, HH:mm').format(t);
  }
}

// ── Building blocks ──

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
}

// Status shown as icon + label, the colour only reinforcing it.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: brandInk)),
        ]),
      );
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.icon, required this.color, required this.text, this.onTap});

  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: brandInk))),
              if (onTap != null) const Icon(Icons.chevron_right, color: _inkMuted),
            ]),
          ),
        ),
      );
}

// label · value, ink colours only; the icon is the tile's identity.
class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, required this.icon, this.onTap});

  final String label;
  final int value;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _hairline)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  Icon(icon, size: 18, color: brandPurple),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(label, style: const TextStyle(fontSize: 12, color: _inkSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ]),
                Text(NumberFormat.compact().format(value),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: brandInk)),
              ],
            ),
          ),
        ),
      );
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [brandOrange.withValues(alpha: 0.10), brandPurple.withValues(alpha: 0.10)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(colors: [brandOrange, brandPurple]),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 18, color: Colors.white),
                  ),
                  Text(label,
                      style: const TextStyle(fontWeight: FontWeight.w600, color: brandInk), maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
        ),
      );
}

// The paper register's header row; returns the values to start capturing.
class _NewRegisterSheet extends StatefulWidget {
  const _NewRegisterSheet();

  @override
  State<_NewRegisterSheet> createState() => _NewRegisterSheetState();
}

class _NewRegisterSheetState extends State<_NewRegisterSheet> {
  final _name = TextEditingController();
  final _date = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _compiledBy = TextEditingController();
  final _reviewedBy = TextEditingController();
  String? _nameError;

  @override
  void dispose() {
    for (final c in [_name, _date, _compiledBy, _reviewedBy]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_date.text) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) _date.text = DateFormat('yyyy-MM-dd').format(picked);
  }

  void _start() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter an activity name');
      return;
    }
    String? optional(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    Navigator.pop(context, (name: name, date: _date.text.trim(), compiledBy: optional(_compiledBy), reviewedBy: optional(_reviewedBy)));
  }

  @override
  Widget build(BuildContext context) {
    const border = OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)));
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('New attendance register', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: brandInk)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: 'Activity name', errorText: _nameError, border: border),
            onChanged: (_) => setState(() => _nameError = null),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _date,
            readOnly: true,
            onTap: _pickDate,
            decoration: const InputDecoration(labelText: 'Date', suffixIcon: Icon(Icons.calendar_today, size: 18), border: border),
          ),
          const SizedBox(height: 12),
          TextField(controller: _compiledBy, decoration: const InputDecoration(labelText: 'Compiled by (optional)', border: border)),
          const SizedBox(height: 12),
          TextField(controller: _reviewedBy, decoration: const InputDecoration(labelText: 'Reviewed by (optional)', border: border)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Start capturing beneficiaries'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ],
      ),
    );
  }
}
