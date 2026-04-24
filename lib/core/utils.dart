import 'package:flutter/material.dart';

// Uygulama versiyonu
const String appVersiyon = 'v1.2.0';

// Gün kapanış saati — ayarlar'dan yüklenir, varsayılan 5
int gunKapanisSaati = 5;

// Döviz cins rengi — tüm ekranlarda ortak kullanım
Color dovizRenk(String cins) {
  if (cins == 'USD') return const Color(0xFFE65100); // turuncu
  if (cins == 'EUR') return const Color(0xFF6A1B9A); // mor
  if (cins == 'GBP') return const Color(0xFF1B5E20); // yeşil
  return Colors.blueGrey[700]!;
}

Color dovizBgRenk(String cins) {
  if (cins == 'USD') return const Color(0xFFFFF8E1);
  if (cins == 'EUR') return const Color(0xFFF3E5F5);
  if (cins == 'GBP') return const Color(0xFFE8F5E9);
  return Colors.grey[100]!;
}
