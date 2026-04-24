import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../core/formatters.dart';
import '../core/utils.dart';
import 'gider_duzenle_sheet.dart';
import 'gider_adi_alani.dart';
import 'gider_turleri_kart.dart';

// ─── Projeksiyon Widget ───────────────────────────────────────────────────────

class ProjeksiyonWidget extends StatefulWidget {
  const ProjeksiyonWidget({super.key});
  @override
  State<ProjeksiyonWidget> createState() => ProjeksiyonWidgetState();
}

class ProjeksiyonWidgetState extends State<ProjeksiyonWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  bool _yukleniyor = false;
  String? _hata;
  List<Map<String, dynamic>> _subeVeriler = [];
  final Map<String, TextEditingController> _tahminCtrl = {};
  final ScrollController _yatayScroll = ScrollController();

  // Ay seçici
  int _secilenYil = DateTime.now().year;
  int _secilenAy = DateTime.now().month;

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

  // Gider türleri listesi — _GiderDuzenleSheet için
  List<String> _giderTurleri = [];

  @override
  void initState() {
    super.initState();
    _giderTurleriYukle();
    // Veriler 'Göster' butonuna basınca yüklenir
  }

  Future<void> _giderTurleriYukle() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('giderTurleri')
          .get();
      final liste =
          (doc.data()?['liste'] as List?)?.map((e) => e.toString()).toList();
      if (mounted)
        setState(() {
          final ham = liste?.isNotEmpty == true
              ? liste!
              : [
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
          ham.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          _giderTurleri = ham;
        });
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final c in _tahminCtrl.values) c.dispose();
    _yatayScroll.dispose();
    super.dispose();
  }

  static DateTime _bugunuHesapla() {
    final s = DateTime.now();
    return s.hour < 5
        ? DateTime(s.year, s.month, s.day - 1)
        : DateTime(s.year, s.month, s.day);
  }

  String _fmt(double v) {
    final parts = v.abs().toStringAsFixed(0);
    final buf = StringBuffer();
    for (int i = 0; i < parts.length; i++) {
      if (i > 0 && (parts.length - i) % 3 == 0) buf.write('.');
      buf.write(parts[i]);
    }
    return '${v < 0 ? '-' : ''}${buf.toString()} ₺';
  }

  double _parseD(String s) =>
      double.tryParse(s.replaceAll('.', '').replaceAll(',', '.')) ?? 0.0;

  Future<void> _yukle() async {
    setState(() => _yukleniyor = true);
    try {
      final bugun = _bugunuHesapla();
      final secilenAyBasi = DateTime(_secilenYil, _secilenAy, 1);
      final secilenAyBitis = DateTime(_secilenYil, _secilenAy + 1, 0);

      // Seçili ay geçmişteyse ayın son gününe kadar çek,
      // bu ay ise bugüne kadar çek
      final buGunMu = _secilenYil == bugun.year && _secilenAy == bugun.month;
      final sorguBitis = buGunMu ? bugun : secilenAyBitis;

      final ayBasiKey =
          '${secilenAyBasi.year}-${secilenAyBasi.month.toString().padLeft(2, '0')}-01';
      final bugunKey =
          '${sorguBitis.year}-${sorguBitis.month.toString().padLeft(2, '0')}-${sorguBitis.day.toString().padLeft(2, '0')}';

      // Kalan gün şube bazında hesaplanacak (her şubenin son kapatılan günü farklı olabilir)
      // Bu yüzden kalanGun sabit hesap kaldırıldı — her şube için ayrı hesaplanıyor

      // Tüm şubeleri al — client-side filtre (composite index gerekmez)
      final subelerSnap = await FirebaseFirestore.instance
          .collection('subeler')
          .orderBy('ad')
          .get();

      // Şube adlarını al (aktif olmayanları atla)
      final subeAdlari = <String, String>{};
      for (final d in subelerSnap.docs) {
        final aktif = d.data()['aktif'];
        if (aktif == false) continue; // false olanları atla, null/true geçer
        subeAdlari[d.id] = (d.data()['ad'] as String?) ?? d.id;
      }

      // Aktif şube listesi
      final aktifSubeler =
          subelerSnap.docs.where((d) => subeAdlari.containsKey(d.id)).toList();

      // Tüm şubeler için paralel sorgu — sıralı yerine aynı anda
      final futures = aktifSubeler.map((subeDoc) async {
        final subeId = subeDoc.id;
        final subeAd = subeAdlari[subeId] ?? subeId;

        // Günlük kayıtlar + ayarlar aynı anda çek
        final results = await Future.wait([
          FirebaseFirestore.instance
              .collection('subeler')
              .doc(subeId)
              .collection('gunluk')
              .where('tarih', isGreaterThanOrEqualTo: ayBasiKey)
              .where('tarih', isLessThanOrEqualTo: bugunKey)
              .get(),
          FirebaseFirestore.instance
              .collection('subeler')
              .doc(subeId)
              .collection('ayarlar')
              .doc('genel')
              .get(),
        ]);

        final kayitlarSnap = results[0] as QuerySnapshot<Map<String, dynamic>>;
        final ayarSnap = results[1] as DocumentSnapshot<Map<String, dynamic>>;
        final ayar = ayarSnap.data() ?? {};

        double gerceklesenCiro = 0;
        double gerceklesenHarcama = 0;
        double gidenTransfer = 0;
        double gelenTransfer = 0;
        for (final k in kayitlarSnap.docs) {
          final d = k.data();
          gerceklesenCiro += (d['gunlukSatisToplami'] as num? ?? 0).toDouble();
          gerceklesenHarcama += (d['toplamHarcama'] as num? ?? 0).toDouble();
          gerceklesenHarcama +=
              (d['toplamAnaKasaHarcama'] as num? ?? 0).toDouble();
          for (final da in (d['digerAlimlar'] as List?)?.cast<Map>() ?? []) {
            gerceklesenHarcama += (da['tutar'] as num? ?? 0).toDouble();
          }
          for (final t in (d['transferler'] as List?)?.cast<Map>() ?? []) {
            final kat = t['kategori'] as String? ?? '';
            final tutar = (t['tutar'] as num? ?? 0).toDouble();
            if (kat == 'GİDEN') gidenTransfer += tutar;
            if (kat == 'GELEN') gelenTransfer += tutar;
          }
        }

        final personelSayi = (ayar['personelSayisi'] as num? ?? 0).toInt();
        final personelBasi =
            (ayar['personelBasiMaliyet'] as num? ?? 0).toDouble();
        final personelEkstra =
            (ayar['personelEkstraMaliyet'] as num? ?? 0).toDouble();
        final sabitGiderler =
            (ayar['sabitGiderler'] as List?)?.cast<Map>() ?? [];
        double sabitToplami = 0;
        for (final g in sabitGiderler) {
          sabitToplami += (g['tutar'] as num? ?? 0).toDouble();
        }
        final personelMaliyet = (personelSayi * personelBasi) + personelEkstra;

        List<Map<String, dynamic>> ciroBazliGiderler;
        if (ayar.containsKey('ciroBazliGiderler')) {
          ciroBazliGiderler =
              (ayar['ciroBazliGiderler'] as List).cast<Map<String, dynamic>>();
        } else {
          ciroBazliGiderler = [];
          final eskiRoyalty = (ayar['royaltyOrani'] as num?)?.toDouble();
          final eskiKomisyon = (ayar['komisyonOrani'] as num?)?.toDouble();
          if (eskiRoyalty != null && eskiRoyalty > 0)
            ciroBazliGiderler.add({'ad': 'Royalty', 'oran': eskiRoyalty});
          if (eskiKomisyon != null && eskiKomisyon > 0)
            ciroBazliGiderler.add({'ad': 'Komisyon', 'oran': eskiKomisyon});
        }

        final kayitSayisi = kayitlarSnap.docs.length;

        // ── Kalan Gün Hesabı ──────────────────────────────────────────────────
        // Geçmiş ay ise kalan gün = 0 (ay kapandı).
        // Bu ay ise: en son KAPATILMIŞ (tamamlandi==true) günü bul;
        // ayın son gününden çıkar.
        // Örnek: son kapatılan 28, ay 31 gün → kalanGun = 3
        int kalanGun = 0;
        if (buGunMu) {
          // Sadece tamamlandi==true olan kayıtlar arasından en büyük tarihi bul
          String? enSonKapaliTarihKey;
          for (final k in kayitlarSnap.docs) {
            final d = k.data();
            final tamamlandi = d['tamamlandi'] as bool? ?? false;
            if (!tamamlandi) continue; // Kapatılmamış günleri atla
            final t = d['tarih'] as String?;
            if (t != null) {
              if (enSonKapaliTarihKey == null ||
                  t.compareTo(enSonKapaliTarihKey) > 0) {
                enSonKapaliTarihKey = t;
              }
            }
          }

          if (enSonKapaliTarihKey != null) {
            // En son kapatılmış günün gün numarasını çıkar
            final parcalar = enSonKapaliTarihKey.split('-');
            final enSonGun =
                parcalar.length == 3 ? int.tryParse(parcalar[2]) ?? 0 : 0;
            // Kalan = ayın son günü - en son kapatılmış gün
            kalanGun = (secilenAyBitis.day - enSonGun).clamp(0, 31);
          } else {
            // Hiç kapatılmış kayıt yoksa tüm ay kalan
            kalanGun = secilenAyBitis.day;
          }
        }
        // ─────────────────────────────────────────────────────────────────────

        final otomatikTahmin =
            kayitSayisi > 0 ? gerceklesenCiro / kayitSayisi : 0.0;
        // Controller yoksa: kaydedilmiş manuel tahmin varsa onu kullan,
        // yoksa otomatik ortalamayı kullan. Varsa dokunma.
        if (!_tahminCtrl.containsKey(subeId)) {
          final kayitliTahmin =
              (ayar['tahminliGunlukCiro'] as num?)?.toDouble();
          final baslangicDeger = kayitliTahmin != null && kayitliTahmin > 0
              ? kayitliTahmin.toStringAsFixed(0)
              : otomatikTahmin.toStringAsFixed(0);
          _tahminCtrl[subeId] = TextEditingController(text: baslangicDeger);
        }

        return {
          'subeId': subeId,
          'subeAd': subeAd,
          'gerceklesenCiro': gerceklesenCiro,
          'gerceklesenHarcama': gerceklesenHarcama,
          'gidenTransfer': gidenTransfer,
          'gelenTransfer': gelenTransfer,
          'kalanGun': kalanGun,
          'ciroBazliGiderler': ciroBazliGiderler,
          'personelMaliyet': personelMaliyet,
          'sabitGiderToplami': sabitToplami,
          'sabitGiderler': sabitGiderler,
          'personelSayisi': personelSayi,
          'personelBasiMaliyet': personelBasi,
          'personelEkstraMaliyet': personelEkstra,
          'detayAcik': false,
        };
      });

      // Tüm şubeleri paralel çek
      final veriler = List<Map<String, dynamic>>.from(
        await Future.wait(futures),
      );

      // Ada göre sırala
      veriler.sort(
        (a, b) => (a['subeAd'] as String).compareTo(b['subeAd'] as String),
      );

      if (mounted)
        setState(() {
          _subeVeriler = veriler;
          _yukleniyor = false;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          _yukleniyor = false;
          _hata = e.toString();
        });
    }
  }

  Future<void> _giderDuzenleDialog(Map<String, dynamic> v) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => GiderDuzenleSheet(
        v: v,
        giderTurleri: _giderTurleri,
        onKaydet: (sonuc) async {
          await FirebaseFirestore.instance
              .collection('subeler')
              .doc(v['subeId'] as String)
              .collection('ayarlar')
              .doc('genel')
              .set({
            'ciroBazliGiderler': sonuc['ciroBazliGiderler'],
            'personelSayisi': sonuc['personelSayisi'],
            'personelBasiMaliyet': sonuc['personelBasi'],
            'personelEkstraMaliyet': sonuc['personelEkstra'],
            'sabitGiderler': sonuc['sabitGiderler'],
            'guncelleme': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          // Sadece bu şubenin verisini güncelle — tüm sayfa yeniden yüklenmez
          setState(() {
            v['ciroBazliGiderler'] = sonuc['ciroBazliGiderler'];
            v['personelSayisi'] = sonuc['personelSayisi'] as int;
            v['personelBasiMaliyet'] = sonuc['personelBasi'] as double;
            v['personelEkstraMaliyet'] = sonuc['personelEkstra'] as double;
            v['sabitGiderler'] = sonuc['sabitGiderler'];
            // Personel maliyetini yeniden hesapla
            v['personelMaliyet'] = (sonuc['personelSayisi'] as int) *
                    (sonuc['personelBasi'] as double) +
                (sonuc['personelEkstra'] as double);
            // Sabit gider toplamını yeniden hesapla
            v['sabitGiderToplami'] =
                (sonuc['sabitGiderler'] as List<Map<String, dynamic>>).fold(
              0.0,
              (s, g) => s + ((g['tutar'] as num?) ?? 0).toDouble(),
            );
          });
        },
      ),
    );
  }

  Widget _giderBaslik(String baslik) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          baslik,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13,
            color: Color(0xFF0288D1),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin için gerekli
    if (_yukleniyor) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_hata != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 12),
              Text(
                'Hata: $_hata',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _hata = null;
                    _yukleniyor = true;
                  });
                  _yukle();
                },
                child: const Text('Tekrar Dene'),
              ),
            ],
          ),
        ),
      );
    }

    final ay = '${_aylar[_secilenAy - 1]} $_secilenYil';

    // Özet toplamlar
    double toplamGerceklesen = 0;
    double toplamTahmini = 0;
    double toplamGider = 0;
    double toplamKalan = 0;
    for (final v in _subeVeriler) {
      final subeId = v['subeId'] as String;
      final tahminCtrl = _tahminCtrl[subeId]!;
      final tahminGunluk = _parseD(tahminCtrl.text);
      final kalanGun = v['kalanGun'] as int;
      final gerceklesen = v['gerceklesenCiro'] as double;
      final tahminiAySonu = gerceklesen + tahminGunluk * kalanGun;
      final ciroBazliGiderler = (v['ciroBazliGiderler'] as List).cast<Map>();
      double ciroBazliToplam = 0;
      for (final g in ciroBazliGiderler) {
        ciroBazliToplam +=
            tahminiAySonu * ((g['oran'] as num? ?? 0).toDouble()) / 100;
      }
      final toplamGiderSube = ciroBazliToplam +
          (v['sabitGiderToplami'] as double) +
          (v['personelMaliyet'] as double) +
          (v['gerceklesenHarcama'] as double) +
          (v['gelenTransfer'] as double) -
          (v['gidenTransfer'] as double);
      toplamGerceklesen += gerceklesen;
      toplamTahmini += tahminiAySonu;
      toplamGider += toplamGiderSube;
      toplamKalan += tahminiAySonu - toplamGiderSube;
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Başlık + Ay Seçici ──
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  // Ay dropdown
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      value: _secilenAy,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: 'Ay',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      items: List.generate(
                        12,
                        (i) => DropdownMenuItem(
                          value: i + 1,
                          child: Text(
                            _aylar[i],
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                      onChanged: (v) => setState(() => _secilenAy = v!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Yıl dropdown
                  SizedBox(
                    width: 90,
                    child: DropdownButtonFormField<int>(
                      value: _secilenYil,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: 'Yıl',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      items: List.generate(3, (i) => DateTime.now().year - i)
                          .map(
                            (y) => DropdownMenuItem(
                              value: y,
                              child: Text(
                                '$y',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _secilenYil = v!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _yukle,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0288D1),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    child: const Text('Göster'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: 'Yenile',
                    onPressed: _yukle,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Seçili ay başlığı
          Text(
            '$ay — Tahmin',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF0288D1),
            ),
          ),
          const SizedBox(height: 12),

          // ── Genel toplam kartı (lacivert) ──
          if (_subeVeriler.isNotEmpty) ...[
            Card(
              color: const Color(0xFF0288D1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
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
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _toplamHucre(
                            'Gerçekleşen',
                            toplamGerceklesen,
                            Colors.white,
                          ),
                        ),
                        Expanded(
                          child: _toplamHucre(
                            'Tahmini Ay Sonu',
                            toplamTahmini,
                            Colors.white,
                          ),
                        ),
                        Expanded(
                          child: _toplamHucre(
                            'Tahmini Kalan',
                            toplamKalan,
                            toplamKalan >= 0
                                ? const Color(0xFF80CBC4)
                                : Colors.red[300]!,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // ── Şube kartları ──
            ..._subeVeriler.map((v) => _subeKarti(v)),
          ] else ...[
            const SizedBox(height: 48),
            Center(
              child: Text(
                'Ay ve yıl seçip "Göster" butonuna basın.',
                style: TextStyle(color: Colors.grey[500], fontSize: 14),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Özet kart (artık kullanılmıyor ama korunuyor) ───────────────────────────
  Widget _toplamHucre(String etiket, double deger, Color renk) => Column(
        children: [
          Text(
            etiket,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            _fmt(deger),
            style: TextStyle(
              color: renk,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );

  Widget _ozetKart(String etiket, double deger, bool? pozitif) {
    Color renk = const Color(0xFF0288D1);
    if (pozitif == true) renk = Colors.green[700]!;
    if (pozitif == false) renk = Colors.red[700]!;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              etiket,
              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              _fmt(deger),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: renk,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  // ── Şube kartı ──────────────────────────────────────────────────────────────
  Widget _subeKarti(Map<String, dynamic> v) {
    final subeId = v['subeId'] as String;
    final subeAd = v['subeAd'] as String;
    final tahminCtrl = _tahminCtrl[subeId]!;
    final tahminGunluk = _parseD(tahminCtrl.text);
    final kalanGun = v['kalanGun'] as int;
    final gerceklesen = v['gerceklesenCiro'] as double;
    final tahminiAySonu = gerceklesen + tahminGunluk * kalanGun;
    final ciroBazliGiderler = (v['ciroBazliGiderler'] as List).cast<Map>();
    double ciroBazliToplam = 0;
    for (final g in ciroBazliGiderler) {
      ciroBazliToplam +=
          tahminiAySonu * ((g['oran'] as num? ?? 0).toDouble()) / 100;
    }
    final sabit = v['sabitGiderToplami'] as double;
    final personel = v['personelMaliyet'] as double;
    final gercekHarcama = v['gerceklesenHarcama'] as double;
    final gidenTransfer = v['gidenTransfer'] as double;
    final gelenTransfer = v['gelenTransfer'] as double;
    final toplamGider = ciroBazliToplam +
        sabit +
        personel +
        gercekHarcama +
        gelenTransfer -
        gidenTransfer;
    final kalan = tahminiAySonu - toplamGider;
    final detayAcik = v['detayAcik'] as bool;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 1,
      child: Column(
        children: [
          // ── Başlık (lacivert, tıklanabilir) ──
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
                  // Şube adı
                  Expanded(
                    flex: 3,
                    child: Text(
                      subeAd,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Gerçekleşen + Ay sonu
                  Expanded(
                    flex: 4,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 12,
                      children: [
                        _baslikDegerBeyaz('Gerçekleşen', gerceklesen),
                        _baslikDegerBeyaz('Ay Sonu', tahminiAySonu),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Kalan pill
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: kalan >= 0 ? Colors.green[700] : Colors.red[700],
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      _fmt(kalan),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    detayAcik ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: Colors.white60,
                  ),
                ],
              ),
            ),
          ),

          // ── Detay paneli ──
          if (detayAcik) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  // 2×2 grid: Ciro Bazlı / Personel / Sabit / Diğer
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _detayBlok(
                          'Ciro Bazlı',
                          ciroBazliGiderler.map((g) {
                            final ad = g['ad'] as String? ?? '';
                            final oran = (g['oran'] as num? ?? 0).toDouble();
                            return _detayKalemData(
                              '$ad (%${oran.toStringAsFixed(1)})',
                              tahminiAySonu * oran / 100,
                            );
                          }).toList(),
                          Colors.orange[700]!,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _detayBlok(
                            'Personel',
                            [
                              _detayKalemData(
                                '${v['personelSayisi']} kişi × ${_fmt(v['personelBasiMaliyet'] as double)}',
                                (v['personelSayisi'] as int) *
                                    (v['personelBasiMaliyet'] as double),
                              ),
                              if ((v['personelEkstraMaliyet'] as double) > 0)
                                _detayKalemData(
                                  'Ekstra',
                                  v['personelEkstraMaliyet'] as double,
                                ),
                            ],
                            Colors.blue[700]!),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _detayBlok(
                          'Sabit Giderler',
                          (v['sabitGiderler'] as List)
                              .cast<Map>()
                              .map(
                                (g) => _detayKalemData(
                                  g['ad'] as String? ?? '',
                                  (g['tutar'] as num? ?? 0).toDouble(),
                                ),
                              )
                              .toList(),
                          Colors.grey[700]!,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _detayBlok(
                            'Diğer',
                            [
                              _detayKalemData(
                                  'Gerçekleşen Harc.', gercekHarcama),
                              if (gelenTransfer > 0)
                                _detayKalemData(
                                  'Gelen Transfer (+)',
                                  gelenTransfer,
                                ),
                              if (gidenTransfer > 0)
                                _detayKalemData(
                                  'Giden Transfer (−)',
                                  -gidenTransfer,
                                  renk: Colors.green[700]!,
                                ),
                            ],
                            Colors.red[700]!),
                      ),
                    ],
                  ),
                  // Toplam gider özeti
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey[200]!),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Toplam Gider',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          _fmt(toplamGider),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ── Alt şerit: Tahmini günlük + Gider düzenle ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFFF8F8F8),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(12)),
              border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
            ),
            child: Row(
              children: [
                // Tahmin girişi
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Tahmini günlük:',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      width: 110,
                      child: TextFormField(
                        controller: tahminCtrl,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          border: OutlineInputBorder(),
                          suffixText: '₺',
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [BinAraciFormatter()],
                        onChanged: (val) {
                          setState(() {});
                          final temiz =
                              val.replaceAll('.', '').replaceAll(',', '.');
                          final deger = double.tryParse(temiz);
                          if (deger != null) {
                            FirebaseFirestore.instance
                                .collection('subeler')
                                .doc(subeId)
                                .collection('ayarlar')
                                .doc('genel')
                                .set({
                              'tahminliGunlukCiro': deger,
                            }, SetOptions(merge: true));
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                // Ortalama bilgi
                if (kalanGun > 0)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Günlük ort.:',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _fmt(
                          gerceklesen /
                              (kalanGun > 0
                                  ? (DateTime(
                                            _secilenYil,
                                            _secilenAy + 1,
                                            0,
                                          ).day -
                                          kalanGun)
                                      .clamp(1, 31)
                                  : 1),
                        ),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _giderDuzenleDialog(v),
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text(
                    'Gider Düzenle',
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

  Widget _baslikDegerBeyaz(String etiket, double deger) => Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(etiket,
              style: const TextStyle(fontSize: 10, color: Colors.white54)),
          Text(
            _fmt(deger),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ],
      );

  Widget _baslikDeger(String etiket, double deger, bool? pozitif) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(etiket, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        Text(
          _fmt(deger),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  // Detay bloğu — başlık + kalem listesi
  Widget _detayBlok(
    String baslik,
    List<Map<String, dynamic>> kalemler,
    Color baslikRenk,
  ) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            baslik,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: baslikRenk,
            ),
          ),
          const SizedBox(height: 6),
          if (kalemler.isEmpty)
            Text('—', style: TextStyle(fontSize: 12, color: Colors.grey[400]))
          else
            ...kalemler.map(
              (k) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        k['ad'] as String,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _fmt(k['tutar'] as double),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: k['renk'] as Color? ?? baslikRenk,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Map<String, dynamic> _detayKalemData(
    String ad,
    double tutar, {
    Color? renk,
  }) =>
      {'ad': ad, 'tutar': tutar, 'renk': renk};
}
