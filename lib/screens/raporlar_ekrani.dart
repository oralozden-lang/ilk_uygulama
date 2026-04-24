import 'ozet_ekrani.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/utils.dart';
import '../widgets/sube_ozet_tablosu.dart';
// ─── Özet Ekranı ──────────────────────────────────────────────────────────────

// ─── Raporlar Ekranı ──────────────────────────────────────────────────────────

class RaporlarEkrani extends StatelessWidget {
  final List<String> subeler;
  const RaporlarEkrani({super.key, required this.subeler});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F7FA),
        appBar: AppBar(
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFF01579B),
                  Color(0xFF0288D1),
                  Color(0xFF29B6F6)
                ],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
          ),
          title: const Text('Raporlar'),
          backgroundColor: const Color(0xFF0288D1),
          foregroundColor: Colors.white,
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            indicatorColor: Colors.white,
            tabs: [
              Tab(icon: Icon(Icons.bar_chart), text: 'Dönem Raporu'),
              Tab(icon: Icon(Icons.store, size: 18), text: 'Şube Özet'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            RaporlarWidget(subeler: subeler),
            SubeOzetTablosu(subeler: subeler),
          ],
        ),
      ),
    );
  }
}

class RaporlarWidget extends StatefulWidget {
  final List<String> subeler;
  final bool merkziGiderGor;
  const RaporlarWidget({this.subeler = const [], this.merkziGiderGor = true});

  @override
  State<RaporlarWidget> createState() => RaporlarWidgetState();
}

class RaporlarWidgetState extends State<RaporlarWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  // Filtre seçenekleri
  String _filtreModu = 'ay'; // 'ay' veya 'aralik'
  int _secilenYil = DateTime.now().year;
  int _secilenAy = DateTime.now().month;
  DateTime _baslangic = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _bitis = DateTime.now();
  String? _secilenSube; // null = tüm şubeler
  Set<String> _secilenSubeler =
      {}; // çoklu seçim (kullanılmıyor — dropdown A seçeneği)

  // Karşılaştırma
  bool _karsilastirmaAcik = false;
  int _karsilastirmaYil = DateTime.now().year;
  int _karsilastirmaAy =
      DateTime.now().month == 1 ? 12 : DateTime.now().month - 1;
  // Karşılaştırma tarih aralığı (filtreModu == 'aralik' ise)
  DateTime _karsilastirmaBaslangic = DateTime(
    DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year,
    DateTime.now().month == 1 ? 12 : DateTime.now().month - 1,
    1,
  );
  DateTime _karsilastirmaBitis = DateTime(
    DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year,
    DateTime.now().month == 1 ? 12 : DateTime.now().month - 1 + 1,
    0,
  );

  bool _yukleniyor = false;
  List<Map<String, dynamic>> _kayitlar = [];
  List<Map<String, dynamic>> _karsilastirmaKayitlar = [];
  Map<String, String> _subeAdlari = {};
  List<String> _giderTurleri = [];

  // Gerçekleşen giderler — aktif dönem ve karşılaştırma dönemi ayrı
  Map<String, List<Map<String, dynamic>>> _gerceklesenGiderler = {};
  Map<String, List<Map<String, dynamic>>> _gerceklesenGiderlerKarsilastirma =
      {};

  // Özet kart akordeon
  bool _ozetDetayAcik = false;

  // Tablo sıralama
  bool _siralamaArtan = false; // false = yeniden eskiye (varsayılan)

  // Arama
  final TextEditingController _aramaCtrl = TextEditingController();
  String _aramaMetni = '';
  String? _aramaGiderTuru; // null = tür filtresi yok

  final List<String> _aylar = [
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

  @override
  void initState() {
    super.initState();
    _giderTurleriYukle();
    // Şube adları yüklendikten sonra raporu getir
    _subeAdlariniYukleVeRaporuGetir();
  }

  Future<void> _subeAdlariniYukleVeRaporuGetir() async {
    await _subeAdlariniYukle();
    if (mounted) _yukle();
  }

  @override
  void dispose() {
    _aramaCtrl.dispose();
    super.dispose();
  }

  Future<void> _giderTurleriYukle() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('giderTurleri')
          .get();
      final liste =
          (doc.data()?['liste'] as List?)?.map((e) => e.toString()).toList() ??
              [];
      if (mounted) setState(() => _giderTurleri = liste);
    } catch (_) {}
  }

  Future<void> _subeAdlariniYukle() async {
    final snapshot =
        await FirebaseFirestore.instance.collection('subeler').get();
    final adlar = <String, String>{};
    for (var doc in snapshot.docs) {
      adlar[doc.id] = (doc.data()['ad'] as String?) ?? doc.id;
    }
    if (mounted) setState(() => _subeAdlari = adlar);
  }

  List<String> get _aktifSubeler =>
      widget.subeler.isNotEmpty ? widget.subeler : _subeAdlari.keys.toList();

  Future<void> _yukle() async {
    setState(() => _yukleniyor = true);
    try {
      final donemKey = _baslangicKey().substring(0, 7);
      final hedefSubeler =
          _secilenSube != null ? [_secilenSube!] : _aktifSubeler;
      final results = await Future.wait([
        _veriCek(_baslangicKey(), _bitisKey()),
        if (_karsilastirmaAcik)
          _veriCek(_karsilastirmaBas(), _karsilastirmaBit())
        else
          Future.value(<Map<String, dynamic>>[]),
        // Gerçekleşen giderlerini paralel çek
        Future.wait(
          hedefSubeler.map(
            (subeId) => FirebaseFirestore.instance
                .collection('gerceklesen_giderler')
                .doc('${subeId}_$donemKey')
                .get()
                .then(
                  (doc) => MapEntry(
                    subeId,
                    (doc.data()?['giderler'] as List?)
                            ?.cast<Map<String, dynamic>>() ??
                        [],
                  ),
                ),
          ),
        ).then(
          (entries) => Map.fromEntries(
            entries.cast<MapEntry<String, List<Map<String, dynamic>>>>(),
          ),
        ),
      ]);
      _kayitlar = results[0] as List<Map<String, dynamic>>;
      if (_karsilastirmaAcik)
        _karsilastirmaKayitlar = results[1] as List<Map<String, dynamic>>;
      _gerceklesenGiderler =
          results[2] as Map<String, List<Map<String, dynamic>>>;

      // Karşılaştırma dönemi için ayrı gerceklesen giderleri çek
      if (_karsilastirmaAcik) {
        final karsilastirmaDonemKey = _karsilastirmaBas().substring(0, 7);
        final karsilastirmaGiderEntries = await Future.wait(
          hedefSubeler.map(
            (subeId) => FirebaseFirestore.instance
                .collection('gerceklesen_giderler')
                .doc('${subeId}_$karsilastirmaDonemKey')
                .get()
                .then(
                  (doc) => MapEntry(
                    subeId,
                    (doc.data()?['giderler'] as List?)
                            ?.cast<Map<String, dynamic>>() ??
                        [],
                  ),
                ),
          ),
        );
        _gerceklesenGiderlerKarsilastirma = Map.fromEntries(
          karsilastirmaGiderEntries
              .cast<MapEntry<String, List<Map<String, dynamic>>>>(),
        );
      } else {
        _gerceklesenGiderlerKarsilastirma = {};
      }
    } finally {
      if (mounted) setState(() => _yukleniyor = false);
    }
  }

  Future<List<Map<String, dynamic>>> _veriCek(String bas, String bit) async {
    final hedefSubeler = _secilenSube != null ? [_secilenSube!] : _aktifSubeler;
    // Tüm şubeler paralel — sıralı await yerine Future.wait
    final futures = hedefSubeler.map((sube) async {
      final snapshot = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(sube)
          .collection('gunluk')
          .where('tarih', isGreaterThanOrEqualTo: bas)
          .where('tarih', isLessThanOrEqualTo: bit)
          .orderBy('tarih')
          .get();
      return snapshot.docs
          .map((doc) => {...doc.data(), '_subeId': sube})
          .toList();
    });

    final results = await Future.wait(futures);
    final sonuc = <Map<String, dynamic>>[];
    for (final liste in results) {
      sonuc.addAll(liste);
    }
    sonuc.sort(
      (a, b) => (a['tarih'] as String).compareTo(b['tarih'] as String),
    );
    return sonuc; // Her zaman artan — gösterimde _siralamaArtan kontrol eder
  }

  String _baslangicKey() {
    if (_filtreModu == 'ay') {
      return '${_secilenYil.toString().padLeft(4, '0')}-${_secilenAy.toString().padLeft(2, '0')}-01';
    }
    return '${_baslangic.year.toString().padLeft(4, '0')}-${_baslangic.month.toString().padLeft(2, '0')}-${_baslangic.day.toString().padLeft(2, '0')}';
  }

  String _bitisKey() {
    if (_filtreModu == 'ay') {
      final sonGun = DateTime(_secilenYil, _secilenAy + 1, 0).day;
      return '${_secilenYil.toString().padLeft(4, '0')}-${_secilenAy.toString().padLeft(2, '0')}-${sonGun.toString().padLeft(2, '0')}';
    }
    return '${_bitis.year.toString().padLeft(4, '0')}-${_bitis.month.toString().padLeft(2, '0')}-${_bitis.day.toString().padLeft(2, '0')}';
  }

  String _karsilastirmaBas() {
    if (_filtreModu == 'aralik') {
      return '${_karsilastirmaBaslangic.year.toString().padLeft(4, '0')}-${_karsilastirmaBaslangic.month.toString().padLeft(2, '0')}-${_karsilastirmaBaslangic.day.toString().padLeft(2, '0')}';
    }
    return '${_karsilastirmaYil.toString().padLeft(4, '0')}-${_karsilastirmaAy.toString().padLeft(2, '0')}-01';
  }

  String _karsilastirmaBit() {
    if (_filtreModu == 'aralik') {
      return '${_karsilastirmaBitis.year.toString().padLeft(4, '0')}-${_karsilastirmaBitis.month.toString().padLeft(2, '0')}-${_karsilastirmaBitis.day.toString().padLeft(2, '0')}';
    }
    final sonGun = DateTime(_karsilastirmaYil, _karsilastirmaAy + 1, 0).day;
    return '${_karsilastirmaYil.toString().padLeft(4, '0')}-${_karsilastirmaAy.toString().padLeft(2, '0')}-${sonGun.toString().padLeft(2, '0')}';
  }

  double _topla(List<Map<String, dynamic>> kayitlar, String alan) =>
      kayitlar.fold(0.0, (s, k) => s + ((k[alan] as num?) ?? 0).toDouble());

  String _fmt(double v) {
    final parts = v.toStringAsFixed(2).split('.');
    final buf = StringBuffer();
    for (int i = 0; i < parts[0].length; i++) {
      if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write('.');
      buf.write(parts[0][i]);
    }
    return '${buf.toString()},${parts[1]} ₺';
  }

  // Döviz miktarları için — ₺ ikonu EKLEMEz
  String _fmtSade(double v) {
    final parts = v.toStringAsFixed(2).split('.');
    final buf = StringBuffer();
    for (int i = 0; i < parts[0].length; i++) {
      if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write('.');
      buf.write(parts[0][i]);
    }
    return '${buf.toString()},${parts[1]}';
  }

  Widget _ozet(
    List<Map<String, dynamic>> kayitlar,
    String baslik,
    Color renk, {
    Map<String, List<Map<String, dynamic>>> gerceklesenGiderler = const {},
    bool detayAcik = false,
    VoidCallback? onDetayToggle,
    bool merkziGiderGor = true,
  }) {
    if (kayitlar.isEmpty) return const SizedBox.shrink();
    final satis = _topla(kayitlar, 'gunlukSatisToplami');
    final pos = _topla(kayitlar, 'toplamPos');
    final bankaya = _topla(kayitlar, 'bankayaYatirilan');
    final nakitCikis = _topla(kayitlar, 'toplamNakitCikis');

    // Toplam Harcama = Harcamalar + Ana Kasa Harc. + Diğer Alımlar
    //                + GELEN transfer (gider) - GİDEN transfer (gelir)
    double harcama = _topla(kayitlar, 'toplamHarcama') +
        _topla(kayitlar, 'toplamAnaKasaHarcama');
    for (final k in kayitlar) {
      // Diğer alımlar (liste alan)
      final digerAlimlar = (k['digerAlimlar'] as List?)?.cast<Map>() ?? [];
      for (final da in digerAlimlar) {
        harcama += (da['tutar'] as num? ?? 0).toDouble();
      }
      // Transferler: GELEN = gider (+), GİDEN = gelir (-)
      final transferler = (k['transferler'] as List?)?.cast<Map>() ?? [];
      for (final t in transferler) {
        final kat = t['kategori'] as String? ?? '';
        final tutar = (t['tutar'] as num? ?? 0).toDouble();
        if (kat == 'GELEN') harcama += tutar;
        if (kat == 'GİDEN') harcama -= tutar;
      }
    }

    // Her şubenin dönem içindeki SON kaydının anaKasaKalanini topla
    // (kayitlar tarih sıralı ve _subeId içeriyor)
    final Map<String, double> subeAnaKasa = {};
    for (final k in kayitlar) {
      final subeId = k['_subeId'] as String? ?? '';
      final deger = ((k['anaKasaKalani'] as num?) ?? 0).toDouble();
      subeAnaKasa[subeId] =
          deger; // son gelen üzerine yazar → en son tarih kalır
    }
    final anaKasa = subeAnaKasa.values.fold(0.0, (s, v) => s + v);

    // Ana Kasa harcama toplamı
    final anaKasaHarcama = _topla(kayitlar, 'toplamAnaKasaHarcama');
    // Nakit çıkış TL
    final nakitCikisTL = _topla(kayitlar, 'toplamNakitCikis');

    // Bankaya yatan döviz toplamları
    final Map<String, double> bankaDovizOzet = {};
    for (final k in kayitlar) {
      final list = (k['bankaDovizler'] as List?)?.cast<Map>() ?? [];
      for (final d in list) {
        final cins = d['cins'] as String? ?? '';
        final miktar = (d['miktar'] as num? ?? 0).toDouble();
        bankaDovizOzet[cins] = (bankaDovizOzet[cins] ?? 0) + miktar;
      }
    }

    // Nakit çıkış döviz toplamları
    final Map<String, double> nakitDovizOzet = {};
    for (final k in kayitlar) {
      final list = (k['nakitDovizler'] as List?)?.cast<Map>() ?? [];
      for (final d in list) {
        final cins = d['cins'] as String? ?? '';
        final miktar = (d['miktar'] as num? ?? 0).toDouble();
        if (miktar > 0)
          nakitDovizOzet[cins] = (nakitDovizOzet[cins] ?? 0) + miktar;
      }
    }

    // Son Ana Kasa döviz kalanları — son kayıttan al
    final Map<String, double> akDovizOzetMap = {};
    if (kayitlar.isNotEmpty) {
      // Her şubenin son kaydından döviz kalanlarını al
      final Map<String, Map<String, double>> subeDoviz = {};
      for (final k in kayitlar) {
        final subeId = k['_subeId'] as String? ?? '';
        final dovizMap = (k['dovizAnaKasaKalanlari'] as Map?) ?? {};
        if (dovizMap.isNotEmpty) {
          subeDoviz[subeId] = dovizMap.map(
            (key, val) => MapEntry(key.toString(), (val as num).toDouble()),
          );
        }
      }
      for (final dovizMap in subeDoviz.values) {
        for (final entry in dovizMap.entries) {
          akDovizOzetMap[entry.key] =
              (akDovizOzetMap[entry.key] ?? 0) + entry.value;
        }
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: renk.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: renk,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  baslik,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                Text(
                  '${kayitlar.length} gün',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                _satirOzet('Satış Toplamı', satis, Colors.red[700]!),
                _satirOzet('Toplam POS', pos, const Color(0xFF0288D1)),
                // Detaylar akordeon butonu
                if (onDetayToggle != null)
                  InkWell(
                    onTap: onDetayToggle,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            detayAcik ? 'Daha az' : 'Detaylar',
                            style: TextStyle(fontSize: 12, color: renk),
                          ),
                          Icon(
                            detayAcik ? Icons.expand_less : Icons.expand_more,
                            size: 16,
                            color: renk,
                          ),
                        ],
                      ),
                    ),
                  ),
                if (detayAcik || onDetayToggle == null) ...[
                  _satirOzet('Harcamalar', harcama, Colors.orange[700]!),
                  if (nakitCikisTL > 0)
                    _satirOzet(
                      'Nakit Çıkış (TL)',
                      nakitCikisTL,
                      Colors.purple[700]!,
                    ),
                  ...nakitDovizOzet.entries.where((e) => e.value > 0).map((e) {
                    final sembol = e.key == 'USD'
                        ? r'$'
                        : e.key == 'EUR'
                            ? '€'
                            : e.key == 'GBP'
                                ? '£'
                                : e.key;
                    final dovizRenk = e.key == 'USD'
                        ? const Color(0xFFE65100)
                        : e.key == 'EUR'
                            ? const Color(0xFF6A1B9A)
                            : e.key == 'GBP'
                                ? const Color(0xFF1B5E20)
                                : Colors.purple[600]!;
                    return _satirOzetDoviz(
                      'Nakit Çıkış ($sembol)',
                      e.value,
                      sembol,
                      dovizRenk,
                    );
                  }),
                  _satirOzet('Bankaya Yatan (TL)', bankaya, Colors.teal[700]!),
                  ...bankaDovizOzet.entries.where((e) => e.value > 0).map((e) {
                    final sembol = e.key == 'USD'
                        ? r'$'
                        : e.key == 'EUR'
                            ? '€'
                            : e.key == 'GBP'
                                ? '£'
                                : e.key;
                    final dovizRenk = e.key == 'USD'
                        ? const Color(0xFFE65100)
                        : e.key == 'EUR'
                            ? const Color(0xFF6A1B9A)
                            : e.key == 'GBP'
                                ? const Color(0xFF1B5E20)
                                : Colors.teal[600]!;
                    return _satirOzetDoviz(
                      'Bankaya Yatan ($sembol)',
                      e.value,
                      sembol,
                      dovizRenk,
                    );
                  }),
                  // Diğer Alımlar toplamı
                  Builder(
                    builder: (ctx) {
                      double digerToplam = 0;
                      for (final k in kayitlar) {
                        for (final da
                            in (k['digerAlimlar'] as List?)?.cast<Map>() ??
                                []) {
                          digerToplam += (da['tutar'] as num? ?? 0).toDouble();
                        }
                      }
                      if (digerToplam <= 0) return const SizedBox.shrink();
                      return _satirOzet(
                        'Diğer Alımlar',
                        digerToplam,
                        Colors.brown[600]!,
                      );
                    },
                  ),
                  // Transferler net
                  Builder(
                    builder: (ctx) {
                      double transferGelen = 0, transferGiden = 0;
                      for (final k in kayitlar) {
                        for (final t
                            in (k['transferler'] as List?)?.cast<Map>() ?? []) {
                          final kat = t['kategori'] as String? ?? '';
                          final tutar = (t['tutar'] as num? ?? 0).toDouble();
                          if (kat == 'GELEN') transferGelen += tutar;
                          if (kat == 'GİDEN') transferGiden += tutar;
                        }
                      }
                      if (transferGelen == 0 && transferGiden == 0)
                        return const SizedBox.shrink();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (transferGelen > 0)
                            _satirOzet(
                              'Transfer Gelen',
                              transferGelen,
                              Colors.indigo[400]!,
                            ),
                          if (transferGiden > 0)
                            _satirOzet(
                              'Transfer Giden',
                              transferGiden,
                              Colors.indigo[700]!,
                            ),
                        ],
                      );
                    },
                  ),
                  // Gerçekleşen merkezi giderler
                  if (merkziGiderGor)
                    Builder(
                      builder: (ctx) {
                        final Map<String, double> turToplam = {};
                        for (final entry in gerceklesenGiderler.entries) {
                          for (final g in entry.value) {
                            final ad = (g['ad'] ?? g['tur'] ?? '').toString();
                            final tutar = (g['tutar'] as num? ?? 0).toDouble();
                            if (ad.isNotEmpty && tutar > 0)
                              turToplam[ad] = (turToplam[ad] ?? 0) + tutar;
                          }
                        }
                        if (turToplam.isEmpty) return const SizedBox.shrink();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 6, bottom: 2),
                              child: Text(
                                'Merkezi Giderler',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.black45,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            ...turToplam.entries.map(
                              (e) => _satirOzet(
                                e.key,
                                e.value,
                                Colors.deepOrange[700]!,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                ], // if detayAcik
                // ── Her zaman görünen bölüm (akordeon dışı) ──────────────
                const Divider(),
                _satirOzetBold(
                  'Son Ana Kasa (TL)',
                  anaKasa,
                  anaKasa >= 0 ? Colors.green[700]! : Colors.red[700]!,
                ),
                ...akDovizOzetMap.entries.where((e) => e.value > 0).map((e) {
                  final sembol = e.key == 'USD'
                      ? r'$'
                      : e.key == 'EUR'
                          ? '€'
                          : e.key == 'GBP'
                              ? '£'
                              : e.key;
                  final dovizRenk = e.key == 'USD'
                      ? const Color(0xFFE65100)
                      : e.key == 'EUR'
                          ? const Color(0xFF6A1B9A)
                          : e.key == 'GBP'
                              ? const Color(0xFF1B5E20)
                              : Colors.green[600]!;
                  return _satirOzetDoviz(
                    'Ana Kasa ($sembol)',
                    e.value,
                    sembol,
                    dovizRenk,
                  );
                }),
                // Net Kar — sadece merkezi giderleri görebilenlere
                if (merkziGiderGor)
                  Builder(
                    builder: (ctx) {
                      double toplamGider = harcama;
                      // Merkezi giderler
                      for (final entry in gerceklesenGiderler.entries) {
                        for (final g in entry.value) {
                          toplamGider += (g['tutar'] as num? ?? 0).toDouble();
                        }
                      }
                      final netKar = satis - toplamGider;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Divider(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: netKar >= 0
                                  ? Colors.green[50]
                                  : Colors.red[50],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Net Kar',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    _fmt(netKar),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: netKar >= 0
                                          ? Colors.green[700]
                                          : Colors.red[700],
                                    ),
                                    textAlign: TextAlign.end,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _satirOzet(String label, double deger, Color renk) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: renk, fontSize: 13),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              _fmt(deger),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: renk,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );

  Widget _satirOzetBold(String label, double deger, Color renk) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: renk,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              _fmt(deger),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: renk,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );

  // Döviz satırı — sembol + miktar, ₺ yok
  Widget _satirOzetDoviz(
    String label,
    double deger,
    String sembol,
    Color renk,
  ) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: renk, fontSize: 13),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '$sembol ${_fmtSade(deger)}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: renk,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );

  Widget _detayListesi(List<Map<String, dynamic>> kayitlar) {
    if (kayitlar.isEmpty) return const SizedBox.shrink();

    // Kolon genişlikleri
    const double wTarih = 90;
    const double wSatis = 90;
    const double wAnaKasa = 110;
    const double wPos = 80;
    const double wHarcama = 90;
    const double wGunlukKasa = 100;
    const double wAnaKasaHarc = 90;
    const double wNakit = 90;
    const double wTransfer = 100;
    const double wDiger = 90;
    const double wBankaya = 100;
    const double colGap = 5;
    const double rowH = 42.0;
    const double rowHSube = 54.0;
    const double baslikH = 40.0;

    final cokSube = _aktifSubeler.length > 1;

    // Sembol yardımcısı
    String sembol(String cins) => cins == 'USD'
        ? r'$'
        : cins == 'EUR'
            ? '€'
            : cins == 'GBP'
                ? '£'
                : cins;

    // Döviz özet string
    // Döviz listesi döndürür — cins bazlı renk için List<Map>
    List<Map<String, dynamic>> dovizList(Map<String, dynamic> k, String alan) {
      final list = (k[alan] as List?)?.cast<Map>() ?? [];
      final result = <Map<String, dynamic>>[];
      // Sabit sıra: USD, EUR, GBP
      for (final cins in ['USD', 'EUR', 'GBP']) {
        for (final d in list) {
          if (d['cins'] == cins) {
            final miktar = (d['miktar'] as num? ?? 0).toDouble();
            if (miktar > 0) result.add({'cins': cins, 'miktar': miktar});
          }
        }
      }
      return result;
    }

    // Geriye dönük uyumluluk için string versiyonu
    String dovizStr(Map<String, dynamic> k, String alan) {
      return dovizList(k, alan)
          .map((d) =>
              '${sembol(d['cins'] as String)}${_fmtSade(d['miktar'] as double)}')
          .join(' ');
    }

    final satirlar = kayitlar.asMap().entries.map((e) {
      final idx = e.key;
      final k = e.value;
      final zebra = idx % 2 == 0;
      final tarih = k['tarihGoster'] ?? k['tarih'] ?? '';
      final subeAd = _subeAdlari[k['_subeId']] ?? '';
      final subeId = k['_subeId'] as String? ?? '';

      final satis = ((k['gunlukSatisToplami'] as num?) ?? 0).toDouble();
      final pos = ((k['toplamPos'] as num?) ?? 0).toDouble();
      final anaKasa = ((k['anaKasaKalani'] as num?) ?? 0).toDouble();
      final anaKasaHarc = ((k['toplamAnaKasaHarcama'] as num?) ?? 0).toDouble();
      final nakit = ((k['toplamNakitCikis'] as num?) ?? 0).toDouble();

      // Günlük kasa kalanı (TL)
      final gunlukKasaTL = ((k['gunlukKasaKalaniTL'] as num?) ?? 0).toDouble();

      // Günlük kasa döviz string
      final dovizlerList = (k['dovizler'] as List?)?.cast<Map>() ?? [];
      final gunlukKasaDoviz = dovizlerList
          .where((d) => (d['miktar'] as num? ?? 0) > 0)
          .map(
            (d) =>
                '${sembol(d['cins'] as String? ?? '')}${_fmtSade((d['miktar'] as num).toDouble())}',
          )
          .join(' ');

      // Ana kasa döviz string
      final akDovizMap = (k['dovizAnaKasaKalanlari'] as Map?) ?? {};
      final anaKasaDoviz = akDovizMap.entries
          .where((e) => (e.value as num? ?? 0) > 0)
          .map(
            (e) =>
                '${sembol(e.key.toString())}${_fmtSade((e.value as num).toDouble())}',
          )
          .join(' ');

      // Nakit çıkış döviz
      final nakitDoviz = dovizStr(k, 'nakitDovizler');

      // Harcamalar sadece günlük kasa (toplamHarcama)
      final harcama = ((k['toplamHarcama'] as num?) ?? 0).toDouble();

      // Diğer alımlar
      double diger = 0;
      for (final da in (k['digerAlimlar'] as List?)?.cast<Map>() ?? []) {
        diger += (da['tutar'] as num? ?? 0).toDouble();
      }

      // Transferler giden / gelen
      double transferGiden = 0, transferGelen = 0;
      for (final t in (k['transferler'] as List?)?.cast<Map>() ?? []) {
        final kat = t['kategori'] as String? ?? '';
        final tutar = (t['tutar'] as num? ?? 0).toDouble();
        if (kat == 'GİDEN') transferGiden += tutar;
        if (kat == 'GELEN') transferGelen += tutar;
      }

      final h = (cokSube && subeAd.isNotEmpty) ? rowHSube : rowH;
      return {
        'zebra': zebra,
        'tarih': tarih,
        'subeAd': subeAd,
        'subeId': subeId,
        'tarihRaw': k['tarih'] ?? '',
        'satis': satis,
        'anaKasa': anaKasa,
        'anaKasaDoviz': anaKasaDoviz,
        'pos': pos,
        'harcama': harcama,
        'gunlukKasaTL': gunlukKasaTL,
        'gunlukKasaDoviz': gunlukKasaDoviz,
        'anaKasaHarc': anaKasaHarc,
        'nakit': nakit,
        'nakitDoviz': nakitDoviz,
        'bankaya': ((k['bankayaYatirilan'] as num?) ?? 0).toDouble(),
        'bankaDoviz': dovizList(k, 'bankaDovizler'),
        'transferGiden': transferGiden,
        'transferGelen': transferGelen,
        'diger': diger,
        'h': h,
      };
    }).toList();

    // Başlık satırı
    Widget _sagBaslik() => Container(
          height: baslikH,
          padding: const EdgeInsets.only(right: 8),
          color: const Color(0xFF0288D1),
          child: Row(
            children: [
              for (final col in [
                ('Satış', wSatis, Colors.white),
                ('Ana Kasa', wAnaKasa, const Color(0xFF81D4FA)),
                ('Bankaya Yatan', wBankaya, const Color(0xFF80CBC4)),
                ('POS', wPos, Colors.white),
                ('Harc.(Kasa)', wHarcama, const Color(0xFFEF9A9A)),
                ('G.Kasa', wGunlukKasa, const Color(0xFFA5D6A7)),
                ('A.K.Harc.', wAnaKasaHarc, const Color(0xFFFFCC80)),
                ('Nakit Çıkış', wNakit, const Color(0xFFCE93D8)),
                ('Transfer G/A', wTransfer, const Color(0xFFB3E5FC)),
                ('Diğer Alım', wDiger, const Color(0xFFD7CCC8)),
              ]) ...[
                SizedBox(width: colGap),
                SizedBox(
                  width: col.$2,
                  child: Text(
                    col.$1,
                    style: TextStyle(
                      color: col.$3,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        );

    // Hücre widget'ı
    Widget _hucre(double w, Widget child) => SizedBox(width: w, child: child);

    Widget _txt(String v, {Color? renk, bool bold = false, double size = 11}) =>
        Text(
          v,
          style: TextStyle(
            fontSize: size,
            color: renk,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
          textAlign: TextAlign.right,
          overflow: TextOverflow.ellipsis,
        );

    Widget _col2(String v1, String v2, Color renk1) => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (v1.isNotEmpty) _txt(v1, renk: renk1, bold: true),
            if (v2.isNotEmpty) _txt(v2, renk: renk1.withOpacity(0.7), size: 10),
          ],
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Sol sabit: Tarih ────────────────────────────────────────
            Column(
              children: [
                Container(
                  width: wTarih,
                  height: baslikH,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0288D1),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(14),
                    ),
                  ),
                  child: const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Tarih',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                ...satirlar.map((s) {
                  final zebra = s['zebra'] as bool;
                  final tarih = s['tarih'] as String;
                  final subeAd = s['subeAd'] as String;
                  final h = s['h'] as double;
                  final subeId = s['subeId'] as String;
                  final tarihRaw = s['tarihRaw'] as String;
                  return GestureDetector(
                    onTap: () {
                      final parts = tarihRaw.split('-');
                      if (parts.length != 3) return;
                      final dt = DateTime(
                        int.parse(parts[0]),
                        int.parse(parts[1]),
                        int.parse(parts[2]),
                      );
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => OzetEkrani(
                            subeKodu: subeId,
                            baslangicTarihi: dt,
                            subeler: widget.subeler,
                            gecmisGunHakki: -1,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      width: wTarih,
                      height: h,
                      color: zebra ? Colors.grey[50] : Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (cokSube && subeAd.isNotEmpty)
                            Text(
                              subeAd,
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 9,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  tarih,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Icon(
                                Icons.chevron_right,
                                size: 12,
                                color: Colors.grey[400],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),

            // ── Sağ kaydırılabilir sütunlar ────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sagBaslik(),
                    ...satirlar.map((s) {
                      final zebra = s['zebra'] as bool;
                      final h = s['h'] as double;
                      final satis = s['satis'] as double;
                      final anaKasa = s['anaKasa'] as double;
                      final anaKasaDoviz = s['anaKasaDoviz'] as String;
                      final pos = s['pos'] as double;
                      final harcama = s['harcama'] as double;
                      final gunlukKasaTL = s['gunlukKasaTL'] as double;
                      final gunlukKasaDoviz = s['gunlukKasaDoviz'] as String;
                      final anaKasaHarc = s['anaKasaHarc'] as double;
                      final nakit = s['nakit'] as double;
                      final nakitDoviz = s['nakitDoviz'] as String;
                      final transferGiden = s['transferGiden'] as double;
                      final transferGelen = s['transferGelen'] as double;
                      final diger = s['diger'] as double;
                      // bankaya ve bankaDoviz s map'ten doğrudan okunuyor

                      return Container(
                        height: h,
                        color: zebra ? Colors.grey[50] : Colors.white,
                        padding: const EdgeInsets.only(right: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(width: colGap),
                            _hucre(
                              wSatis,
                              _txt(
                                _fmt(satis),
                                renk: Colors.red[700],
                                bold: true,
                              ),
                            ),
                            SizedBox(width: colGap),
                            _hucre(
                              wAnaKasa,
                              _col2(
                                _fmt(anaKasa),
                                anaKasaDoviz,
                                anaKasa >= 0
                                    ? Colors.green[700]!
                                    : Colors.red[700]!,
                              ),
                            ),
                            SizedBox(width: colGap),
                            _hucre(
                              wBankaya,
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  _txt(
                                    (s['bankaya'] as double) > 0
                                        ? _fmt(s['bankaya'] as double)
                                        : '—',
                                    renk: Colors.teal[700],
                                    bold: true,
                                  ),
                                  ...(s['bankaDoviz']
                                          as List<Map<String, dynamic>>)
                                      .map((d) {
                                    final cn = d['cins'] as String;
                                    final sem = cn == 'USD'
                                        ? r'$'
                                        : cn == 'EUR'
                                            ? '€'
                                            : '£';
                                    final renk = cn == 'USD'
                                        ? const Color(0xFFE65100)
                                        : cn == 'EUR'
                                            ? const Color(0xFF6A1B9A)
                                            : const Color(0xFF1B5E20);
                                    return _txt(
                                      '$sem${_fmtSade(d['miktar'] as double)}',
                                      renk: renk,
                                      size: 10,
                                    );
                                  }),
                                ],
                              ),
                            ),
                            SizedBox(width: colGap),
                            _hucre(wPos, _txt(_fmt(pos))),
                            SizedBox(width: colGap),
                            _hucre(
                              wHarcama,
                              _txt(
                                harcama > 0 ? _fmt(harcama) : '—',
                                renk: harcama > 0
                                    ? Colors.orange[700]
                                    : Colors.grey[400],
                              ),
                            ),
                            SizedBox(width: colGap),
                            _hucre(
                              wGunlukKasa,
                              _col2(
                                _fmt(gunlukKasaTL),
                                gunlukKasaDoviz,
                                gunlukKasaTL >= 0
                                    ? Colors.green[800]!
                                    : Colors.red[700]!,
                              ),
                            ),
                            SizedBox(width: colGap),
                            _hucre(
                              wAnaKasaHarc,
                              _txt(
                                anaKasaHarc > 0 ? _fmt(anaKasaHarc) : '—',
                                renk: anaKasaHarc > 0
                                    ? Colors.orange[800]
                                    : Colors.grey[400],
                              ),
                            ),
                            SizedBox(width: colGap),
                            _hucre(
                              wNakit,
                              _col2(
                                nakit > 0 ? _fmt(nakit) : '—',
                                nakitDoviz,
                                Colors.purple[700]!,
                              ),
                            ),
                            SizedBox(width: colGap),
                            _hucre(
                              wTransfer,
                              transferGiden == 0 && transferGelen == 0
                                  ? _txt('—', renk: Colors.grey[400])
                                  : Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        if (transferGiden > 0)
                                          _txt(
                                            'G:${_fmtSade(transferGiden)} ₺',
                                            renk: Colors.red[700],
                                            size: 10,
                                          ),
                                        if (transferGelen > 0)
                                          _txt(
                                            'A:${_fmtSade(transferGelen)} ₺',
                                            renk: Colors.blue[600],
                                            size: 10,
                                          ),
                                      ],
                                    ),
                            ),
                            SizedBox(width: colGap),
                            _hucre(
                              wDiger,
                              _txt(
                                diger > 0 ? _fmt(diger) : '—',
                                renk: diger > 0
                                    ? Colors.brown[600]
                                    : Colors.grey[400],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final tumSubeler = _aktifSubeler;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Filtre Kartı ──────────────────────────────────────────────
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

                  // Şube seçimi — açılır kutu (tek seçim)
                  if (tumSubeler.length > 1) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      value: _secilenSube,
                      decoration: const InputDecoration(
                        labelText: 'Şube',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Tüm Şubeler'),
                        ),
                        ...tumSubeler.map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text(_subeAdlari[s] ?? s),
                          ),
                        ),
                      ],
                      onChanged: (v) => setState(() => _secilenSube = v),
                    ),
                  ],

                  // Karşılaştırma
                  const SizedBox(height: 8),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Önceki Dönemle Karşılaştır'),
                    value: _karsilastirmaAcik,
                    activeColor: const Color(0xFF0288D1),
                    onChanged: (v) => setState(() => _karsilastirmaAcik = v),
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
                    if (_filtreModu == 'aralik')
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
                              icon: const Icon(Icons.calendar_today, size: 16),
                              label: Text(
                                '${_karsilastirmaBaslangic.day.toString().padLeft(2, '0')}.${_karsilastirmaBaslangic.month.toString().padLeft(2, '0')}.${_karsilastirmaBaslangic.year}',
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
                                  initialDate: _karsilastirmaBitis,
                                  firstDate: _karsilastirmaBaslangic,
                                  lastDate: DateTime.now(),
                                );
                                if (p != null)
                                  setState(() => _karsilastirmaBitis = p);
                              },
                              icon: const Icon(Icons.calendar_today, size: 16),
                              label: Text(
                                '${_karsilastirmaBitis.day.toString().padLeft(2, '0')}.${_karsilastirmaBitis.month.toString().padLeft(2, '0')}.${_karsilastirmaBitis.year}',
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],

                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _yukle,
                      icon: _yukleniyor
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.search),
                      label: const Text('Raporu Getir'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0288D1),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Sonuçlar ──────────────────────────────────────────────────
          if (_kayitlar.isNotEmpty) ...[
            const SizedBox(height: 16),
            if (_karsilastirmaAcik && _karsilastirmaKayitlar.isNotEmpty)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _ozet(
                      _karsilastirmaKayitlar,
                      _filtreModu == 'aralik'
                          ? '${_karsilastirmaBaslangic.day}.${_karsilastirmaBaslangic.month} – ${_karsilastirmaBitis.day}.${_karsilastirmaBitis.month}.${_karsilastirmaBitis.year}'
                          : '${_aylar[_karsilastirmaAy - 1]} $_karsilastirmaYil',
                      Colors.blueGrey[600]!,
                      gerceklesenGiderler: _gerceklesenGiderlerKarsilastirma,
                      merkziGiderGor: widget.merkziGiderGor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ozet(
                      _kayitlar,
                      _filtreModu == 'ay'
                          ? '${_aylar[_secilenAy - 1]} $_secilenYil'
                          : 'Seçili Dönem',
                      const Color(0xFF0288D1),
                      gerceklesenGiderler: _gerceklesenGiderler,
                      detayAcik: _ozetDetayAcik,
                      onDetayToggle: () =>
                          setState(() => _ozetDetayAcik = !_ozetDetayAcik),
                      merkziGiderGor: widget.merkziGiderGor,
                    ),
                  ),
                ],
              )
            else
              _ozet(
                _kayitlar,
                _filtreModu == 'ay'
                    ? '${_aylar[_secilenAy - 1]} $_secilenYil'
                    : 'Seçili Dönem',
                const Color(0xFF0288D1),
                gerceklesenGiderler: _gerceklesenGiderler,
                detayAcik: _ozetDetayAcik,
                onDetayToggle: () =>
                    setState(() => _ozetDetayAcik = !_ozetDetayAcik),
                merkziGiderGor: widget.merkziGiderGor,
              ),

            const SizedBox(height: 8),
            _aramaSection(),
            const SizedBox(height: 8),
            // ── Sıralama ikonu ────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  _siralamaArtan ? 'Eskiden Yeniye' : 'Yeniden Eskiye',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(
                    _siralamaArtan ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18,
                    color: const Color(0xFF0288D1),
                  ),
                  tooltip: _siralamaArtan
                      ? 'Yeniden Eskiye Sırala'
                      : 'Eskiden Yeniye Sırala',
                  onPressed: () =>
                      setState(() => _siralamaArtan = !_siralamaArtan),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _detayListesi(
              _siralamaArtan ? _kayitlar : _kayitlar.reversed.toList(),
            ),
            const SizedBox(height: 32),
          ],
        ],
      ),
    );
  }

  // ── Açıklama Arama Bölümü ───────────────────────────────────────────────────
  Widget _aramaSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Gider Ara',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: Color(0xFF0288D1),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _aramaCtrl,
                    decoration: InputDecoration(
                      labelText: 'Açıklama ara (örn: Avans)',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _aramaMetni.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => setState(() {
                                _aramaCtrl.clear();
                                _aramaMetni = '';
                              }),
                            )
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) =>
                        setState(() => _aramaMetni = v.trim().toLowerCase()),
                  ),
                ),
                if (_giderTurleri.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  DropdownButton<String?>(
                    value: _aramaGiderTuru,
                    hint: const Text('Tür', style: TextStyle(fontSize: 13)),
                    underline: const SizedBox(),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Tümü')),
                      ..._giderTurleri.map(
                        (t) => DropdownMenuItem(
                          value: t,
                          child: Text(t, style: const TextStyle(fontSize: 13)),
                        ),
                      ),
                    ],
                    onChanged: (v) => setState(() => _aramaGiderTuru = v),
                  ),
                ],
              ],
            ),
            if (_aramaMetni.isNotEmpty || _aramaGiderTuru != null) ...[
              const SizedBox(height: 12),
              _aramaListesi(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _aramaListesi() {
    final sonuclar = <Map<String, dynamic>>[];
    final aranan = _aramaMetni.toLowerCase();

    for (final k in _kayitlar) {
      final tarih = k['tarihGoster'] ?? k['tarih'] ?? '';
      final subeAd = _subeAdlari[k['_subeId']] ?? '';

      void ekle(String kaynak, String aciklama, double tutar) {
        final aciklamaLower = aciklama.toLowerCase();
        final turEslesi = _aramaGiderTuru == null ||
            aciklamaLower.contains(_aramaGiderTuru!.toLowerCase());
        final metinEslesi = aranan.isEmpty || aciklamaLower.contains(aranan);
        if (turEslesi && metinEslesi && tutar > 0) {
          sonuclar.add({
            'tarih': tarih,
            'sube': subeAd,
            'kaynak': kaynak,
            'aciklama': aciklama,
            'tutar': tutar,
          });
        }
      }

      // Harcamalar
      for (final h in (k['harcamalar'] as List?)?.cast<Map>() ?? []) {
        ekle(
          'Harcama',
          (h['aciklama'] ?? '').toString(),
          (h['tutar'] as num? ?? 0).toDouble(),
        );
      }
      // Ana Kasa Harcamaları
      for (final h in (k['anaKasaHarcamalari'] as List?)?.cast<Map>() ?? []) {
        ekle(
          'Ana Kasa Harc.',
          (h['aciklama'] ?? '').toString(),
          (h['tutar'] as num? ?? 0).toDouble(),
        );
      }
      // Nakit Çıkışlar
      for (final h in (k['nakitCikislar'] as List?)?.cast<Map>() ?? []) {
        ekle(
          'Nakit Çıkış',
          (h['aciklama'] ?? '').toString(),
          (h['tutar'] as num? ?? 0).toDouble(),
        );
      }
      // Diğer Alımlar
      for (final h in (k['digerAlimlar'] as List?)?.cast<Map>() ?? []) {
        ekle(
          'Diğer Alım',
          (h['aciklama'] ?? '').toString(),
          (h['tutar'] as num? ?? 0).toDouble(),
        );
      }
      // Transferler
      for (final t in (k['transferler'] as List?)?.cast<Map>() ?? []) {
        final kat = t['kategori'] as String? ?? '';
        final aciklama = (t['aciklama'] ?? '').toString();
        final tutar = (t['tutar'] as num? ?? 0).toDouble();
        ekle('Transfer $kat', aciklama, tutar);
      }
    }

    // Gerçekleşen merkezi giderler — yetki varsa
    if (widget.merkziGiderGor)
      for (final entry in _gerceklesenGiderler.entries) {
        final subeAd = _subeAdlari[entry.key] ?? entry.key;
        for (final g in entry.value) {
          final ad = (g['ad'] ?? g['tur'] ?? '').toString();
          final tutar = (g['tutar'] as num? ?? 0).toDouble();
          final turEslesi = _aramaGiderTuru == null ||
              ad.toLowerCase().contains(_aramaGiderTuru!.toLowerCase());
          final metinEslesi =
              aranan.isEmpty || ad.toLowerCase().contains(aranan);
          if (turEslesi && metinEslesi && tutar > 0) {
            sonuclar.add({
              'tarih': '—',
              'sube': subeAd,
              'kaynak': 'Merkezi',
              'aciklama': ad,
              'tutar': tutar,
            });
          }
        }
      }

    if (sonuclar.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Sonuç bulunamadı.',
          style: TextStyle(color: Colors.grey[500], fontSize: 13),
        ),
      );
    }

    final toplam = sonuclar.fold(0.0, (s, r) => s + (r['tutar'] as double));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Toplam
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF0288D1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${sonuclar.length} kayıt',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              Text(
                _fmt(toplam),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Liste
        ...sonuclar.map(
          (r) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Row(
              children: [
                // Kaynak etiketi
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: r['kaynak'] == 'Merkezi'
                        ? Colors.deepOrange[50]
                        : r['kaynak'].toString().contains('Transfer')
                            ? Colors.indigo[50]
                            : Colors.orange[50],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    r['kaynak'] as String,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: r['kaynak'] == 'Merkezi'
                          ? Colors.deepOrange[700]
                          : r['kaynak'].toString().contains('Transfer')
                              ? Colors.indigo[700]
                              : Colors.orange[700],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Tarih + şube
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r['tarih'] as String,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black45,
                      ),
                    ),
                    if ((r['sube'] as String).isNotEmpty)
                      Text(
                        r['sube'] as String,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.black45,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 8),
                // Açıklama — uzun basınca tam metin
                Expanded(
                  child: Tooltip(
                    message: r['aciklama'] as String,
                    preferBelow: true,
                    child: Text(
                      r['aciklama'] as String,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Tutar
                Text(
                  _fmt(r['tutar'] as double),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
