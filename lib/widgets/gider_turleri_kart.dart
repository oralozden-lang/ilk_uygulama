import '../core/formatters.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class GiderTurleriKart extends StatefulWidget {
  const GiderTurleriKart();

  @override
  State<GiderTurleriKart> createState() => GiderTurleriKartState();
}

class GiderTurleriKartState extends State<GiderTurleriKart> {
  static const _docPath = 'ayarlar';
  static const _docId = 'giderTurleri';

  static const List<String> _varsayilanlar = [
    'Royalty',
    'Komisyon',
    'Kira',
    'Elektrik',
    'Su',
    'Doğalgaz',
    'Telefon / İnternet',
    'Sigorta',
    'Muhasebe',
    'Temizlik',
  ];

  Future<List<String>> _oku() async {
    final doc =
        await FirebaseFirestore.instance.collection(_docPath).doc(_docId).get();
    if (!doc.exists || doc.data() == null) return List.from(_varsayilanlar);
    final liste =
        (doc.data()!['liste'] as List?)?.map((e) => e.toString()).toList();
    final sonuc = liste ?? List.from(_varsayilanlar);
    sonuc.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sonuc;
  }

  Future<void> _kaydet(List<String> liste) async {
    await FirebaseFirestore.instance.collection(_docPath).doc(_docId).set({
      'liste': liste,
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _oku(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final liste = List<String>.from(snap.data ?? _varsayilanlar);

        return StatefulBuilder(
          builder: (context, setS) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Gider Türleri',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Projeksiyon ve Diğer Alımlar alanlarında açılır listede gösterilir.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 12),
                  ...liste.asMap().entries.map((e) {
                    final idx = e.key;
                    final ad = e.value;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.grey.withOpacity(0.25),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.label_outline,
                            size: 16,
                            color: Color(0xFF0288D1),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ad,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () async {
                              final yeni = List<String>.from(liste)
                                ..removeAt(idx);
                              await _kaydet(yeni);
                              setS(() {
                                liste.clear();
                                liste.addAll(yeni);
                              });
                            },
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: Colors.redAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  Builder(
                    builder: (context) {
                      final ctrl = TextEditingController();
                      Future<void> ekle() async {
                        final deger = ctrl.text.trim();
                        if (deger.isEmpty) return;
                        if (liste.any(
                          (e) => e.toLowerCase() == deger.toLowerCase(),
                        )) {
                          ctrl.clear();
                          return;
                        }
                        final yeni = List<String>.from(liste)
                          ..add(deger)
                          ..sort(
                            (a, b) =>
                                a.toLowerCase().compareTo(b.toLowerCase()),
                          );
                        await _kaydet(yeni);
                        ctrl.clear();
                        setS(() {
                          liste.clear();
                          liste.addAll(yeni);
                        });
                      }

                      return Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: ctrl,
                              decoration: const InputDecoration(
                                labelText: 'Yeni gider türü ekle',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              textCapitalization: TextCapitalization.words,
                              inputFormatters: [IlkHarfBuyukFormatter()],
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
        );
      },
    );
  }
}
