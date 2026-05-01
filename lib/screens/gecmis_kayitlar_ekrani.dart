import 'on_hazirlik_ekrani.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../core/utils.dart';
import '../widgets/gider_duzenle_sheet.dart';
import '../widgets/ek_gider_sheet.dart';
// ─── Geçmiş Kayıtlar Ekranı ───────────────────────────────────────────────────

class GecmisKayitlarEkrani extends StatefulWidget {
  final String subeKodu;
  final List<String> subeler;
  final int gecmisGunHakki;
  final DateTime? sonKapaliTarih; // Referans: bu günden 3 gün öncesi
  const GecmisKayitlarEkrani({
    super.key,
    required this.subeKodu,
    this.subeler = const [],
    this.gecmisGunHakki = 0,
    this.sonKapaliTarih,
  });
  @override
  State<GecmisKayitlarEkrani> createState() => _GecmisKayitlarEkraniState();
}

class _GecmisKayitlarEkraniState extends State<GecmisKayitlarEkrani> {
  // Aktif şube — başlangıçta widget.subeKodu, dropdown ile değişebilir
  late String _aktifSubeKodu;
  Map<String, String> _subeAdlari = {};
  // Şube bazlı son kapalı tarih — şube değişince güncellenir
  DateTime? _aktifSonKapaliTarih;
  bool _sonKapaliYukleniyor = false;
  // Önceki veri — göz kırpmayı önlemek için
  List<QueryDocumentSnapshot>? _oncekiDocs;

  // Yönetici ay filtresi
  int _seciliYil = DateTime.now().year;
  int _seciliAy = DateTime.now().month;

  static const List<String> _ayAdlari = [
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

  // Ay → aylık toplam satış (tek sorguda yüklenir)
  final Map<String, double> _aylikToplam = {};
  // Hangi aylar yüklendi
  final Set<String> _yuklenenAylar = {};

  @override
  void initState() {
    super.initState();
    _aktifSubeKodu = widget.subeKodu;
    _aktifSonKapaliTarih = widget.sonKapaliTarih;
    _subeAdlariniYukle();
    // Başlangıç şubesi için son kapalı tarihi yükle
    _sonKapaliTarihiYukle(widget.subeKodu);
  }

  // Şube için son kapatılan günü Firestore'dan çek
  Future<void> _sonKapaliTarihiYukle(String subeId) async {
    if (widget.gecmisGunHakki == -1) return; // Yönetici — gerek yok
    if (mounted) setState(() => _sonKapaliYukleniyor = true);
    try {
      final snap = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(subeId)
          .collection('gunluk')
          .orderBy('tarih', descending: true)
          .get();
      DateTime? sonKapali;
      for (final doc in snap.docs) {
        final d = doc.data();
        final kapali = d['tamamlandi'] == true ||
            d['tamamlandi'] == 1 ||
            d['tamamlandi']?.toString() == 'true';
        if (kapali) {
          final tarihStr = d['tarih'] as String? ?? '';
          final p = tarihStr.split('-');
          if (p.length == 3) {
            sonKapali = DateTime(
              int.parse(p[0]),
              int.parse(p[1]),
              int.parse(p[2]),
            );
          }
          break;
        }
      }
      if (mounted) {
        setState(() {
          _aktifSonKapaliTarih = sonKapali;
          _sonKapaliYukleniyor = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _sonKapaliYukleniyor = false);
    }
  }

  Future<void> _subeAdlariniYukle() async {
    if (widget.subeler.length <= 1) return;
    final snap = await FirebaseFirestore.instance.collection('subeler').get();
    final adlar = <String, String>{};
    for (final d in snap.docs) {
      adlar[d.id] = (d.data()['ad'] as String?) ?? d.id;
    }
    if (mounted) setState(() => _subeAdlari = adlar);
  }

  @override
  void dispose() {
    super.dispose();
  }

  static DateTime _bugunuHesapla() {
    final simdi = DateTime.now();
    if (simdi.hour < 5) {
      return DateTime(simdi.year, simdi.month, simdi.day - 1);
    }
    return DateTime(simdi.year, simdi.month, simdi.day);
  }

  String _tarihKey(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  String _binAyrac(double v) {
    final neg = v < 0;
    final s = v.abs().toStringAsFixed(0);
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return '${neg ? '-' : ''}${buf.toString()} ₺';
  }

  // Döviz miktarları için — ₺ ikonu EKLEMEz
  String _binAyracSade(double v) {
    final neg = v < 0;
    final s = v.abs().toStringAsFixed(0);
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return '${neg ? '-' : ''}${buf.toString()}';
  }

  // Ayın tüm satışlarını tek sorguda çek
  Future<void> _aylikToplamYukle(String ayKey) async {
    if (_yuklenenAylar.contains(ayKey)) return;
    _yuklenenAylar.add(ayKey);
    final parts = ayKey.split('-');
    if (parts.length != 2) return;
    final ayBasi = '$ayKey-01';
    final ayBitis = DateTime(int.parse(parts[0]), int.parse(parts[1]) + 1, 0);
    final ayBitisKey = _tarihKey(ayBitis);

    final snap = await FirebaseFirestore.instance
        .collection('subeler')
        .doc(_aktifSubeKodu)
        .collection('gunluk')
        .where('tarih', isGreaterThanOrEqualTo: ayBasi)
        .where('tarih', isLessThanOrEqualTo: ayBitisKey)
        .get();

    double toplam = 0;
    for (final doc in snap.docs) {
      toplam += ((doc.data()['gunlukSatisToplami'] as num?) ?? 0).toDouble();
    }
    if (mounted) setState(() => _aylikToplam[ayKey] = toplam);
  }

  @override
  Widget build(BuildContext context) {
    final yonetici = widget.gecmisGunHakki == -1;
    final bugun = _bugunuHesapla();
    // Yönetici: ay bazlı filtre; Kullanıcı: gün sınırı
    final String? ayBasKey = yonetici
        ? '$_seciliYil-${_seciliAy.toString().padLeft(2, '0')}-01'
        : null;
    final String? ayBitisKey = yonetici
        ? () {
            final sonGun = DateTime(_seciliYil, _seciliAy + 1, 0).day;
            return '$_seciliYil-${_seciliAy.toString().padLeft(2, '0')}-${sonGun.toString().padLeft(2, '0')}';
          }()
        : null;
    // Şubeye özgü son kapalı tarih — şube değişince güncellenir
    final aktifReferans = _aktifSonKapaliTarih;
    final enEskiTarih = yonetici || aktifReferans == null
        ? null
        : aktifReferans.subtract(Duration(days: widget.gecmisGunHakki));
    final enEskiKey = enEskiTarih != null ? _tarihKey(enEskiTarih) : null;
    // Kullanıcı için üst sınır: en son kapatılan gün (kapatılmamış gün görünmesin)
    final enSonKey =
        (!yonetici && aktifReferans != null) ? _tarihKey(aktifReferans) : null;

    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF01579B), Color(0xFF0288D1), Color(0xFF29B6F6)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
          ),
        ),
        title: widget.subeler.length > 1
            ? DropdownButton<String>(
                value: _aktifSubeKodu,
                dropdownColor: const Color(0xFF0288D1),
                underline: const SizedBox(),
                icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                items: widget.subeler
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text(
                          _subeAdlari[s] ?? s,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (yeni) {
                  if (yeni != null && yeni != _aktifSubeKodu) {
                    setState(() {
                      _aktifSubeKodu = yeni;
                      _aktifSonKapaliTarih = null; // sıfırla, yenisi yüklenecek
                      _aylikToplam.clear();
                      _yuklenenAylar.clear();
                      // _oncekiDocs korunuyor — göz kırpma yok
                    });
                    _sonKapaliTarihiYukle(yeni);
                  }
                },
              )
            : Text(
                'Geçmiş Kayıtlar — ${_subeAdlari[_aktifSubeKodu] ?? _aktifSubeKodu}',
              ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: Container(
            color: const Color(0xFF0288D1),
            padding: const EdgeInsets.only(bottom: 4),
            child: yonetici
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.chevron_left,
                          color: Colors.white70,
                          size: 20,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => setState(() {
                          _aylikToplam.clear();
                          _yuklenenAylar.clear();
                          if (_seciliAy == 1) {
                            _seciliAy = 12;
                            _seciliYil--;
                          } else {
                            _seciliAy--;
                          }
                        }),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${_ayAdlari[_seciliAy - 1]} $_seciliYil',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(
                          Icons.chevron_right,
                          color: Colors.white70,
                          size: 20,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          final simdi = DateTime.now();
                          if (_seciliYil == simdi.year &&
                              _seciliAy == simdi.month) return;
                          setState(() {
                            _aylikToplam.clear();
                            _yuklenenAylar.clear();
                            if (_seciliAy == 12) {
                              _seciliAy = 1;
                              _seciliYil++;
                            } else {
                              _seciliAy++;
                            }
                          });
                        },
                      ),
                    ],
                  )
                : widget.gecmisGunHakki > 0
                    ? Text(
                        widget.sonKapaliTarih != null
                            ? '${aktifReferans != null ? _tarihKey(aktifReferans) : '-'} tarihinden ${widget.gecmisGunHakki} gün'
                            : 'Son ${widget.gecmisGunHakki} gün gösteriliyor',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      )
                    : const SizedBox.shrink(),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        key: ValueKey('$_aktifSubeKodu-$_seciliYil-$_seciliAy'),
        stream: yonetici
            ? FirebaseFirestore.instance
                .collection('subeler')
                .doc(_aktifSubeKodu)
                .collection('gunluk')
                .where('tarih', isGreaterThanOrEqualTo: ayBasKey)
                .where('tarih', isLessThanOrEqualTo: ayBitisKey)
                .orderBy('tarih', descending: true)
                .snapshots()
            : enEskiKey != null
                ? (enSonKey != null
                    ? FirebaseFirestore.instance
                        .collection('subeler')
                        .doc(_aktifSubeKodu)
                        .collection('gunluk')
                        .where('tarih', isGreaterThanOrEqualTo: enEskiKey)
                        .where('tarih', isLessThanOrEqualTo: enSonKey)
                        .orderBy('tarih', descending: true)
                        .snapshots()
                    : FirebaseFirestore.instance
                        .collection('subeler')
                        .doc(_aktifSubeKodu)
                        .collection('gunluk')
                        .where('tarih', isGreaterThanOrEqualTo: enEskiKey)
                        .orderBy('tarih', descending: true)
                        .snapshots())
                : FirebaseFirestore.instance
                    .collection('subeler')
                    .doc(_aktifSubeKodu)
                    .collection('gunluk')
                    .orderBy('tarih', descending: true)
                    .snapshots(),
        builder: (context, snapshot) {
          // Veri gelince önbelleğe al — göz kırpma yok
          if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
            _oncekiDocs = snapshot.data!.docs;
          }
          // Yüklenirken önceki veri varsa onu göster (ince progress bar ile)
          if (snapshot.connectionState == ConnectionState.waiting &&
              (_oncekiDocs == null || _oncekiDocs!.isEmpty)) {
            return const Center(child: CircularProgressIndicator());
          }

          // Aktif docs: yeni geldiyse yeni, yoksa önceki
          final docs = (snapshot.hasData && snapshot.data!.docs.isNotEmpty)
              ? snapshot.data!.docs
              : (_oncekiDocs ?? []);

          if (docs.isEmpty) {
            return Center(
              child: Text(
                widget.gecmisGunHakki == 0
                    ? 'Geçmiş kayıtlara erişim yetkiniz yok.'
                    : 'Son ${widget.gecmisGunHakki} günde kayıt yok.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
            );
          }

          // Her ay için tek sorgu — sadece en üst (en son) günde aylık toplam göster
          return Column(
            children: [
              if (snapshot.connectionState == ConnectionState.waiting)
                const LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  color: Color(0xFF0288D1),
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    final anaKasaKalani =
                        ((data['anaKasaKalani'] as num?) ?? 0).toDouble();
                    final gunlukSatis =
                        ((data['gunlukSatisToplami'] as num?) ?? 0).toDouble();
                    final bankayaYatirilan =
                        ((data['bankayaYatirilan'] as num?) ?? 0).toDouble();
                    final anaKasaHarcama =
                        ((data['toplamAnaKasaHarcama'] as num?) ?? 0)
                            .toDouble();
                    final nakitCikis =
                        ((data['toplamNakitCikis'] as num?) ?? 0).toDouble();
                    // Nakit döviz çıkışı özeti
                    final nakitDovizRaw =
                        (data['nakitDovizler'] as List?)?.cast<Map>() ?? [];
                    // Nakit döviz çıkışı — cins bazlı renkli liste
                    final List<Map<String, dynamic>> nakitDovizListesiGecmis =
                        [];
                    for (final nd in nakitDovizRaw) {
                      final miktar = (nd['miktar'] as num? ?? 0).toDouble();
                      final cins = nd['cins'] as String? ?? '';
                      if (miktar > 0 && cins.isNotEmpty)
                        nakitDovizListesiGecmis.add({
                          'cins': cins,
                          'miktar': miktar,
                          'aciklama': nd['aciklama'] as String? ?? '',
                        });
                    }
                    final gunlukKasaKalani =
                        ((data['gunlukKasaKalani'] as num?) ?? 0).toDouble();
                    final gunlukKasaKalaniTL =
                        ((data['gunlukKasaKalaniTL'] as num?) ?? 0).toDouble();
                    // Döviz kasa özeti — sabit sıra: USD, EUR, GBP
                    final dovizListKasa =
                        (data['dovizler'] as List?)?.cast<Map>() ?? [];
                    final List<Map<String, dynamic>> dovizKasaOzet = [];
                    for (final cins in ['USD', 'EUR', 'GBP']) {
                      double topMiktar = 0;
                      for (final d in dovizListKasa) {
                        if (d['cins'] == cins)
                          topMiktar += (d['miktar'] as num? ?? 0).toDouble();
                      }
                      if (topMiktar > 0)
                        dovizKasaOzet.add({'cins': cins, 'miktar': topMiktar});
                    }
                    // Ana Kasa döviz kalanı — sabit sıra: USD, EUR, GBP
                    final akDovizMap =
                        (data['dovizAnaKasaKalanlari'] as Map?) ?? {};
                    final List<Map<String, dynamic>> akDovizOzet = [];
                    for (final cins in ['USD', 'EUR', 'GBP']) {
                      final miktar = (akDovizMap[cins] as num? ?? 0).toDouble();
                      if (miktar > 0)
                        akDovizOzet.add({'cins': cins, 'miktar': miktar});
                    }
                    // Döviz bankaya yatan özeti — sabit sıra: USD, EUR, GBP
                    final bankaDovizList =
                        (data['bankaDovizler'] as List?)?.cast<Map>() ?? [];
                    final List<Map<String, dynamic>> dovizYatanOzet = [];
                    for (final cins in ['USD', 'EUR', 'GBP']) {
                      double topMiktar = 0;
                      for (final d in bankaDovizList) {
                        if (d['cins'] == cins)
                          topMiktar += (d['miktar'] as num? ?? 0).toDouble();
                      }
                      if (topMiktar > 0)
                        dovizYatanOzet.add({'cins': cins, 'miktar': topMiktar});
                    }
                    final tarih = data['tarih'] as String? ?? '';

                    // Ay anahtarı
                    final parts3 = tarih.split('-');
                    final ayKey =
                        parts3.length == 3 ? '${parts3[0]}-${parts3[1]}' : '';

                    // Descending listede bir önceki elemanın ayı farklıysa
                    // veya bu ilk eleman ise → bu ayın en son günü → aylık göster
                    final oncekiAyKey = index > 0
                        ? (() {
                            final oncekiTarih = (docs[index - 1].data()
                                        as Map<String, dynamic>)['tarih']
                                    as String? ??
                                '';
                            final op = oncekiTarih.split('-');
                            return op.length == 3 ? '${op[0]}-${op[1]}' : '';
                          })()
                        : '';
                    final buAyinSonGunu = index == 0 || ayKey != oncekiAyKey;

                    // Aylık toplam yükle (sadece aylık gösterilecek günler için)
                    if (buAyinSonGunu && ayKey.isNotEmpty) {
                      _aylikToplamYukle(ayKey);
                    }
                    final aylikToplam =
                        buAyinSonGunu ? (_aylikToplam[ayKey] ?? 0) : 0.0;

                    // Tarih format: 2026-03-22 → 22.03.2026
                    String tarihGoster = tarih;
                    if (tarih.length == 10) {
                      final p = tarih.split('-');
                      if (p.length == 3)
                        tarihGoster = '${p[2]}.${p[1]}.${p[0]}';
                    }

                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF0288D1),
                          child: Text(
                            tarihGoster.split('.').first,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        title: Text(
                          tarihGoster,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            // Satır 1: Günlük Satış | Aylık Toplam | Günlük Kasa Kalanı
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Günlük Satış',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                      Text(
                                        _binAyrac(gunlukSatis),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (buAyinSonGunu && aylikToplam > 0)
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Aylık Toplam',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                        Text(
                                          _binAyrac(aylikToplam),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.red[700],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'G. Kasa',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                      Row(
                                        children: [
                                          Text(
                                            _binAyrac(gunlukKasaKalaniTL),
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: gunlukKasaKalaniTL >= 0
                                                  ? Colors.blue[700]
                                                  : Colors.red[700],
                                            ),
                                          ),
                                          if (dovizKasaOzet.isNotEmpty) ...[
                                            const SizedBox(width: 4),
                                            Flexible(
                                              child: Wrap(
                                                spacing: 3,
                                                children: dovizKasaOzet.map((
                                                  d,
                                                ) {
                                                  final c = d['cins'] as String;
                                                  final sem = c == 'USD'
                                                      ? r'$'
                                                      : c == 'EUR'
                                                          ? '€'
                                                          : c == 'GBP'
                                                              ? '£'
                                                              : c;
                                                  final m =
                                                      d['miktar'] as double;
                                                  return Text(
                                                    '$sem${_binAyracSade(m)}',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      color: dovizRenk(c),
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  );
                                                }).toList(),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            // Satır 2: Bankaya | Döviz | Nakit Çıkış | A. Harcanan | A. Kalanı
                            Row(
                              children: [
                                if (bankayaYatirilan > 0)
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Bankaya',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                        Text(
                                          _binAyrac(bankayaYatirilan),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.blue[700],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (dovizYatanOzet.isNotEmpty)
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Döviz Yatan',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                        Wrap(
                                          spacing: 4,
                                          children: dovizYatanOzet.map((d) {
                                            final c = d['cins'] as String;
                                            final sem = c == 'USD'
                                                ? r'$'
                                                : c == 'EUR'
                                                    ? '€'
                                                    : c == 'GBP'
                                                        ? '£'
                                                        : c;
                                            final m = d['miktar'] as double;
                                            return Text(
                                              '$sem${_binAyracSade(m)}',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: dovizRenk(c),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (nakitCikis > 0 ||
                                    nakitDovizListesiGecmis.isNotEmpty)
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Nakit Çıkış',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                        Row(
                                          children: [
                                            if (nakitCikis > 0)
                                              Text(
                                                _binAyrac(nakitCikis),
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.purple[700],
                                                ),
                                              ),
                                            if (nakitDovizListesiGecmis
                                                .isNotEmpty) ...[
                                              if (nakitCikis > 0)
                                                const SizedBox(width: 4),
                                              Flexible(
                                                child: Wrap(
                                                  spacing: 3,
                                                  children:
                                                      nakitDovizListesiGecmis
                                                          .map((d) {
                                                    final c =
                                                        d['cins'] as String;
                                                    final sem = c == 'USD'
                                                        ? r'$'
                                                        : c == 'EUR'
                                                            ? '€'
                                                            : c == 'GBP'
                                                                ? '£'
                                                                : c;
                                                    final m =
                                                        d['miktar'] as double;
                                                    final aciklamaG =
                                                        d['aciklama']
                                                                as String? ??
                                                            '';
                                                    final chip = Text(
                                                      '$sem${_binAyracSade(m)}',
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        color: dovizRenk(c),
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    );
                                                    return aciklamaG.isNotEmpty
                                                        ? Tooltip(
                                                            message: aciklamaG,
                                                            child: chip,
                                                          )
                                                        : chip;
                                                  }).toList(),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                if (anaKasaHarcama > 0)
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'A. Harcanan',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                        Text(
                                          _binAyrac(anaKasaHarcama),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.orange[700],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'A. Kalanı',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                      Row(
                                        children: [
                                          Text(
                                            _binAyrac(anaKasaKalani),
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: anaKasaKalani >= 0
                                                  ? Colors.green[700]
                                                  : Colors.red[700],
                                            ),
                                          ),
                                          if (akDovizOzet.isNotEmpty) ...[
                                            const SizedBox(width: 4),
                                            Flexible(
                                              child: Wrap(
                                                spacing: 3,
                                                children: akDovizOzet.map((d) {
                                                  final c = d['cins'] as String;
                                                  final sem = c == 'USD'
                                                      ? r'$'
                                                      : c == 'EUR'
                                                          ? '€'
                                                          : c == 'GBP'
                                                              ? '£'
                                                              : c;
                                                  final m =
                                                      d['miktar'] as double;
                                                  return Text(
                                                    '$sem${_binAyracSade(m)}',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      color: dovizRenk(c),
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  );
                                                }).toList(),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          color: Color(0xFF0288D1),
                        ),
                        isThreeLine: true,
                        onTap: () {
                          final tarihKey = data['tarih'] as String?;
                          if (tarihKey == null) return;
                          final parts = tarihKey.split('-');
                          if (parts.length != 3) return;
                          final tarihDt = DateTime(
                            int.parse(parts[0]),
                            int.parse(parts[1]),
                            int.parse(parts[2]),
                          );
                          // Kullanıcı için: kapatılmamış güne erişim engeli
                          if (!yonetici) {
                            final kapali = data['tamamlandi'] == true ||
                                data['tamamlandi'] == 1 ||
                                data['tamamlandi']?.toString() == 'true';
                            if (!kapali) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Bu gün henüz kapatılmamış.'),
                                  backgroundColor: Colors.orange,
                                ),
                              );
                              return;
                            }
                            // Referans: son kapanan gün (bugün değil)
                            final referansTarih = _aktifSonKapaliTarih ?? bugun;
                            final fark =
                                referansTarih.difference(tarihDt).inDays;
                            if (fark > widget.gecmisGunHakki) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    widget.gecmisGunHakki == 0
                                        ? 'Geçmiş kayıtları görüntüleme yetkiniz yok.'
                                        : '${widget.gecmisGunHakki} günden eski kayıtlara erişemezsiniz.',
                                  ),
                                  backgroundColor: Colors.red,
                                ),
                              );
                              return;
                            }
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => OnHazirlikEkrani(
                                subeKodu: _aktifSubeKodu,
                                baslangicTarihi: tarihDt,
                                subeler: widget.subeler,
                                gecmisGunHakki: widget.gecmisGunHakki,
                                initialTabIndex: 5,
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
