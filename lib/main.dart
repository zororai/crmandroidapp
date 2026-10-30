import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'api/api_client.dart';
import 'screens/login_screen.dart';
import 'theme/brand_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // sqflite only ships Android/iOS/macOS implementations; desktop needs the
  // FFI factory so the same openDatabase calls work on Windows/Linux.
  // Web (Chrome) runs SQLite as WebAssembly, stored in the browser's IndexedDB.
  if (kIsWeb) {
    databaseFactory = databaseFactoryFfiWeb;
  } else if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await ApiClient.loadBaseUrl();
  runApp(const BeneficiaryApp());
}

class BeneficiaryApp extends StatelessWidget {
  const BeneficiaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Beneficiary Attendance',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: brandPurple,
          primary: brandPurple,
          secondary: brandOrange,
        ),
      ),
      home: const LoginScreen(),
    );
  }
}
