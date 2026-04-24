import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:js' as js;
import 'dart:async';
import 'dart:convert';

import '../core/utils.dart';
import '../screens/on_hazirlik_ekrani.dart';

// ─── POS Kıyaslama Widget ─────────────────────────────────────────────────────

class PosKiyaslamaWidget extends StatefulWidget {
  final List<String> subeler;
  const PosKiyaslamaWidget({this.subeler = const []});

  @override
  State<PosKiyaslamaWidget> createState() => PosKiyaslamaWidgetState();
}

class PosKiyaslamaWidgetState extends State<PosKiyaslamaWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String? _secilenSube;
  Map<String, String> _subeAdlari = {};
  Map<String, String> _uyeIsyeriNolari = {};

  // Excel verisi
  List<Map<String, dynamic>> _excelSatirlar = [];
  bool _excelYuklendi = false;
  bool _excelYukleniyor = false;

  // Karşılaştırma sonuçları
  List<Map<String, dynamic>> _sonuclar = [];
  bool _kiyaslaniyor = false;

  @override
  void initState() {
    super.initState();
    _subeleriYukle();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Sekmeye her dönüşte şube listesini güncelle
    _subeleriYukle();
  }

  Future<void> _subeleriYukle() async {
    final snap = await FirebaseFirestore.instance.collection('subeler').get();
    final adlar = <String, String>{};
    final uyeNolar = <String, String>{};
    for (final d in snap.docs) {
      adlar[d.id] = (d.data()['ad'] as String?) ?? d.id;
      final uyeNo = d.data()['uyeIsyeriNo'] as String?;
      if (uyeNo != null && uyeNo.isNotEmpty) uyeNolar[d.id] = uyeNo;
    }
    if (mounted) {
      setState(() {
        _subeAdlari = adlar;
        _uyeIsyeriNolari = uyeNolar;
        if (_secilenSube == null && adlar.isNotEmpty) {
          _secilenSube = widget.subeler.isNotEmpty
              ? widget.subeler.first
              : adlar.keys.first;
        }
      });
    }
  }

  // Excel dosyasını yükle ve işle — web uyumlu
  // Excel dosyasını SheetJS ile yükle — web uyumlu, hızlı
  Future<void> _excelYukle() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final bytes = result.files.first.bytes;
      if (bytes == null) return;

      setState(() {
        _excelYukleniyor = true;
        _excelSatirlar = [];
        _sonuclar = [];
        _excelYuklendi = false;
      });

      // SheetJS ile parse et (JavaScript)
      final completer = Completer<String>();
      final jsArray = js.JsObject(
        js.context['Uint8Array'] as js.JsFunction,
        [js.JsArray.from(bytes.toList())],
      );

      js.context.callMethod('parseExcelFile', [
        jsArray,
        gunKapanisSaati,
        (String result) => completer.complete(result),
      ]);
      final jsonStr = await completer.future;
      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;

      if (parsed['error'] != null) throw Exception(parsed['error']);

      // {uyeNo: {gun: toplam}} -> List<Map>
      final data = parsed['data'] as Map<String, dynamic>;
      final satirlar = <Map<String, dynamic>>[];
      for (final uyeNo in data.keys) {
        final gunler = data[uyeNo] as Map<String, dynamic>;
        for (final gun in gunler.keys) {
          satirlar.add({
            'uyeNo': uyeNo,
            'gun': gun,
            'tutar': (gunler[gun] as num).toDouble(),
          });
        }
      }

      setState(() {
        _excelSatirlar = satirlar;
        _excelYuklendi = true;
        _excelYukleniyor = false;
      });
    } catch (e) {
      setState(() => _excelYukleniyor = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _kiyasla() async {
    if (_secilenSube == null || !_excelYuklendi) return;
    final uyeNo = _uyeIsyeriNolari[_secilenSube];
    if (uyeNo == null || uyeNo.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Bu şube için Üye İşyeri No tanımlanmamış. Şube düzenleme ile ekleyin.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _kiyaslaniyor = true);

    // Excel'den bu şubenin gün bazlı toplamları
    final Map<String, double> excelGunluk = {};
    for (final s in _excelSatirlar) {
      if (s['uyeNo'] == uyeNo) {
        final gun = s['gun'] as String;
        excelGunluk[gun] = (excelGunluk[gun] ?? 0) + (s['tutar'] as double);
      }
    }

    if (excelGunluk.isEmpty) {
      setState(() => _kiyaslaniyor = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Excel\'de $uyeNo numaralı işyeri bulunamadı.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Günleri belirle
    final gunler = excelGunluk.keys.toList()..sort();
    final baslangic = gunler.first;
    final bitis = gunler.last;

    // Firestore'dan bu aralıktaki kayıtları çek
    final snap = await FirebaseFirestore.instance
        .collection('subeler')
        .doc(_secilenSube)
        .collection('gunluk')
        .where('tarih', isGreaterThanOrEqualTo: baslangic)
        .where('tarih', isLessThanOrEqualTo: bitis)
        .get();

    final Map<String, double> programGunluk = {};
    for (final doc in snap.docs) {
      final tarih = doc.data()['tarih'] as String? ?? '';
      final pos = (doc.data()['toplamPos'] as num? ?? 0).toDouble();
      programGunluk[tarih] = pos;
    }

    // Karşılaştır
    final sonuclar = <Map<String, dynamic>>[];
    for (final gun in gunler) {
      final excel = excelGunluk[gun] ?? 0;
      final program = programGunluk[gun] ?? 0;
      final fark = excel - program;
      sonuclar.add({
        'gun': gun,
        'excel': excel,
        'program': program,
        'fark': fark,
        'eslesme': fark.abs() < 0.01,
      });
    }

    setState(() {
      _sonuclar = sonuclar;
      _kiyaslaniyor = false;
    });
  }

  String _fmtTL(double v) {
    final s = v.abs().toStringAsFixed(2).replaceAll('.', ',');
    return '${v < 0 ? '-' : ''}$s ₺';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final aktifSubeler =
        widget.subeler.isNotEmpty ? widget.subeler : _subeAdlari.keys.toList();

    final eslesenSayi = _sonuclar.where((s) => s['eslesme'] == true).length;
    final farkliSayi = _sonuclar.where((s) => s['eslesme'] == false).length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Şube seçici
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Şube',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _secilenSube,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    items: aktifSubeler
                        .map((s) => DropdownMenuItem(
                              value: s,
                              child: Text(_subeAdlari[s] ?? s),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() {
                      _secilenSube = v;
                      _sonuclar = [];
                    }),
                  ),
                  if (_secilenSube != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _uyeIsyeriNolari[_secilenSube] != null
                          ? 'Üye İşyeri No: ${_uyeIsyeriNolari[_secilenSube]}'
                          : '⚠️ Üye İşyeri No tanımlanmamış',
                      style: TextStyle(
                        fontSize: 12,
                        color: _uyeIsyeriNolari[_secilenSube] != null
                            ? Colors.green[700]
                            : Colors.orange[700],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Excel yükleme
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Banka Excel Dosyası',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _excelYukleniyor ? null : _excelYukle,
                        icon: _excelYukleniyor
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.upload_file),
                        label: Text(
                            _excelYukleniyor ? 'Yükleniyor...' : 'Excel Yükle'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0288D1),
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (_excelYuklendi)
                        Text(
                          '✅ ${_excelSatirlar.length} gün yüklendi',
                          style:
                              TextStyle(color: Colors.green[700], fontSize: 13),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Kıyasla butonu
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed:
                  (_excelYuklendi && _secilenSube != null && !_kiyaslaniyor)
                      ? _kiyasla
                      : null,
              icon: _kiyaslaniyor
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.compare_arrows),
              label: Text(_kiyaslaniyor ? 'Kıyaslanıyor...' : 'Kıyasla'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green[700],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),

          // Sonuçlar
          if (_sonuclar.isNotEmpty) ...[
            const SizedBox(height: 16),
            // Özet
            Row(
              children: [
                Expanded(
                  child: Card(
                    color: Colors.green[50],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Text('$eslesenSayi',
                              style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green[700])),
                          Text('Eşleşen',
                              style: TextStyle(color: Colors.green[700])),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Card(
                    color: farkliSayi > 0 ? Colors.red[50] : Colors.green[50],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Text('$farkliSayi',
                              style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: farkliSayi > 0
                                      ? Colors.red[700]
                                      : Colors.green[700])),
                          Text('Farklı',
                              style: TextStyle(
                                  color: farkliSayi > 0
                                      ? Colors.red[700]
                                      : Colors.green[700])),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Gün bazlı liste
            ..._sonuclar.map((s) {
              final eslesme = s['eslesme'] as bool;
              final gun = s['gun'] as String;
              final parts = gun.split('-');
              final gunGoster = parts.length == 3
                  ? '${parts[2]}.${parts[1]}.${parts[0]}'
                  : gun;
              final excel = s['excel'] as double;
              final program = s['program'] as double;
              final fark = s['fark'] as double;
              // Tarihi DateTime'a çevir
              final tarihParts = gun.split('-');
              final tarihDt = tarihParts.length == 3
                  ? DateTime(int.parse(tarihParts[0]), int.parse(tarihParts[1]),
                      int.parse(tarihParts[2]))
                  : null;

              return Card(
                margin: const EdgeInsets.only(bottom: 6),
                color: eslesme
                    ? Colors.green[50]
                    : fark > 0
                        ? Colors.green[50]
                        : Colors.red[50],
                child: ListTile(
                  leading: Icon(
                    eslesme ? Icons.check_circle : Icons.error,
                    color: eslesme ? Colors.green[700] : Colors.red[700],
                  ),
                  title: Text(gunGoster,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    'Banka: ${_fmtTL(excel)}  •  Program: ${_fmtTL(program)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: eslesme
                      ? Text('✓',
                          style: TextStyle(
                              color: Colors.green[700],
                              fontWeight: FontWeight.bold))
                      : Text(
                          '${fark >= 0 ? '+' : ''}${_fmtTL(fark)}',
                          style: TextStyle(
                            color:
                                fark > 0 ? Colors.green[700] : Colors.red[700],
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                  onTap: tarihDt == null || _secilenSube == null
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => OnHazirlikEkrani(
                                subeKodu: _secilenSube!,
                                subeler: widget.subeler,
                                gecmisGunHakki: -1,
                                baslangicTarihi: tarihDt,
                              ),
                            ),
                          ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}
