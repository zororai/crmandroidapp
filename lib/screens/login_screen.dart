import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../data_collection/db/data_collection_store.dart';
import '../data_collection/media/media_files.dart';
import '../db/repository.dart';
import '../theme/brand_colors.dart';
import 'activity_screen.dart';

const _gradientStart = brandOrange;
const _gradientEnd = brandPurple;
// White matches the logo's own background, so it sits seamlessly on the page.
const _backgroundColor = Colors.white;

// reauth: opened over the app when the token has expired (401 during data
// collection sync). Skips the auto-login and server prompt, and pops with
// true on success instead of replacing the app.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.reauth = false});

  final bool reauth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _repo = Repository();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.reauth) {
      _prefillEmail();
    } else {
      _checkExistingSession();
    }
  }

  Future<void> _prefillEmail() async {
    final user = await _repo.getCurrentUser();
    if (user != null) _emailController.text = user['email'] as String? ?? '';
  }

  // Already logged in (session row exists in SQLite) — skip straight to
  // the app, works even with no connectivity.
  Future<void> _checkExistingSession() async {
    if (await _repo.isLoggedIn() && ApiClient.baseUrl != null) {
      await _repo.restoreTokenIntoMemory();
      _goToActivityScreen();
      return;
    }
    if (mounted) await _askForServer();
  }

  Future<void> _askForServer() async {
    final controller = TextEditingController(text: ApiClient.baseUrl ?? '');
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void connect() {
            final url = ApiClient.normalizeBaseUrl(controller.text);
            if (url == null) {
              setDialogState(() => error = 'Enter a valid URL or IP address');
              return;
            }
            ApiClient.saveBaseUrl(url);
            Navigator.of(context).pop();
          }

          return AlertDialog(
            title: const Text('Connect to server'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Enter the address of the CRM server.',
                  style: TextStyle(
                      fontSize: 13, color: Colors.black.withOpacity(0.6)),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => connect(),
                  decoration: InputDecoration(
                    labelText: 'Server URL or IP',
                    hintText: 'e.g. 192.168.10.149',
                    prefixIcon: const Icon(Icons.dns_outlined),
                    errorText: error,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              FilledButton(onPressed: connect, child: const Text('CONNECT')),
            ],
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (ApiClient.baseUrl == null) {
      await _askForServer();
      return;
    }
    if (email.isEmpty || password.isEmpty) {
      _showMessage('Enter email and password');
      return;
    }

    setState(() => _loading = true);
    try {
      final response = await ApiClient.login(email, password);
      if (!await _resolveQueuedSubmissions(response['user'] as Map<String, dynamic>)) return;
      await _repo.saveSessionFromLogin(response);
      if (!mounted) return;
      if (widget.reauth) {
        Navigator.of(context).pop(true);
      } else {
        _goToActivityScreen();
      }
    } on LoginRejected catch (e) {
      _showMessage(e.message);
    } catch (e) {
      // No connectivity for first login is expected — the app needs one
      // successful online login before it can work offline, since the
      // Sanctum token has to come from the server.
      _showMessage('Could not reach server: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Unsent data collection submissions belong to the user who collected
  // them and are only ever sent under that account. If someone else logs in
  // on this device, they choose: keep them locked to the original user, or
  // discard them. Returns false to cancel the login.
  Future<bool> _resolveQueuedSubmissions(Map<String, dynamic> user) async {
    final store = await DataCollectionStore.open();
    for (final other in await store.queuedForOtherOwners(user['id'] as int)) {
      if (!mounted) return false;
      final owner = other.ownerName.isEmpty ? 'another user' : other.ownerName;
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text('Unsent forms from $owner'),
          content: Text(
            'This device has ${other.count} form submission(s) collected by $owner that have not been sent. '
            'They can only be sent from $owner\'s account.\n\n'
            'Keep them for $owner to send later, or discard them permanently?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel login')),
            TextButton(onPressed: () => Navigator.pop(context, 'discard'), child: const Text('Discard')),
            FilledButton(onPressed: () => Navigator.pop(context, 'keep'), child: Text('Keep for $owner')),
          ],
        ),
      );
      if (choice == null || !mounted) return false;
      if (choice == 'discard') {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Discard ${other.count} submission(s)?'),
            content: Text('$owner\'s unsent forms and photos will be deleted from this device. This can\'t be undone.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Back')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
            ],
          ),
        );
        if (confirmed != true) return false;
        for (final path in await store.discardQueue(other.ownerUserId)) {
          await const MediaFiles().delete(path);
        }
      }
    }
    return true;
  }

  void _goToActivityScreen() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ActivityScreen()),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            // Decorative gradient blobs, matching the mockup's rotated
            // rounded-square accent behind the card's top edge.
            Positioned(
              top: -20,
              right: -30,
              child: Transform.rotate(
                angle: 0.5,
                child: Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(40),
                    gradient: const LinearGradient(
                      colors: [_gradientStart, _gradientEnd],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 30,
              right: 10,
              child: Transform.rotate(
                angle: 0.5,
                child: Container(
                  width: 130,
                  height: 130,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(32),
                    gradient: const LinearGradient(
                      colors: [_gradientStart, _gradientEnd],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                          color: _gradientEnd.withOpacity(0.3),
                          blurRadius: 30,
                          offset: const Offset(0, 15)),
                    ],
                  ),
                ),
              ),
            ),

            // Scrolls on short screens (small phones, keyboard open, short
            // browser windows) instead of overflowing; centred otherwise.
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Center(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Image.asset('assets/images/logo.png',
                                height: 120),
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          widget.reauth ? 'Log in again' : 'Login',
                          style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.reauth
                              ? 'Your session expired. Unsent forms are safe on this device.'
                              : 'Please sign in to continue',
                          style: TextStyle(
                              fontSize: 14,
                              color: Colors.black.withOpacity(0.5)),
                        ),
                        const SizedBox(height: 40),
                        _buildLabeledField(
                          label: 'EMAIL',
                          icon: Icons.email_outlined,
                          child: TextField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: const InputDecoration(
                                border: InputBorder.none, isDense: true),
                          ),
                        ),
                        const SizedBox(height: 22),
                        _buildLabeledField(
                          label: 'PASSWORD',
                          icon: Icons.lock_outline,
                          trailing: TextButton(
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                            style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero),
                            child: Text(
                              _obscurePassword ? 'SHOW' : 'HIDE',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: _gradientEnd,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          child: TextField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            decoration: const InputDecoration(
                                border: InputBorder.none, isDense: true),
                          ),
                        ),
                        const SizedBox(height: 40),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(26),
                              gradient: const LinearGradient(
                                  colors: [_gradientStart, _gradientEnd]),
                              boxShadow: [
                                BoxShadow(
                                    color: _gradientEnd.withOpacity(0.4),
                                    blurRadius: 16,
                                    offset: const Offset(0, 8)),
                              ],
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(26),
                                onTap: _loading ? null : _login,
                                child: Center(
                                  child: _loading
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white),
                                        )
                                      : const Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              'LOGIN',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 1,
                                              ),
                                            ),
                                            SizedBox(width: 8),
                                            Icon(Icons.arrow_forward,
                                                color: Colors.white, size: 18),
                                          ],
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Center(
                          child: TextButton.icon(
                            onPressed: _askForServer,
                            icon: const Icon(Icons.dns_outlined, size: 16),
                            label: Text(
                              ApiClient.baseUrl ?? 'Set server',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        if (widget.reauth)
                          Center(
                            child: TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('Not now'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLabeledField({
    required String label,
    required IconData icon,
    required Widget child,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
              fontSize: 11,
              color: Colors.black.withOpacity(0.4),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(icon, size: 18, color: Colors.black.withOpacity(0.4)),
            const SizedBox(width: 10),
            Expanded(child: child),
            if (trailing != null) trailing,
          ],
        ),
        const SizedBox(height: 8),
        Container(height: 1, color: Colors.black.withOpacity(0.12)),
      ],
    );
  }
}
