import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// Minimal finger-drawn signature pad — matches the paper register's
// "Signature" column. Tracks strokes as a list of point-lists, paints
// them, and exports to PNG bytes via RenderRepaintBoundary on save.
class SignaturePad extends StatefulWidget {
  const SignaturePad({super.key, required this.controller});

  final SignaturePadController controller;

  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class SignaturePadController {
  final key = GlobalKey();
  final List<List<Offset>> strokes = [];
  VoidCallback? _onClear;

  void clear() {
    strokes.clear();
    _onClear?.call();
  }

  bool get isEmpty => strokes.isEmpty;

  Future<Uint8List?> exportPng() async {
    if (isEmpty) return null;
    final boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }
}

class _SignaturePadState extends State<SignaturePad> {
  @override
  void initState() {
    super.initState();
    widget.controller._onClear = () => setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: widget.controller.key,
      child: GestureDetector(
        onPanStart: (details) => setState(() {
          widget.controller.strokes.add([details.localPosition]);
        }),
        onPanUpdate: (details) => setState(() {
          widget.controller.strokes.last.add(details.localPosition);
        }),
        child: Container(
          color: Colors.white,
          child: CustomPaint(
            painter: _SignaturePainter(widget.controller.strokes),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.strokes);
  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      for (var i = 0; i < stroke.length - 1; i++) {
        canvas.drawLine(stroke[i], stroke[i + 1], paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => true;
}
