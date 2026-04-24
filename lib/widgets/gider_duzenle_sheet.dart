import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../core/formatters.dart';
import '../core/utils.dart';
import 'gider_adi_alani.dart';
// ─── Gider Türleri Kartı ──────────────────────────────────────────────────────

// ─── Gider Düzenle Sheet ─────────────────────────────────────────────────────

class GiderDuzenleSheet extends StatefulWidget {
  final Map<String, dynamic> v;
  final List<String> giderTurleri;
  final Future<void> Function(Map<String, dynamic>) onKaydet;

  const GiderDuzenleSheet({
    required this.v,
    required this.giderTurleri,
    required this.onKaydet,
  });

  @override
  State<GiderDuzenleSheet> createState() => _GiderDuzenleSheetState();
}

class _GiderDuzenleSheetState extends State<GiderDuzenleSheet> {
  late TextEditingController _personelSayiCtrl;
  late TextEditingController _personelBasiCtrl;
  late TextEditingController _personelEkstraCtrl;
  late List<Map<String, dynamic>> _ciroBazli;
  late List<Map<String, dynamic>> _sabitGiderler;
  bool _kaydediliyor = false;

  String _fmt(double v) {
    final parts = v.toStringAsFixed(2).split('.');
    final buf = StringBuffer();
    for (int i = 0; i < parts[0].length; i++) {
      if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write('.');
      buf.write(parts[0][i]);
    }
    return '${buf.toString()},${parts[1]}';
  }

  double _parseD(String s) =>
      double.tryParse(s.replaceAll('.', '').replaceAll(',', '.')) ?? 0.0;

  @override
  void initState() {
    super.initState();
    final v = widget.v;
    _personelSayiCtrl = TextEditingController(
      text: (v['personelSayisi'] as int).toString(),
    );
    _personelBasiCtrl = TextEditingController(
      text: _fmt(v['personelBasiMaliyet'] as double),
    );
    _personelEkstraCtrl = TextEditingController(
      text: _fmt(v['personelEkstraMaliyet'] as double),
    );

    _ciroBazli = (v['ciroBazliGiderler'] as List)
        .cast<Map>()
        .map(
          (g) => {
            'adCtrl': TextEditingController(text: g['ad'] ?? ''),
            'oranCtrl': TextEditingController(
              text: (g['oran'] as num? ?? 0).toStringAsFixed(1),
            ),
          },
        )
        .toList();

    if (_ciroBazli.isEmpty) {
      _ciroBazli = [
        {
          'adCtrl': TextEditingController(text: 'Royalty'),
          'oranCtrl': TextEditingController(text: '12.0'),
        },
        {
          'adCtrl': TextEditingController(text: 'Komisyon'),
          'oranCtrl': TextEditingController(text: '5.0'),
        },
      ];
    }

    _sabitGiderler = (v['sabitGiderler'] as List)
        .cast<Map>()
        .map(
          (g) => {
            'adCtrl': TextEditingController(text: g['ad'] ?? ''),
            'tutarCtrl': TextEditingController(
              text: _fmt((g['tutar'] as num? ?? 0).toDouble()),
            ),
          },
        )
        .toList();
  }

  @override
  void dispose() {
    _personelSayiCtrl.dispose();
    _personelBasiCtrl.dispose();
    _personelEkstraCtrl.dispose();
    for (final g in _ciroBazli) {
      (g['adCtrl'] as TextEditingController).dispose();
      (g['oranCtrl'] as TextEditingController).dispose();
    }
    for (final g in _sabitGiderler) {
      (g['adCtrl'] as TextEditingController).dispose();
      (g['tutarCtrl'] as TextEditingController).dispose();
    }
    super.dispose();
  }

  Widget _bolumBaslik(String baslik) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(
          baslik,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13,
            color: Color(0xFF0288D1),
          ),
        ),
      );

  Future<void> _kaydet() async {
    setState(() => _kaydediliyor = true);
    try {
      final ciroBazliVerisi = _ciroBazli
          .where((g) => (g['adCtrl'] as TextEditingController).text.isNotEmpty)
          .map(
            (g) => {
              'ad': (g['adCtrl'] as TextEditingController).text.trim(),
              'oran': double.tryParse(
                    (g['oranCtrl'] as TextEditingController).text.replaceAll(
                          ',',
                          '.',
                        ),
                  ) ??
                  0.0,
            },
          )
          .toList();

      final sabitVerisi = _sabitGiderler
          .where((g) => (g['adCtrl'] as TextEditingController).text.isNotEmpty)
          .map(
            (g) => {
              'ad': (g['adCtrl'] as TextEditingController).text.trim(),
              'tutar': _parseD((g['tutarCtrl'] as TextEditingController).text),
            },
          )
          .toList();

      final personelSayi = int.tryParse(_personelSayiCtrl.text) ?? 0;
      final personelBasi = _parseD(_personelBasiCtrl.text);
      final personelEkstra = _parseD(_personelEkstraCtrl.text);

      await widget.onKaydet({
        'ciroBazliGiderler': ciroBazliVerisi,
        'personelSayisi': personelSayi,
        'personelBasi': personelBasi,
        'personelEkstra': personelEkstra,
        'sabitGiderler': sabitVerisi,
      });

      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _kaydediliyor = false);
    }
  }

  Widget _satirCiroBazli(int idx) {
    final g = _ciroBazli[idx];
    return Padding(
      key: ValueKey('ciro_$idx'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextFormField(
              controller: g['adCtrl'] as TextEditingController,
              decoration: const InputDecoration(
                labelText: 'Gider Adı',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
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
              controller: g['oranCtrl'] as TextEditingController,
              decoration: const InputDecoration(
                labelText: 'Oran',
                suffixText: '%',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.remove_circle_outline,
              color: Colors.red,
              size: 20,
            ),
            onPressed: () => setState(() {
              _ciroBazli = List.from(_ciroBazli)..removeAt(idx);
            }),
          ),
        ],
      ),
    );
  }

  Widget _satirSabit(int idx) {
    final g = _sabitGiderler[idx];
    return Padding(
      key: ValueKey('sabit_$idx'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: TextFormField(
              controller: g['adCtrl'] as TextEditingController,
              decoration: InputDecoration(
                labelText: 'Gider Adı',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                // Açılır kutu — Ayarlardan gelen listeden seç
                suffixIcon: PopupMenuButton<String>(
                  icon: const Icon(Icons.arrow_drop_down, size: 20),
                  tooltip: 'Listeden seç',
                  itemBuilder: (_) => widget.giderTurleri
                      .map(
                        (t) => PopupMenuItem(
                          value: t,
                          child: Text(t, style: const TextStyle(fontSize: 13)),
                        ),
                      )
                      .toList(),
                  onSelected: (val) => setState(
                    () => (g['adCtrl'] as TextEditingController).text = val,
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
              controller: g['tutarCtrl'] as TextEditingController,
              decoration: const InputDecoration(
                labelText: 'Tutar (₺)',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [BinAraciFormatter()],
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.remove_circle_outline,
              color: Colors.red,
              size: 20,
            ),
            onPressed: () => setState(() {
              _sabitGiderler = List.from(_sabitGiderler)..removeAt(idx);
            }),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subeAd = widget.v['subeAd'] as String;
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
            // Başlık + İptal + Kaydet
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Gider Ayarları — $subeAd',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
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
            // İçerik — ListView.builder ile rebuild garantisi
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                itemCount: 1, // Tek item — Column içinde tüm içerik
                itemBuilder: (_, __) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Ciro Bazlı ──────────────────────────
                    _bolumBaslik('Ciro Bazlı Giderler (%)'),
                    for (int i = 0; i < _ciroBazli.length; i++)
                      _satirCiroBazli(i),
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _ciroBazli = List.from(_ciroBazli)
                          ..add({
                            'adCtrl': TextEditingController(),
                            'oranCtrl': TextEditingController(text: '0.0'),
                          });
                      }),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text(
                        'Ciro Bazlı Gider Ekle',
                        style: TextStyle(fontSize: 13),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF0288D1),
                      ),
                    ),
                    // ── Personel ─────────────────────────────
                    _bolumBaslik('Personel'),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _personelSayiCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Personel Sayısı',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                            ),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            controller: _personelBasiCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Kişi Başı (₺)',
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
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _personelEkstraCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Ekstra Personel Maliyeti (₺)',
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
                    ),
                    // ── Sabit Giderler ───────────────────────
                    _bolumBaslik('Diğer Giderler (Sabit Tutar)'),
                    for (int i = 0; i < _sabitGiderler.length; i++)
                      _satirSabit(i),
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _sabitGiderler = List.from(_sabitGiderler)
                          ..add({
                            'adCtrl': TextEditingController(),
                            'tutarCtrl': TextEditingController(),
                          });
                      }),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text(
                        'Sabit Gider Ekle',
                        style: TextStyle(fontSize: 13),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF0288D1),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
