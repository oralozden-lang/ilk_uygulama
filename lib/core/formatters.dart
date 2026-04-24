import 'package:flutter/services.dart';

// ─── İlk Harf Büyük Formatter ───────────────────────────────────────────────

class IlkHarfBuyukFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;
    final words = newValue.text.split(' ');
    final result = words.map((word) {
      if (word.isEmpty) return word;
      // Türkçe i → İ
      final ilk = word[0] == 'i' ? 'İ' : word[0].toUpperCase();
      return ilk + word.substring(1);
    }).join(' ');
    return newValue.copyWith(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
  }
}

// ─── Bin Ayracı Formatter ────────────────────────────────────────────────────

class BinAraciFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;

    String raw = newValue.text.replaceAll('.', '').replaceAll(',', '.');

    final parts = raw.split('.');
    String intPart = parts[0];
    String decPart = parts.length > 1 ? parts[1] : '';
    if (decPart.length > 2) decPart = decPart.substring(0, 2);

    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write('.');
      buffer.write(intPart[i]);
    }

    String result = buffer.toString();
    if (parts.length > 1) result += ',$decPart';

    return TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
  }
}
