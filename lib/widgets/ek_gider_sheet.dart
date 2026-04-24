import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../core/formatters.dart';
import 'gider_adi_alani.dart';
// ─── Ek Gider Sheet ──────────────────────────────────────────────────────────

class EkGiderSheet extends StatefulWidget {
  final String subeAd;
  final String donemKey;
  final List<Map<String, dynamic>> satirlar;
  final List<String> giderTurleri;
  final Future<void> Function(List<Map<String, dynamic>>) onKaydet;

  const EkGiderSheet({
    required this.subeAd,
    required this.donemKey,
    required this.satirlar,
    required this.giderTurleri,
    required this.onKaydet,
  });

  @override
  State<EkGiderSheet> createState() => EkGiderSheetState();
}

class EkGiderSheetState extends State<EkGiderSheet> {
  late List<Map<String, dynamic>> _satirlar;
  bool _kaydediliyor = false;

  @override
  void initState() {
    super.initState();
    _satirlar = widget.satirlar;
  }

  String _fmtTutar(double v) {
    final parts = v.toStringAsFixed(2).split('.');
    final buf = StringBuffer();
    for (int i = 0; i < parts[0].length; i++) {
      if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write('.');
      buf.write(parts[0][i]);
    }
    return '${buf.toString()},${parts[1]}';
  }

  void _ozelEkle() {
    setState(() {
      _satirlar = List.from(_satirlar)
        ..add({
          'adCtrl': TextEditingController(),
          'tutarCtrl': TextEditingController(),
          'sabit': false,
        });
    });
  }

  void _sil(int idx) {
    setState(() {
      final s = _satirlar[idx];
      (s['adCtrl'] as TextEditingController).dispose();
      (s['tutarCtrl'] as TextEditingController).dispose();
      _satirlar = List.from(_satirlar)..removeAt(idx);
    });
  }

  Future<void> _kaydet() async {
    setState(() => _kaydediliyor = true);
    final kaydedilecek = _satirlar.where((s) {
      final ad = (s['adCtrl'] as TextEditingController).text.trim();
      final tStr = (s['tutarCtrl'] as TextEditingController).text.trim();
      final tutar =
          double.tryParse(tStr.replaceAll('.', '').replaceAll(',', '.')) ?? 0.0;
      return ad.isNotEmpty && tutar > 0;
    }).map((s) {
      final tutar = double.tryParse(
            (s['tutarCtrl'] as TextEditingController)
                .text
                .replaceAll('.', '')
                .replaceAll(',', '.'),
          ) ??
          0.0;
      return {
        'ad': (s['adCtrl'] as TextEditingController).text.trim(),
        'tutar': tutar,
      };
    }).toList();

    await widget.onKaydet(kaydedilecek);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollCtrl) => Column(
          children: [
            // Tutamak
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Başlık
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ek Giderler — ${widget.subeAd}',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          widget.donemKey,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('İptal'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _kaydediliyor ? null : _kaydet,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0288D1),
                      foregroundColor: Colors.white,
                    ),
                    child: _kaydediliyor
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Kaydet'),
                  ),
                ],
              ),
            ),
            const Divider(),
            // Sütun başlıkları
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: const [
                  Expanded(
                    flex: 3,
                    child: Text(
                      'Gider Türü',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'Tutar (₺)',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(width: 40),
                ],
              ),
            ),
            // Liste
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                itemCount: _satirlar.length + 1, // +1 ekle butonu için
                itemBuilder: (_, idx) {
                  // Son item = Ekle butonu
                  if (idx == _satirlar.length) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: OutlinedButton.icon(
                        onPressed: _ozelEkle,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Özel Gider Ekle'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF0288D1),
                          side: const BorderSide(color: Color(0xFF0288D1)),
                        ),
                      ),
                    );
                  }

                  final s = _satirlar[idx];
                  final sabit = s['sabit'] as bool;

                  return Padding(
                    key: ValueKey(idx),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: sabit
                              ? Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey[50],
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.grey[300]!,
                                    ),
                                  ),
                                  child: Text(
                                    (s['adCtrl'] as TextEditingController).text,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                )
                              : TextFormField(
                                  controller:
                                      s['adCtrl'] as TextEditingController,
                                  decoration: InputDecoration(
                                    labelText: 'Gider Adı',
                                    border: const OutlineInputBorder(),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    suffixIcon: PopupMenuButton<String>(
                                      icon: const Icon(
                                        Icons.arrow_drop_down,
                                        size: 20,
                                      ),
                                      itemBuilder: (_) => widget.giderTurleri
                                          .map(
                                            (t) => PopupMenuItem(
                                              value: t,
                                              child: Text(
                                                t,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                          )
                                          .toList(),
                                      onSelected: (val) => setState(
                                        () => (s['adCtrl']
                                                as TextEditingController)
                                            .text = val,
                                      ),
                                    ),
                                  ),
                                  textCapitalization: TextCapitalization.words,
                                  inputFormatters: [IlkHarfBuyukFormatter()],
                                ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: TextFormField(
                            controller: s['tutarCtrl'] as TextEditingController,
                            decoration: const InputDecoration(
                              hintText: '0,00',
                              suffixText: '₺',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [BinAraciFormatter()],
                            textAlign: TextAlign.right,
                          ),
                        ),
                        if (!sabit)
                          IconButton(
                            icon: const Icon(
                              Icons.remove_circle_outline,
                              color: Colors.red,
                              size: 20,
                            ),
                            onPressed: () => _sil(idx),
                          )
                        else
                          const SizedBox(width: 40),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
