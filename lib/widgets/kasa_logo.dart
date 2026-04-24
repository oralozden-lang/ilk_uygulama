import 'package:flutter/material.dart';
import 'dart:ui' as ui;

// ─── Kasa Logo Widget ─────────────────────────────────────────────────────────

class KasaLogo extends StatelessWidget {
  const KasaLogo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: CustomPaint(painter: _KasaLogoPainter()),
    );
  }
}

class _KasaLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Dış daire
    final daiPaint = Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 56, daiPaint);

    // İç daire
    final icPaint = Paint()
      ..color = Colors.white.withOpacity(0.1)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 44, icPaint);

    // Kasa gövdesi
    final kasaPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final rr = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + 4), width: 52, height: 38),
      const Radius.circular(6),
    );
    canvas.drawRRect(rr, kasaPaint);

    // Kasa kapak çizgisi
    final cizgiPaint = Paint()
      ..color = const Color(0xFF0288D1)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(cx - 26, cy - 2),
      Offset(cx + 26, cy - 2),
      cizgiPaint,
    );

    // Kilit dairesi
    canvas.drawCircle(
      Offset(cx, cy + 8),
      6,
      Paint()
        ..color = const Color(0xFF0288D1)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(cx, cy + 8),
      3,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );

    // Para sembolleri
    final tp = TextPainter(
      text: const TextSpan(
        text: '₺',
        style: TextStyle(
          color: Color(0xFF0288D1),
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - 22, cy - 1));

    final tp2 = TextPainter(
      text: const TextSpan(
        text: '\$',
        style: TextStyle(
          color: Color(0xFF0288D1),
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp2.paint(canvas, Offset(cx + 12, cy - 1));

    // Üst çerçeve
    final cerceve = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy - 16), width: 36, height: 10),
      const Radius.circular(3),
    );
    canvas.drawRRect(
      cerceve,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );

    // Dış daire kenarlık
    canvas.drawCircle(
      Offset(cx, cy),
      56,
      Paint()
        ..color = Colors.white.withOpacity(0.4)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}
