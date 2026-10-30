import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

import '../config.dart';

class CapturedPhoto {
  const CapturedPhoto(this.bytes, this.mimeType);

  final Uint8List bytes;
  final String mimeType;
}

// Thrown with a message that can be shown to the user as-is.
class CaptureException implements Exception {
  CaptureException(this.message);
  final String message;

  @override
  String toString() => message;
}

// Camera/gallery → JPEG of at most maxPhotoBytes. The picker already scales
// to 1920px; on Android the result is recompressed at falling quality and
// size until it fits. Chrome skips compression (flutter_image_compress
// doesn't run there) and relies on the picker's own scaling.
class PhotoCapture {
  static final _picker = ImagePicker();

  // Null when the user backs out of the camera/gallery.
  static Future<CapturedPhoto?> pick(ImageSource source, {int maxBytes = maxPhotoBytes}) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(source: source, maxWidth: 1920, maxHeight: 1920, imageQuality: 85);
    } on PlatformException catch (e) {
      // image_picker asks for the camera permission itself (it's declared in
      // the manifest); a refusal comes back as this code.
      if (e.code == 'camera_access_denied') {
        throw CaptureException('Camera access was refused. Allow it in the phone settings to take photos.');
      }
      if (e.code == 'photo_access_denied') {
        throw CaptureException('Photo access was refused. Allow it in the phone settings to choose a photo.');
      }
      throw CaptureException('Could not open the ${source == ImageSource.camera ? 'camera' : 'gallery'}.');
    }
    if (file == null) return null;

    if (kIsWeb) return CapturedPhoto(await file.readAsBytes(), 'image/jpeg');

    // Shrink in steps; the original never needs to be held in memory.
    for (final (width, quality) in [(1920, 80), (1600, 70), (1280, 60), (1024, 50), (800, 40)]) {
      final bytes = await FlutterImageCompress.compressWithFile(file.path, minWidth: width, minHeight: width, quality: quality);
      if (bytes != null && bytes.length <= maxBytes) return CapturedPhoto(bytes, 'image/jpeg');
    }
    throw CaptureException('The photo is too large even after compression. Try again closer to the subject.');
  }
}
