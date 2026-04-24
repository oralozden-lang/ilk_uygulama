import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../widgets/gider_turleri_kart.dart';
import '../../widgets/odeme_yontemleri_kart.dart';

class AyarlarTab extends StatelessWidget {
  const AyarlarTab({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('banknotlar')
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Hata: ${snap.error}'));
        }

        final data = snap.data?.data() as Map<String, dynamic>?;
        final List<int> mevcutBanknotlar;
        try {
          mevcutBanknotlar = (data?['liste'] as List?)
                  ?.map((e) => (e as num).toInt())
                  .toList() ??
              [200, 100, 50, 20, 10, 5];
        } catch (_) {
          return const Center(child: Text('Banknot listesi okunamadı.'));
        }
        mevcutBanknotlar.sort((a, b) => b.compareTo(a));
        final mevcutFlotSiniri = (data?['flotSiniri'] as num?)?.toInt() ?? 20;
        final tumBanknotlar = [200, 100, 50, 20, 10, 5, 1];

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Genel Ayarlar',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0288D1),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Bu ayarlar yeni açılan günler için geçerlidir. Mevcut günler etkilenmez.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 20),

              const GiderTurleriKart(),
              const SizedBox(height: 16),

              // Banknot listesi
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Banknot Değerleri',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Kasada sayılacak banknot değerleri',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: tumBanknotlar.map((b) {
                          final secili = mevcutBanknotlar.contains(b);
                          return FilterChip(
                            label: Text('$b ₺'),
                            selected: secili,
                            selectedColor:
                                const Color(0xFF0288D1).withOpacity(0.15),
                            checkmarkColor: const Color(0xFF0288D1),
                            onSelected: (v) async {
                              final yeni = List<int>.from(mevcutBanknotlar);
                              if (v) {
                                yeni.add(b);
                              } else {
                                if (yeni.length <= 1) return;
                                yeni.remove(b);
                              }
                              yeni.sort((a, b) => b.compareTo(a));
                              await FirebaseFirestore.instance
                                  .collection('ayarlar')
                                  .doc('banknotlar')
                                  .set({
                                'liste': yeni,
                                'flotSiniri': mevcutFlotSiniri
                              });
                            },
                          );
                        }).toList(),
                      ),
                      Builder(
                        builder: (context) {
                          final ozelBanknotlar = mevcutBanknotlar
                              .where((b) => !tumBanknotlar.contains(b))
                              .toList();
                          if (ozelBanknotlar.isEmpty)
                            return const SizedBox.shrink();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 10),
                              Text(
                                'Özel Değerler',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: ozelBanknotlar.map((b) {
                                  return Chip(
                                    label: Text(
                                      '$b ₺',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    backgroundColor: const Color(0xFF0288D1)
                                        .withOpacity(0.08),
                                    side: BorderSide(
                                      color: const Color(0xFF0288D1)
                                          .withOpacity(0.3),
                                    ),
                                    deleteIcon: const Icon(
                                      Icons.close,
                                      size: 16,
                                      color: Colors.redAccent,
                                    ),
                                    onDeleted: () async {
                                      if (mevcutBanknotlar.length <= 1) return;
                                      final yeni =
                                          List<int>.from(mevcutBanknotlar)
                                            ..remove(b);
                                      yeni.sort((a, b) => b.compareTo(a));
                                      await FirebaseFirestore.instance
                                          .collection('ayarlar')
                                          .doc('banknotlar')
                                          .set({
                                        'liste': yeni,
                                        'flotSiniri': mevcutFlotSiniri,
                                      });
                                    },
                                  );
                                }).toList(),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      Builder(
                        builder: (context) {
                          final ctrl = TextEditingController();
                          Future<void> ekle() async {
                            final deger = int.tryParse(ctrl.text.trim());
                            if (deger == null || deger <= 0) return;
                            if (mevcutBanknotlar.contains(deger)) {
                              ctrl.clear();
                              return;
                            }
                            final yeni = List<int>.from(mevcutBanknotlar)
                              ..add(deger);
                            yeni.sort((a, b) => b.compareTo(a));
                            await FirebaseFirestore.instance
                                .collection('ayarlar')
                                .doc('banknotlar')
                                .set({
                              'liste': yeni,
                              'flotSiniri': mevcutFlotSiniri
                            });
                            ctrl.clear();
                          }

                          return Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: ctrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Özel değer ekle (₺)',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                    suffixText: '₺',
                                  ),
                                  keyboardType: TextInputType.number,
                                  onFieldSubmitted: (_) => ekle(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: ekle,
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Ekle'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF0288D1),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Varsayılan flot sınırı
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Varsayılan Flot Sınırı',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Yeni açılan günlerde flot hesabı için kullanılır.',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: mevcutBanknotlar.map((b) {
                          final secili = b == mevcutFlotSiniri;
                          return ChoiceChip(
                            label: Text('$b ₺ ve altı'),
                            selected: secili,
                            selectedColor:
                                const Color(0xFF0288D1).withOpacity(0.15),
                            onSelected: (_) async {
                              await FirebaseFirestore.instance
                                  .collection('ayarlar')
                                  .doc('banknotlar')
                                  .set({
                                'liste': mevcutBanknotlar,
                                'flotSiniri': b,
                              });
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Gün Kapanış Saati
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Gün Kapanış Saati',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Gece bu saatten önce yapılan işlemler bir önceki güne sayılır',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 12),
                      Builder(builder: (ctx) {
                        final mevcutSaat =
                            (data?['gunKapanisSaati'] as num?)?.toInt() ?? 5;
                        return Row(
                          children: [
                            const Text('Gece '),
                            DropdownButton<int>(
                              value: mevcutSaat,
                              items: List.generate(8, (i) => i + 1)
                                  .map((s) => DropdownMenuItem(
                                      value: s, child: Text('$s:00')))
                                  .toList(),
                              onChanged: (v) async {
                                if (v == null) return;
                                await FirebaseFirestore.instance
                                    .collection('ayarlar')
                                    .doc('banknotlar')
                                    .set({'gunKapanisSaati': v},
                                        SetOptions(merge: true));
                              },
                            ),
                            const Text(' saatinden önce = önceki gün'),
                          ],
                        );
                      }),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),
              const OdemeYontemleriKart(),
              const SizedBox(height: 16),

              // KDV Oranı
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'KDV Oranı',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Şube Özet raporunda toplam cironun yanında KDVsiz tutar gösterilir.',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 12),
                      StatefulBuilder(
                        builder: (ctx, setKdv) {
                          final mevcutOran =
                              (data?['kdvOrani'] as num?)?.toDouble() ?? 10.0;
                          double seciliOran = mevcutOran;
                          return Column(
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.percent,
                                      size: 18, color: Color(0xFF0288D1)),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Oran: %${seciliOran.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14),
                                  ),
                                  const Spacer(),
                                  Text(
                                    'KDVsiz = Ciro ÷ (1 + %${seciliOran.toStringAsFixed(0)})',
                                    style: TextStyle(
                                        fontSize: 11, color: Colors.grey[600]),
                                  ),
                                ],
                              ),
                              Slider(
                                value: seciliOran,
                                min: 1,
                                max: 25,
                                divisions: 24,
                                label: '%${seciliOran.toStringAsFixed(0)}',
                                activeColor: const Color(0xFF0288D1),
                                onChanged: (v) => setKdv(() => seciliOran = v),
                                onChangeEnd: (v) async {
                                  await FirebaseFirestore.instance
                                      .collection('ayarlar')
                                      .doc('banknotlar')
                                      .update({'kdvOrani': v.roundToDouble()});
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
