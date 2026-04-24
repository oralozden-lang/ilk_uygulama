import 'dart:async';
import 'ek_gider_sheet.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../core/utils.dart';
// ─── Gerçekleşen Widget ───────────────────────────────────────────────────────

class GerceklesenWidget extends StatefulWidget {
  const GerceklesenWidget();
  @override
  State<GerceklesenWidget> createState() => GerceklesenWidgetState();
}

class GerceklesenWidgetState extends State<GerceklesenWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  // ── Filtre durumu ──────────────────────────────────────────────────────────
  String _filtreModu = 'ay'; // 'ay' veya 'aralik'
  int _secilenYil = DateTime.now().year;
  int _secilenAy = DateTime.now().month;
  DateTime _baslangic = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _bitis = DateTime.now();
  String? _secilenSube; // null = tüm şubeler

  bool _karsilastirmaAcik = false;
  int _karsilastirmaYil =
      DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year;
  int _karsilastirmaAy =
      DateTime.now().month == 1 ? 12 : DateTime.now().month - 1;
  // Karşılaştırma tarih aralığı
  DateTime _karsilastirmaBaslangic = DateTime(
    DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year,
    DateTime.now().month == 1 ? 12 : DateTime.now().month - 1,
    1,
  );
  DateTime _karsilastirmaBitis = DateTime(
    DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year,
    DateTime.now().month == 1 ? 13 : DateTime.now().month,
    0,
  );

  // ── Veri ──────────────────────────────────────────────────────────────────
  bool _yukleniyor = false;
  List<Map<String, dynamic>> _subeVeriler = [];
  List<Map<String, dynamic>> _karsilastirmaVeriler = [];
  Map<String, String> _subeAdlari = {};
  List<String> _giderTurleri = [];

  static const List<String> _aylar = [
    'Ocak',
    'Şubat',
    'Mart',
    'Nisan',
    'Mayıs',
    'Haziran',
    'Temmuz',
    'Ağustos',
    'Eylül',
    'Ekim',
    'Kasım',
    'Aralık',
  ];

  StreamSubscription? _giderTurleriStream;

  @override
  void initState() {
    super.initState();
    _giderTurleriDinle();
    // Şubeler yüklendikten sonra raporu getir
    _subeleriYukleVeRaporuGetir();
  }

  Future<void> _subeleriYukleVeRaporuGetir() async {
    await _subeleriYukle();
    if (mounted) _yukle();
  }

  @override
  void dispose() {
    _giderTurleriStream?.cancel();
    super.dispose();
  }

  void _giderTurleriDinle() {
    _giderTurleriStream = FirebaseFirestore.instance
        .collection('ayarlar')
        .doc('giderTurleri')
        .snapshots()
        .listen((doc) {
      final liste =
          (doc.data()?['liste'] as List?)?.map((e) => e.toString()).toList();
      if (mounted) {
        setState(() {
          final ham2 = liste?.isNotEmpty == true
              ? liste!
              : [
                  'Kira',
                  'Elektrik',
                  'Su',
                  'Doğalgaz',
                  'Telefon / İnternet',
                  'Sigorta',
                  'Muhasebe',
                  'Temizlik',
                  'Royalty',
                  'Komisyon',
                ];
          ham2.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          _giderTurleri = ham2;
        });
      }
    });
  }

  Future<void> _subeleriYukle() async {
    final snap = await FirebaseFirestore.instance
        .collection('subeler')
        .orderBy('ad')
        .get();
    final adlar = <String, String>{};
    for (final d in snap.docs) {
      if (d.data()['aktif'] == false) continue;
      adlar[d.id] = (d.data()['ad'] as String?) ?? d.id;
    }
    if (mounted) setState(() => _subeAdlari = adlar);
  }

  String _baslangicKey() {
    if (_filtreModu == 'ay') {
      return '$_secilenYil-${_secilenAy.toString().padLeft(2, '0')}-01';
    }
    return '${_baslangic.year}-${_baslangic.month.toString().padLeft(2, '0')}-${_baslangic.day.toString().padLeft(2, '0')}';
  }

  String _bitisKey() {
    if (_filtreModu == 'ay') {
      final son = DateTime(_secilenYil, _secilenAy + 1, 0).day;
      return '$_secilenYil-${_secilenAy.toString().padLeft(2, '0')}-${son.toString().padLeft(2, '0')}';
    }
    return '${_bitis.year}-${_bitis.month.toString().padLeft(2, '0')}-${_bitis.day.toString().padLeft(2, '0')}';
  }

  String _karsilastirmaBasKey() {
    if (_filtreModu == 'aralik') {
      return '${_karsilastirmaBaslangic.year}-${_karsilastirmaBaslangic.month.toString().padLeft(2, '0')}-${_karsilastirmaBaslangic.day.toString().padLeft(2, '0')}';
    }
    return '$_karsilastirmaYil-${_karsilastirmaAy.toString().padLeft(2, '0')}-01';
  }

  String _karsilastirmaBitKey() {
    if (_filtreModu == 'aralik') {
      return '${_karsilastirmaBitis.year}-${_karsilastirmaBitis.month.toString().padLeft(2, '0')}-${_karsilastirmaBitis.day.toString().padLeft(2, '0')}';
    }
    final son = DateTime(_karsilastirmaYil, _karsilastirmaAy + 1, 0).day;
    return '$_karsilastirmaYil-${_karsilastirmaAy.toString().padLeft(2, '0')}-${son.toString().padLeft(2, '0')}';
  }

  // Firestore kasadan islenen harcamalari + ciroyu cek
  Future<List<Map<String, dynamic>>> _kasaVeriCek(
    String bas,
    String bit,
  ) async {
    final hedefSubeler =
        _secilenSube != null ? [_secilenSube!] : _subeAdlari.keys.toList();
    final donemKey = bas.substring(0, 7); // 'YYYY-MM'

    // Tüm şubeler paralel
    final futures = hedefSubeler.map((subeId) async {
      final results = await Future.wait([
        FirebaseFirestore.instance
            .collection('subeler')
            .doc(subeId)
            .collection('gunluk')
            .where('tarih', isGreaterThanOrEqualTo: bas)
            .where('tarih', isLessThanOrEqualTo: bit)
            .get(),
        FirebaseFirestore.instance
            .collection('gerceklesen_giderler')
            .doc('${subeId}_$donemKey')
            .get(),
      ]);

      final snap = results[0] as QuerySnapshot<Map<String, dynamic>>;
      final ekGiderDoc = results[1] as DocumentSnapshot<Map<String, dynamic>>;

      double ciro = 0, harcama = 0;
      for (final doc in snap.docs) {
        final d = doc.data();
        ciro += ((d['gunlukSatisToplami'] as num?) ?? 0).toDouble();
        harcama += ((d['toplamHarcama'] as num?) ?? 0).toDouble();
        harcama += ((d['toplamAnaKasaHarcama'] as num?) ?? 0).toDouble();
        for (final da in (d['digerAlimlar'] as List?)?.cast<Map>() ?? []) {
          harcama += (da['tutar'] as num? ?? 0).toDouble();
        }
        for (final t in (d['transferler'] as List?)?.cast<Map>() ?? []) {
          final kat = t['kategori'] as String? ?? '';
          final tutar = (t['tutar'] as num? ?? 0).toDouble();
          if (kat == 'GELEN') harcama += tutar;
          if (kat == 'GİDEN') harcama -= tutar;
        }
      }

      final ekGiderler =
          (ekGiderDoc.data()?['giderler'] as List?)?.cast<Map>() ?? [];

      return {
        'subeId': subeId,
        'subeAd': _subeAdlari[subeId] ?? subeId,
        'ciro': ciro,
        'harcama': harcama,
        'ekGiderler': ekGiderler,
        'donemKey': donemKey,
        'detayAcik': false,
      };
    });

    final sonuc = List<Map<String, dynamic>>.from(await Future.wait(futures));
    sonuc.sort(
      (a, b) => (a['subeAd'] as String).compareTo(b['subeAd'] as String),
    );
    return sonuc;
  }

  Future<void> _yukle() async {
    setState(() => _yukleniyor = true);
    try {
      // Ana dönem ve karşılaştırma dönemini paralel çek
      final results = await Future.wait([
        _kasaVeriCek(_baslangicKey(), _bitisKey()),
        if (_karsilastirmaAcik)
          _kasaVeriCek(_karsilastirmaBasKey(), _karsilastirmaBitKey())
        else
          Future.value(<Map<String, dynamic>>[]),
      ]);
      if (mounted)
        setState(() {
          _subeVeriler = results[0];
          _karsilastirmaVeriler = results[1];
          _yukleniyor = false;
        });
    } catch (e) {
      if (mounted) setState(() => _yukleniyor = false);
    }
  }

  // Ek gider kaydet
  Future<void> _ekGiderKaydet(
    String subeId,
    String donemKey,
    List<Map<String, dynamic>> giderler,
  ) async {
    await FirebaseFirestore.instance
        .collection('gerceklesen_giderler')
        .doc('${subeId}_$donemKey')
        .set({'subeId': subeId, 'donem': donemKey, 'giderler': giderler});
  }

  // Ek gider düzenleme diyaloğu
  Future<void> _ekGiderDialog(Map<String, dynamic> v) async {
    final subeId = v['subeId'] as String;
    final subeAd = v['subeAd'] as String;
    final donemKey = v['donemKey'] as String;

    // Mevcut giderlerden controller listesi oluştur
    final List<Map<String, dynamic>> satirlar = [];

    // Ayarlar listesindeki tüm türler — sabit satırlar
    for (final ad in _giderTurleri) {
      final mevcut = (v['ekGiderler'] as List).cast<Map>().firstWhere(
            (g) => g['ad'] == ad,
            orElse: () => <String, dynamic>{},
          );
      final tutar =
          mevcut.isNotEmpty ? (mevcut['tutar'] as num? ?? 0).toDouble() : 0.0;
      satirlar.add({
        'adCtrl': TextEditingController(text: ad),
        'tutarCtrl': TextEditingController(
          text: tutar > 0 ? _fmtTutar(tutar) : '',
        ),
        'sabit': true,
      });
    }
    // Kayıtlı olup listede olmayan özel giderler
    for (final g in (v['ekGiderler'] as List).cast<Map>()) {
      final ad = g['ad'] as String? ?? '';
      if (!_giderTurleri.contains(ad) && ad.isNotEmpty) {
        final tutar = (g['tutar'] as num? ?? 0).toDouble();
        satirlar.add({
          'adCtrl': TextEditingController(text: ad),
          'tutarCtrl': TextEditingController(
            text: tutar > 0 ? _fmtTutar(tutar) : '',
          ),
          'sabit': false,
        });
      }
    }

    // Bottom sheet aç — kasa sayfasındaki harcama girişi gibi
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => EkGiderSheet(
        subeAd: subeAd,
        donemKey: donemKey,
        satirlar: satirlar,
        giderTurleri: _giderTurleri,
        onKaydet: (kaydedilecek) async {
          await _ekGiderKaydet(subeId, donemKey, kaydedilecek);
          setState(() => v['ekGiderler'] = kaydedilecek);
          Navigator.pop(ctx);
        },
      ),
    );

    // Controller'ları temizle
    for (final s in satirlar) {
      (s['adCtrl'] as TextEditingController).dispose();
      (s['tutarCtrl'] as TextEditingController).dispose();
    }
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

  String _fmt(double v) {
    final neg = v < 0;
    final abs = v.abs();
    final parts = abs.toStringAsFixed(2).split('.');
    final buf = StringBuffer();
    for (int i = 0; i < parts[0].length; i++) {
      if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write('.');
      buf.write(parts[0][i]);
    }
    return '${neg ? '-' : ''}${buf.toString()},${parts[1]} ₺';
  }

  // Şube kartı
  Widget _subeKarti(
    Map<String, dynamic> v, {
    Map<String, dynamic>? karsilastirma,
  }) {
    final subeAd = v['subeAd'] as String;
    final ciro = v['ciro'] as double;
    final harcama = v['harcama'] as double;
    final ekGiderler = (v['ekGiderler'] as List).cast<Map>();
    final ekToplam = ekGiderler.fold(
      0.0,
      (s, g) => s + ((g['tutar'] as num?) ?? 0).toDouble(),
    );
    final toplamGider = harcama + ekToplam;
    final kar = ciro - toplamGider;

    // Karşılaştırma
    double? karKarsilastirma;
    if (karsilastirma != null) {
      final kCiro = karsilastirma['ciro'] as double;
      final kHarcama = karsilastirma['harcama'] as double;
      final kEk = (karsilastirma['ekGiderler'] as List).cast<Map>().fold(
            0.0,
            (s, g) => s + ((g['tutar'] as num?) ?? 0).toDouble(),
          );
      karKarsilastirma = kCiro - kHarcama - kEk;
    }

    final detayAcik = v['detayAcik'] as bool? ?? false;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 1,
      child: Column(
        children: [
          // Başlık — tıklanabilir
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            onTap: () => setState(() => v['detayAcik'] = !detayAcik),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: const BoxDecoration(
                color: Color(0xFF0288D1),
                borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      subeAd,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  // Ciro pill
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      _fmt(ciro),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Net kâr pill
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: kar >= 0 ? Colors.green[700] : Colors.red[700],
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      _fmt(kar),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    detayAcik ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white60,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),

          // Detay — açılır/kapanır
          if (detayAcik) ...[
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _satirKalem('Ciro', ciro, const Color(0xFF0288D1)),
                  _satirKalem(
                    'Kasadan Harcamalar',
                    -harcama,
                    Colors.orange[700]!,
                  ),
                  ...ekGiderler.map(
                    (g) => _satirKalem(
                      '  ${g['ad'] ?? ''}',
                      -((g['tutar'] as num?) ?? 0).toDouble(),
                      Colors.red[700]!,
                      kucuk: true,
                    ),
                  ),
                  if (ekToplam > 0)
                    _satirKalem(
                      'Ek Giderler Toplamı',
                      -ekToplam,
                      Colors.red[700]!,
                      bold: true,
                    ),
                  const Divider(height: 12),
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: kar >= 0 ? Colors.green[50] : Colors.red[50],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: kar >= 0 ? Colors.green[200]! : Colors.red[200]!,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Net Kâr',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          _fmt(kar),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color:
                                kar >= 0 ? Colors.green[700] : Colors.red[700],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (karKarsilastirma != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          'Önceki dönem: ${_fmt(karKarsilastirma)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: karKarsilastirma >= 0
                                ? Colors.green[700]
                                : Colors.red[700],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _degisimBadge(kar, karKarsilastirma),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],

          // Alt şerit: Ek Gider Düzenle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(12)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _ekGiderDialog(v),
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text(
                    'Ek Gider Düzenle',
                    style: TextStyle(fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF0288D1),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _satirKalem(
    String ad,
    double tutar,
    Color renk, {
    bool bold = false,
    bool buyuk = false,
    bool kucuk = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            ad,
            style: TextStyle(
              fontSize: kucuk ? 11 : (buyuk ? 14 : 13),
              color: kucuk ? Colors.grey[600] : null,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            _fmt(tutar.abs()),
            style: TextStyle(
              fontSize: kucuk ? 11 : (buyuk ? 14 : 13),
              color: renk,
              fontWeight: bold ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _degisimBadge(double yeni, double eski) {
    if (eski == 0) return const SizedBox.shrink();
    final pct = (yeni - eski) / eski.abs() * 100;
    final artti = pct >= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: artti ? Colors.green[50] : Colors.red[50],
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: artti ? Colors.green[200]! : Colors.red[200]!,
        ),
      ),
      child: Text(
        '${artti ? '▲' : '▼'} ${pct.abs().toStringAsFixed(1)}%',
        style: TextStyle(
          fontSize: 11,
          color: artti ? Colors.green[700] : Colors.red[700],
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // Özet kart (tüm şubeler toplamı)
  Widget _toplamKart() {
    if (_subeVeriler.isEmpty) return const SizedBox.shrink();
    double topCiro = 0, topHarcama = 0, topEk = 0;
    for (final v in _subeVeriler) {
      topCiro += v['ciro'] as double;
      topHarcama += v['harcama'] as double;
      topEk += (v['ekGiderler'] as List).cast<Map>().fold(
            0.0,
            (s, g) => s + ((g['tutar'] as num?) ?? 0).toDouble(),
          );
    }
    final topKar = topCiro - topHarcama - topEk;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: const Color(0xFF0288D1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'GENEL TOPLAM',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  '${_subeVeriler.length} şube',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _toplamHucre('Ciro', topCiro, Colors.white)),
                Expanded(
                  child: _toplamHucre(
                    'Harcama',
                    topHarcama + topEk,
                    const Color(0xFFEF9A9A),
                  ),
                ),
                Expanded(
                  child: _toplamHucre(
                    'Net Kâr',
                    topKar,
                    topKar >= 0 ? const Color(0xFF80CBC4) : Colors.red[300]!,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _toplamHucre(String etiket, double deger, Color renk) => Column(
        children: [
          Text(etiket,
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 4),
          Text(
            _fmt(deger),
            style: TextStyle(
              color: renk,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final donemBaslik = _filtreModu == 'ay'
        ? '${_aylar[_secilenAy - 1]} $_secilenYil'
        : '${_baslangic.day}.${_baslangic.month}.${_baslangic.year}'
            ' — ${_bitis.day}.${_bitis.month}.${_bitis.year}';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Filtre Kartı ─────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Mod seçimi
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'ay',
                        label: Text('Ay Seç'),
                        icon: Icon(Icons.calendar_month),
                      ),
                      ButtonSegment(
                        value: 'aralik',
                        label: Text('Tarih Aralığı'),
                        icon: Icon(Icons.date_range),
                      ),
                    ],
                    selected: {_filtreModu},
                    onSelectionChanged: (s) =>
                        setState(() => _filtreModu = s.first),
                  ),
                  const SizedBox(height: 12),

                  if (_filtreModu == 'ay') ...[
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _secilenAy,
                            decoration: const InputDecoration(
                              labelText: 'Ay',
                              border: OutlineInputBorder(),
                            ),
                            items: List.generate(
                              12,
                              (i) => DropdownMenuItem(
                                value: i + 1,
                                child: Text(_aylar[i]),
                              ),
                            ),
                            onChanged: (v) => setState(() => _secilenAy = v!),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _secilenYil,
                            decoration: const InputDecoration(
                              labelText: 'Yıl',
                              border: OutlineInputBorder(),
                            ),
                            items:
                                List.generate(5, (i) => DateTime.now().year - i)
                                    .map(
                                      (y) => DropdownMenuItem(
                                        value: y,
                                        child: Text('$y'),
                                      ),
                                    )
                                    .toList(),
                            onChanged: (v) => setState(() => _secilenYil = v!),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final p = await showDatePicker(
                                context: context,
                                initialDate: _baslangic,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now(),
                              );
                              if (p != null) setState(() => _baslangic = p);
                            },
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: Text(
                              '${_baslangic.day.toString().padLeft(2, '0')}.${_baslangic.month.toString().padLeft(2, '0')}.${_baslangic.year}',
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('—'),
                        ),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final p = await showDatePicker(
                                context: context,
                                initialDate: _bitis,
                                firstDate: _baslangic,
                                lastDate: DateTime.now(),
                              );
                              if (p != null) setState(() => _bitis = p);
                            },
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: Text(
                              '${_bitis.day.toString().padLeft(2, '0')}.${_bitis.month.toString().padLeft(2, '0')}.${_bitis.year}',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),

                  // Şube seçimi
                  if (_subeAdlari.isNotEmpty)
                    DropdownButtonFormField<String?>(
                      value: _secilenSube,
                      decoration: const InputDecoration(
                        labelText: 'Şube',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Tüm Şubeler'),
                        ),
                        ..._subeAdlari.entries.map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        ),
                      ],
                      onChanged: (v) => setState(() => _secilenSube = v),
                    ),
                  const SizedBox(height: 8),

                  // Karşılaştırma
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Önceki Dönemle Karşılaştır'),
                    value: _karsilastirmaAcik,
                    activeColor: const Color(0xFF0288D1),
                    onChanged: (v) {
                      setState(() {
                        _karsilastirmaAcik = v;
                        if (v) {
                          // Açılınca otomatik: bir önceki ay
                          final simdi = DateTime.now();
                          final oncekiAy =
                              simdi.month == 1 ? 12 : simdi.month - 1;
                          final oncekiYil =
                              simdi.month == 1 ? simdi.year - 1 : simdi.year;
                          _karsilastirmaAy = oncekiAy;
                          _karsilastirmaYil = oncekiYil;
                          _karsilastirmaBaslangic = DateTime(
                            oncekiYil,
                            oncekiAy,
                            1,
                          );
                          _karsilastirmaBitis = DateTime(
                            oncekiYil,
                            oncekiAy + 1,
                            0,
                          );
                        }
                      });
                    },
                  ),
                  if (_karsilastirmaAcik) ...[
                    if (_filtreModu == 'ay')
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: _karsilastirmaAy,
                              decoration: const InputDecoration(
                                labelText: 'Karş. Ay',
                                border: OutlineInputBorder(),
                              ),
                              items: List.generate(
                                12,
                                (i) => DropdownMenuItem(
                                  value: i + 1,
                                  child: Text(_aylar[i]),
                                ),
                              ),
                              onChanged: (v) =>
                                  setState(() => _karsilastirmaAy = v!),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: _karsilastirmaYil,
                              decoration: const InputDecoration(
                                labelText: 'Karş. Yıl',
                                border: OutlineInputBorder(),
                              ),
                              items: List.generate(
                                5,
                                (i) => DateTime.now().year - i,
                              )
                                  .map(
                                    (y) => DropdownMenuItem(
                                      value: y,
                                      child: Text('$y'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _karsilastirmaYil = v!),
                            ),
                          ),
                        ],
                      ),
                    if (_filtreModu == 'aralik') ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final p = await showDatePicker(
                                  context: context,
                                  initialDate: _karsilastirmaBaslangic,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime.now(),
                                );
                                if (p != null)
                                  setState(() => _karsilastirmaBaslangic = p);
                              },
                              icon: const Icon(Icons.calendar_today, size: 14),
                              label: Text(
                                'Karş: ${_karsilastirmaBaslangic.day}.${_karsilastirmaBaslangic.month}.${_karsilastirmaBaslangic.year}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final p = await showDatePicker(
                                  context: context,
                                  initialDate: _karsilastirmaBitis,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime.now(),
                                );
                                if (p != null)
                                  setState(() => _karsilastirmaBitis = p);
                              },
                              icon: const Icon(Icons.calendar_today, size: 14),
                              label: Text(
                                'Bitiş: ${_karsilastirmaBitis.day}.${_karsilastirmaBitis.month}.${_karsilastirmaBitis.year}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],

                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _yukle,
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('Göster'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0288D1),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Yükleniyor ───────────────────────────────────────────────
          if (_yukleniyor) const Center(child: CircularProgressIndicator()),

          // ── Sonuçlar ─────────────────────────────────────────────────
          if (!_yukleniyor && _subeVeriler.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              donemBaslik,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF0288D1),
              ),
            ),
            const SizedBox(height: 12),

            // Genel toplam kartı
            _toplamKart(),

            // Şube kartları
            if (_karsilastirmaAcik && _karsilastirmaVeriler.isNotEmpty)
              ..._subeVeriler.map((v) {
                final kars = _karsilastirmaVeriler.firstWhere(
                  (k) => k['subeId'] == v['subeId'],
                  orElse: () => {
                    'subeId': v['subeId'],
                    'subeAd': v['subeAd'],
                    'ciro': 0.0,
                    'harcama': 0.0,
                    'ekGiderler': [],
                    'donemKey': '',
                  },
                );
                return _subeKarti(v, karsilastirma: kars);
              })
            else
              ..._subeVeriler.map((v) => _subeKarti(v)),
          ],

          if (!_yukleniyor && _subeVeriler.isEmpty && _yukleniyor == false) ...[
            const SizedBox(height: 24),
            Center(
              child: Text(
                'Filtre seçip "Göster" butonuna basın.',
                style: TextStyle(color: Colors.grey[500]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Önerili Metin Alanı (Overlay tabanlı, sıfır controller çakışması) ─────────
//
// Tek controller — doğrudan widget.ctrl. Overlay tamamen ayrı katmanda.
// Yazma deneyimine hiç dokunmaz; listeden seçince ctrl.text güncellenir.
