import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../db/repository.dart';
import 'activity_screen.dart';

const _gradientStart = Color(0xFFFFC947);
const _gradientEnd = Color(0xFFFF8A00);
const _backgroundColor = Color(0xFFEDE6DC);

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

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
    _checkExistingSession();
  }

  // Already logged in (session row exists in SQLite) — skip straight to
  // the app, works even with no connectivity.
  Future<void> _checkExistingSession() async {
    if (await _repo.isLoggedIn()) {
      await _repo.restoreTokenIntoMemory();
      _goToActivityScreen();
    }
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      _showMessage('Enter email and password');
      return;
    }

    setState(() => _loading = true);
    try {
      final response = await ApiClient.login(email, password);
      await _repo.saveSessionFromLogin(response);
      if (mounted) _goToActivityScreen();
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

  void _goToActivityScreen() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ActivityScreen()),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
                      BoxShadow(color: _gradientEnd.withOpacity(0.3), blurRadius: 30, offset: const Offset(0, 15)),
                    ],
                  ),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 60),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Login',
                    style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Please sign in to continue',
                    style: TextStyle(fontSize: 14, color: Colors.black.withOpacity(0.5)),
                  ),
                  const SizedBox(height: 40),

                  _buildLabeledField(
                    label: 'EMAIL',
                    icon: Icons.email_outlined,
                    child: TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                    ),
                  ),
                  const SizedBox(height: 22),

                  _buildLabeledField(
                    label: 'PASSWORD',
                    icon: Icons.lock_outline,
                    trailing: TextButton(
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
                      child: Text(
                        _obscurePassword ? 'SHOW' : 'HIDE',
                        style: const TextStyle(fontSize: 11, color: _gradientEnd, fontWeight: FontWeight.bold),
                      ),
                    ),
                    child: TextField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                    ),
                  ),

                  const SizedBox(height: 40),

                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: const LinearGradient(colors: [_gradientStart, _gradientEnd]),
                        boxShadow: [
                          BoxShadow(color: _gradientEnd.withOpacity(0.4), blurRadius: 16, offset: const Offset(0, 8)),
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
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
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
                                      Icon(Icons.arrow_forward, color: Colors.white, size: 18),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
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
          style: TextStyle(fontSize: 11, color: Colors.black.withOpacity(0.4), fontWeight: FontWeight.w600, letterSpacing: 0.5),
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
