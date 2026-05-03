import 'on_hazirlik_ekrani.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/utils.dart';
import '../widgets/sube_ozet_tablosu.dart';

class RaporlarEkrani extends StatelessWidget {
  final List<String> subeler;
  const RaporlarEkrani({super.key, required this.subeler});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
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
              Tab(icon: Icon(Icons.payment, size: 18), text: 'Ödeme Kanalları'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            RaporlarWidget(subeler: subeler),
            SubeOzetTablosu(subeler: subeler),
            OdemeKanallariWidget(subeler: subeler),
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

  String _filtreModu = 'ay';
  int _secilenYil = DateTime.now().year;
  int _secilenAy = DateTime.now().month;
  DateTime _baslangic = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _bitis = DateTime.now();
  Set<String> _secilenSubeler = {};
  bool _subeSecimAcik = false;

  bool _karsilastirmaAcik = false;
  int _karsilastirmaYil = DateTime.now().year;
  int _karsilastirmaAy =
      DateTime.now().month == 1 ? 12 : DateTime.now().month - 1;
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

  Map<String, List<Map<String, dynamic>>> _gerceklesenGiderler = {};
  Map<String, List<Map<String, dynamic>>> _gerceklesenGiderlerKarsilastirma =
      {};

  bool _ozetDetayAcik = false;
  bool _siralamaArtan = false;

  final TextEditingController _aramaCtrl = TextEditingController();
  String _aramaMetni = '';
  String? _aramaGiderTuru;

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
    // Tüm başlangıç yüklemelerini paralel başlat — zincirleme await yok
    _ilkYukle();
  }

  /// Paralel başlatır — şube adları beklenmeden rapor hemen çekilir
  Future<void> _ilkYukle() async {
    _subeAdlariniYukle(); // await yok — sadece görüntüleme için
    _giderTurleriYukle(); // await yok
    if (mounted) _yukle(); // hemen başla
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
    try {
      final snapshot =
          await FirebaseFirestore.instance.collection('subeler').get();
      final adlar = <String, String>{};
      for (var doc in snapshot.docs) {
        adlar[doc.id] = (doc.data()['ad'] as String?) ?? doc.id;
      }
      if (mounted) setState(() => _subeAdlari = adlar);
    } catch (_) {}
  }

  List<String> get _aktifSubeler =>
      widget.subeler.isNotEmpty ? widget.subeler : _subeAdlari.keys.toList();

  Future<void> _yukle() async {
    if (!mounted) return;
    setState(() => _yukleniyor = true);
    try {
      final hedefSubeler =
          _secilenSubeler.isEmpty ? _aktifSubeler : _secilenSubeler.toList();
      final donemKey = _baslangicKey().substring(0, 7);

      // ── Tüm sorgular tek seferde paralel ──────────────────────────────
      final futures = <Future>[
        _veriCek(_baslangicKey(), _bitisKey()),
        if (_karsilastirmaAcik)
          _veriCek(_karsilastirmaBas(), _karsilastirmaBit())
        else
          Future.value(<Map<String, dynamic>>[]),
        _gerceklesenGiderlerCek(hedefSubeler, donemKey),
        if (_karsilastirmaAcik)
          _gerceklesenGiderlerCek(
              hedefSubeler, _karsilastirmaBas().substring(0, 7))
        else
          Future.value(<String, List<Map<String, dynamic>>>{}),
      ];

      final results = await Future.wait(futures);

      if (!mounted) return;
      setState(() {
        _kayitlar = results[0] as List<Map<String, dynamic>>;
        _karsilastirmaKayitlar =
            _karsilastirmaAcik ? results[1] as List<Map<String, dynamic>> : [];
        _gerceklesenGiderler =
            results[2] as Map<String, List<Map<String, dynamic>>>;
        _gerceklesenGiderlerKarsilastirma = _karsilastirmaAcik
            ? results[3] as Map<String, List<Map<String, dynamic>>>
            : {};
        _yukleniyor = false;
      });
    } catch (e) {
      if (mounted) setState(() => _yukleniyor = false);
    }
  }

  /// Şube bazlı gerçekleşen giderleri paralel çeker
  Future<Map<String, List<Map<String, dynamic>>>> _gerceklesenGiderlerCek(
    List<String> subeIdsler,
    String donemKey,
  ) async {
    final entries = await Future.wait(
      subeIdsler.map((subeId) async {
        try {
          final doc = await FirebaseFirestore.instance
              .collection('gerceklesen_giderler')
              .doc('${subeId}_$donemKey')
              .get();
          return MapEntry(
            subeId,
            (doc.data()?['giderler'] as List?)?.cast<Map<String, dynamic>>() ??
                [],
          );
        } catch (_) {
          return MapEntry(subeId, <Map<String, dynamic>>[]);
        }
      }),
    );
    return Map.fromEntries(entries);
  }

  Future<List<Map<String, dynamic>>> _veriCek(String bas, String bit) async {
    final hedefSubeler = _secilenSubeler.isEmpty ? _aktifSubeler : _secilenSubeler.toList();
    final futures = hedefSubeler.map((sube) async {
      try {
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
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    });

    final results = await Future.wait(futures);
    final sonuc = <Map<String, dynamic>>[];
    for (final liste in results) sonuc.addAll(liste);
    sonuc
        .sort((a, b) => (a['tarih'] as String).compareTo(b['tarih'] as String));
    return sonuc;
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

    double harcama = _topla(kayitlar, 'toplamHarcama') +
        _topla(kayitlar, 'toplamAnaKasaHarcama');
    for (final k in kayitlar) {
      final digerAlimlar = (k['digerAlimlar'] as List?)?.cast<Map>() ?? [];
      for (final da in digerAlimlar) {
        harcama += (da['tutar'] as num? ?? 0).toDouble();
      }
      final transferler = (k['transferler'] as List?)?.cast<Map>() ?? [];
      for (final t in transferler) {
        final kat = t['kategori'] as String? ?? '';
        final tutar = (t['tutar'] as num? ?? 0).toDouble();
        if (kat == 'GELEN') harcama += tutar;
        if (kat == 'GİDEN') harcama -= tutar;
      }
    }

    final Map<String, double> subeAnaKasa = {};
    for (final k in kayitlar) {
      final subeId = k['_subeId'] as String? ?? '';
      final deger = ((k['anaKasaKalani'] as num?) ?? 0).toDouble();
      subeAnaKasa[subeId] = deger;
    }
    final anaKasa = subeAnaKasa.values.fold(0.0, (s, v) => s + v);
    final anaKasaHarcama = _topla(kayitlar, 'toplamAnaKasaHarcama');
    final nakitCikisTL = _topla(kayitlar, 'toplamNakitCikis');

    final Map<String, double> bankaDovizOzet = {};
    for (final k in kayitlar) {
      for (final d in (k['bankaDovizler'] as List?)?.cast<Map>() ?? []) {
        final cins = d['cins'] as String? ?? '';
        final miktar = (d['miktar'] as num? ?? 0).toDouble();
        bankaDovizOzet[cins] = (bankaDovizOzet[cins] ?? 0) + miktar;
      }
    }

    final Map<String, double> nakitDovizOzet = {};
    for (final k in kayitlar) {
      for (final d in (k['nakitDovizler'] as List?)?.cast<Map>() ?? []) {
        final cins = d['cins'] as String? ?? '';
        final miktar = (d['miktar'] as num? ?? 0).toDouble();
        if (miktar > 0)
          nakitDovizOzet[cins] = (nakitDovizOzet[cins] ?? 0) + miktar;
      }
    }

    final Map<String, double> akDovizOzetMap = {};
    if (kayitlar.isNotEmpty) {
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
              offset: const Offset(0, 2))
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
                Text(baslik,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
                Text('${kayitlar.length} gün',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                _satirOzet('Satış Toplamı', satis, Colors.red[700]!),
                _satirOzet('Toplam POS', pos, const Color(0xFF0288D1)),
                if (onDetayToggle != null)
                  InkWell(
                    onTap: onDetayToggle,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(detayAcik ? 'Daha az' : 'Detaylar',
                              style: TextStyle(fontSize: 12, color: renk)),
                          Icon(
                              detayAcik ? Icons.expand_less : Icons.expand_more,
                              size: 16,
                              color: renk),
                        ],
                      ),
                    ),
                  ),
                if (detayAcik || onDetayToggle == null) ...[
                  _satirOzet('Harcamalar', harcama, Colors.orange[700]!),
                  if (nakitCikisTL > 0)
                    _satirOzet(
                        'Nakit Çıkış (TL)', nakitCikisTL, Colors.purple[700]!),
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
                        'Nakit Çıkış ($sembol)', e.value, sembol, dovizRenk);
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
                        'Bankaya Yatan ($sembol)', e.value, sembol, dovizRenk);
                  }),
                  Builder(builder: (ctx) {
                    double digerToplam = 0;
                    for (final k in kayitlar) {
                      for (final da
                          in (k['digerAlimlar'] as List?)?.cast<Map>() ?? []) {
                        digerToplam += (da['tutar'] as num? ?? 0).toDouble();
                      }
                    }
                    if (digerToplam <= 0) return const SizedBox.shrink();
                    return _satirOzet(
                        'Diğer Alımlar', digerToplam, Colors.brown[600]!);
                  }),
                  Builder(builder: (ctx) {
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
                            _satirOzet('Transfer Gelen', transferGelen,
                                Colors.indigo[400]!),
                          if (transferGiden > 0)
                            _satirOzet('Transfer Giden', transferGiden,
                                Colors.indigo[700]!),
                        ]);
                  }),
                  if (merkziGiderGor)
                    Builder(builder: (ctx) {
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
                              child: Text('Merkezi Giderler',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.black45,
                                      fontWeight: FontWeight.w600)),
                            ),
                            ...turToplam.entries.map((e) => _satirOzet(
                                e.key, e.value, Colors.deepOrange[700]!)),
                          ]);
                    }),
                ],
                const Divider(),
                _satirOzetBold('Son Ana Kasa (TL)', anaKasa,
                    anaKasa >= 0 ? Colors.green[700]! : Colors.red[700]!),
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
                      'Ana Kasa ($sembol)', e.value, sembol, dovizRenk);
                }),
                if (merkziGiderGor)
                  Builder(builder: (ctx) {
                    double toplamGider = harcama;
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
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: netKar >= 0
                                  ? Colors.green[50]
                                  : Colors.red[50],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Net Kar',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14)),
                                const SizedBox(width: 8),
                                Flexible(
                                    child: Text(
                                  _fmt(netKar),
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: netKar >= 0
                                          ? Colors.green[700]
                                          : Colors.red[700]),
                                  textAlign: TextAlign.end,
                                  overflow: TextOverflow.ellipsis,
                                )),
                              ],
                            ),
                          ),
                        ]);
                  }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _satirOzet(String label, double deger, Color renk) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: renk, fontSize: 13))),
          const SizedBox(width: 4),
          Text(_fmt(deger),
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: renk, fontSize: 13)),
        ]),
      );

  Widget _satirOzetBold(String label, double deger, Color renk) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: renk, fontSize: 14))),
          const SizedBox(width: 4),
          Text(_fmt(deger),
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: renk, fontSize: 14)),
        ]),
      );

  Widget _satirOzetDoviz(
          String label, double deger, String sembol, Color renk) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: renk, fontSize: 13))),
          const SizedBox(width: 4),
          Text('$sembol ${_fmtSade(deger)}',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: renk, fontSize: 13)),
        ]),
      );

  Widget _detayListesi(List<Map<String, dynamic>> kayitlar) {
    if (kayitlar.isEmpty) return const SizedBox.shrink();

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

    String sembol(String cins) => cins == 'USD'
        ? r'$'
        : cins == 'EUR'
            ? '€'
            : cins == 'GBP'
                ? '£'
                : cins;

    List<Map<String, dynamic>> dovizList(Map<String, dynamic> k, String alan) {
      final list = (k[alan] as List?)?.cast<Map>() ?? [];
      final result = <Map<String, dynamic>>[];
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

    String dovizStr(Map<String, dynamic> k, String alan) {
      return dovizList(k, alan)
          .map((d) =>
              '${sembol(d['cins'] as String)}${_fmtSade(d['miktar'] as double)}')
          .join(' ');
    }

    // Satır verilerini önceden hesapla — build sırasında hesaplama yok
    final satirlar = kayitlar.asMap().entries.map((e) {
      final idx = e.key;
      final k = e.value;
      final subeId = k['_subeId'] as String? ?? '';
      final subeAd = _subeAdlari[subeId] ?? '';
      final h = (cokSube && subeAd.isNotEmpty) ? rowHSube : rowH;

      double diger = 0;
      for (final da in (k['digerAlimlar'] as List?)?.cast<Map>() ?? []) {
        diger += (da['tutar'] as num? ?? 0).toDouble();
      }
      double transferGiden = 0, transferGelen = 0;
      for (final t in (k['transferler'] as List?)?.cast<Map>() ?? []) {
        final kat = t['kategori'] as String? ?? '';
        final tutar = (t['tutar'] as num? ?? 0).toDouble();
        if (kat == 'GİDEN') transferGiden += tutar;
        if (kat == 'GELEN') transferGelen += tutar;
      }

      final akDovizMap = (k['dovizAnaKasaKalanlari'] as Map?) ?? {};
      final anaKasaDoviz = akDovizMap.entries
          .where((e) => (e.value as num? ?? 0) > 0)
          .map((e) =>
              '${sembol(e.key.toString())}${_fmtSade((e.value as num).toDouble())}')
          .join(' ');

      final dovizlerList = (k['dovizler'] as List?)?.cast<Map>() ?? [];
      final gunlukKasaDoviz = dovizlerList
          .where((d) => (d['miktar'] as num? ?? 0) > 0)
          .map((d) =>
              '${sembol(d['cins'] as String? ?? '')}${_fmtSade((d['miktar'] as num).toDouble())}')
          .join(' ');

      return {
        'zebra': idx % 2 == 0,
        'tarih': k['tarihGoster'] ?? k['tarih'] ?? '',
        'subeAd': subeAd,
        'subeId': subeId,
        'tarihRaw': k['tarih'] ?? '',
        'satis': ((k['gunlukSatisToplami'] as num?) ?? 0).toDouble(),
        'anaKasa': ((k['anaKasaKalani'] as num?) ?? 0).toDouble(),
        'anaKasaDoviz': anaKasaDoviz,
        'pos': ((k['toplamPos'] as num?) ?? 0).toDouble(),
        'harcama': ((k['toplamHarcama'] as num?) ?? 0).toDouble(),
        'gunlukKasaTL': ((k['gunlukKasaKalaniTL'] as num?) ?? 0).toDouble(),
        'gunlukKasaDoviz': gunlukKasaDoviz,
        'anaKasaHarc': ((k['toplamAnaKasaHarcama'] as num?) ?? 0).toDouble(),
        'nakit': ((k['toplamNakitCikis'] as num?) ?? 0).toDouble(),
        'nakitDoviz': dovizStr(k, 'nakitDovizler'),
        'bankaya': ((k['bankayaYatirilan'] as num?) ?? 0).toDouble(),
        'bankaDoviz': dovizList(k, 'bankaDovizler'),
        'transferGiden': transferGiden,
        'transferGelen': transferGelen,
        'diger': diger,
        'h': h,
      };
    }).toList();

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
                        fontSize: 11),
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        );

    Widget _txt(String v, {Color? renk, bool bold = false, double size = 11}) =>
        Text(
          v,
          style: TextStyle(
              fontSize: size,
              color: renk,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal),
          textAlign: TextAlign.right,
          overflow: TextOverflow.ellipsis,
        );

    // ── Overflow düzeltmesi: Column'u Flexible ile sar ──
    Widget _col2(String v1, String v2, Color renk1) => LayoutBuilder(
          builder: (ctx, constraints) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (v1.isNotEmpty)
                FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _txt(v1, renk: renk1, bold: true)),
              if (v2.isNotEmpty)
                FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _txt(v2, renk: renk1.withOpacity(0.7), size: 10)),
            ],
          ),
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
                offset: const Offset(0, 2))
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                Container(
                  width: wTarih,
                  height: baslikH,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0288D1),
                    borderRadius:
                        BorderRadius.only(topLeft: Radius.circular(14)),
                  ),
                  child: const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Tarih',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12)),
                  ),
                ),
                ...satirlar.map((s) {
                  final h = s['h'] as double;
                  final subeAd = s['subeAd'] as String;
                  final tarihRaw = s['tarihRaw'] as String;
                  final subeId = s['subeId'] as String;
                  return GestureDetector(
                    onTap: () {
                      final parts = tarihRaw.split('-');
                      if (parts.length != 3) return;
                      final dt = DateTime(int.parse(parts[0]),
                          int.parse(parts[1]), int.parse(parts[2]));
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => OnHazirlikEkrani(
                              subeKodu: subeId,
                              subeler: widget.subeler,
                              baslangicTarihi: dt,
                              gecmisGunHakki: -1,
                              initialTabIndex: 5, // Özet & Kapat sekmesi
                            ),
                          ));
                    },
                    child: Container(
                      width: wTarih,
                      height: h,
                      color:
                          (s['zebra'] as bool) ? Colors.grey[50] : Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (cokSube && subeAd.isNotEmpty)
                            Text(subeAd,
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 9),
                                overflow: TextOverflow.ellipsis),
                          Row(children: [
                            Expanded(
                                child: Text(s['tarih'] as String,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500),
                                    overflow: TextOverflow.ellipsis)),
                            Icon(Icons.chevron_right,
                                size: 12, color: Colors.grey[400]),
                          ]),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sagBaslik(),
                    ...satirlar.map((s) {
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

                      return Container(
                        height: h,
                        color: (s['zebra'] as bool)
                            ? Colors.grey[50]
                            : Colors.white,
                        padding: const EdgeInsets.only(right: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(width: colGap),
                            SizedBox(
                                width: wSatis,
                                child: _txt(_fmt(satis),
                                    renk: Colors.red[700], bold: true)),
                            SizedBox(width: colGap),
                            SizedBox(
                                width: wAnaKasa,
                                child: _col2(
                                    _fmt(anaKasa),
                                    anaKasaDoviz,
                                    anaKasa >= 0
                                        ? Colors.green[700]!
                                        : Colors.red[700]!)),
                            SizedBox(width: colGap),
                            SizedBox(
                              width: wBankaya,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: _txt(
                                          (s['bankaya'] as double) > 0
                                              ? _fmt(s['bankaya'] as double)
                                              : '—',
                                          renk: Colors.teal[700],
                                          bold: true)),
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
                                    return FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: _txt(
                                            '$sem${_fmtSade(d['miktar'] as double)}',
                                            renk: renk,
                                            size: 10));
                                  }),
                                ],
                              ),
                            ),
                            SizedBox(width: colGap),
                            SizedBox(width: wPos, child: _txt(_fmt(pos))),
                            SizedBox(width: colGap),
                            SizedBox(
                                width: wHarcama,
                                child: _txt(harcama > 0 ? _fmt(harcama) : '—',
                                    renk: harcama > 0
                                        ? Colors.orange[700]
                                        : Colors.grey[400])),
                            SizedBox(width: colGap),
                            SizedBox(
                                width: wGunlukKasa,
                                child: _col2(
                                    _fmt(gunlukKasaTL),
                                    gunlukKasaDoviz,
                                    gunlukKasaTL >= 0
                                        ? Colors.green[800]!
                                        : Colors.red[700]!)),
                            SizedBox(width: colGap),
                            SizedBox(
                                width: wAnaKasaHarc,
                                child: _txt(
                                    anaKasaHarc > 0 ? _fmt(anaKasaHarc) : '—',
                                    renk: anaKasaHarc > 0
                                        ? Colors.orange[800]
                                        : Colors.grey[400])),
                            SizedBox(width: colGap),
                            SizedBox(
                                width: wNakit,
                                child: _col2(nakit > 0 ? _fmt(nakit) : '—',
                                    nakitDoviz, Colors.purple[700]!)),
                            SizedBox(width: colGap),
                            SizedBox(
                              width: wTransfer,
                              child: transferGiden == 0 && transferGelen == 0
                                  ? _txt('—', renk: Colors.grey[400])
                                  : Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        if (transferGiden > 0)
                                          FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: _txt(
                                                  'G:${_fmtSade(transferGiden)} ₺',
                                                  renk: Colors.red[700],
                                                  size: 10)),
                                        if (transferGelen > 0)
                                          FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: _txt(
                                                  'A:${_fmtSade(transferGelen)} ₺',
                                                  renk: Colors.blue[600],
                                                  size: 10)),
                                      ],
                                    ),
                            ),
                            SizedBox(width: colGap),
                            SizedBox(
                                width: wDiger,
                                child: _txt(diger > 0 ? _fmt(diger) : '—',
                                    renk: diger > 0
                                        ? Colors.brown[600]
                                        : Colors.grey[400])),
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
    super.build(context);
    final tumSubeler = _aktifSubeler;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'ay',
                          label: Text('Ay Seç'),
                          icon: Icon(Icons.calendar_month)),
                      ButtonSegment(
                          value: 'aralik',
                          label: Text('Tarih Aralığı'),
                          icon: Icon(Icons.date_range)),
                    ],
                    selected: {_filtreModu},
                    onSelectionChanged: (s) =>
                        setState(() => _filtreModu = s.first),
                  ),
                  const SizedBox(height: 12),
                  if (_filtreModu == 'ay') ...[
                    Row(children: [
                      Expanded(
                          child: DropdownButtonFormField<int>(
                        value: _secilenAy,
                        decoration: const InputDecoration(
                            labelText: 'Ay', border: OutlineInputBorder()),
                        items: List.generate(
                            12,
                            (i) => DropdownMenuItem(
                                value: i + 1, child: Text(_aylar[i]))),
                        onChanged: (v) => setState(() => _secilenAy = v!),
                      )),
                      const SizedBox(width: 8),
                      Expanded(
                          child: DropdownButtonFormField<int>(
                        value: _secilenYil,
                        decoration: const InputDecoration(
                            labelText: 'Yıl', border: OutlineInputBorder()),
                        items: List.generate(5, (i) => DateTime.now().year - i)
                            .map((y) =>
                                DropdownMenuItem(value: y, child: Text('$y')))
                            .toList(),
                        onChanged: (v) => setState(() => _secilenYil = v!),
                      )),
                    ]),
                  ] else ...[
                    Row(children: [
                      Expanded(
                          child: OutlinedButton.icon(
                        onPressed: () async {
                          final p = await showDatePicker(
                              context: context,
                              initialDate: _baslangic,
                              firstDate: DateTime(2020),
                              lastDate: DateTime.now());
                          if (p != null) setState(() => _baslangic = p);
                        },
                        icon: const Icon(Icons.calendar_today, size: 16),
                        label: Text(
                            '${_baslangic.day.toString().padLeft(2, '0')}.${_baslangic.month.toString().padLeft(2, '0')}.${_baslangic.year}'),
                      )),
                      const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('—')),
                      Expanded(
                          child: OutlinedButton.icon(
                        onPressed: () async {
                          final p = await showDatePicker(
                              context: context,
                              initialDate: _bitis,
                              firstDate: _baslangic,
                              lastDate: DateTime.now());
                          if (p != null) setState(() => _bitis = p);
                        },
                        icon: const Icon(Icons.calendar_today, size: 16),
                        label: Text(
                            '${_bitis.day.toString().padLeft(2, '0')}.${_bitis.month.toString().padLeft(2, '0')}.${_bitis.year}'),
                      )),
                    ]),
                  ],
                  if (tumSubeler.length > 1) ...[
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () =>
                          setState(() => _subeSecimAcik = !_subeSecimAcik),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black38),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(children: [
                          const Text('Şube',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.black54)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _secilenSubeler.isEmpty
                                  ? 'Tümü'
                                  : _secilenSubeler
                                      .map((s) => _subeAdlari[s] ?? s)
                                      .join(', '),
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(
                              _subeSecimAcik
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 18,
                              color: Colors.black54),
                        ]),
                      ),
                    ),
                    if (_subeSecimAcik) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          FilterChip(
                            label: const Text('Tümü'),
                            selected: _secilenSubeler.isEmpty,
                            onSelected: (_) =>
                                setState(() => _secilenSubeler.clear()),
                            selectedColor:
                                const Color(0xFF0288D1).withOpacity(0.18),
                            checkmarkColor: const Color(0xFF0288D1),
                          ),
                          ...tumSubeler.map((s) => FilterChip(
                                label: Text(_subeAdlari[s] ?? s),
                                selected: _secilenSubeler.contains(s),
                                onSelected: (secildi) => setState(() {
                                  if (secildi) {
                                    _secilenSubeler.add(s);
                                  } else {
                                    _secilenSubeler.remove(s);
                                  }
                                }),
                                selectedColor:
                                    const Color(0xFF0288D1).withOpacity(0.18),
                                checkmarkColor: const Color(0xFF0288D1),
                              )),
                        ],
                      ),
                    ],
                  ],
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
                      Row(children: [
                        Expanded(
                            child: DropdownButtonFormField<int>(
                          value: _karsilastirmaAy,
                          decoration: const InputDecoration(
                              labelText: 'Karş. Ay',
                              border: OutlineInputBorder()),
                          items: List.generate(
                              12,
                              (i) => DropdownMenuItem(
                                  value: i + 1, child: Text(_aylar[i]))),
                          onChanged: (v) =>
                              setState(() => _karsilastirmaAy = v!),
                        )),
                        const SizedBox(width: 8),
                        Expanded(
                            child: DropdownButtonFormField<int>(
                          value: _karsilastirmaYil,
                          decoration: const InputDecoration(
                              labelText: 'Karş. Yıl',
                              border: OutlineInputBorder()),
                          items: List.generate(
                                  5, (i) => DateTime.now().year - i)
                              .map((y) =>
                                  DropdownMenuItem(value: y, child: Text('$y')))
                              .toList(),
                          onChanged: (v) =>
                              setState(() => _karsilastirmaYil = v!),
                        )),
                      ]),
                    if (_filtreModu == 'aralik')
                      Row(children: [
                        Expanded(
                            child: OutlinedButton.icon(
                          onPressed: () async {
                            final p = await showDatePicker(
                                context: context,
                                initialDate: _karsilastirmaBaslangic,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now());
                            if (p != null)
                              setState(() => _karsilastirmaBaslangic = p);
                          },
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(
                              '${_karsilastirmaBaslangic.day.toString().padLeft(2, '0')}.${_karsilastirmaBaslangic.month.toString().padLeft(2, '0')}.${_karsilastirmaBaslangic.year}'),
                        )),
                        const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('—')),
                        Expanded(
                            child: OutlinedButton.icon(
                          onPressed: () async {
                            final p = await showDatePicker(
                                context: context,
                                initialDate: _karsilastirmaBitis,
                                firstDate: _karsilastirmaBaslangic,
                                lastDate: DateTime.now());
                            if (p != null)
                              setState(() => _karsilastirmaBitis = p);
                          },
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(
                              '${_karsilastirmaBitis.day.toString().padLeft(2, '0')}.${_karsilastirmaBitis.month.toString().padLeft(2, '0')}.${_karsilastirmaBitis.year}'),
                        )),
                      ]),
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
                                  color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.search),
                      label: const Text('Raporu Getir'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0288D1),
                          foregroundColor: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
                  )),
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
                  )),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(_siralamaArtan ? 'Eskiden Yeniye' : 'Yeniden Eskiye',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(
                      _siralamaArtan
                          ? Icons.arrow_upward
                          : Icons.arrow_downward,
                      size: 18,
                      color: const Color(0xFF0288D1)),
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
                _siralamaArtan ? _kayitlar : _kayitlar.reversed.toList()),
            const SizedBox(height: 32),
          ],
        ],
      ),
    );
  }

  Widget _aramaSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Gider Ara',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Color(0xFF0288D1))),
            const SizedBox(height: 10),
            Row(children: [
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
                              }))
                      : null,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) =>
                    setState(() => _aramaMetni = v.trim().toLowerCase()),
              )),
              if (_giderTurleri.isNotEmpty) ...[
                const SizedBox(width: 8),
                DropdownButton<String?>(
                  value: _aramaGiderTuru,
                  hint: const Text('Tür', style: TextStyle(fontSize: 13)),
                  underline: const SizedBox(),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Tümü')),
                    ..._giderTurleri.map((t) => DropdownMenuItem(
                        value: t,
                        child: Text(t, style: const TextStyle(fontSize: 13)))),
                  ],
                  onChanged: (v) => setState(() => _aramaGiderTuru = v),
                ),
              ],
            ]),
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

      final tarihRaw = k['tarih'] as String? ?? '';
      final subeId = k['_subeId'] as String? ?? '';
      void ekle(String kaynak, String aciklama, double tutar) {
        final aciklamaLower = aciklama.toLowerCase();
        final turEslesi = _aramaGiderTuru == null ||
            aciklamaLower.contains(_aramaGiderTuru!.toLowerCase());
        final metinEslesi = aranan.isEmpty || aciklamaLower.contains(aranan);
        if (turEslesi && metinEslesi && tutar > 0) {
          sonuclar.add({
            'tarih': tarih,
            'tarihRaw': tarihRaw,
            'subeId': subeId,
            'sube': subeAd,
            'kaynak': kaynak,
            'aciklama': aciklama,
            'tutar': tutar,
          });
        }
      }

      for (final h in (k['harcamalar'] as List?)?.cast<Map>() ?? [])
        ekle('Harcama', (h['aciklama'] ?? '').toString(),
            (h['tutar'] as num? ?? 0).toDouble());
      for (final h in (k['anaKasaHarcamalari'] as List?)?.cast<Map>() ?? [])
        ekle('Ana Kasa Harc.', (h['aciklama'] ?? '').toString(),
            (h['tutar'] as num? ?? 0).toDouble());
      for (final h in (k['nakitCikislar'] as List?)?.cast<Map>() ?? [])
        ekle('Nakit Çıkış', (h['aciklama'] ?? '').toString(),
            (h['tutar'] as num? ?? 0).toDouble());
      for (final h in (k['nakitDovizler'] as List?)?.cast<Map>() ?? []) {
        final aciklama = (h['aciklama'] ?? '').toString().trim();
        final cins = (h['cins'] ?? '').toString();
        final sembol = cins == 'USD'
            ? r'$'
            : cins == 'EUR'
                ? '€'
                : cins == 'GBP'
                    ? '£'
                    : cins;
        if (aciklama.isNotEmpty)
          ekle('Nakit Çıkış ($sembol)', aciklama,
              (h['miktar'] as num? ?? 0).toDouble());
      }
      for (final h in (k['digerAlimlar'] as List?)?.cast<Map>() ?? [])
        ekle('Diğer Alım', (h['aciklama'] ?? '').toString(),
            (h['tutar'] as num? ?? 0).toDouble());
      for (final t in (k['transferler'] as List?)?.cast<Map>() ?? [])
        ekle(
            'Transfer ${t['kategori'] ?? ''}',
            (t['aciklama'] ?? '').toString(),
            (t['tutar'] as num? ?? 0).toDouble());
    }

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
          if (turEslesi && metinEslesi && tutar > 0)
            sonuclar.add({
              'tarih': '—',
              'sube': subeAd,
              'kaynak': 'Merkezi',
              'aciklama': ad,
              'tutar': tutar
            });
        }
      }

    if (sonuclar.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text('Sonuç bulunamadı.',
            style: TextStyle(color: Colors.grey[500], fontSize: 13)),
      );
    }

    final toplam = sonuclar.fold(0.0, (s, r) => s + (r['tutar'] as double));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: const Color(0xFF0288D1),
              borderRadius: BorderRadius.circular(8)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${sonuclar.length} kayıt',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              Text(_fmt(toplam),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ...sonuclar.map((r) => GestureDetector(
            onTap: () {
              final tarihRaw = r['tarihRaw'] as String? ?? '';
              final subeId = r['subeId'] as String? ?? '';
              if (tarihRaw.isEmpty || subeId.isEmpty) return;
              final parts = tarihRaw.split('-');
              if (parts.length != 3) return;
              final dt = DateTime(int.parse(parts[0]), int.parse(parts[1]),
                  int.parse(parts[2]));
              Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OnHazirlikEkrani(
                      subeKodu: subeId,
                      subeler: widget.subeler,
                      baslangicTarihi: dt,
                      gecmisGunHakki: -1,
                      initialTabIndex: 5, // Özet & Kapat
                    ),
                  ));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Row(children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                                : Colors.orange[700]),
                  ),
                ),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r['tarih'] as String,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.black45)),
                  if ((r['sube'] as String).isNotEmpty)
                    Text(r['sube'] as String,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black45)),
                ]),
                const SizedBox(width: 8),
                Expanded(
                    child: Tooltip(
                  message: r['aciklama'] as String,
                  preferBelow: true,
                  child: Text(r['aciklama'] as String,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                )),
                const SizedBox(width: 8),
                Text(_fmt(r['tutar'] as double),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 14, color: Colors.grey[400]),
              ]),
            ))),
      ],
    );
  }
}

// ─── Ödeme Kanalları Widget ──────────────────────────────────────────────────

class OdemeKanallariWidget extends StatefulWidget {
  final List<String> subeler;
  const OdemeKanallariWidget({super.key, required this.subeler});

  @override
  State<OdemeKanallariWidget> createState() => _OdemeKanallariWidgetState();
}

class _OdemeKanallariWidgetState extends State<OdemeKanallariWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String _filtreModu = 'ay';
  int _secilenYil = DateTime.now().year;
  int _secilenAy = DateTime.now().month;
  DateTime _baslangic = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _bitis = DateTime.now();
  Set<String> _secilenSubeler = {};
  bool _karsilastirmaAcik = false;
  int _karsilastirmaYil = DateTime.now().year;
  int _karsilastirmaAy =
      DateTime.now().month == 1 ? 12 : DateTime.now().month - 1;
  DateTime _karsilastirmaBaslangic = DateTime(
    DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year,
    DateTime.now().month == 1 ? 12 : DateTime.now().month - 1,
    1,
  );
  DateTime _karsilastirmaBitis = DateTime(
    DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year,
    DateTime.now().month == 1 ? 12 : DateTime.now().month,
    0,
  );
  bool _siralamaArtan = false;
  Set<String> _secilenKanalDocIds = {}; // boş = Tüm Yöntemler
  bool _subeSecimAcik = false;
  bool _kanalSecimAcik = false;

  bool _yukleniyor = false;
  Map<String, String> _subeAdlari = {};
  List<Map<String, dynamic>> _kanallar = [];
  List<Map<String, dynamic>> _kayitlar = [];
  List<Map<String, dynamic>> _karsilastirmaKayitlar = [];
  Map<String, String> _subeGunMap = {};

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
    _subeAdlariniYukle();
    _kanallarYukle();
  }

  Future<void> _subeAdlariniYukle() async {
    try {
      final snap = await FirebaseFirestore.instance.collection('subeler').get();
      if (!mounted) return;
      setState(() => _subeAdlari = {
            for (var d in snap.docs) d.id: (d.data()['ad'] as String?) ?? d.id
          });
    } catch (_) {}
  }

  Future<void> _kanallarYukle() async {
    try {
      final snap =
          await FirebaseFirestore.instance.collection('odemeyontemleri').get();
      if (!mounted) return;
      final liste = <Map<String, dynamic>>[];
      for (final doc in snap.docs) {
        final tip = (doc.data()['tip'] as String?) ?? '';
        final aktif = (doc.data()['aktif'] as bool?) ?? true;
        final rapordaGoster = (doc.data()['rapordaGoster'] as bool?) ?? true;
        if ((tip == 'yemekKarti' || tip == 'online' || tip == 'pulseKalemi') &&
            aktif &&
            rapordaGoster) {
          final sira = (doc.data()['sira'] as num?)?.toInt() ??
              (doc.data()['pulseSira'] as num?)?.toInt() ??
              99;
          liste.add({
            'docId': doc.id,
            'ad': (doc.data()['ad'] as String?) ?? doc.id,
            'tip': tip,
            'sira': sira,
            'sistemAlani': (doc.data()['sistemAlani'] as String?) ?? '',
          });
        }
      }
      liste.sort((a, b) => (a['sira'] as int).compareTo(b['sira'] as int));
      if (mounted) {
        setState(() {
          _kanallar = liste;
          // _secilenKanalDocIds boş kalır = Tüm Yöntemler
        });
      }
    } catch (_) {}
  }

  List<String> get _aktifSubeler =>
      widget.subeler.isNotEmpty ? widget.subeler : _subeAdlari.keys.toList();

  String _pad2(int n) => n.toString().padLeft(2, '0');

  String _baslangicKey() {
    if (_filtreModu == 'ay') {
      return '${_secilenYil.toString().padLeft(4, '0')}-${_pad2(_secilenAy)}-01';
    }
    return '${_baslangic.year.toString().padLeft(4, '0')}-${_pad2(_baslangic.month)}-${_pad2(_baslangic.day)}';
  }

  String _bitisKey() {
    if (_filtreModu == 'ay') {
      final sonGun = DateTime(_secilenYil, _secilenAy + 1, 0).day;
      return '${_secilenYil.toString().padLeft(4, '0')}-${_pad2(_secilenAy)}-${_pad2(sonGun)}';
    }
    return '${_bitis.year.toString().padLeft(4, '0')}-${_pad2(_bitis.month)}-${_pad2(_bitis.day)}';
  }

  String _karsilastirmaBas() {
    if (_filtreModu == 'ay') {
      return '${_karsilastirmaYil.toString().padLeft(4, '0')}-${_pad2(_karsilastirmaAy)}-01';
    }
    return '${_karsilastirmaBaslangic.year.toString().padLeft(4, '0')}-${_pad2(_karsilastirmaBaslangic.month)}-${_pad2(_karsilastirmaBaslangic.day)}';
  }

  String _karsilastirmaBit() {
    if (_filtreModu == 'ay') {
      final sonGun = DateTime(_karsilastirmaYil, _karsilastirmaAy + 1, 0).day;
      return '${_karsilastirmaYil.toString().padLeft(4, '0')}-${_pad2(_karsilastirmaAy)}-${_pad2(sonGun)}';
    }
    return '${_karsilastirmaBitis.year.toString().padLeft(4, '0')}-${_pad2(_karsilastirmaBitis.month)}-${_pad2(_karsilastirmaBitis.day)}';
  }

  String _fmtTarih(DateTime dt) =>
      '${_pad2(dt.day)}.${_pad2(dt.month)}.${dt.year}';

  Future<List<Map<String, dynamic>>> _veriCek(String bas, String bit) async {
    final hedefSubeler = _secilenSubeler.isEmpty ? _aktifSubeler : _secilenSubeler.toList();
    final futures = hedefSubeler.map((sube) async {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(sube)
            .collection('gunluk')
            .where('tarih', isGreaterThanOrEqualTo: bas)
            .where('tarih', isLessThanOrEqualTo: bit)
            .orderBy('tarih')
            .get();
        return snap.docs.map((d) => {...d.data(), '_subeId': sube}).toList();
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    });
    final results = await Future.wait(futures);
    final sonuc = <Map<String, dynamic>>[];
    for (final liste in results) sonuc.addAll(liste);
    sonuc
        .sort((a, b) => (a['tarih'] as String).compareTo(b['tarih'] as String));
    for (final k in sonuc) {
      _subeGunMap[k['tarih'] as String] = k['_subeId'] as String;
    }
    return sonuc;
  }

  Future<void> _yukle() async {
    if (!mounted) return;
    if (_kanallar.isEmpty) await _kanallarYukle();
    if (_kanallar.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ödeme kanalları bulunamadı.'),
          backgroundColor: Colors.orange,
        ));
      }
      return;
    }
    setState(() {
      _yukleniyor = true;
      _kayitlar = [];
      _karsilastirmaKayitlar = [];
    });
    try {
      final futures = <Future>[
        _veriCek(_baslangicKey(), _bitisKey()),
        if (_karsilastirmaAcik)
          _veriCek(_karsilastirmaBas(), _karsilastirmaBit())
        else
          Future.value(<Map<String, dynamic>>[]),
      ];
      final results = await Future.wait(futures);
      if (!mounted) return;
      setState(() {
        _kayitlar = results[0] as List<Map<String, dynamic>>;
        _karsilastirmaKayitlar =
            _karsilastirmaAcik ? results[1] as List<Map<String, dynamic>> : [];
        _yukleniyor = false;
      });
    } catch (e) {
      if (mounted) setState(() => _yukleniyor = false);
    }
  }

  double _parseFirestore(dynamic raw) {
    if (raw == null) return 0.0;
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    final s = raw.toString().trim();
    final temiz = s.replaceAll('.', '').replaceAll(',', '.');
    return double.tryParse(temiz) ?? 0.0;
  }

  double _kanalTutarTek(
      Map<String, dynamic> kayit, Map<String, dynamic> kanal) {
    // sistemAlani varsa — Firestore alanından direkt oku (örn: bankaParasi)
    final sistemAlani = kanal['sistemAlani'] as String?;
    if (sistemAlani != null && sistemAlani.isNotEmpty) {
      return _parseFirestore(kayit[sistemAlani]);
    }

    final docId = kanal['docId'] as String;
    final tip = kanal['tip'] as String;
    final pulse = (kayit['pulseKiyasVerileri'] as Map?) ?? {};
    final String pulseKey;
    if (tip == 'yemekKarti') {
      pulseKey = 'yemek_$docId';
    } else if (tip == 'online') {
      pulseKey = 'online_$docId';
    } else {
      pulseKey = 'pulse_$docId'; // pulseKalemi
    }
    var raw = pulse[pulseKey];
    if (raw == null) {
      final ad = kanal['ad'] as String;
      if (tip == 'yemekKarti')
        raw = pulse['yemek_$ad'];
      else if (tip == 'online')
        raw = pulse[ad];
      else
        raw = pulse[ad];
    }
    return _parseFirestore(raw);
  }

  double _kanalTutar(Map<String, dynamic> kayit, Set<String> docIds) {
    if (docIds.isEmpty) {
      return _kanallar.fold(0.0, (s, k) => s + _kanalTutarTek(kayit, k));
    }
    return _kanallar
        .where((k) => docIds.contains(k['docId'] as String))
        .fold(0.0, (s, k) => s + _kanalTutarTek(kayit, k));
  }

  String _fmt(double v) {
    final parts = v.toStringAsFixed(2).split('.');
    final buf = StringBuffer();
    for (int i = 0; i < parts[0].length; i++) {
      if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write('.');
      buf.write(parts[0][i]);
    }
    return '${buf.toString()},${parts[1]} ₺';
  }

  Widget _satirOzet(String label, double deger, Color renk) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: renk, fontSize: 13))),
          const SizedBox(width: 8),
          Text(_fmt(deger),
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: renk, fontSize: 13)),
        ]),
      );

  Widget _ozetKart(
    List<Map<String, dynamic>> kayitlar,
    String baslik,
    Color renk,
    Set<String> docIds,
  ) {
    if (kayitlar.isEmpty) return const SizedBox.shrink();
    // Gösterilecek kanallar
    final gorunenKanallar = docIds.isEmpty
        ? _kanallar
        : _kanallar.where((k) => docIds.contains(k['docId'] as String)).toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: renk.withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: renk,
            borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14), topRight: Radius.circular(14)),
          ),
          child:
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(baslik,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
            Text('${kayitlar.length} gün',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            ...gorunenKanallar.map((kanal) {
              final toplam =
                  kayitlar.fold(0.0, (s, k) => s + _kanalTutarTek(k, kanal));
              if (toplam <= 0) return const SizedBox.shrink();
              final isYemek = kanal['tip'] == 'yemekKarti';
              return _satirOzet(
                kanal['ad'] as String,
                toplam,
                isYemek ? const Color(0xFF2E7D32) : const Color(0xFF1565C0),
              );
            }),
            const Divider(),
            _satirOzet(
                'Toplam',
                kayitlar.fold(0.0, (s, k) => s + _kanalTutar(k, docIds)),
                renk),
          ]),
        ),
      ]),
    );
  }

  Widget _detayTablo(List<Map<String, dynamic>> kayitlar, Set<String> docIds) {
    if (kayitlar.isEmpty) return const SizedBox.shrink();
    // Sıralama burada yapılıyor — build'den ham liste gelir
    final sirali = _siralamaArtan ? kayitlar : kayitlar.reversed.toList();

    // Gösterilecek kanallar
    final gorunenKanallar = docIds.isEmpty
        ? _kanallar
        : _kanallar.where((k) => docIds.contains(k['docId'] as String)).toList();

    // Tek kanal → basit liste, çok kanal → yatay kaydırmalı tablo
    if (gorunenKanallar.length == 1) {
      // Tek kanal — basit liste
      final kanal = gorunenKanallar.first;
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
                  offset: const Offset(0, 2))
            ],
          ),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: const Color(0xFF0288D1),
              child: const Row(children: [
                Expanded(
                    child: Text('Tarih',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12))),
                Text('Tutar',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
              ]),
            ),
            ...sirali.asMap().entries.map((e) {
              final idx = e.key;
              final k = e.value;
              final tarihRaw = k['tarih'] as String? ?? '';
              final tarihGoster = k['tarihGoster'] as String? ?? tarihRaw;
              final subeId = k['_subeId'] as String? ?? '';
              final subeAd = _subeAdlari[subeId] ?? '';
              final tutar = _kanalTutarTek(k, kanal);
              return GestureDetector(
                onTap: () {
                  final parts = tarihRaw.split('-');
                  if (parts.length != 3) return;
                  final dt = DateTime(int.parse(parts[0]), int.parse(parts[1]),
                      int.parse(parts[2]));
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => OnHazirlikEkrani(
                              subeKodu: subeId,
                              subeler: widget.subeler,
                              baslangicTarihi: dt,
                              gecmisGunHakki: -1,
                              initialTabIndex: 0)));
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: idx % 2 == 0 ? Colors.grey[50] : Colors.white,
                  child: Row(children: [
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Row(children: [
                            Text(tarihGoster,
                                style: const TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w500)),
                            Icon(Icons.chevron_right,
                                size: 14, color: Colors.grey[400]),
                          ]),
                          if (_aktifSubeler.length > 1 && subeAd.isNotEmpty)
                            Text(subeAd,
                                style: TextStyle(
                                    fontSize: 10, color: Colors.grey[500])),
                        ])),
                    Text(tutar > 0 ? _fmt(tutar) : '—',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: tutar > 0
                                ? const Color(0xFF0288D1)
                                : Colors.grey[400])),
                  ]),
                ),
              );
            }),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: const Color(0xFF0288D1),
              child: Row(children: [
                const Expanded(
                    child: Text('TOPLAM',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12))),
                Text(
                    _fmt(kayitlar.fold(
                        0.0, (s, k) => s + _kanalTutarTek(k, kanal))),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
              ]),
            ),
          ]),
        ),
      );
    }

    // Çok kanal — yatay kaydırmalı tablo
    const double tarihW = 90.0;
    const double colW = 90.0;
    const double rowH = 38.0;
    const double baslikH = 44.0;

    // Dönem toplamları
    final toplamlar = {
      for (final k in gorunenKanallar)
        k['docId'] as String:
            kayitlar.fold(0.0, (s, r) => s + _kanalTutarTek(r, k))
    };

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
                offset: const Offset(0, 2))
          ],
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Sol: sabit tarih sütunu
          SizedBox(
            width: tarihW,
            child: Column(children: [
              Container(
                height: baslikH,
                color: const Color(0xFF0288D1),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.centerLeft,
                child: const Text('Tarih',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
              ),
              ...sirali.asMap().entries.map((e) {
                final idx = e.key;
                final k = e.value;
                final tarihRaw = k['tarih'] as String? ?? '';
                final tarihGoster = k['tarihGoster'] as String? ?? tarihRaw;
                final subeId = k['_subeId'] as String? ?? '';
                final subeAd = _subeAdlari[subeId] ?? '';
                return GestureDetector(
                  onTap: () {
                    final parts = tarihRaw.split('-');
                    if (parts.length != 3) return;
                    final dt = DateTime(int.parse(parts[0]),
                        int.parse(parts[1]), int.parse(parts[2]));
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => OnHazirlikEkrani(
                                subeKodu: subeId,
                                subeler: widget.subeler,
                                baslangicTarihi: dt,
                                gecmisGunHakki: -1,
                                initialTabIndex: 0)));
                  },
                  child: Container(
                    height: rowH,
                    color: idx % 2 == 0 ? Colors.grey[50] : Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                                child: Text(tarihGoster,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500),
                                    overflow: TextOverflow.ellipsis)),
                            Icon(Icons.chevron_right,
                                size: 12, color: Colors.grey[400]),
                          ]),
                          if (_aktifSubeler.length > 1 && subeAd.isNotEmpty)
                            Text(subeAd,
                                style: TextStyle(
                                    fontSize: 9, color: Colors.grey[500])),
                        ]),
                  ),
                );
              }),
              Container(
                height: rowH,
                color: const Color(0xFF0288D1),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.centerLeft,
                child: const Text('TOPLAM',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 10)),
              ),
            ]),
          ),
          // Sağ: yatay kaydırmalı kanallar
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Başlıklar
                    Container(
                      height: baslikH,
                      color: const Color(0xFF0288D1),
                      padding: const EdgeInsets.only(right: 8),
                      child: Row(children: [
                        ...gorunenKanallar.map((k) => Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: SizedBox(
                                  width: colW,
                                  child: Text(k['ad'] as String,
                                      style: TextStyle(
                                          color: k['tip'] == 'yemekKarti'
                                              ? const Color(0xFFA5D6A7)
                                              : k['tip'] == 'pulseKalemi'
                                                  ? const Color(0xFFFFCC80)
                                                  : const Color(0xFF90CAF9),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11),
                                      textAlign: TextAlign.right,
                                      overflow: TextOverflow.ellipsis)),
                            )),
                        // Brüt Satış
                        Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: SizedBox(
                                width: colW,
                                child: const Text('Brüt Satış',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 11),
                                    textAlign: TextAlign.right,
                                    overflow: TextOverflow.ellipsis))),
                        // Fark
                        Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: SizedBox(
                                width: colW,
                                child: const Text('Fark',
                                    style: TextStyle(
                                        color: Color(0xFFEF9A9A),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 11),
                                    textAlign: TextAlign.right,
                                    overflow: TextOverflow.ellipsis))),
                      ]),
                    ),
                    // Gün satırları
                    ...sirali.asMap().entries.map((e) {
                      final idx = e.key;
                      final k = e.value;
                      final brutSatis =
                          ((k['gunlukSatisToplami'] as num?) ?? 0).toDouble();
                      final kanalToplam = gorunenKanallar.fold(
                          0.0, (s, kanal) => s + _kanalTutarTek(k, kanal));
                      final fark = brutSatis - kanalToplam;
                      final farkRenk = fark.abs() < 0.01
                          ? const Color(0xFF2E7D32)
                          : Colors.red[600]!;
                      return Container(
                        height: rowH,
                        color: idx % 2 == 0 ? Colors.grey[50] : Colors.white,
                        padding: const EdgeInsets.only(right: 8),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              ...gorunenKanallar.map((kanal) {
                                final val = _kanalTutarTek(k, kanal);
                                final tip = kanal['tip'] as String;
                                final renk = tip == 'yemekKarti'
                                    ? const Color(0xFF2E7D32)
                                    : tip == 'pulseKalemi'
                                        ? const Color(0xFFE65100)
                                        : const Color(0xFF1565C0);
                                return Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: SizedBox(
                                      width: colW,
                                      child: Text(val > 0 ? _fmt(val) : '—',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: val > 0
                                                  ? renk
                                                  : Colors.grey[400],
                                              fontWeight: val > 0
                                                  ? FontWeight.w600
                                                  : FontWeight.normal),
                                          textAlign: TextAlign.right,
                                          overflow: TextOverflow.ellipsis)),
                                );
                              }),
                              // Brüt Satış
                              Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: SizedBox(
                                      width: colW,
                                      child: Text(
                                          brutSatis > 0 ? _fmt(brutSatis) : '—',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: brutSatis > 0
                                                  ? Colors.black87
                                                  : Colors.grey[400],
                                              fontWeight: FontWeight.bold),
                                          textAlign: TextAlign.right,
                                          overflow: TextOverflow.ellipsis))),
                              // Fark
                              Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: SizedBox(
                                      width: colW,
                                      child: Text(
                                          fark.abs() < 0.01 ? '✓' : _fmt(fark),
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: farkRenk,
                                              fontWeight: FontWeight.bold),
                                          textAlign: TextAlign.right,
                                          overflow: TextOverflow.ellipsis))),
                            ]),
                      );
                    }),
                    // Toplam satırı
                    Builder(builder: (ctx) {
                      final topBrut = sirali.fold(
                          0.0,
                          (s, k) =>
                              s +
                              ((k['gunlukSatisToplami'] as num?) ?? 0)
                                  .toDouble());
                      final topKanal = gorunenKanallar.fold(0.0,
                          (s, kanal) => s + (toplamlar[kanal['docId']] ?? 0.0));
                      final topFark = topBrut - topKanal;
                      return Container(
                        height: rowH,
                        color: const Color(0xFF0288D1),
                        padding: const EdgeInsets.only(right: 8),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              ...gorunenKanallar.map((k) {
                                final t = toplamlar[k['docId']] ?? 0.0;
                                return Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: SizedBox(
                                        width: colW,
                                        child: Text(t > 0 ? _fmt(t) : '—',
                                            style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                color: t > 0
                                                    ? Colors.white
                                                    : Colors.white38),
                                            textAlign: TextAlign.right)));
                              }),
                              // Brüt Satış toplam
                              Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: SizedBox(
                                      width: colW,
                                      child: Text(
                                          topBrut > 0 ? _fmt(topBrut) : '—',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white),
                                          textAlign: TextAlign.right))),
                              // Fark toplam
                              Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: SizedBox(
                                      width: colW,
                                      child: Text(
                                          topFark.abs() < 0.01
                                              ? '✓'
                                              : _fmt(topFark),
                                          style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: topFark.abs() < 0.01
                                                  ? const Color(0xFFA5D6A7)
                                                  : const Color(0xFFEF9A9A)),
                                          textAlign: TextAlign.right))),
                            ]),
                      );
                    }),
                  ]),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final docIds = _secilenKanalDocIds;
    final baslikAna = _filtreModu == 'ay'
        ? '${_aylar[_secilenAy - 1]} $_secilenYil'
        : 'Seçili Dönem';
    final baslikKars = _filtreModu == 'ay'
        ? '${_aylar[_karsilastirmaAy - 1]} $_karsilastirmaYil'
        : '${_pad2(_karsilastirmaBaslangic.day)}.${_pad2(_karsilastirmaBaslangic.month)} – ${_fmtTarih(_karsilastirmaBitis)}';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'ay',
                      label: Text('Ay Seç'),
                      icon: Icon(Icons.calendar_month)),
                  ButtonSegment(
                      value: 'aralik',
                      label: Text('Tarih Aralığı'),
                      icon: Icon(Icons.date_range)),
                ],
                selected: {_filtreModu},
                onSelectionChanged: (s) =>
                    setState(() => _filtreModu = s.first),
              ),
              const SizedBox(height: 12),
              if (_filtreModu == 'ay') ...[
                Row(children: [
                  Expanded(
                      child: DropdownButtonFormField<int>(
                    value: _secilenAy,
                    decoration: const InputDecoration(
                        labelText: 'Ay', border: OutlineInputBorder()),
                    items: List.generate(
                        12,
                        (i) => DropdownMenuItem(
                            value: i + 1, child: Text(_aylar[i]))),
                    onChanged: (v) => setState(() => _secilenAy = v!),
                  )),
                  const SizedBox(width: 8),
                  Expanded(
                      child: DropdownButtonFormField<int>(
                    value: _secilenYil,
                    decoration: const InputDecoration(
                        labelText: 'Yıl', border: OutlineInputBorder()),
                    items: List.generate(5, (i) => DateTime.now().year - i)
                        .map((y) => DropdownMenuItem(
                            value: y, child: Text(y.toString())))
                        .toList(),
                    onChanged: (v) => setState(() => _secilenYil = v!),
                  )),
                ]),
              ] else ...[
                Row(children: [
                  Expanded(
                      child: OutlinedButton.icon(
                    onPressed: () async {
                      final p = await showDatePicker(
                          context: context,
                          initialDate: _baslangic,
                          firstDate: DateTime(2020),
                          lastDate: DateTime.now());
                      if (p != null) setState(() => _baslangic = p);
                    },
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(_fmtTarih(_baslangic)),
                  )),
                  const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('—')),
                  Expanded(
                      child: OutlinedButton.icon(
                    onPressed: () async {
                      final p = await showDatePicker(
                          context: context,
                          initialDate: _bitis,
                          firstDate: _baslangic,
                          lastDate: DateTime.now());
                      if (p != null) setState(() => _bitis = p);
                    },
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(_fmtTarih(_bitis)),
                  )),
                ]),
              ],
              if (_aktifSubeler.length > 1) ...[
                const SizedBox(height: 12),
                // ── Şube seçici ──────────────────────────────────────────
                GestureDetector(
                  onTap: () =>
                      setState(() => _subeSecimAcik = !_subeSecimAcik),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black38),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(children: [
                      const Text('Şube',
                          style: TextStyle(
                              fontSize: 12, color: Colors.black54)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _secilenSubeler.isEmpty
                              ? 'Tümü'
                              : _secilenSubeler
                                  .map((s) => _subeAdlari[s] ?? s)
                                  .join(', '),
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                          _subeSecimAcik
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 18,
                          color: Colors.black54),
                    ]),
                  ),
                ),
                if (_subeSecimAcik) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      FilterChip(
                        label: const Text('Tümü'),
                        selected: _secilenSubeler.isEmpty,
                        onSelected: (_) =>
                            setState(() => _secilenSubeler.clear()),
                        selectedColor:
                            const Color(0xFF0288D1).withOpacity(0.18),
                        checkmarkColor: const Color(0xFF0288D1),
                      ),
                      ..._aktifSubeler.map((s) => FilterChip(
                            label: Text(_subeAdlari[s] ?? s),
                            selected: _secilenSubeler.contains(s),
                            onSelected: (secildi) => setState(() {
                              if (secildi) {
                                _secilenSubeler.add(s);
                              } else {
                                _secilenSubeler.remove(s);
                              }
                            }),
                            selectedColor:
                                const Color(0xFF0288D1).withOpacity(0.18),
                            checkmarkColor: const Color(0xFF0288D1),
                          )),
                    ],
                  ),
                ],
              ],
              const SizedBox(height: 12),
              // ── Ödeme Yöntemi seçici ─────────────────────────────────
              GestureDetector(
                onTap: () =>
                    setState(() => _kanalSecimAcik = !_kanalSecimAcik),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black38),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(children: [
                    const Text('Ödeme Yöntemi',
                        style:
                            TextStyle(fontSize: 12, color: Colors.black54)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _secilenKanalDocIds.isEmpty
                            ? 'Tümü'
                            : _secilenKanalDocIds
                                .map((id) =>
                                    _kanallar.firstWhere(
                                        (k) => k['docId'] == id,
                                        orElse: () =>
                                            {'ad': id})['ad'] as String)
                                .join(', '),
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                        _kanalSecimAcik
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                        color: Colors.black54),
                  ]),
                ),
              ),
              if (_kanalSecimAcik) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    FilterChip(
                      label: const Text('Tümü'),
                      selected: _secilenKanalDocIds.isEmpty,
                      onSelected: (_) =>
                          setState(() => _secilenKanalDocIds.clear()),
                      selectedColor:
                          const Color(0xFF0288D1).withOpacity(0.18),
                      checkmarkColor: const Color(0xFF0288D1),
                    ),
                    ..._kanallar.map((k) => FilterChip(
                          label: Text(k['ad'] as String),
                          selected: _secilenKanalDocIds
                              .contains(k['docId'] as String),
                          onSelected: (secildi) => setState(() {
                            if (secildi) {
                              _secilenKanalDocIds.add(k['docId'] as String);
                            } else {
                              _secilenKanalDocIds.remove(k['docId'] as String);
                            }
                          }),
                          selectedColor:
                              const Color(0xFF0288D1).withOpacity(0.18),
                          checkmarkColor: const Color(0xFF0288D1),
                        )),
                  ],
                ),
              ],
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
                  Row(children: [
                    Expanded(
                        child: DropdownButtonFormField<int>(
                      value: _karsilastirmaAy,
                      decoration: const InputDecoration(
                          labelText: 'Karş. Ay', border: OutlineInputBorder()),
                      items: List.generate(
                          12,
                          (i) => DropdownMenuItem(
                              value: i + 1, child: Text(_aylar[i]))),
                      onChanged: (v) => setState(() => _karsilastirmaAy = v!),
                    )),
                    const SizedBox(width: 8),
                    Expanded(
                        child: DropdownButtonFormField<int>(
                      value: _karsilastirmaYil,
                      decoration: const InputDecoration(
                          labelText: 'Karş. Yıl', border: OutlineInputBorder()),
                      items: List.generate(5, (i) => DateTime.now().year - i)
                          .map((y) => DropdownMenuItem(
                              value: y, child: Text(y.toString())))
                          .toList(),
                      onChanged: (v) => setState(() => _karsilastirmaYil = v!),
                    )),
                  ])
                else
                  Row(children: [
                    Expanded(
                        child: OutlinedButton.icon(
                      onPressed: () async {
                        final p = await showDatePicker(
                            context: context,
                            initialDate: _karsilastirmaBaslangic,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now());
                        if (p != null)
                          setState(() => _karsilastirmaBaslangic = p);
                      },
                      icon: const Icon(Icons.calendar_today, size: 16),
                      label: Text(_fmtTarih(_karsilastirmaBaslangic)),
                    )),
                    const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('—')),
                    Expanded(
                        child: OutlinedButton.icon(
                      onPressed: () async {
                        final p = await showDatePicker(
                            context: context,
                            initialDate: _karsilastirmaBitis,
                            firstDate: _karsilastirmaBaslangic,
                            lastDate: DateTime.now());
                        if (p != null) setState(() => _karsilastirmaBitis = p);
                      },
                      icon: const Icon(Icons.calendar_today, size: 16),
                      label: Text(_fmtTarih(_karsilastirmaBitis)),
                    )),
                  ]),
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
                              color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: const Text('Raporu Getir'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0288D1),
                      foregroundColor: Colors.white),
                ),
              ),
            ]),
          ),
        ),
        if (_kayitlar.isNotEmpty) ...[
          const SizedBox(height: 16),
          if (_karsilastirmaAcik && _karsilastirmaKayitlar.isNotEmpty)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: _ozetKart(_karsilastirmaKayitlar, baslikKars,
                      Colors.blueGrey[600]!, docIds)),
              const SizedBox(width: 8),
              Expanded(
                  child: _ozetKart(
                      _kayitlar, baslikAna, const Color(0xFF0288D1), docIds)),
            ])
          else
            _ozetKart(_kayitlar, baslikAna, const Color(0xFF0288D1), docIds),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            Text(_siralamaArtan ? 'Eskiden Yeniye' : 'Yeniden Eskiye',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(
                  _siralamaArtan ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 18,
                  color: const Color(0xFF0288D1)),
              onPressed: () => setState(() => _siralamaArtan = !_siralamaArtan),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ]),
          if (_karsilastirmaAcik && _karsilastirmaKayitlar.isNotEmpty) ...[
            _detayTablo(_karsilastirmaKayitlar, docIds),
            const SizedBox(height: 12),
          ],
          _detayTablo(_kayitlar, docIds),
          const SizedBox(height: 32),
        ],
      ]),
    );
  }
}
