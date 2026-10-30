import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'photo_capture.dart' show CaptureException;

// Geopoint answer in XLSForm's format: "lat lng altitude accuracy".
String formatGeopoint(Position p) => '${p.latitude} ${p.longitude} ${p.altitude} ${p.accuracy}';

// (lat, lng, accuracy in metres) from a stored answer.
(double, double, double?)? parseGeopoint(String? value) {
  final parts = (value ?? '').trim().split(RegExp(r'\s+'));
  if (parts.length < 2) return null;
  final lat = double.tryParse(parts[0]);
  final lng = double.tryParse(parts[1]);
  if (lat == null || lng == null) return null;
  return (lat, lng, parts.length > 3 ? double.tryParse(parts[3]) : null);
}

class LocationCapture {
  // Asks for permission here, at the point of use. Waits up to [timeout]
  // for a fresh fix; if none comes (indoors, weak GPS) falls back to the
  // last known position so the enumerator isn't stuck.
  static Future<Position> current({Duration timeout = const Duration(seconds: 30)}) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw CaptureException('Location is turned off. Turn on location (GPS) and try again.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      throw CaptureException('Location access was refused, so the location can\'t be recorded.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw CaptureException('Location access is blocked. Allow it for this app in the phone settings.');
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(accuracy: LocationAccuracy.high, timeLimit: timeout),
      );
    } on TimeoutException {
      final last = kIsWeb ? null : await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      throw CaptureException('Could not get a GPS fix. Move to an open area and try again.');
    }
  }

  static Future<bool> openSettings() => Geolocator.openAppSettings();
}
