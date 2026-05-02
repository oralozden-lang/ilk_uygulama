import '../widgets/kasa_logo.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as xl;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:ui' as ui;
import 'dart:js' as js;
import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import '../excel_download.dart';

import '../core/formatters.dart';
import '../core/utils.dart';
import '../core/kullanici_yetki.dart';
import '../models/veri_modelleri.dart';
import '../widgets/gider_duzenle_sheet.dart';
import '../widgets/ek_gider_sheet.dart';
import '../widgets/gider_adi_alani.dart';
import '../widgets/odeme_yontemleri_kart.dart';
import '../widgets/gider_turleri_kart.dart';
import '../widgets/projeksiyon_widget.dart';
import '../widgets/gerceklesen_widget.dart';
import '../widgets/sube_ozet_tablosu.dart';
import '../widgets/pos_kiyaslama_widget.dart';
import 'gecmis_kayitlar_ekrani.dart';
import 'raporlar_ekrani.dart';
import 'giris_ekrani.dart';
// ─── Ön Hazırlık Ekranı ───────────────────────────────────────────────────────

class OnHazirlikEkrani extends StatefulWidget {
  final String subeKodu;
  final List<String> subeler;
  final bool raporYetkisi;
  final DateTime? baslangicTarihi;
  final int gecmisGunHakki;
  final int initialTabIndex; // Açılışta hangi sekme aktif olsun (varsayılan: 0)
  const OnHazirlikEkrani({
    super.key,
    required this.subeKodu,
    this.subeler = const [],
    this.raporYetkisi = false,
    this.baslangicTarihi,
    this.gecmisGunHakki = 0,
    this.initialTabIndex = 0,
  });
  @override
  State<OnHazirlikEkrani> createState() => _OnHazirlikEkraniState();
}

class _OnHazirlikEkraniState extends State<OnHazirlikEkrani>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late TabController _tabController;
  DateTime _secilenTarih = DateTime.now();
  Map<String, String> _subeAdlari = {}; // subeId -> subeAdi

  final List<PosGirisi> _posListesi = [PosGirisi(ad: 'POS 1')];
  final List<YemekKartiGirisi> _yemekKartlari = [];
  final Map<String, TextEditingController> _sistemYemekKartiCtrl = {};
  List<String> _yemekKartiCinsleri = []; // Firestore'dan yüklenir
  List<Map<String, dynamic>> _yemekKartiTanimlari = []; // {ad, sira, pulseAdi}
  List<Map<String, dynamic>> _onlineOdemeler = []; // {ad, ctrl}
  Map<String, double> _myDominosOkunan = {}; // My Dominos okunan veriler
  bool _myDominosYuklendi = false;
  bool _myDominosOkunuyor = false;
  bool _pulseOkunuyor = false;
  bool _pulseIptalEdildi = false;
  bool _myDomIptalEdildi = false;
  bool _pulseOkundu = false; // Pulse başarıyla okundu mu
  bool _myDomOkundu = false; // MyDom başarıyla okundu mu
  bool _pulseKontrolOnaylandi = false; // "Pulse kontrol edildi" onayı
  bool _posOkunuyor = false;
  bool _posIptalEdildi = false;
  bool _posOkundu = false;
  bool _posKontrolOnaylandi = false;
  final Set<String> _acikSatirlar = {}; // ✏ ile açılan eşleşen satırlar
  double _pulseBankaParasi = 0; // Pulse sayfasındaki Banka Parası
  String? _focustaKiSatir; // Şu an focus'ta olan satır key'i — mod değiştirme
  final Map<String, String> _satirModu =
      {}; // Her satırın mevcut modu: 'bos','sol','eslesme','fark'
  final Map<String, String> _eskiPulseDegler =
      {}; // İptal için eski Pulse değerleri
  final Map<String, String> _eskiMyDomDegler =
      {}; // İptal için eski MyDom değerleri
  String _okumaMesaji = ''; // Alt banttaki mesaj
  final Map<String, TextEditingController> _pulseKiyasCtrl =
      {}; // Pulse manuel giriş
  final Map<String, TextEditingController> _myDomKiyasCtrl =
      {}; // MyDom manuel giriş
  final Set<TextEditingController> _pulseCtrlListenerli =
      {}; // Listener eklenmiş Pulse ctrl'leri (dedup)
  List<Map<String, dynamic>> _pulseKalemleri = []; // tip: pulseKalemi
  List<String> _onlineOdemeAdlari = []; // Firestore'dan yüklenir
  final TextEditingController _sistemPosCtrl = TextEditingController();
  final TextEditingController _gunlukSatisCtrl = TextEditingController();
  final List<HarcamaGirisi> _harcamalar = [HarcamaGirisi()];
  List<int> _banknotlar = [200, 100, 50, 20, 10, 5, 1];
  List<String> _giderTurleriListesi = [];
  final Map<int, TextEditingController> _banknotCtrl = {};
  int _flotSiniri = 20;
  final TextEditingController _manuelFlotCtrl = TextEditingController();
  final TextEditingController _devredenFlotCtrl = TextEditingController();
  final TextEditingController _ekrandaGorunenNakitCtrl =
      TextEditingController();
  final List<HarcamaGirisi> _anaKasaHarcamalari = [HarcamaGirisi()];
  final List<HarcamaGirisi> _nakitCikislar = [HarcamaGirisi()];
  final List<Map<String, dynamic>> _nakitDovizler = []; // Nakit çıkış döviz
  final TextEditingController _bankayaYatiranCtrl = TextEditingController();

  // Döviz
  final List<Map<String, dynamic>> _dovizler = [];

  // Döviz Ana Kasa — her döviz türü için devreden, bankaya yatırılan
  final List<String> _dovizTurleri = ['USD', 'EUR', 'GBP'];
  Map<String, double> _devredenDovizMiktarlari = {'USD': 0, 'EUR': 0, 'GBP': 0};
  Map<String, TextEditingController> _dovizBankayaYatiranCtrl = {};

  // Bankaya yatırılan döviz - dinamik liste
  final List<Map<String, dynamic>> _bankaDovizler = [];

  // Transferler
  final List<Map<String, dynamic>> _transferler = [];

  // Diğer Alımlar
  final List<Map<String, dynamic>> _digerAlimlar = [];

  double _oncekiAnaKasaKalani = 0;
  double _otomatikDevredenFlot = 0;
  bool _kaydediliyor = false;
  bool _degisiklikVar = false; // Kaydedilmemiş değişiklik var mı
  bool _gercekDegisiklikVar =
      false; // Kullanıcı gerçekten bir alan değiştirdi mi
  bool _internetVar = true; // İnternet bağlantısı durumu
  Timer? _internetTimer;
  Timer? _arkaPlanTimer; // Arka planda geçen süre
  Timer? _idleTimer; // Kullanıcı dokunmayı bırakınca kaydet (idle)
  bool _otomatikKaydediliyor = false; // Otomatik kayıt devam ediyor mu
  String _appBarMesaj = ''; // AppBar'da gösterilecek mesaj
  Timer? _appBarMesajTimer; // AppBar mesajı için timer
  bool _kilitTutuyorum = false;
  String? _kilitTutanKullanici;
  Timer? _kilitTimer;
  String _mevcutKullanici = '';
  bool _gunuKapatildi = false;
  DateTime? _ilkKapaliTarih; // Şubenin açılış tarihi (ilk kapatılan gün)
  DateTime? _sonKapaliTarih; // En son kapatılan gün (gecmisGunHakki referansı)
  bool _duzenlemeAcik = false;
  int _bekleyenTransferSayisi = 0; // AppBar rozet
  bool _bildirimIsleniyor = false;
  bool _gorselSeciliyor =
      false; // Resim seçimi sırasında lifecycle event yoksay // Bildirim döngüsü yeniden tetiklenmesin
  StreamSubscription<QuerySnapshot>? _bekleyenTransferStream; // Realtime rozet
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _transferKey = GlobalKey(); // Transfer bölümüne scroll

  // ── Gün kesim saati: 05:00 öncesi = önceki gün ─────────────────────────────
  static DateTime _bugunuHesapla() {
    final simdi = DateTime.now();
    if (simdi.hour < gunKapanisSaati) {
      return DateTime(simdi.year, simdi.month, simdi.day - 1);
    }
    return DateTime(simdi.year, simdi.month, simdi.day);
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 6,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 5),
    );

    // Pulse/MyDom sekmesine geçince rebuild et — POS değerleri güncellensin
    int _sonTabIndex = 0;
    _tabController.addListener(() {
      if (!mounted) return;
      // indexIsChanging VEYA index değişimi — swipe dahil her geçişi yakala
      if (_tabController.index != _sonTabIndex) {
        _sonTabIndex = _tabController.index;
        setState(() {}); // chip ikonları güncellenir
        // Sekme değişince bekleyen kayıt varsa kaydet
        if (_degisiklikVar) {
          _anindaKaydet();
        }
      }
    });
    _banknotlariYukle();
    _giderTurleriYukle();
    _yemekKartiCinsleriniYukle();
    _onlineOdemeleriYukle();
    _subeAdlariniYukle();
    for (var t in _dovizTurleri) {
      _dovizBankayaYatiranCtrl[t] = TextEditingController();
    }
    WidgetsBinding.instance.addObserver(this);
    _kullaniciyiYukle();
    _bildirimIsleniyor = false;
    _bekleyenTransferSayisi = 0;

    // Başlangıç tarihi dışarıdan verilmişse (geçmiş gün linki) direkt kullan
    if (widget.baslangicTarihi != null) {
      _secilenTarih = widget.baslangicTarihi!;
      _mevcutKaydiYukleYaDaTemizle().then((_) {
        if (!mounted) return;
        setState(() => _degisiklikVar = false);
        _controllerListenerEkle();
        _bekleyenTransferStreamBaslat();
        _ilkKapaliTarihiYukle();
      });
    } else {
      // Yönetici ise bugünde aç, kullanıcı ise kapanmamış ilk günü bul
      _secilenTarih = _bugunuHesapla();
      _kapanmamisGunuBulVeAc();
    }
    // İnternet bağlantısını periyodik kontrol et
    _internetKontrol();
    _internetTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _internetKontrol();
    });
  }

  // Controllerlara listener ekle (değişiklik takibi için)
  void _controllerListenerEkle() {
    final controllers = [
      _sistemPosCtrl,
      _gunlukSatisCtrl,
      _manuelFlotCtrl,
      _devredenFlotCtrl,
      _ekrandaGorunenNakitCtrl,
      _bankayaYatiranCtrl,
    ];
    for (var c in controllers) {
      c.addListener(() {
        if (!mounted || _yukleniyor || _readOnly) return;
        // setState'i bir sonraki frame'e ertele — build sırasında çağrılmasını önle
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _degisiklikVar = true;
            if (_duzenlemeAcik) _gercekDegisiklikVar = true;
          });
          _kilitAl();
        });
      });
    }

    // Mevcut Pulse/MyDom ctrl'lerine listener bağla
    for (var c in _pulseKiyasCtrl.values) _pulseCtrlBagla(c);
    for (var c in _myDomKiyasCtrl.values) _pulseCtrlBagla(c);
  }

  // Pulse/balance etkileyen ctrl'lere değişiklik + onay-reset listener ekle (dedup)
  void _pulseCtrlBagla(TextEditingController ctrl) {
    if (_pulseCtrlListenerli.contains(ctrl)) return;
    _pulseCtrlListenerli.add(ctrl);
    ctrl.addListener(() {
      if (!mounted || _yukleniyor || _readOnly) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _degisiklikVar = true;
          if (_pulseKontrolOnaylandi) _pulseKontrolOnaylandi = false;
        });
        _kilitAl();
      });
    });
  }

  // Açılışta kapanmamış ilk günü bul ve oraya git
  Future<void> _kapanmamisGunuBulVeAc() async {
    // Yönetici de kullanıcı gibi son kapatılan gün+1'de açılır
    // Ama istediği güne gitmekte serbesttir (ok, tarih seçici, geçmiş kayıtlar)
    if (widget.gecmisGunHakki == -1) {
      // Yönetici için de son kapatılmış günü bul — limit(30) ile hafif
      try {
        final bugun = _bugunuHesapla();
        final snap = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(widget.subeKodu)
            .collection('gunluk')
            .orderBy('tarih', descending: true)
            .limit(30)
            .get();
        String sonKapaliStr = '';
        for (final doc in snap.docs) {
          final d = doc.data();
          final kapali = d['tamamlandi'] == true ||
              d['tamamlandi'] == 1 ||
              d['tamamlandi']?.toString() == 'true';
          if (kapali) {
            sonKapaliStr = d['tarih'] as String? ?? '';
            break;
          }
        }
        if (sonKapaliStr.isNotEmpty) {
          final p = sonKapaliStr.split('-');
          if (p.length == 3) {
            final sonKapali = DateTime(
              int.parse(p[0]),
              int.parse(p[1]),
              int.parse(p[2]),
            );
            _sonKapaliTarih = sonKapali;
            final sonraki = sonKapali.add(const Duration(days: 1));
            _secilenTarih = sonraki.isAfter(bugun) ? bugun : sonraki;
          }
        } else {
          // Hiç kapalı gün yok — bugünde aç
          _secilenTarih = bugun;
        }
      } catch (_) {
        // Hata olursa bugünde aç
        _secilenTarih = _bugunuHesapla();
      }
      await _mevcutKaydiYukleYaDaTemizle();
      if (mounted) {
        setState(() => _degisiklikVar = false);
        _controllerListenerEkle();
      }
      _bekleyenTransferStreamBaslat();
      _ilkKapaliTarihiYukle();
      return;
    }

    try {
      final bugun = _bugunuHesapla();

      // Tüm kayıtları tarih sırasına göre çek — client-side filtre
      // where(tamamlandi) + orderBy composite index gerektiriyor,
      // index yoksa sorgu boş dönüyor. Client-side güvenli.
      // limit(30) ile hafif çekiyor — son 30 günde kapanmış gün mutlaka vardır
      final snap = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .orderBy('tarih', descending: true)
          .limit(2)
          .get();

      // En son tamamlandi==true olan günü bul
      String sonKapaliTarihStr = '';
      for (final doc in snap.docs) {
        final data = doc.data();
        final tamamlandi = data['tamamlandi'];
        // bool/int/string farkı — hepsini yakala
        final kapali = tamamlandi == true ||
            tamamlandi == 1 ||
            tamamlandi?.toString() == 'true';
        if (kapali) {
          sonKapaliTarihStr = data['tarih'] as String? ?? '';
          break;
        }
      }

      if (sonKapaliTarihStr.isNotEmpty) {
        final p = sonKapaliTarihStr.split('-');
        if (p.length == 3) {
          final sonKapali = DateTime(
            int.parse(p[0]),
            int.parse(p[1]),
            int.parse(p[2]),
          );
          _sonKapaliTarih = sonKapali; // State'e kaydet
          final sonraki = sonKapali.add(const Duration(days: 1));
          // Sonraki gün bugünü geçmiyorsa oraya git, geçiyorsa bugüne
          _secilenTarih = sonraki.isAfter(bugun) ? bugun : sonraki;
        } else {
          _secilenTarih = bugun;
        }
      } else if (snap.docs.isNotEmpty) {
        // Kapalı gün yok ama kayıt var — en eski kaydın tarihine git
        final enEskiStr = (snap.docs.last.data())['tarih'] as String? ?? '';
        if (enEskiStr.isNotEmpty) {
          final p = enEskiStr.split('-');
          if (p.length == 3) {
            final enEski = DateTime(
              int.parse(p[0]),
              int.parse(p[1]),
              int.parse(p[2]),
            );
            _secilenTarih = enEski.isAfter(bugun) ? bugun : enEski;
          } else {
            _secilenTarih = bugun;
          }
        } else {
          _secilenTarih = bugun;
        }
      } else {
        // Hiç kayıt yok — bugünde aç
        _secilenTarih = bugun;
      }
    } catch (_) {
      _secilenTarih = _bugunuHesapla();
    }

    await _mevcutKaydiYukleYaDaTemizle();
    if (mounted) {
      setState(() => _degisiklikVar = false);
      _controllerListenerEkle();
    }
    _bekleyenTransferStreamBaslat();
    _ilkKapaliTarihiYukle();
  }

  Future<void> _ilkKapaliTarihiYukle() async {
    if (widget.gecmisGunHakki == -1) return; // Yönetici — gerek yok
    try {
      final snap = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .orderBy('tarih', descending: false)
          .get();

      DateTime? ilk;
      DateTime? son;

      for (final doc in snap.docs) {
        final data = doc.data();
        final tamamlandi = data['tamamlandi'];
        final kapali = tamamlandi == true ||
            tamamlandi == 1 ||
            tamamlandi?.toString() == 'true';
        if (kapali) {
          final tarihStr = data['tarih'] as String? ?? '';
          if (tarihStr.isNotEmpty) {
            final p = tarihStr.split('-');
            if (p.length == 3) {
              final dt = DateTime(
                int.parse(p[0]),
                int.parse(p[1]),
                int.parse(p[2]),
              );
              ilk ??= dt; // İlk kapalı gün
              son = dt; // Her seferinde güncelle — en son kapalı gün
            }
          }
        }
      }

      if (mounted && (ilk != null || son != null)) {
        setState(() {
          if (ilk != null) _ilkKapaliTarih = ilk;
          if (son != null) _sonKapaliTarih = son;
        });
      }
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  void _bekleyenTransferStreamBaslat() {
    _bekleyenTransferStream?.cancel();
    _bekleyenTransferStream = FirebaseFirestore.instance
        .collection('subeler')
        .doc(widget.subeKodu)
        .collection('bekleyen_transferler')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;

      // Rozet sayısını güncelle
      final yeniSayi = snap.docs
          .where(
            (d) =>
                d.data()['kategori'] == 'GELEN' ||
                d.data()['kategori'] == 'ONAY_BILDIRIMI' ||
                d.data()['kategori'] == 'RET' ||
                d.data()['kategori'] == 'BEKLET_BILDIRIMI',
          )
          .length;
      setState(() => _bekleyenTransferSayisi = yeniSayi);

      // Aya gelen durum bildirimleri (ONAY, RET, BEKLET) otomatik işle
      // — kullanıcı rozete tıklamak zorunda kalmasın
      final durumBildirimleri = snap.docs.where((d) {
        final kat = d.data()['kategori'] as String? ?? '';
        return kat == 'ONAY_BILDIRIMI' ||
            kat == 'RET' ||
            kat == 'BEKLET_BILDIRIMI';
      }).toList();

      if (durumBildirimleri.isNotEmpty && !_bildirimIsleniyor) {
        // Kısa gecikme ile işle — setState tamamlansın
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && !_bildirimIsleniyor) {
            _bekleyenTransferleriBildir();
          }
        });
      }
    });
  }

  // ── Uygulama yaşam döngüsü gözlemcisi ──────────────────────────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      // Arka plana atıldı — idle timer iptal et, hemen kaydet
      _idleTimer?.cancel();
      if (_degisiklikVar) {
        FirebaseFirestore.instance
            .collection('subeler')
            .doc(widget.subeKodu)
            .collection('gunluk')
            .doc(_tarihKey(_secilenTarih))
            .set(_otomatikKayitVerisi(), SetOptions(merge: true))
            .then((_) {
          if (mounted) setState(() => _degisiklikVar = false);
        }).catchError((_) {});
      }
      // 20 dakika oturum zaman aşımı başlat
      _arkaPlanTimer?.cancel();
      _arkaPlanTimer = Timer(const Duration(minutes: 20), () {
        if (mounted) _oturumZamanAsimi();
      });
    } else if (state == AppLifecycleState.resumed) {
      // Geri dönüldü — timerı iptal et
      _arkaPlanTimer?.cancel();
      _arkaPlanTimer = null;
      // Düzenleme açıksa uyar — resim seçimi sonrası değilse
      if (_duzenlemeAcik && mounted && !_gorselSeciliyor) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _oturumZamanAsimiDuzenleme();
        });
      }
    }
  }

  // ── Arka plana atılıp dönünce düzenleme uyarısı ────────────────────────────
  Future<void> _oturumZamanAsimiDuzenleme() async {
    if (!mounted || !_duzenlemeAcik) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange),
            SizedBox(width: 8),
            Text('Düzenleme Devam Ediyor'),
          ],
        ),
        content: const Text(
          'Arka planda açık bir düzenleme var. Lütfen günü kapatın veya değişiklikleri iptal edin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  // ── Oturum zaman aşımı diyalogu ──────────────────────────────────────────
  Future<void> _oturumZamanAsimi() async {
    if (!mounted) return;
    // Kaydedilmemiş değişiklik var mı?
    if (_degisiklikVar) {
      final sonuc = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.timer_off, color: Colors.orange),
              SizedBox(width: 8),
              Text('Oturum Zaman Aşımı'),
            ],
          ),
          content: const Text(
            'Uygulama 20 dakikadır arka planda.\n\nKaydedilmemiş değişiklikler var, ne yapmak istersiniz?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'devam'),
              child: const Text('Devam Et'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'cikis'),
              child: const Text(
                'Kaydetmeden Çıkış',
                style: TextStyle(color: Colors.red),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, 'kaydet'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green[700],
                foregroundColor: Colors.white,
              ),
              child: const Text('Kaydet ve Devam Et'),
            ),
          ],
        ),
      );
      if (sonuc == 'kaydet') await _kaydet();
      if (sonuc == 'cikis') await _cikisYap();
      // devam → hiçbir şey yapma
    } else {
      // Değişiklik yok — direkt sor
      final devamEt = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.timer_off, color: Colors.orange),
              SizedBox(width: 8),
              Text('Oturum Zaman Aşımı'),
            ],
          ),
          content: Text(
            'Uygulama 20 dakikadır arka planda.\nDevam etmek istiyor musunuz?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text(
                'Çıkış Yap',
                style: TextStyle(color: Colors.red),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0288D1),
                foregroundColor: Colors.white,
              ),
              child: const Text('Devam Et'),
            ),
          ],
        ),
      );
      if (devamEt == false) await _cikisYap();
    }
  }

  // ── Otomatik kaydet (debounce 3 sn) ────────────────────────────────────────
  // Kaydet — direkt, timer yok
  // Tetikleyiciler: odak kaybı, sekme değişimi, lifecycle paused, sayfa pop
  Future<void> _otomatikKaydet() async {
    if (_readOnly || !_degisiklikVar || _otomatikKaydediliyor) return;
    if (!mounted) return;
    // _degisiklikVar async bekleme ÖNCE sıfırla — kayıt sırasında gelen
    // yeni değişiklik (ör. Eşleştir) onu tekrar true yapar ve kayıt sonrası
    // yakalanır. Sıfırlamayı await sonrasına bırakmak race condition yaratır.
    setState(() {
      _otomatikKaydediliyor = true;
      _degisiklikVar = false;
    });
    if (mounted) _appBarMesajGoster('⏳ Kaydediliyor...');
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      final data = _otomatikKayitVerisi();
      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .doc(tarihKey)
          .set(data, SetOptions(merge: true));
      if (mounted) {
        _appBarMesajGoster('✓ Kaydedildi');
        await _kilitBirak();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _degisiklikVar = true); // Hata durumunda geri al
        _appBarMesajGoster('✗ Kayıt Hatası: $e');
      }
    } finally {
      if (mounted) setState(() => _otomatikKaydediliyor = false);
      // Kayıt devam ederken yeni değişiklik (ör. Eşleştir) geldiyse hemen kaydet
      if (mounted && _degisiklikVar) _otomatikKaydet();
    }
  }

  // Geriye dönük uyumluluk — eski _otomatikKaydetBaslat çağrıları için
  // Veri değişince çağrıl — idle timer başlat (60sn sonra kaydet)
  void _otomatikKaydetBaslat() {
    if (_readOnly) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(minutes: 10), () {
      if (mounted && _degisiklikVar) _otomatikKaydet();
    });
  }

  // Anında kaydet — sekme/lifecycle/gün değişimi gibi kritik anlarda
  void _anindaKaydet() {
    _idleTimer?.cancel();
    _otomatikKaydet();
  }

  // Otomatik kayıt için veri — zincirleme gerektirmez
  Map<String, dynamic> _otomatikKayitVerisi() {
    return {
      'tarih': _tarihKey(_secilenTarih),
      'tarihGoster': _tarihGoster(_secilenTarih),
      'subeKodu': widget.subeKodu,
      'otomatikKayit': true,
      'kayitZamani': FieldValue.serverTimestamp(),
      'kaydeden': _mevcutKullanici,
      'versiyon': appVersiyon,
      'posListesi': _posListesi
          .map(
            (p) => {
              'ad': p.adCtrl.text,
              'tutar': _parseDouble(p.tutarCtrl.text),
            },
          )
          .toList(),
      'toplamPos': _toplamPos,
      'sistemPos': _parseDouble(_sistemPosCtrl.text),
      'yemekKartlari': _yemekKartlari
          .map((y) => {'cins': y.cins, 'tutar': _parseDouble(y.tutarCtrl.text)})
          .toList(),
      'sistemYemekKartlari': {
        for (var c in _yemekKartiCinsleri)
          c: _parseDouble(_sistemYemekKartiCtrl[c]?.text ?? ''),
      },
      'onlineOdemeler': _onlineOdemeler
          .map(
            (o) => {
              'ad': o['ad'],
              'tutar': _parseDouble((o['ctrl'] as TextEditingController).text),
            },
          )
          .toList(),
      'gunlukSatisToplami': _parseDouble(_gunlukSatisCtrl.text),
      'pulseKiyasVerileri': Map.fromEntries(
        _pulseKiyasCtrl.entries
            .where((e) => e.value.text.isNotEmpty)
            .map((e) => MapEntry(e.key, e.value.text)),
      ),
      'myDomKiyasVerileri': Map.fromEntries(
        _myDomKiyasCtrl.entries
            .where((e) => e.value.text.isNotEmpty)
            .map((e) => MapEntry(e.key, e.value.text)),
      ),
      'pulseKontrolOnaylandi': _pulseKontrolOnaylandi,
      'pulseResmiOkundu': _pulseOkundu,
      'myDomResmiOkundu': _myDomOkundu,
      'posKontrolOnaylandi': _posKontrolOnaylandi,
      'posResmiOkundu': _posOkundu,
      'harcamalar': _harcamalar
          .map(
            (h) => {
              'aciklama': h.aciklamaCtrl.text,
              'tutar': _parseDouble(h.tutarCtrl.text),
            },
          )
          .toList(),
      'toplamHarcama': _toplamHarcama,
      'bankaParasi': _bankaParasi,
      'banknotlar': {
        for (var b in _banknotlar)
          b.toString(): _parseInt(_banknotCtrl[b]!.text),
      },
      'toplamNakit': _toplamNakit,
      'toplamNakitTL': _toplamNakitTL,
      'toplamDovizTL': _toplamDovizTL,
      'dovizler': _dovizler
          .map(
            (d) => {
              'cins': d['cins'],
              'miktar': _parseDouble(
                (d['miktarCtrl'] as TextEditingController).text,
              ),
              'kur': _parseDouble((d['kurCtrl'] as TextEditingController).text),
              'tlKarsiligi': _parseDouble(
                    (d['miktarCtrl'] as TextEditingController).text,
                  ) *
                  _parseDouble((d['kurCtrl'] as TextEditingController).text),
            },
          )
          .toList(),
      'devredenFlot': _parseDouble(_devredenFlotCtrl.text),
      'ekrandaGorunenNakit': _parseDouble(_ekrandaGorunenNakitCtrl.text),
      'manuelFlot': _parseDouble(_manuelFlotCtrl.text),
      'gunlukFlot': _flotTutari,
      'flotSiniri': _flotSiniri,
      'olmasiGereken': _olmasiGereken,
      'kasaFarki': _kasaFarki,
      'gunlukKasaKalani': _gunlukKasaKalani,
      'gunlukKasaKalaniTL': _gunlukKasaKalaniTL,
      'bankayaYatirilan': _parseDouble(_bankayaYatiranCtrl.text),
      'nakitCikislar': _nakitCikislar
          .map(
            (h) => {
              'aciklama': h.aciklama,
              'tutar': _parseDouble(h.tutarCtrl.text),
            },
          )
          .where((h) => (h['tutar'] as double) > 0)
          .toList(),
      'nakitDovizler': _nakitDovizler
          .map(
            (d) => {
              'cins': d['cins'],
              'miktar': _parseDouble((d['ctrl'] as TextEditingController).text),
              'aciklama':
                  (d['aciklamaCtrl'] as TextEditingController?)?.text.trim() ??
                      '',
            },
          )
          .where((d) => (d['miktar'] as double) > 0)
          .toList(),
      'toplamNakitCikis': _toplamNakitCikis,
      'bankaDovizler': _bankaDovizler
          .map(
            (d) => {
              'cins': d['cins'],
              'miktar': _parseDouble((d['ctrl'] as TextEditingController).text),
            },
          )
          .toList(),
      'oncekiAnaKasaKalani': _oncekiAnaKasaKalani,
      'anaKasa': _anaKasa,
      'anaKasaHarcamalari': _anaKasaHarcamalari
          .map(
            (h) => {
              'aciklama': h.aciklamaCtrl.text,
              'tutar': _parseDouble(h.tutarCtrl.text),
            },
          )
          .toList(),
      'toplamAnaKasaHarcama': _toplamAnaKasaHarcama,
      'anaKasaKalani': _anaKasaKalani,
      'dovizAnaKasaKalanlari': {
        for (var t in _dovizTurleri) t: _dovizAnaKasaKalani(t),
      },
      'oncekiDovizAnaKasaKalanlari': {
        for (var t in _dovizTurleri) t: _devredenDovizMiktarlari[t] ?? 0,
      },
      'digerAlimlar': _digerAlimlar
          .map(
        (t) => {
          'aciklama': (t['aciklamaCtrl'] as TextEditingController).text,
          'tutar': _parseDouble(
            (t['tutarCtrl'] as TextEditingController).text,
          ),
        },
      )
          .where((t) {
        final aciklama = (t['aciklama'] as String).trim();
        final tutar = t['tutar'] as double;
        return aciklama.isNotEmpty || tutar > 0;
      }).toList(),
      'transferler': _transferler
          .map(
            (t) => {
              'kategori': t['kategori'],
              'hedefSube': t['hedefSube'] ?? '',
              'hedefSubeAd': t['hedefSubeAd'] ?? '',
              'kaynakSube': t['kaynakSube'] ?? '',
              'kaynakSubeAd': t['kaynakSubeAd'] ?? '',
              'aciklama': (t['aciklamaCtrl'] as TextEditingController).text,
              'tutar': _parseDouble(
                (t['tutarCtrl'] as TextEditingController).text,
              ),
              'gonderildi': t['gonderildi'] ?? false,
              'onaylandi': t['onaylandi'] ?? false,
              'reddedildi': t['reddedildi'] ?? false,
              'bekletildi': t['bekletildi'] ?? false,
              'transferId': t['transferId'] ?? '',
              'onayDocId': t['onayDocId'] ?? '',
            },
          )
          .toList(),
    };
  }

  // AppBarda geçici mesaj göster
  void _appBarMesajGoster(String mesaj) {
    _appBarMesajTimer?.cancel();
    setState(() => _appBarMesaj = mesaj);
    // Kaydedildi/Hata mesajları 3 sn, Kaydediliyor mesajı timer ile kapanır
    if (!mesaj.contains('Kaydediliyor')) {
      _appBarMesajTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _appBarMesaj = '');
      });
    }
  }

  // ── Kullanıcı adını SharedPreferencesdan yükle ───────────────────────────
  Future<void> _kullaniciyiYukle() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted)
      setState(() => _mevcutKullanici = prefs.getString('kullanici') ?? '');
  }

  // ── Kilit al ─────────────────────────────────────────────────────────────
  Future<void> _kilitAl() async {
    if (_kilitTutuyorum || _mevcutKullanici.isEmpty) return;
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      final kilitRef = FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('kilitler')
          .doc(tarihKey);

      // Önce mevcut kilidi kontrol et
      final mevcut = await kilitRef.get();
      if (mevcut.exists) {
        final data = mevcut.data()!;
        final kilitKullanici = data['kullanici'] as String? ?? '';
        // Başkası kilitlemişse ve timeout geçmemişse kilit alamayız
        if (kilitKullanici != _mevcutKullanici) {
          final zaman = (data['zaman'] as Timestamp?)?.toDate();
          if (zaman != null &&
              DateTime.now().difference(zaman).inMinutes < 20) {
            if (mounted) setState(() => _kilitTutanKullanici = kilitKullanici);
            return;
          }
        }
      }

      // Kilidi al
      await kilitRef.set({
        'kullanici': _mevcutKullanici,
        'zaman': FieldValue.serverTimestamp(),
      });
      if (mounted)
        setState(() {
          _kilitTutuyorum = true;
          _kilitTutanKullanici = null;
        });

      // 20 dk timeout — her değişiklikte sıfırlanır
      _kilitTimer?.cancel();
      _kilitTimer = Timer(const Duration(minutes: 20), () {
        _kilitBirak();
      });
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  // ── Kilit bırak ──────────────────────────────────────────────────────────
  Future<void> _kilitBirak() async {
    if (!_kilitTutuyorum || _mevcutKullanici.isEmpty) return;
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('kilitler')
          .doc(tarihKey)
          .delete();
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
    _kilitTimer?.cancel();
    if (mounted)
      setState(() {
        _kilitTutuyorum = false;
      });
  }

  // ── Kilit durumunu realtime dinle ─────────────────────────────────────────
  Stream<DocumentSnapshot> _kilitStream() {
    final tarihKey = _tarihKey(_secilenTarih);
    return FirebaseFirestore.instance
        .collection('subeler')
        .doc(widget.subeKodu)
        .collection('kilitler')
        .doc(tarihKey)
        .snapshots();
  }

  // ── İnternet bağlantısı kontrolü ───────────────────────────────────────────
  Future<void> _internetKontrol() async {
    try {
      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .get()
          .timeout(const Duration(seconds: 5));
      if (mounted && !_internetVar) setState(() => _internetVar = true);
    } catch (_) {
      if (mounted && _internetVar) setState(() => _internetVar = false);
    }
  }

  Future<void> _subeAdlariniYukle() async {
    try {
      final Map<String, String> adlar = {};
      // Transfer için tüm şubeleri yükle
      final snapshot =
          await FirebaseFirestore.instance.collection('subeler').get();
      for (var doc in snapshot.docs) {
        adlar[doc.id] = doc.data()['ad'] as String? ?? doc.id;
      }
      if (mounted) setState(() => _subeAdlari = adlar);
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  Future<void> _banknotlariYukle() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('banknotlar')
          .get();
      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        final list =
            (data['liste'] as List?)?.map((e) => (e as num).toInt()).toList();
        final sinir = data['flotSiniri'] as int?;
        if (mounted)
          setState(() {
            if (list != null && list.isNotEmpty) {
              _banknotlar = list..sort((a, b) => b.compareTo(a));
            }
            if (sinir != null) _flotSiniri = sinir;
            for (var b in _banknotlar) {
              _banknotCtrl[b] ??= TextEditingController();
            }
          });
      } else {
        if (mounted)
          setState(() {
            for (var b in _banknotlar) {
              _banknotCtrl[b] ??= TextEditingController();
            }
          });
      }
    } catch (_) {
      if (mounted)
        setState(() {
          for (var b in _banknotlar) {
            _banknotCtrl[b] ??= TextEditingController();
          }
        });
    }
  }

  Future<void> _giderTurleriYukle() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('giderTurleri')
          .get();
      final liste =
          (doc.data()?['liste'] as List?)?.map((e) => e.toString()).toList();
      if (mounted) {
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
          _giderTurleriListesi = ham;
        });
      }
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  Future<void> _yemekKartiCinsleriniYukle() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('odemeyontemleri')
          .where('tip', isEqualTo: 'yemekKarti')
          .where('aktif', isEqualTo: true)
          .get();
      if (mounted) {
        final docs = snap.docs.toList();
        // pulseSira'ya göre sırala
        docs.sort((a, b) {
          final sa = (a.data()['sira'] as num?)?.toInt() ??
              (a.data()['pulseSira'] as num?)?.toInt() ??
              99;
          final sb = (b.data()['sira'] as num?)?.toInt() ??
              (b.data()['pulseSira'] as num?)?.toInt() ??
              99;
          return sa.compareTo(sb);
        });
        final cinsList = docs
            .map((d) => d.data()['ad'] as String? ?? '')
            .where((ad) => ad.isNotEmpty)
            .toList();
        setState(() {
          _yemekKartiCinsleri = cinsList;
          _yemekKartiTanimlari = docs
              .map(
                (d) => {
                  'id': d.id, // docId — key için
                  'ad': d.data()['ad'] as String? ?? '',
                  'sira': (d.data()['sira'] as num?)?.toInt() ??
                      (d.data()['pulseSira'] as num?)?.toInt() ??
                      99,
                  'pulseAdi': d.data()['pulseAdi'] as String? ?? '',
                  'dogruKaynak':
                      d.data()['dogruKaynak'] as String? ?? 'program',
                },
              )
              .where((m) => (m['ad'] as String).isNotEmpty)
              .toList();
          // Pulse ctrl'lerini hazırla
          _pulseKiyasCtrl.putIfAbsent(
            'pulseBrut',
            () => TextEditingController(),
          );
          _pulseKiyasCtrl.putIfAbsent(
            'pulseBanka',
            () => TextEditingController(),
          );
          _pulseKiyasCtrl.putIfAbsent(
            'pulsePos',
            () => TextEditingController(),
          );
          for (final t in _yemekKartiTanimlari) {
            final key =
                'yemek_${t['id']}'; // docId bazlı — ad değişse etkilenmez
            _pulseKiyasCtrl.putIfAbsent(key, () => TextEditingController());
          }
          // Sistem Pulse ctrl'lerini hazırla
          for (var c in cinsList) {
            _sistemYemekKartiCtrl[c] ??= TextEditingController();
          }
          // İlk yemek kartı girişi yoksa boş başlat
          if (_yemekKartlari.isEmpty && cinsList.isNotEmpty) {
            _yemekKartlari.add(YemekKartiGirisi(cins: cinsList.first));
          }
        });
      }
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  // ── Chip sekme yardımcısı ────────────────────────────────────────────────────
  static const _sekmeRenkleri = {
    'POS & Y. Kartı': Color(0xFF0288D1),
    'Pulse / My Dom.': Color(0xFF7C3AED),
    'Günlük Kasa': Color(0xFF059669),
    'Ana Kasa': Color(0xFFB45309),
    'Transfer/D. Alım': Color(0xFFDC2626),
    'Özet & Kapat': Color(0xFF0F766E),
  };

  static const _sekmeAcikRenkleri = {
    'POS & Y. Kartı': Color(0xFFE0F2FE),
    'Pulse / My Dom.': Color(0xFFEDE9FE),
    'Günlük Kasa': Color(0xFFD1FAE5),
    'Ana Kasa': Color(0xFFFEF3C7),
    'Transfer/D. Alım': Color(0xFFFEE2E2),
    'Özet & Kapat': Color(0xFFCCFBF1),
  };

  static const _sekmeIkonlar = {
    'POS & Y. Kartı': Icons.credit_card,
    'Pulse / My Dom.': Icons.bar_chart,
    'Günlük Kasa': Icons.account_balance_wallet,
    'Ana Kasa': Icons.account_balance,
    'Transfer/D. Alım': Icons.swap_horiz,
    'Özet & Kapat': Icons.check_circle_outline,
  };

  Widget _chipTab(String label) {
    final labels = [
      'POS & Y. Kartı',
      'Pulse / My Dom.',
      'Günlük Kasa',
      'Ana Kasa',
      'Transfer/D. Alım',
      'Özet & Kapat',
    ];
    final isActive = _tabController.index == labels.indexOf(label);
    final renk = _sekmeRenkleri[label] ?? const Color(0xFF0288D1);
    final acikRenk = _sekmeAcikRenkleri[label] ?? const Color(0xFFE0F2FE);
    final ikon = _sekmeIkonlar[label] ?? Icons.circle;
    // Kısa etiket — sekme adından al
    final kisaEtiket = label
        .replaceAll('& Y. Kartı', '& Y.K.')
        .replaceAll('/ My Dom.', '/ MyDom')
        .replaceAll('/D. Alım', '/D.Alım');
    return Tab(
      height: 60,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? acikRenk : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive ? renk.withOpacity(0.35) : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: isActive ? renk : const Color(0xFFE2E8F0),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                ikon,
                size: 15,
                color: isActive ? Colors.white : const Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              kisaEtiket,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: isActive ? renk : const Color(0xFF64748B),
                height: 1.1,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  // ── Günü Kapat / Düzenlemeyi Aç Butonu ──────────────────────────────────────
  Widget _gunuKapatButonu() {
    if (_gunuKapatildi && !_duzenlemeAcik) {
      // Düzenlemeyi Aç — turuncu
      return SizedBox(
        width: double.infinity,
        height: 44,
        child: ElevatedButton.icon(
          onPressed: () async {
            final hakki = widget.gecmisGunHakki;
            if (hakki >= 0) {
              final referans = _sonKapaliTarih ?? _bugunuHesapla();
              final fark = referans
                  .difference(
                    DateTime(
                      _secilenTarih.year,
                      _secilenTarih.month,
                      _secilenTarih.day,
                    ),
                  )
                  .inDays;
              if (fark > hakki) {
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        hakki == 0
                            ? 'Geçmiş kayıtları düzenleme yetkiniz yok.'
                            : '$hakki günden eski kayıtları düzenleyemezsiniz.',
                      ),
                      backgroundColor: Colors.red,
                    ),
                  );
                return;
              }
            }
            await FirebaseFirestore.instance
                .collection('subeler')
                .doc(widget.subeKodu)
                .collection('gunluk')
                .doc(_tarihKey(_secilenTarih))
                .update({
              'tamamlandi': false,
              'aktiviteLog': FieldValue.arrayUnion([
                {
                  'islem': 'Düzenlemeyi Aç',
                  'kullanici': _mevcutKullanici,
                  'zaman': Timestamp.now(),
                },
              ]),
            });
            if (mounted)
              setState(() {
                _gunuKapatildi = false;
                _duzenlemeAcik = true;
                _degisiklikVar = true;
                _gercekDegisiklikVar = false;
              });
          },
          icon: const Icon(Icons.lock_open, size: 18),
          label: const Text(
            'Düzenlemeyi Aç',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange[700],
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      );
    }

    // Günü Kapat — mavi degrade
    // Eksik alanları listele
    void eksikAlanlariGoster() {
      final eksikler = <String>[];
      if (!_posKontrolOnaylandi) eksikler.add('POS kontrolü onaylanmamış');
      if (!_pulseKontrolOnaylandi) eksikler.add('Pulse kontrolü onaylanmamış');
      if (_pulseBankaParasi < -0.01)
        eksikler.add(
          'Pulse/MyDom Banka Parası negatif (${_formatTL(_pulseBankaParasi)})',
        );
      if (_parseDouble(_gunlukSatisCtrl.text) <= 0)
        eksikler.add('Günlük Satış Toplamı girilmemiş');
      if (_toplamPos <= 0) eksikler.add('POS tutarı girilmemiş');
      if (_toplamNakitTL <= 0) eksikler.add('Nakit sayım yapılmamış');
      if (_bankaParasi <= 0) eksikler.add('Banka Parası hesaplanmamış');
      if (_dovizLimitiAsildi) eksikler.add('Döviz limiti aşılmış');
      // Döviz eklenmiş ama kur girilmemiş → kapanışa engel
      final kurEksikDoviz = _dovizler.where((d) {
        final kur = _parseDouble((d['kurCtrl'] as TextEditingController).text);
        return kur <= 0;
      }).toList();
      if (kurEksikDoviz.isNotEmpty)
        eksikler.add(
          'Döviz KUR bilgisi girilmemiş (${kurEksikDoviz.map((d) => d['cins'] ?? 'Döviz').join(', ')})',
        );
      if (!_internetVar) eksikler.add('İnternet bağlantısı yok');

      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning_amber, color: Colors.orange[700]),
              const SizedBox(width: 8),
              const Text('Eksik Bilgiler'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Günü kapatmak için aşağıdakileri tamamlayın:'),
              const SizedBox(height: 12),
              ...eksikler.map(
                (e) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(Icons.close, color: Colors.red[600], size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(e, style: const TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                ),
              ),
              if (eksikler.isEmpty)
                Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Colors.green[600],
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    const Text('Tüm alanlar dolu, kaydediliyor...'),
                  ],
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Tamam'),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 44,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: _kilitTutanKullanici != null
              ? const LinearGradient(colors: [Colors.grey, Colors.grey])
              : LinearGradient(
                  colors: _kaydetButonuAktif
                      ? const [
                          Color(0xFF01579B),
                          Color(0xFF0288D1),
                          Color(0xFF29B6F6),
                        ]
                      : [
                          Colors.blue[200]!,
                          Colors.blue[300]!,
                          Colors.blue[200]!,
                        ],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: ElevatedButton.icon(
          onPressed: (_kilitTutanKullanici != null)
              ? null
              : _kaydetButonuAktif
                  ? _kaydet
                  : eksikAlanlariGoster,
          icon: _kaydediliyor
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : Icon(
                  !_internetVar ? Icons.wifi_off : Icons.lock_clock,
                  size: 18,
                ),
          label: Text(
            _kaydediliyor
                ? 'Kaydediliyor...'
                : !_internetVar
                    ? 'Bağlantı Yok'
                    : 'Günü Kapat',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ),
    );
  }

  // ── Pulse / My Dominos Kıyas Sekmesi ─────────────────────────────────────────

  Widget _pulseKiyasSekmesi() {
    final posToplamiVal = _toplamPos;

    // Yemek kartı toplamı — tanımlı kartların girilen tutarları
    Map<String, double> yemekTutarlari = {};
    for (var c in _yemekKartlari) {
      final tutar = _parseDouble(c.tutarCtrl.text);
      yemekTutarlari[c.cins] = (yemekTutarlari[c.cins] ?? 0) + tutar;
    }

    // Online toplamı
    double onlineToplamiVal = 0;
    for (final o in _onlineOdemeler) {
      onlineToplamiVal += _parseDouble(
        (o['ctrl'] as TextEditingController).text,
      );
    }

    // Banka Parası = Brüt Satış - Sonuç toplamları (tumKalemler sonradan hesaplanacak)
    // Brüt Satış: önce Pulse kutusundan (manuel düzeltilebilir), yoksa üst bardaki değer
    final brutSatisProgram = _pulseKiyasCtrl.containsKey('pulseBrut') &&
            _pulseKiyasCtrl['pulseBrut']!.text.isNotEmpty
        ? _parseDouble(_pulseKiyasCtrl['pulseBrut']!.text)
        : _parseDouble(_gunlukSatisCtrl.text);

    // Tüm kalemleri tek listede birleştir — pulseSira'ya göre sırala
    // Her kalem: {tip, ad, sira, myDomVal, pulseKey}
    final List<Map<String, dynamic>> tumKalemler = [];

    // Kredi Kartı / POS — pulse kalemleri arasında zaten varsa ekleme
    final posZatenVar = _pulseKalemleri.any((k) {
      final ad = (k['ad'] as String).toLowerCase();
      return ad.contains('kredi') || ad.contains('pos');
    });
    if (!posZatenVar) {
      tumKalemler.add({
        'tip': 'pos',
        'ad': 'Kredi Kartı',
        'sira': 1,
        'myDomVal': posToplamiVal,
        'pulseKey': 'pulsePos',
      });
    }

    // Yemek kartları — tanımlardan pulseSira alınıyor
    for (final t in _yemekKartiTanimlari) {
      final ad = t['ad'] as String;
      tumKalemler.add({
        'tip': 'yemek',
        'ad': ad,
        'id': t['id'] as String? ?? '',
        'sira': t['sira'] as int? ?? 99,
        'dogruKaynak': t['dogruKaynak'] as String? ?? 'program',
        'myDomVal': yemekTutarlari[ad] ?? 0.0,
        'pulseKey': 'yemek_${t['id']}', // docId bazlı
      });
    }

    // Online ödemeler
    for (final o in _onlineOdemeler) {
      final ad = o['ad'] as String;
      // MyDominos okunmamışsa 0 kullan — sadece okunmuş veri karşılaştırılsın
      final myDomVal = _myDomOkundu && _myDominosOkunan.containsKey(ad)
          ? _myDominosOkunan[ad]!
          : _myDomOkundu
              ? _parseDouble((o['ctrl'] as TextEditingController).text)
              : 0.0;
      tumKalemler.add({
        'tip': 'online',
        'ad': ad,
        'id': o['id'] as String? ?? '',
        'sira': o['sira'] as int? ?? 99,
        'dogruKaynak': o['dogruKaynak'] as String? ?? 'myDominos',
        'myDomVal': myDomVal,
        'pulseKey': 'online_${o['id']}', // docId bazlı
      });
    }

    // Pulse kalemleri
    for (final k in _pulseKalemleri) {
      final ad = k['ad'] as String;
      final adLower = ad.toLowerCase();
      // Kredi Kartı ise POS tipini kullan — böylece isPosOrYemek true döner
      final isKrediKarti = adLower.contains('kredi') || adLower.contains('pos');
      final myDomVal = isKrediKarti ? posToplamiVal : 0.0;
      tumKalemler.add({
        'tip': isKrediKarti ? 'pos' : 'pulseKalemi',
        'ad': ad,
        'id': k['id'] as String? ?? '',
        'sira': k['sira'] as int? ?? 99,
        'dogruKaynak': k['dogruKaynak'] as String? ?? 'pulse',
        'myDomVal': myDomVal,
        'pulseKey': 'pulse_${k['id']}', // docId bazlı
      });
    }

    // pulseSira'ya göre sırala
    tumKalemler.sort((a, b) {
      final sa = a['sira'] as int? ?? 99;
      final sb = b['sira'] as int? ?? 99;
      return sa.compareTo(sb);
    });

    // Banka Parası = Brüt Satış - Sonuç toplamları (effectiveMyDom değerleri)
    // Brüt Satış kalemi listedeyse çıkarma hesabına dahil etme — zaten brutSatisProgram olarak kullanılıyor
    // Banka Parası = Brüt Satış (Pulse) - Girilen Pulse değerlerinin toplamı
    double toplamPulse = 0;
    for (final k in tumKalemler) {
      final pulseKey = k['pulseKey'] as String;
      final adLowerBanka = (k['ad'] as String).toLowerCase();
      if (adLowerBanka.contains('brüt') || adLowerBanka.contains('brut'))
        continue;
      final pulseCtrlBanka = _pulseKiyasCtrl[pulseKey];
      if (pulseCtrlBanka != null && pulseCtrlBanka.text.isNotEmpty) {
        toplamPulse += _parseDouble(pulseCtrlBanka.text);
      }
    }
    final bankaParasi = brutSatisProgram - toplamPulse;
    // Günlük Kasa için banka parasını güncelle
    if (_pulseBankaParasi != bankaParasi) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _pulseBankaParasi = bankaParasi);
      });
    }

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Pulse / MyDom okuma butonları
              Row(
                children: [
                  // MyDominos solda
                  Expanded(
                    child: _myDominosOkunuyor
                        ? ElevatedButton.icon(
                            onPressed: () => setState(() {
                              _myDomIptalEdildi = true;
                              _myDominosOkunuyor = false;
                            }),
                            icon: const Icon(Icons.cancel, size: 15),
                            label: const Text(
                              'İptal',
                              style: TextStyle(fontSize: 12),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red[700],
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                          )
                        : ElevatedButton.icon(
                            onPressed: _readOnly ||
                                    _pulseOkunuyor ||
                                    _myDominosOkunuyor
                                ? null
                                : () async {
                                    setState(() => _myDomIptalEdildi = false);
                                    final src = await _resimKaynagiSec(context);
                                    if (src != null)
                                      _myDominosResmiOku(source: src);
                                  },
                            icon: Icon(
                              _myDomOkundu
                                  ? Icons.check_circle
                                  : Icons.camera_alt,
                              size: 15,
                            ),
                            label: Text(
                              _myDomOkundu ? 'My Dom. ✓' : 'My Dominos',
                              style: const TextStyle(fontSize: 12),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _myDomOkundu
                                  ? Colors.green[700]
                                  : const Color(0xFFFF8F00),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  // Pulse Resmi sağda
                  Expanded(
                    child: _pulseOkunuyor
                        ? ElevatedButton.icon(
                            onPressed: () => setState(() {
                              _pulseIptalEdildi = true;
                              _pulseOkunuyor = false;
                            }),
                            icon: const Icon(Icons.cancel, size: 15),
                            label: const Text(
                              'İptal',
                              style: TextStyle(fontSize: 12),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red[700],
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                          )
                        : ElevatedButton.icon(
                            onPressed: _readOnly ||
                                    _myDominosOkunuyor ||
                                    _pulseOkunuyor
                                ? null
                                : () async {
                                    setState(() => _pulseIptalEdildi = false);
                                    final src = await _resimKaynagiSec(context);
                                    if (src != null)
                                      _pulseResmiOku(source: src);
                                  },
                            icon: Icon(
                              _pulseOkundu
                                  ? Icons.check_circle
                                  : Icons.camera_alt,
                              size: 15,
                            ),
                            label: Text(
                              _pulseOkundu ? 'Pulse ✓' : 'Pulse Resmi',
                              style: const TextStyle(fontSize: 12),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _pulseOkundu
                                  ? Colors.green[700]
                                  : const Color(0xFF0288D1),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // ── Üst Alan: Brüt Satış + Banka Parası ──
              Row(
                children: [
                  // Brüt Satış kartı
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF93C5FD)),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Brüt Satış',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1D4ED8),
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Pulse değeri — düzenle',
                            style: TextStyle(
                              fontSize: 8,
                              color: Color(0xFF93C5FD),
                            ),
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _pulseKiyasCtrl['pulseBrut'] ??
                                TextEditingController(),
                            enabled: !_readOnly,
                            textAlign: TextAlign.right,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [BinAraciFormatter()],
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1D4ED8),
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              hintText: '0,00',
                              filled: true,
                              fillColor: const Color(0xFFEFF6FF),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(
                                  color: Color(0xFF93C5FD),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(
                                  color: Color(0xFF93C5FD),
                                  width: 1.5,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(
                                  color: Color(0xFF1D4ED8),
                                  width: 1.5,
                                ),
                              ),
                            ),
                            onChanged: (_) {
                              setState(() {});
                              if (!_yukleniyor) {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Banka Parası kartı
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: bankaParasi >= 0
                              ? const Color(0xFF86EFAC)
                              : const Color(0xFFFCA5A5),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Banka Parası',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F766E),
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Brüt − POS − Yemek − Online',
                            style: TextStyle(
                              fontSize: 8,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: bankaParasi >= 0
                                  ? const Color(0xFFF0FDF4)
                                  : const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: bankaParasi >= 0
                                    ? const Color(0xFF86EFAC)
                                    : const Color(0xFFFCA5A5),
                                width: 1.5,
                              ),
                            ),
                            child: Text(
                              _formatTL(bankaParasi),
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: bankaParasi >= 0
                                    ? const Color(0xFF15803D)
                                    : const Color(0xFFDC2626),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // ── Kıyaslama listesi — sabit sıra ──
              Builder(
                builder: (ctx) {
                  final gorunenler = tumKalemler.where((k) {
                    final adL = (k['ad'] as String).toLowerCase();
                    return !adL.contains('brüt') && !adL.contains('brut');
                  }).toList();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Tablo başlık ──
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(10),
                            topRight: Radius.circular(10),
                          ),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Kalem',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 76,
                              child: Text(
                                'Prog/MyDom',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF15803D),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 76,
                              child: Text(
                                'Pulse',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1D4ED8),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 48,
                              child: Text(
                                'Fark',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                            ),
                            const SizedBox(width: 28),
                          ],
                        ),
                      ),

                      // ── Tablo satırları ──
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(10),
                            bottomRight: Radius.circular(10),
                          ),
                          border: const Border(
                            left: BorderSide(color: Color(0xFFE2E8F0)),
                            right: BorderSide(color: Color(0xFFE2E8F0)),
                            bottom: BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                        ),
                        child: Column(
                          children: [
                            ...gorunenler.map((k) {
                              final ad = k['ad'] as String;
                              final pulseKey = k['pulseKey'] as String;
                              final sira = k['sira'] as int? ?? 99;
                              final tip = k['tip'] as String;
                              final myDomVal = tip == 'pos'
                                  ? _toplamPos
                                  : (k['myDomVal'] as double);
                              final isPosOrYemek = tip == 'pos' ||
                                  tip == 'yemek' ||
                                  (tip == 'pulseKalemi' && myDomVal > 0);
                              final isOnline = tip == 'online';
                              final pulseCtrl = _pulseKiyasCtrl[pulseKey] ??
                                  TextEditingController();
                              final myDomCtrl = _myDomKiyasCtrl[pulseKey];

                              // Prog/MyDom değeri
                              final progVal = isPosOrYemek
                                  ? myDomVal
                                  : (myDomCtrl != null &&
                                          myDomCtrl.text.isNotEmpty
                                      ? _parseDouble(myDomCtrl.text)
                                      : myDomVal);

                              final pulseVal = _parseDouble(pulseCtrl.text);
                              final progDolu =
                                  isPosOrYemek ? myDomVal > 0 : progVal > 0;
                              final pulseValDolu = pulseVal > 0;
                              final pulseDolu = pulseCtrl.text.isNotEmpty;
                              final fark = progVal - pulseVal;
                              // Eşleşme: her ikisi dolu ve fark yok
                              // VEYA her ikisi de 0/boş (program boş, pulse da 0)
                              final eslesme = (pulseDolu &&
                                      progDolu &&
                                      fark.abs() < 0.01) ||
                                  (!progDolu && !pulseValDolu);
                              // Fark: biri dolu biri farklı/boş → her durumda göster
                              // (Pulse>0 prog=0, prog>0 pulse=0, her ikisi farklı)
                              final farkVar =
                                  (pulseValDolu || progDolu) && !eslesme;

                              // Sol şerit rengi: eşleşme=yeşil, fark=kırmızı, boş=gri
                              final seritRenk = eslesme
                                  ? const Color(0xFF22C55E)
                                  : farkVar
                                      ? const Color(0xFFEF4444)
                                      : const Color(
                                          0xFFE2E8F0,
                                        ); // boş — bu satır artık kullanılmıyor
                              return Container(
                                decoration: BoxDecoration(
                                  border: Border(
                                    left: BorderSide(
                                      color: seritRenk,
                                      width: 3,
                                    ),
                                    bottom: const BorderSide(
                                      color: Color(0xFFF1F5F9),
                                      width: 0.5,
                                    ),
                                  ),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    // Kalem adı
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '$sira. $ad',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF1E293B),
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            isPosOrYemek
                                                ? (tip == 'pos'
                                                    ? 'POS'
                                                    : 'Yemek')
                                                : 'Online',
                                            style: const TextStyle(
                                              fontSize: 8,
                                              color: Color(0xFF94A3B8),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),

                                    // Prog/MyDom kolonu
                                    SizedBox(
                                      width: 76,
                                      child: isPosOrYemek
                                          // POS/Yemek: kilitli program değeri
                                          ? Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 6,
                                              ),
                                              decoration: BoxDecoration(
                                                color: farkVar
                                                    ? const Color(0xFFFEF2F2)
                                                    : const Color(0xFFF0FDF4),
                                                borderRadius:
                                                    BorderRadius.circular(5),
                                                border: Border.all(
                                                  color: farkVar
                                                      ? const Color(0xFFFCA5A5)
                                                      : const Color(0xFF86EFAC),
                                                ),
                                              ),
                                              child: Text(
                                                myDomVal > 0
                                                    ? _formatTL(
                                                        myDomVal,
                                                      ).replaceAll(' ₺', '')
                                                    : '—',
                                                textAlign: TextAlign.right,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                  color: farkVar
                                                      ? const Color(0xFFDC2626)
                                                      : const Color(0xFF15803D),
                                                ),
                                              ),
                                            )
                                          // Online: düzenlenebilir MyDom kutusu
                                          : TextField(
                                              controller: myDomCtrl ??
                                                  TextEditingController(),
                                              enabled: !_readOnly,
                                              textAlign: TextAlign.right,
                                              keyboardType: const TextInputType
                                                  .numberWithOptions(
                                                decimal: true,
                                              ),
                                              inputFormatters: [
                                                BinAraciFormatter(),
                                              ],
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFF15803D),
                                              ),
                                              decoration: InputDecoration(
                                                isDense: true,
                                                contentPadding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 6,
                                                ),
                                                hintText: '0,00',
                                                hintStyle: const TextStyle(
                                                  fontSize: 10,
                                                  color: Color(0xFFCBD5E1),
                                                ),
                                                filled: true,
                                                fillColor: const Color(
                                                  0xFFF0FDF4,
                                                ),
                                                border: OutlineInputBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                  borderSide: const BorderSide(
                                                    color: Color(0xFF86EFAC),
                                                  ),
                                                ),
                                                enabledBorder:
                                                    OutlineInputBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                    5,
                                                  ),
                                                  borderSide: const BorderSide(
                                                    color: Color(
                                                      0xFF86EFAC,
                                                    ),
                                                  ),
                                                ),
                                                focusedBorder:
                                                    OutlineInputBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                    5,
                                                  ),
                                                  borderSide: const BorderSide(
                                                    color: Color(
                                                      0xFF15803D,
                                                    ),
                                                    width: 1.5,
                                                  ),
                                                ),
                                              ),
                                              onTap: () {
                                                if (myDomCtrl != null &&
                                                    !_eskiMyDomDegler
                                                        .containsKey(
                                                      pulseKey,
                                                    )) {
                                                  _eskiMyDomDegler[pulseKey] =
                                                      myDomCtrl.text;
                                                }
                                              },
                                              onChanged: (_) {
                                                setState(() {});
                                                if (!_yukleniyor)
                                                  _degisiklikVar = true;
                                              },
                                            ),
                                    ),
                                    const SizedBox(width: 6),

                                    // Pulse kolonu
                                    SizedBox(
                                      width: 76,
                                      child: TextField(
                                        controller: pulseCtrl,
                                        enabled: !_readOnly,
                                        textAlign: TextAlign.right,
                                        keyboardType: const TextInputType
                                            .numberWithOptions(
                                          decimal: true,
                                        ),
                                        inputFormatters: [BinAraciFormatter()],
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: eslesme
                                              ? const Color(0xFF15803D)
                                              : farkVar
                                                  ? const Color(0xFFDC2626)
                                                  : const Color(0xFF1D4ED8),
                                        ),
                                        decoration: InputDecoration(
                                          isDense: true,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 6,
                                          ),
                                          hintText: '0,00',
                                          hintStyle: const TextStyle(
                                            fontSize: 10,
                                            color: Color(0xFFCBD5E1),
                                          ),
                                          filled: true,
                                          fillColor: eslesme
                                              ? const Color(0xFFF0FDF4)
                                              : farkVar
                                                  ? const Color(0xFFFEF2F2)
                                                  : const Color(0xFFEFF6FF),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              5,
                                            ),
                                            borderSide: BorderSide(
                                              color: eslesme
                                                  ? const Color(0xFF86EFAC)
                                                  : farkVar
                                                      ? const Color(0xFFFCA5A5)
                                                      : const Color(0xFF93C5FD),
                                            ),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              5,
                                            ),
                                            borderSide: BorderSide(
                                              color: eslesme
                                                  ? const Color(0xFF86EFAC)
                                                  : farkVar
                                                      ? const Color(0xFFFCA5A5)
                                                      : const Color(0xFF93C5FD),
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              5,
                                            ),
                                            borderSide: const BorderSide(
                                              color: Color(0xFF1D4ED8),
                                              width: 1.5,
                                            ),
                                          ),
                                        ),
                                        onTap: () {
                                          if (!_eskiPulseDegler.containsKey(
                                            pulseKey,
                                          )) {
                                            _eskiPulseDegler[pulseKey] =
                                                pulseCtrl.text;
                                          }
                                        },
                                        onChanged: (_) {
                                          setState(() {});
                                          if (!_yukleniyor)
                                            _degisiklikVar = true;
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 6),

                                    // Fark kolonu
                                    SizedBox(
                                      width: 48,
                                      child: eslesme
                                          ? const Center(
                                              child: Text(
                                                '✓',
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  color: Color(0xFF16A34A),
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            )
                                          : farkVar
                                              ? Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.end,
                                                  children: [
                                                    Text(
                                                      fark.abs() < 0.01
                                                          ? '0,00'
                                                          : fark > 0
                                                              ? '+${_formatTL(fark).replaceAll(' ₺', '')}'
                                                              : '−${_formatTL(fark.abs()).replaceAll(' ₺', '')}',
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: fark > 0
                                                            ? const Color(
                                                                0xFF15803D,
                                                              )
                                                            : const Color(
                                                                0xFFDC2626,
                                                              ),
                                                      ),
                                                      textAlign:
                                                          TextAlign.right,
                                                    ),
                                                    Text(
                                                      fark > 0
                                                          ? 'ekle'
                                                          : 'çıkar',
                                                      style: const TextStyle(
                                                        fontSize: 7,
                                                        color:
                                                            Color(0xFF94A3B8),
                                                      ),
                                                    ),
                                                  ],
                                                )
                                              : const Center(
                                                  child: Text(
                                                    '—',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: Color(0xFFCBD5E1),
                                                    ),
                                                  ),
                                                ),
                                    ),
                                    const SizedBox(width: 4),

                                    // Eşleştir butonu (sadece fark varsa)
                                    SizedBox(
                                      width: 24,
                                      child: farkVar
                                          ? GestureDetector(
                                              onTap: _readOnly
                                                  ? null
                                                  : () {
                                                      final hedef = progVal > 0
                                                          ? progVal
                                                          : myDomVal;
                                                      _pulseKiyasCtrl
                                                          .putIfAbsent(
                                                        pulseKey,
                                                        () =>
                                                            TextEditingController(),
                                                      );
                                                      _pulseCtrlBagla(
                                                        _pulseKiyasCtrl[
                                                            pulseKey]!,
                                                      );
                                                      setState(() {
                                                        _pulseKiyasCtrl[pulseKey]!.text =
                                                            hedef > 0
                                                                ? _formatTL(
                                                                    hedef,
                                                                  ).replaceAll(
                                                                    ' ₺',
                                                                    '',
                                                                  )
                                                                : '0';
                                                        _eskiPulseDegler.remove(
                                                          pulseKey,
                                                        );
                                                        _eskiMyDomDegler.remove(
                                                          pulseKey,
                                                        );
                                                        _degisiklikVar = true;
                                                        if (_duzenlemeAcik)
                                                          _gercekDegisiklikVar =
                                                              true;
                                                      });
                                                    },
                                              child: Container(
                                                width: 24,
                                                height: 28,
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFF0288D1,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                ),
                                                child: const Icon(
                                                  Icons.check,
                                                  size: 14,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            )
                                          : const SizedBox(width: 24),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ],
                        ),
                      ),

                      const SizedBox(height: 10),

                      const SizedBox(height: 10),

                      // ── Özet bar ──
                      Builder(
                        builder: (ctx) {
                          int farkSayisi = 0,
                              eslesiyorSayisi = 0,
                              girilmemisSayisi = 0;
                          for (final k in gorunenler) {
                            final pk = k['pulseKey'] as String;
                            final t = k['tip'] as String;
                            final mdv = t == 'pos'
                                ? _toplamPos
                                : (k['myDomVal'] as double);
                            final ipoy = t == 'pos' ||
                                t == 'yemek' ||
                                (t == 'pulseKalemi' && mdv > 0);
                            final pc =
                                _pulseKiyasCtrl[pk] ?? TextEditingController();
                            final mc = _myDomKiyasCtrl[pk];
                            final prog = ipoy
                                ? mdv
                                : (mc != null && mc.text.isNotEmpty
                                    ? _parseDouble(mc.text)
                                    : mdv);
                            final pulse = _parseDouble(pc.text);
                            final progD = ipoy ? mdv > 0 : prog > 0;
                            final pulseD = pc.text.isNotEmpty;
                            final pulseV = pulse > 0;
                            final f = prog - pulse;
                            // Her ikisi de 0/boş: program=tire(0), pulse=0 → Girilmemiş
                            final herIkisiSifir = !progD && !pulseV;
                            if (!progD && !pulseD)
                              girilmemisSayisi++;
                            else if (herIkisiSifir)
                              girilmemisSayisi++; // program=-, pulse=0 → eşit/girilmemiş
                            else if ((progD || pulseV) && f.abs() < 0.01)
                              eslesiyorSayisi++;
                            else
                              farkSayisi++; // her iki yönde fark (pulse>0 prog=0 dahil)
                          }
                          return Row(
                            children: [
                              if (farkSayisi > 0)
                                Expanded(
                                  child: Container(
                                    margin: const EdgeInsets.only(right: 4),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFEF2F2),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: const Color(0xFFFCA5A5),
                                      ),
                                    ),
                                    child: Column(
                                      children: [
                                        Text(
                                          '$farkSayisi',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFFDC2626),
                                          ),
                                        ),
                                        const Text(
                                          'Fark var',
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: Color(0xFFDC2626),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (eslesiyorSayisi > 0)
                                Expanded(
                                  child: Container(
                                    margin: EdgeInsets.only(
                                      right: girilmemisSayisi > 0 ? 4 : 0,
                                      left: farkSayisi > 0 ? 4 : 0,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF0FDF4),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: const Color(0xFF86EFAC),
                                      ),
                                    ),
                                    child: Column(
                                      children: [
                                        Text(
                                          '$eslesiyorSayisi',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF16A34A),
                                          ),
                                        ),
                                        const Text(
                                          'Eşleşiyor',
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: Color(0xFF15803D),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (girilmemisSayisi > 0)
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF8FAFC),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: const Color(0xFFE2E8F0),
                                      ),
                                    ),
                                    child: Column(
                                      children: [
                                        Text(
                                          '$girilmemisSayisi',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF64748B),
                                          ),
                                        ),
                                        const Text(
                                          'Girilmemiş',
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: Color(0xFF64748B),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ],
                  ); // Column kapanışı
                },
              ), // Builder kapanışı

              const SizedBox(height: 8),

              // Pulse kontrol onayı
              SizedBox(
                width: double.infinity,
                child: _pulseKontrolOnaylandi
                    ? Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.green[100],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green[400]!),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.verified,
                              color: Colors.green[700],
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Pulse kontrol edildi ✓',
                              style: TextStyle(
                                color: Colors.green[700],
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Builder(
                        builder: (bctx) {
                          // Fark sayısını hesapla
                          int yeniFarkSayisi = 0;
                          int toplamKalem = 0;
                          for (final k in tumKalemler) {
                            final adL = (k['ad'] as String).toLowerCase();
                            if (adL.contains('brüt') || adL.contains('brut'))
                              continue;
                            final pk = k['pulseKey'] as String;
                            final t = k['tip'] as String;
                            final mdv = t == 'pos'
                                ? _toplamPos
                                : (k['myDomVal'] as double);
                            final ipoy = t == 'pos' ||
                                t == 'yemek' ||
                                (t == 'pulseKalemi' && mdv > 0);
                            final pc =
                                _pulseKiyasCtrl[pk] ?? TextEditingController();
                            final mc = _myDomKiyasCtrl[pk];
                            final sagDeger = ipoy
                                ? mdv
                                : _myDomOkundu
                                    ? (mc != null && mc.text.isNotEmpty
                                        ? _parseDouble(mc.text)
                                        : mdv)
                                    : 0.0;
                            final solDeger = _parseDouble(pc.text);
                            final solDoluF = pc.text.isNotEmpty;
                            final sagDoluF = ipoy ? mdv > 0 : sagDeger > 0;
                            // Her iki taraf da doluysa fark var mı bak
                            // POS/Yemek: program=0 ise o gün kullanılmamış → saymaz
                            // Her iki yönde fark say:
                            // prog>0 pulse farklı/boş, pulse>0 prog=0
                            // solDeger ve sagDeger ikisi de 0 ise eşit say (program=tire, pulse=0)
                            final solSifir = solDeger.abs() < 0.01;
                            final sagSifir = sagDeger.abs() < 0.01;
                            final herBiriBos = !solDoluF && !sagDoluF;
                            final herIkisiSifir =
                                solSifir && sagSifir; // - ile 0 → eşit
                            if (!herBiriBos && !herIkisiSifir) {
                              final eslesF = solDoluF &&
                                  sagDoluF &&
                                  (sagDeger - solDeger).abs() < 0.01;
                              if (!eslesF) yeniFarkSayisi++;
                            }
                            if (!herBiriBos && !herIkisiSifir) toplamKalem++;
                          }
                          // Aktif: fark yok VE en az bir kayıt işlenmiş VE Banka Parası negatif değil
                          // Pasif: fark var VEYA hiç kayıt yok VEYA Banka Parası < 0
                          final bankaParasiNegatif = _pulseBankaParasi < -0.01;
                          // Eşitlik bozulduysa veya Banka Parası negatifse onayı otomatik sıfırla
                          if (_pulseKontrolOnaylandi &&
                              (yeniFarkSayisi > 0 || bankaParasiNegatif)) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted && _pulseKontrolOnaylandi) {
                                setState(() => _pulseKontrolOnaylandi = false);
                              }
                            });
                          }
                          final butonAktif = yeniFarkSayisi == 0 &&
                              toplamKalem > 0 &&
                              !bankaParasiNegatif &&
                              !_readOnly;
                          return Tooltip(
                            message: bankaParasiNegatif
                                ? 'Banka Parası negatif — onay verilemez'
                                : yeniFarkSayisi > 0
                                    ? '$yeniFarkSayisi kalemde fark var — tüm farkları kapatın'
                                    : '',
                            child: ElevatedButton.icon(
                              onPressed: butonAktif
                                  ? () => setState(
                                        () => _pulseKontrolOnaylandi = true,
                                      )
                                  : null,
                              icon: const Icon(Icons.check_circle_outline),
                              label: Text(
                                bankaParasiNegatif
                                    ? 'Banka Parası negatif!'
                                    : yeniFarkSayisi > 0
                                        ? '$yeniFarkSayisi kalemde fark var'
                                        : 'Pulse\'u kontrol ettim, veriler doğru',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: butonAktif
                                    ? Colors.orange[700]
                                    : Colors.grey[400],
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ], // Stack children kapanışı
    );
  }

  // ── Pulse Resmi Okuma ────────────────────────────────────────────────────────

  // ── Resim kaynağı seç (Kamera / Galeri) ──────────────────────────────────
  // ── Resim önizleme — gönder / yeniden çek ──────────────────────────────────
  Future<bool> _resimOnizle(
    BuildContext ctx,
    Uint8List bytes,
    String baslik,
  ) async {
    final sonuc = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.image_search,
                    color: Color(0xFF0288D1),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      baslik,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Görüntü net mi? Yazılar okunuyor mu?',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.5,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: InteractiveViewer(
                  minScale: 1.0,
                  maxScale: 4.0,
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Parmakla büyütüp kontrol edebilirsiniz',
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                textAlign: TextAlign.center,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(_, false),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Yeniden Çek'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange[700],
                        side: BorderSide(color: Colors.orange[300]!),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(_, true),
                      icon: const Icon(Icons.send, size: 16),
                      label: const Text('Gönder'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0288D1),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return sonuc == true;
  }

  Future<ImageSource?> _resimKaynagiSec(BuildContext ctx) async {
    return showModalBottomSheet<ImageSource>(
      context: ctx,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE0F2FE),
                  child: Icon(
                    Icons.camera_alt,
                    color: Color(0xFF0288D1),
                    size: 20,
                  ),
                ),
                title: const Text(
                  'Kameradan Çek',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Ekrana tutun, fotoğraf çekin',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(_, ImageSource.camera),
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFF0FDF4),
                  child: Icon(
                    Icons.photo_library,
                    color: Color(0xFF059669),
                    size: 20,
                  ),
                ),
                title: const Text(
                  'Galeriden Seç',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Ekran görüntüsü seçin',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(_, ImageSource.gallery),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ── Görsel Okuma Fallback Zinciri ────────────────────────────────────────
  // 1. Gemini 3.1 Flash Lite Preview
  // 2. Gemini 2.5 Flash Lite
  // 3. Groq (llama-4-scout-17b-16e-instruct)
  // Başarılı olan ilk servisten sonuç döner, hepsi başarısızsa null döner
  Future<String?> _gorselOkuFallback({
    required String base64Image,
    required String mimeType,
    required String prompt,
    required String geminiApiKey,
    required String groqApiKey,
  }) async {
    // Gemini modelleri
    final geminiModeller = [
      'gemini-3.1-flash-lite-preview', // hızlı, önce dene
      'gemini-2.5-flash', // güçlü, yedek
    ];

    for (final model in geminiModeller) {
      try {
        final result = await _geminiOku(
          base64Image: base64Image,
          mimeType: mimeType,
          prompt: prompt,
          apiKey: geminiApiKey,
          model: model,
        );
        if (result != null) return result;
      } catch (_) {}
    }

    // Groq fallback
    if (groqApiKey.isNotEmpty) {
      try {
        final result = await _groqOku(
          base64Image: base64Image,
          mimeType: mimeType,
          prompt: prompt,
          apiKey: groqApiKey,
        );
        if (result != null) return result;
      } catch (_) {}
    }

    return null;
  }

  // Tek Gemini modeli ile okuma
  Future<String?> _geminiOku({
    required String base64Image,
    required String mimeType,
    required String prompt,
    required String apiKey,
    required String model,
  }) async {
    for (int deneme = 1; deneme <= 2; deneme++) {
      try {
        final response = await http
            .post(
              Uri.parse(
                'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
              ),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'contents': [
                  {
                    'parts': [
                      {
                        'inline_data': {
                          'mime_type': mimeType,
                          'data': base64Image,
                        },
                      },
                      {'text': prompt},
                    ],
                  },
                ],
                'generationConfig': {'temperature': 0},
              }),
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final responseJson = jsonDecode(response.body);
          final text = responseJson['candidates']?[0]?['content']?['parts']?[0]
                  ?['text'] as String? ??
              '';
          return text.isNotEmpty ? text : null;
        }
        // 429 = kota doldu → direkt sonraki modele geç
        if (response.statusCode == 429) return null;
        // 503 = meşgul → 5sn bekle, 1 kez retry
        if (response.statusCode == 503 && deneme == 1) {
          await Future.delayed(const Duration(seconds: 5));
          continue;
        }
        return null;
      } catch (_) {
        if (deneme == 1) {
          await Future.delayed(const Duration(seconds: 3));
          continue;
        }
        return null;
      }
    }
    return null;
  }

  // Groq ile okuma — llama-4-scout vision
  Future<String?> _groqOku({
    required String base64Image,
    required String mimeType,
    required String prompt,
    required String apiKey,
  }) async {
    for (int deneme = 1; deneme <= 2; deneme++) {
      try {
        final response = await http
            .post(
              Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
              },
              body: jsonEncode({
                'model': 'meta-llama/llama-4-scout-17b-16e-instruct',
                'messages': [
                  {
                    'role': 'user',
                    'content': [
                      {
                        'type': 'image_url',
                        'image_url': {
                          'url': 'data:$mimeType;base64,$base64Image',
                        },
                      },
                      {'type': 'text', 'text': prompt},
                    ],
                  },
                ],
                'temperature': 0,
                'max_tokens': 2048,
              }),
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final responseJson = jsonDecode(response.body);
          final text =
              responseJson['choices']?[0]?['message']?['content'] as String? ??
                  '';
          return text.isNotEmpty ? text : null;
        }
        // 429 = kota → direkt çık
        if (response.statusCode == 429) return null;
        // 503 = meşgul → 5sn bekle, retry
        if (response.statusCode == 503 && deneme == 1) {
          await Future.delayed(const Duration(seconds: 5));
          continue;
        }
        return null;
      } catch (_) {
        if (deneme == 1) {
          await Future.delayed(const Duration(seconds: 3));
          continue;
        }
        return null;
      }
    }
    return null;
  }

  Future<void> _pulseResmiOku({
    ImageSource source = ImageSource.gallery,
  }) async {
    try {
      // Gemini API key Firestore'dan al
      final ayarDoc = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('gemini')
          .get();
      final apiKey = ayarDoc.data()?['apiKey'] as String? ?? '';
      if (apiKey.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Gemini API key girilmemiş. Ayarlar ekranından ekleyin.',
              ),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      // Resim seç — lifecycle uyarısını geçici devre dışı bırak
      _gorselSeciliyor = true;
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        imageQuality: 60,
        maxWidth: 1200,
        maxHeight: 1600,
      );
      _gorselSeciliyor = false;
      if (picked == null) return;

      // Önizleme — net mi kontrolü
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final gonder = await _resimOnizle(
        context,
        bytes,
        'Pulse Ekranı Önizleme',
      );
      if (!gonder) return; // Kullanıcı yeniden çek dedi

      // Okuma başlamadan önce mevcut Pulse verilerini temizle
      setState(() {
        for (var c in _pulseKiyasCtrl.values) c.clear();
        _pulseOkundu = false;
        _pulseKontrolOnaylandi = false;
        _okumaMesaji = '';
        _pulseBankaParasi = 0;
        _pulseIptalEdildi = false;
        _pulseOkunuyor = true;
      });
      if (!mounted) return;

      // Resmi base64'e çevir
      final base64Image = base64Encode(bytes);
      final mimeType = picked.mimeType ?? 'image/jpeg';

      // Tüm ödeme yöntemlerini Firestore'dan al
      final tumOdemeSnap = await FirebaseFirestore.instance
          .collection('odemeyontemleri')
          .where('aktif', isEqualTo: true)
          .get();

      // Online kanallar
      // Pulse adı → Sistem adı lookup tabloları
      // Pulse adı → Sistem adı eşleştirme — "içeriyor mu" kontrolü ile
      // Her kalem: {pulseAdi, sistemAdi}
      final List<Map<String, String>> onlineEslestirme = [];
      final List<Map<String, String>> yemekEslestirme = [];
      final List<Map<String, String>> digerEslestirme = [];

      for (final doc in tumOdemeSnap.docs) {
        final ad = doc.data()['ad'] as String? ?? '';
        final pulseAdi =
            (doc.data()['pulseAdi'] as String? ?? '').toUpperCase().trim();
        final tip = doc.data()['tip'] as String? ?? '';
        if (ad.isEmpty) continue;
        final key = pulseAdi.isNotEmpty
            ? pulseAdi
            : ad.toUpperCase().replaceAll(' ', '');
        final docId = doc.id;
        if (tip == 'online')
          onlineEslestirme.add({
            'pulseAdi': key,
            'sistemAdi': ad,
            'docId': docId,
          });
        if (tip == 'yemekKarti')
          yemekEslestirme.add({
            'pulseAdi': key,
            'sistemAdi': ad,
            'docId': docId,
          });
        if (tip == 'pulseKalemi')
          digerEslestirme.add({
            'pulseAdi': key,
            'sistemAdi': ad,
            'docId': docId,
          });
      }

      // Fuzzy lookup — Gemini'nin ekrandan okuduğu ham adı tanımlı Pulse adıyla eşleştirir
      // Gemini artık ham ekran adını döndürür (sistem adını değil)
      // docId de döndüren versiyon — Gemini eşleştirmesinde kullanılır
      Map<String, dynamic>? fuzzyBulEslesme(
        String geminiAd,
        List<Map<String, dynamic>> liste,
      ) {
        final aranan = geminiAd.toUpperCase().trim();
        for (final e in liste) {
          if (e['pulseAdi'] == aranan) return e;
        }
        for (final e in liste) {
          final pulseAdi = (e['pulseAdi'] as String? ?? '');
          if (pulseAdi.isNotEmpty && aranan.contains(pulseAdi)) return e;
        }
        for (final e in liste) {
          final pulseAdi = (e['pulseAdi'] as String? ?? '');
          if (pulseAdi.isNotEmpty && pulseAdi.contains(aranan)) return e;
        }
        final arananTokenlar =
            aranan.split(' ').where((t) => t.length >= 2).toList();
        if (arananTokenlar.isNotEmpty) {
          Map<String, dynamic>? enIyi;
          int enIyiSkor = 0;
          for (final e in liste) {
            final pulseTokenlar = (e['pulseAdi'] as String? ?? '')
                .split(' ')
                .where((t) => t.length >= 2)
                .toList();
            int skor = 0;
            for (final at in arananTokenlar) {
              for (final pt in pulseTokenlar) {
                if (at == pt) {
                  skor += 3;
                  break;
                }
                if (pt.startsWith(at) || at.startsWith(pt)) {
                  skor += 2;
                  break;
                }
                if (at.length >= 3 &&
                    pt.length >= 3 &&
                    at.substring(0, 3) == pt.substring(0, 3)) {
                  skor += 1;
                  break;
                }
              }
            }
            // Kısa tanım: tanımlı adın tüm tokenları eşleştiyse kabul et
            final minToken = arananTokenlar.length < digerTokenlar.length
                ? arananTokenlar.length
                : digerTokenlar.length;
            final maxSkor = minToken * 3;
            final oran = maxSkor > 0 ? skor / maxSkor : 0;
            if (oran >= 0.6 && skor > enIyiSkor) {
              enIyiSkor = skor;
              enIyi = e;
            }
          }
          if (enIyi != null) return enIyi;
        }
        final ilkKelime = aranan.split(' ').first;
        if (ilkKelime.length >= 4) {
          for (final e in liste) {
            if ((e['pulseAdi'] as String? ?? '').startsWith(ilkKelime))
              return e;
          }
        }
        return null;
      }

      String? fuzzyBul(String geminiAd, List<Map<String, dynamic>> liste) {
        final aranan = geminiAd.toUpperCase().trim();
        // 1. Tam eşleşme
        for (final e in liste) {
          if (e['pulseAdi'] == aranan) return e['sistemAdi'];
        }
        // 2. Gemini adı tanımlı adı içeriyor mu
        for (final e in liste) {
          final pulseAdi = e['pulseAdi']!;
          if (pulseAdi.isNotEmpty && aranan.contains(pulseAdi))
            return e['sistemAdi'];
        }
        // 3. Tanımlı ad Gemini adını içeriyor mu
        for (final e in liste) {
          final pulseAdi = e['pulseAdi']!;
          if (pulseAdi.isNotEmpty && pulseAdi.contains(aranan))
            return e['sistemAdi'];
        }
        // 4. Token bazlı eşleştirme — kısaltmalar ve yarım görünen metinler için
        // Örnek: "DOMINOS ONL GR" ↔ "DOMINOS ONL ZR" → DOMINOS+ONL eşleşti, yeterli
        final arananTokenlar =
            aranan.split(' ').where((t) => t.length >= 2).toList();
        if (arananTokenlar.isNotEmpty) {
          String? enIyiEslesen;
          int enIyiSkor = 0;
          for (final e in liste) {
            final pulseTokenlar =
                e['pulseAdi']!.split(' ').where((t) => t.length >= 2).toList();
            int skor = 0;
            for (final at in arananTokenlar) {
              for (final pt in pulseTokenlar) {
                if (at == pt) {
                  skor += 3;
                  break;
                }
                if (pt.startsWith(at) || at.startsWith(pt)) {
                  skor += 2;
                  break;
                }
                if (at.length >= 3 &&
                    pt.length >= 3 &&
                    at.substring(0, 3) == pt.substring(0, 3)) {
                  skor += 1;
                  break;
                }
              }
            }
            final eslesmeOrani = skor / (arananTokenlar.length * 3);
            if (eslesmeOrani >= 0.6 && skor > enIyiSkor) {
              enIyiSkor = skor;
              enIyiEslesen = e['sistemAdi'];
            }
          }
          if (enIyiEslesen != null) return enIyiEslesen;
        }
        // 5. İlk kelime eşleşmesi (YEMEK SEPETI → YEMEK)
        final ilkKelime = aranan.split(' ').first;
        if (ilkKelime.length >= 4) {
          for (final e in liste) {
            if (e['pulseAdi']!.startsWith(ilkKelime)) return e['sistemAdi'];
          }
        }
        return null;
      }

      // Pulse'taki adlarını topla — Gemini'ye sadece Pulse'ta görünen adları ver
      final onlinePulseAdlar = tumOdemeSnap.docs
          .where((d) => d.data()['tip'] == 'online')
          .map((d) {
            final ad = d.data()['ad'] as String? ?? '';
            final pulseAdi = (d.data()['pulseAdi'] as String? ?? '').trim();
            return pulseAdi.isNotEmpty ? pulseAdi : ad.toUpperCase();
          })
          .where((s) => s.isNotEmpty)
          .join(', ');

      final yemekPulseAdlar = tumOdemeSnap.docs
          .where((d) => d.data()['tip'] == 'yemekKarti')
          .map((d) {
            final ad = d.data()['ad'] as String? ?? '';
            final pulseAdi = (d.data()['pulseAdi'] as String? ?? '').trim();
            return pulseAdi.isNotEmpty ? pulseAdi : ad.toUpperCase();
          })
          .where((s) => s.isNotEmpty)
          .join(', ');

      final pulseKalemAdlar = tumOdemeSnap.docs
          .where((d) => d.data()['tip'] == 'pulseKalemi')
          .map((d) {
            final ad = d.data()['ad'] as String? ?? '';
            final pulseAdi = (d.data()['pulseAdi'] as String? ?? '').trim();
            return pulseAdi.isNotEmpty ? pulseAdi : ad.toUpperCase();
          })
          .where((s) => s.isNotEmpty)
          .join(', ');

      // Gemini'ye gönderilecek prompt
      // ÖNEMLİ: Gemini ekranda GÖRDÜĞÜ ham adı döndürür, sistem adını değil.
      // Eşleştirme fuzzyBul ile kodda yapılır — ad değişikliği okumayı etkilemez.

      // Brüt Satış için Firestore'dan tanımlı Pulse adını al
      final brutSatisPulseAdi = tumOdemeSnap.docs
              .where((d) => d.data()['tip'] == 'pulseKalemi')
              .map(
                (d) => ({
                  'ad': d.data()['ad'] as String? ?? '',
                  'pulseAdi': (d.data()['pulseAdi'] as String? ?? '').trim(),
                }),
              )
              .where(
                (m) =>
                    (m['ad'] as String).toLowerCase().contains('brüt') ||
                    (m['ad'] as String).toLowerCase().contains('brut'),
              )
              .map(
                (m) => (m['pulseAdi'] as String).isNotEmpty
                    ? m['pulseAdi']
                    : 'Brüt Satış veya Genel Toplam',
              )
              .firstOrNull ??
          'Brüt Satış veya Genel Toplam';

      final prompt = """Bu bir Pulse POS/kasa programı ekran görüntüsü.
ÖNCE iki kontrol yap:
1. Resim yeterince net mi? Yazılar okunabiliyor mu? Net değilse döndür: {"hata": "Resim bulanık veya okunamıyor, daha yakın ve sabit tutarak tekrar çekin"}
2. Resim gerçekten bir Pulse POS/kasa ekranı mı? Pulse ekranında genellikle "Brüt Satış", "Kredi Kartı", "Banka Parası" gibi Türkçe kasa/POS terimleri bulunur. My Dominos, tarayıcı, başka uygulama veya farklı bir ekranın görüntüsü ise döndür: {"hata": "Bu resim Pulse ekranı değil"}

Pulse ekranıysa aşağıdaki verileri JSON formatında çıkar:
- brutsatis: "$brutSatisPulseAdi" rakamı (sadece sayı)
- bankapara: Banka Parası veya Kalan Nakit rakamı (sadece sayı)
- kredikart: 01.KREDI KARTI veya Kredi Kartı toplamı (sadece sayı)
- online: her online ödeme kanalı için {ad, tutar} listesi.
  Ekranda bu adlardan birini gördüğünde ekle: $onlinePulseAdlar
  "ad" alanına ekranda GÖRDÜĞÜN adı AYNEN yaz, değiştirme.
- yemek: her yemek kartı için {ad, tutar} listesi.
  Ekranda bu adlardan birini gördüğünde ekle: $yemekPulseAdlar
  "ad" alanına ekranda GÖRDÜĞÜN adı AYNEN yaz, değiştirme.
- diger: diğer pulse kalemleri için {ad, tutar} listesi.
  Ekranda bu adlardan birini gördüğünde ekle: $pulseKalemAdlar
  "ad" alanına ekranda GÖRDÜĞÜN adı AYNEN yaz, değiştirme.

Sadece JSON dön, başka açıklama yazma. Örnek:
{"brutsatis": 96614.57, "bankapara": 10860.00, "kredikart": 13697.00, "online": [{"ad": "DOMINOS ONL ZR", "tutar": 1819.00}], "yemek": [{"ad": "MULTINET", "tutar": 430.00}], "diger": []}

Sayı formatında virgülü noktaya çevir. Alan bulunamazsa null yaz.""";

      // İptal kontrolü
      if (_pulseIptalEdildi) {
        setState(() => _pulseOkunuyor = false);
        return;
      }

      // Fallback zinciri: 3.1 → 2.5-lite → Groq
      final groqApiKey = ayarDoc.data()?['groqApiKey'] as String? ?? '';
      final String? responseText = await _gorselOkuFallback(
        base64Image: base64Image,
        mimeType: mimeType,
        prompt: prompt,
        geminiApiKey: apiKey,
        groqApiKey: groqApiKey,
      );

      if (responseText == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Tüm servisler meşgul. Lütfen tekrar deneyin veya manuel girin.',
              ),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 5),
            ),
          );
        }
        setState(() => _pulseOkunuyor = false);
        return;
      }

      // JSON parse
      final cleanText =
          responseText.replaceAll(RegExp(r'```json|```'), '').trim();
      final Map<String, dynamic> geminiOkunan = jsonDecode(cleanText);

      // Yanlış resim kontrolü
      if (geminiOkunan.containsKey('hata')) {
        setState(() => _pulseOkunuyor = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(
                    Icons.image_not_supported,
                    color: Colors.white,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Yanlış resim: ' +
                          (geminiOkunan['hata'] as String? ?? '') +
                          '\nLütfen Pulse ekran görüntüsü seçin.',
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.red[700],
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // brutsatis hiç yoksa muhtemelen yanlış/boş resim
      if (geminiOkunan['brutsatis'] == null &&
          geminiOkunan['kredikart'] == null) {
        setState(() => _pulseOkunuyor = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.white, size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Pulse verisi bulunamadı.\nDoğru ekranı seçtiğinizden emin olun.',
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.orange[800],
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      // Değerleri direkt uygula — setState dışında ctrl hazırla
      if (!mounted) return;

      // Önce ctrl'leri hazırla (setState dışında)
      if (geminiOkunan['brutsatis'] != null) {
        _pulseKiyasCtrl.putIfAbsent('pulseBrut', () => TextEditingController());
      }
      if (geminiOkunan['kredikart'] != null) {
        // Kredi Kartı docId'sini digerEslestirme'den bul
        final krediEslesme =
            digerEslestirme.cast<Map<String, dynamic>>().firstWhere((e) {
          final ad = (e['sistemAdi'] as String? ?? '').toLowerCase();
          final pulseAdi = (e['pulseAdi'] as String? ?? '').toLowerCase();
          return ad.contains('kredi') ||
              ad.contains('pos') ||
              pulseAdi.contains('kredi') ||
              pulseAdi.contains('pos');
        }, orElse: () => <String, dynamic>{});
        if (krediEslesme.isNotEmpty) {
          final key = 'pulse_${krediEslesme['docId']}';
          _pulseKiyasCtrl.putIfAbsent(key, () => TextEditingController());
        } else {
          // Fallback: eski pulsePos key'i
          _pulseKiyasCtrl.putIfAbsent(
            'pulsePos',
            () => TextEditingController(),
          );
        }
      }
      if (geminiOkunan['online'] != null) {
        for (final o in (geminiOkunan['online'] as List)) {
          final pulseAd = (o['ad'] as String? ?? '').toUpperCase();
          final eslesme = fuzzyBulEslesme(pulseAd, onlineEslestirme);
          if (eslesme != null) {
            final key = 'online_${eslesme['docId']}';
            _pulseKiyasCtrl.putIfAbsent(key, () => TextEditingController());
          }
        }
      }
      if (geminiOkunan['yemek'] != null) {
        for (final y in (geminiOkunan['yemek'] as List)) {
          final pulseAd = (y['ad'] as String? ?? '').toUpperCase();
          final eslesme = fuzzyBulEslesme(pulseAd, yemekEslestirme);
          if (eslesme != null) {
            final docId = eslesme['docId'] as String;
            final key = 'yemek_$docId';
            _pulseKiyasCtrl.putIfAbsent(key, () => TextEditingController());
          }
        }
      }
      if (geminiOkunan['diger'] != null) {
        for (final d in (geminiOkunan['diger'] as List)) {
          final pulseAd = (d['ad'] as String? ?? '').toUpperCase();
          final eslesme = fuzzyBulEslesme(pulseAd, digerEslestirme);
          if (eslesme != null) {
            final docId = eslesme['docId'] as String;
            final key = 'pulse_$docId';
            _pulseKiyasCtrl.putIfAbsent(key, () => TextEditingController());
          }
        }
      }

      // Yeni oluşan ctrl'lere listener bağla
      for (var c in _pulseKiyasCtrl.values) _pulseCtrlBagla(c);

      // Sonra setState ile değerleri yaz
      setState(() {
        if (geminiOkunan['brutsatis'] != null) {
          final val = (geminiOkunan['brutsatis'] as num).toDouble();
          _pulseKiyasCtrl['pulseBrut']!.text = _formatTL(
            val,
          ).replaceAll(' ₺', '');
          _gunlukSatisCtrl.text = _formatTL(val).replaceAll(' ₺', '');
        }
        if (geminiOkunan['kredikart'] != null) {
          final val = (geminiOkunan['kredikart'] as num).toDouble();
          // Kredi Kartı docId'sini bul
          final krediEslesme =
              digerEslestirme.cast<Map<String, dynamic>>().firstWhere((e) {
            final ad = (e['sistemAdi'] as String? ?? '').toLowerCase();
            final pulseAdi = (e['pulseAdi'] as String? ?? '').toLowerCase();
            return ad.contains('kredi') ||
                ad.contains('pos') ||
                pulseAdi.contains('kredi') ||
                pulseAdi.contains('pos');
          }, orElse: () => <String, dynamic>{});
          final krediKey = krediEslesme.isNotEmpty
              ? 'pulse_${krediEslesme['docId']}'
              : 'pulsePos'; // fallback
          if (_pulseKiyasCtrl.containsKey(krediKey)) {
            _pulseKiyasCtrl[krediKey]!.text = _formatTL(
              val,
            ).replaceAll(' ₺', '');
          }
        }
        if (geminiOkunan['online'] != null) {
          for (final o in (geminiOkunan['online'] as List)) {
            final pulseAd = (o['ad'] as String? ?? '').toUpperCase();
            final eslesme = fuzzyBulEslesme(pulseAd, onlineEslestirme);
            final tutar = (o['tutar'] as num? ?? 0).toDouble();
            if (eslesme != null && tutar > 0) {
              final key = 'online_${eslesme['docId']}';
              if (_pulseKiyasCtrl.containsKey(key))
                _pulseKiyasCtrl[key]!.text = _formatTL(
                  tutar,
                ).replaceAll(' ₺', '');
            }
          }
        }
        if (geminiOkunan['yemek'] != null) {
          for (final y in (geminiOkunan['yemek'] as List)) {
            final pulseAd = (y['ad'] as String? ?? '').toUpperCase();
            final eslesme = fuzzyBulEslesme(pulseAd, yemekEslestirme);
            final tutar = (y['tutar'] as num? ?? 0).toDouble();
            final key = eslesme != null ? 'yemek_${eslesme['docId']}' : '';
            if (eslesme != null &&
                tutar > 0 &&
                _pulseKiyasCtrl.containsKey(key)) {
              _pulseKiyasCtrl[key]!.text = _formatTL(
                tutar,
              ).replaceAll(' ₺', '');
            }
          }
        }
        if (geminiOkunan['diger'] != null) {
          for (final d in (geminiOkunan['diger'] as List)) {
            final pulseAd = (d['ad'] as String? ?? '').toUpperCase();
            final eslesme = fuzzyBulEslesme(pulseAd, digerEslestirme);
            final tutar = (d['tutar'] as num? ?? 0).toDouble();
            if (eslesme != null && tutar > 0) {
              final key = 'pulse_${eslesme['docId']}';
              if (_pulseKiyasCtrl.containsKey(key))
                _pulseKiyasCtrl[key]!.text = _formatTL(
                  tutar,
                ).replaceAll(' ₺', '');
            }
          }
        }
        _pulseOkunuyor = false;
        _pulseOkundu = true;
        _pulseKontrolOnaylandi = false; // Yeni okumada onay sıfırla
        _okumaMesaji = '✓ Pulse verileri okundu';
        _degisiklikVar = true;
        if (_duzenlemeAcik) _gercekDegisiklikVar = true;
      });
      _anindaKaydet();

      // Mesajı 4 saniye sonra temizle
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _okumaMesaji = '');
      });
    } catch (e) {
      setState(() => _pulseOkunuyor = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ── POS Resmi Okuma ───────────────────────────────────────────────────────────

  Future<void> _posResmiOku({ImageSource source = ImageSource.gallery}) async {
    try {
      final ayarDoc = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('gemini')
          .get();
      final apiKey = ayarDoc.data()?['apiKey'] as String? ?? '';
      if (apiKey.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Gemini API key girilmemiş. Ayarlar ekranından ekleyin.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      _gorselSeciliyor = true;
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        imageQuality: 60,
        maxWidth: 1600,
        maxHeight: 2000,
      );
      _gorselSeciliyor = false;
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final gonder = await _resimOnizle(context, bytes, 'POS Fişleri Önizleme');
      if (!gonder) return;

      setState(() {
        for (var p in _posListesi) p.dispose();
        _posListesi.clear();
        _posOkundu = false;
        _posKontrolOnaylandi = false;
        _okumaMesaji = '';
        _posIptalEdildi = false;
        _posOkunuyor = true;
      });
      if (!mounted) return;

      final base64Image = base64Encode(bytes);
      final mimeType = picked.mimeType ?? 'image/jpeg';

      const prompt = """Bu fotoğrafta POS günsonu fişleri ve/veya Z raporu var.
ÖNCE kontrol et:
1. Resim net mi? Net değilse: {"hata": "Resim bulanık veya okunamıyor"}
2. POS fişi veya Z raporu mu? Değilse: {"hata": "Bu resim POS fişi veya Z raporu değil"}

Resim Z raporu ise:
- Banka/Kredi Kartı veya Kredi Kartı satırındaki rakamı al (tek tutar)
- Sadece JSON: {"poslar": [4595.00]}

Resim POS günsonu fişi ise:
- Her fişteki GENEL TOPLAM rakamını al
- Kısmi görünse de kabul et: NEL TOPLAM, ENEL TOPLAM, GENEL TOPLAM hepsi aynı
- Birden fazla fiş varsa hepsini ayrı ayrı listeye ekle

Her iki durumda da sayılarda virgülü noktaya çevir.
Sadece JSON: {"poslar": [4595.00, 3193.00]}""";

      if (_posIptalEdildi) {
        setState(() => _posOkunuyor = false);
        return;
      }

      final groqApiKey = ayarDoc.data()?['groqApiKey'] as String? ?? '';
      final String? responseText = await _gorselOkuFallback(
        base64Image: base64Image,
        mimeType: mimeType,
        prompt: prompt,
        geminiApiKey: apiKey,
        groqApiKey: groqApiKey,
      );

      if (responseText == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Tüm servisler meşgul. Lütfen tekrar deneyin veya manuel girin.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 5),
            ),
          );
        }
        setState(() => _posOkunuyor = false);
        return;
      }

      final cleanText =
          responseText.replaceAll(RegExp(r'```json|```'), '').trim();
      final Map<String, dynamic> okunan = jsonDecode(cleanText);

      if (okunan.containsKey('hata')) {
        setState(() => _posOkunuyor = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(children: [
                const Icon(Icons.image_not_supported,
                    color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(
                  'Yanlış resim: ' +
                      (okunan['hata'] as String? ?? '') +
                      '\nLütfen POS fişi veya Z raporu seçin.',
                )),
              ]),
              backgroundColor: Colors.red[700],
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      final poslar = (okunan['poslar'] as List?)?.cast<num>() ?? [];
      if (poslar.isEmpty) {
        setState(() => _posOkunuyor = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(children: [
                Icon(Icons.warning_amber, color: Colors.white, size: 18),
                SizedBox(width: 10),
                Expanded(
                    child:
                        Text('POS tutarı bulunamadı. Lütfen tekrar deneyin.')),
              ]),
              backgroundColor: Colors.orange[800],
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      final yeniPosListesi = <PosGirisi>[];
      for (int i = 0; i < poslar.length; i++) {
        final yeniPos = PosGirisi(
          ad: 'POS ${i + 1}',
          tutar: _sifirTemizle(poslar[i].toDouble()),
        );
        _pulseCtrlBagla(yeniPos.tutarCtrl);
        yeniPosListesi.add(yeniPos);
      }

      setState(() {
        for (var p in _posListesi) p.dispose();
        _posListesi.clear();
        _posListesi.addAll(yeniPosListesi);
        _posOkunuyor = false;
        _posOkundu = true;
        _posKontrolOnaylandi = false;
        _okumaMesaji = '✓ \${poslar.length} adet POS okundu';
        _degisiklikVar = true;
        if (_duzenlemeAcik) _gercekDegisiklikVar = true;
      });
      _anindaKaydet();
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _okumaMesaji = '');
      });
    } catch (e) {
      setState(() => _posOkunuyor = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ── My Dominos Resmi Okuma ───────────────────────────────────────────────────

  Future<void> _myDominosResmiOku({
    ImageSource source = ImageSource.gallery,
  }) async {
    try {
      // Gemini API key Firestore'dan al
      final ayarDoc = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('gemini')
          .get();
      final apiKey = ayarDoc.data()?['apiKey'] as String? ?? '';
      if (apiKey.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Gemini API key girilmemiş. Ayarlar ekranından ekleyin.',
              ),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      // Resim seç — lifecycle uyarısını geçici devre dışı bırak
      _gorselSeciliyor = true;
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        imageQuality: 60,
        maxWidth: 1200,
        maxHeight: 1600,
      );
      _gorselSeciliyor = false;
      if (picked == null) return;

      // Önizleme — net mi kontrolü
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final gonder = await _resimOnizle(context, bytes, 'My Dominos Önizleme');
      if (!gonder) return; // Kullanıcı yeniden çek dedi

      // Okuma başlamadan önce mevcut MyDominos verilerini temizle
      setState(() {
        for (var c in _myDomKiyasCtrl.values) c.clear();
        _myDominosOkunan.clear();
        _myDominosYuklendi = false;
        _myDomOkundu = false;
        _pulseKontrolOnaylandi = false;
        _okumaMesaji = '';
        _myDomIptalEdildi = false;
        _myDominosOkunuyor = true;
      });
      if (!mounted) return;

      // Resmi base64'e çevir
      final base64Image = base64Encode(bytes);
      final mimeType = picked.mimeType ?? 'image/jpeg';

      // Online ödeme listesini Firestore'dan al — digerEkranAdi ile eşleştirme
      final onlineSnap = await FirebaseFirestore.instance
          .collection('odemeyontemleri')
          .where('tip', isEqualTo: 'online')
          .where('aktif', isEqualTo: true)
          .get();

      // digerEkranAdi → sistemAdi lookup tablosu
      final List<Map<String, dynamic>> myDomEslestirme = [];
      for (final d in onlineSnap.docs) {
        final ad = d.data()['ad'] as String? ?? '';
        final digerAd =
            (d.data()['digerEkranAdi'] as String? ?? '').toUpperCase().trim();
        if (ad.isEmpty) continue;
        final key = digerAd.isNotEmpty ? digerAd : ad.toUpperCase();
        myDomEslestirme.add({'digerAdi': key, 'sistemAdi': ad, 'docId': d.id});
      }

      // MyDominos fuzzy eşleştirme — Pulse fuzzyBul ile aynı mantık
      Map<String, dynamic>? myDomFuzzyBul(String geminiAd) {
        // Boşuksuz tireleri normalize et: "OLO-Garanti" → "OLO - Garanti"
        final normalize = geminiAd.replaceAll(RegExp(r'(?<! )-(?! )'), ' - ');
        final aranan = normalize.toUpperCase().trim();
        // 1. Tam eşleşme
        for (final e in myDomEslestirme) {
          if (e['digerAdi'] == aranan) return e;
        }
        // 2. Aranan tanımlı adı içeriyor mu
        for (final e in myDomEslestirme) {
          final digerAdi = (e['digerAdi'] as String? ?? '');
          if (digerAdi.isNotEmpty && aranan.contains(digerAdi)) return e;
        }
        // 3. Tanımlı ad aramayı içeriyor mu
        for (final e in myDomEslestirme) {
          final digerAdi = (e['digerAdi'] as String? ?? '');
          if (digerAdi.isNotEmpty && digerAdi.contains(aranan)) return e;
        }
        // 4. Token bazlı
        final arananTokenlar =
            aranan.split(' ').where((t) => t.length >= 2).toList();
        if (arananTokenlar.isNotEmpty) {
          Map<String, dynamic>? enIyi;
          int enIyiSkor = 0;
          for (final e in myDomEslestirme) {
            final digerTokenlar = (e['digerAdi'] as String? ?? '')
                .split(' ')
                .where((t) => t.length >= 2)
                .toList();
            int skor = 0;
            for (final at in arananTokenlar) {
              for (final dt in digerTokenlar) {
                if (at == dt) {
                  skor += 3;
                  break;
                }
                if (dt.startsWith(at) || at.startsWith(dt)) {
                  skor += 2;
                  break;
                }
                if (at.length >= 3 &&
                    dt.length >= 3 &&
                    at.substring(0, 3) == dt.substring(0, 3)) {
                  skor += 1;
                  break;
                }
              }
            }
            final oran = skor / (arananTokenlar.length * 3);
            if (oran >= 0.6 && skor > enIyiSkor) {
              enIyiSkor = skor;
              enIyi = e;
            }
          }
          if (enIyi != null) return enIyi;
        }
        final ilkKelime = aranan.split(' ').first;
        if (ilkKelime.length >= 4) {
          for (final e in myDomEslestirme) {
            if ((e['digerAdi'] as String? ?? '').startsWith(ilkKelime))
              return e;
          }
        }
        return null;
      }

      // Gemini'ye sadece My Dominos'ta görünen adları ver
      final kanallar = onlineSnap.docs
          .map((d) {
            final ad = d.data()['ad'] as String? ?? '';
            final digerAd = (d.data()['digerEkranAdi'] as String? ?? '').trim();
            return digerAd.isNotEmpty ? digerAd : ad.toUpperCase();
          })
          .where((s) => s.isNotEmpty)
          .join(', ');

      // ÖNEMLİ: Gemini ekranda GÖRDÜĞÜ ham adı döndürür, sistem adını değil.
      // Eşleştirme myDomFuzzyBul ile kodda yapılır — ad değişikliği okumayı etkilemez.
      final prompt = """Bu bir My Dominos sipariş dökümü ekran görüntüsü.

ÖNCE kontrol et:
1. Net değilse: {"hata": "Resim bulanık veya okunamıyor"}
2. My Dominos değilse: {"hata": "Bu resim My Dominos ekranı değil"}

My Dominos ekranıysa:
- Her satırı yatay oku. Ödeme Tipi ile Ciro AYNI satırda olmalı, karıştırma.
- Ciro o satırın en sağındaki büyük TL tutarıdır. TL yazısını ve küçük sayıları (sipariş adedi) Ciro olarak alma.
- Nakit içeren satırları ALMA.
- Ekranda bu ödeme tiplerinden birini gördüğünde listeye ekle: $kanallar
- "ad" alanına ekranda GÖRDÜĞÜN adı AYNEN yaz, değiştirme.
- Emin olmadığın karakterleri Türkçeye göre düzelt (örn: "Cuzdan" → "Cüzdan").

Sadece JSON döndür:
{"online": [{"ad": "EKRANDAKI_AD", "tutar": 1234.56}]}

Sayılarda virgülü noktaya çevir. Kanal bulunamazsa listeye ekleme.""";

      // İptal kontrolü
      if (_myDomIptalEdildi) {
        setState(() => _myDominosOkunuyor = false);
        return;
      }

      // Fallback zinciri: 3.1 → 2.5-lite → Groq
      final groqApiKey = ayarDoc.data()?['groqApiKey'] as String? ?? '';
      final String? responseText = await _gorselOkuFallback(
        base64Image: base64Image,
        mimeType: mimeType,
        prompt: prompt,
        geminiApiKey: apiKey,
        groqApiKey: groqApiKey,
      );

      setState(() => _myDominosOkunuyor = false);

      if (responseText == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Tüm servisler meşgul. Lütfen tekrar deneyin veya manuel girin.',
              ),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      final cleanText =
          responseText.replaceAll(RegExp(r'```json|```'), '').trim();
      final Map<String, dynamic> okunan = jsonDecode(cleanText);

      // Yanlış resim kontrolü
      if (okunan.containsKey('hata')) {
        setState(() => _myDominosOkunuyor = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(
                    Icons.image_not_supported,
                    color: Colors.white,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Yanlış resim: ' +
                          (okunan['hata'] as String? ?? '') +
                          '\nLütfen My Dominos ekran görüntüsü seçin.',
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.red[700],
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }

      final Map<String, double> yeniOkunan = {};
      if (okunan['online'] != null) {
        for (final o in (okunan['online'] as List)) {
          final geminiAd = o['ad'] as String? ?? '';
          final tutar = (o['tutar'] as num? ?? 0).toDouble();
          if (geminiAd.isEmpty || tutar <= 0) continue;
          // Gemini ham ekran adını döndürür — fuzzy ile docId'ye çevir
          final eslesme = myDomFuzzyBul(geminiAd);
          final key = eslesme != null
              ? 'online_${eslesme['docId']}'
              : 'online_$geminiAd'; // eşleşme yoksa ham adla yaz
          yeniOkunan[key] = (yeniOkunan[key] ?? 0) + tutar;
        }
      }

      if (yeniOkunan.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Eşleşen online ödeme bulunamadı.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // Ctrl'leri setState dışında hazırla
      for (final key in yeniOkunan.keys) {
        _myDomKiyasCtrl.putIfAbsent(key, () => TextEditingController());
      }

      setState(() {
        _myDominosOkunan = yeniOkunan;
        _myDominosYuklendi = true;
        _myDomOkundu = true;
        _okumaMesaji = '✓ My Dominos verileri okundu';
        _degisiklikVar = true;
        if (_duzenlemeAcik) _gercekDegisiklikVar = true;
        for (final entry in yeniOkunan.entries) {
          _myDomKiyasCtrl[entry.key]!.text = _formatTL(
            entry.value,
          ).replaceAll(' ₺', '');
        }
      });
      _anindaKaydet();

      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _okumaMesaji = '');
      });
    } catch (e) {
      setState(() => _myDominosOkunuyor = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _onlineOdemeleriYukle() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('odemeyontemleri')
          .where('aktif', isEqualTo: true)
          .get();
      if (mounted) {
        final onlineDocs =
            snap.docs.where((d) => d.data()['tip'] == 'online').toList();
        final pulseDocs = snap.docs
            .where(
              (d) =>
                  d.data()['tip'] == 'pulseKalemi' &&
                  (d.data()['sistemAlani'] == null ||
                      (d.data()['sistemAlani'] as String).isEmpty),
            )
            .toList();

        // Sırala
        onlineDocs.sort((a, b) {
          final sa = (a.data()['sira'] as num?)?.toInt() ??
              (a.data()['pulseSira'] as num?)?.toInt() ??
              999;
          final sb = (b.data()['sira'] as num?)?.toInt() ??
              (b.data()['pulseSira'] as num?)?.toInt() ??
              999;
          return sa.compareTo(sb);
        });
        pulseDocs.sort((a, b) {
          final sa = (a.data()['sira'] as num?)?.toInt() ??
              (a.data()['pulseSira'] as num?)?.toInt() ??
              999;
          final sb = (b.data()['sira'] as num?)?.toInt() ??
              (b.data()['pulseSira'] as num?)?.toInt() ??
              999;
          return sa.compareTo(sb);
        });

        final siraliAdlar = onlineDocs
            .map((d) => d.data()['ad'] as String? ?? '')
            .where((ad) => ad.isNotEmpty)
            .toList();

        setState(() {
          _onlineOdemeAdlari = siraliAdlar;
          final mevcutIdler =
              _onlineOdemeler.map((o) => o['id'] as String).toSet();
          for (var doc in onlineDocs) {
            final id = doc.id; // docId — sabit
            final ad = doc.data()['ad'] as String? ?? '';
            if (ad.isEmpty) continue;
            final sira = (doc.data()['sira'] as num?)?.toInt() ??
                (doc.data()['pulseSira'] as num?)?.toInt() ??
                99;
            if (!mevcutIdler.contains(id)) {
              _onlineOdemeler.add({
                'id': id,
                'ad': ad,
                'ctrl': TextEditingController(),
                'sira': sira,
                'dogruKaynak':
                    doc.data()['dogruKaynak'] as String? ?? 'myDominos',
                'digerEkranAdi': doc.data()['digerEkranAdi'] ?? '',
              });
            } else {
              final idx = _onlineOdemeler.indexWhere((o) => o['id'] == id);
              if (idx >= 0) {
                _onlineOdemeler[idx]['ad'] = ad;
                _onlineOdemeler[idx]['sira'] = sira;
                _onlineOdemeler[idx]['dogruKaynak'] =
                    doc.data()['dogruKaynak'] as String? ?? 'myDominos';
                _onlineOdemeler[idx]['digerEkranAdi'] =
                    doc.data()['digerEkranAdi'] ?? '';
              }
            }
          }
          // sira'ya göre sırala
          _onlineOdemeler.sort((a, b) {
            final sa = (a['sira'] as int? ?? 99);
            final sb = (b['sira'] as int? ?? 99);
            return sa.compareTo(sb);
          });

          // Pulse kalemleri
          _pulseKalemleri = pulseDocs
              .map(
                (d) => {
                  'id': d.id,
                  'ad': d.data()['ad'] as String? ?? '',
                  'pulseAdi': d.data()['pulseAdi'] as String? ?? '',
                  'sira': (d.data()['sira'] as num?)?.toInt() ??
                      (d.data()['pulseSira'] as num?)?.toInt() ??
                      99,
                  'dogruKaynak': d.data()['dogruKaynak'] as String? ?? 'pulse',
                  'sistemAlani': d.data()['sistemAlani'] as String? ?? '',
                },
              )
              .where((m) => (m['ad'] as String).isNotEmpty)
              .toList();

          // Online ve pulse kalem ctrl'lerini hazırla
          for (var o in _onlineOdemeler) {
            final id = o['id'] as String;
            final key = 'online_$id'; // docId bazlı
            _pulseKiyasCtrl.putIfAbsent(key, () => TextEditingController());
            _myDomKiyasCtrl.putIfAbsent(key, () => TextEditingController());
          }
          for (var k in _pulseKalemleri) {
            final id = k['id'] as String;
            final key = 'pulse_$id'; // docId bazlı
            _pulseKiyasCtrl.putIfAbsent(key, () => TextEditingController());
          }
          // Yeni ctrl'lere listener bağla
          for (var c in _pulseKiyasCtrl.values) _pulseCtrlBagla(c);
          for (var c in _myDomKiyasCtrl.values) _pulseCtrlBagla(c);
        });
      }
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  Future<void> _banknotAyarlariniKaydet() async {
    try {
      await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('banknotlar')
          .set({'liste': _banknotlar, 'flotSiniri': _flotSiniri});
    } catch (e) {
      if (mounted) _appBarMesajGoster('✗ Kayıt hatası');
    }
  }

  @override
  void dispose() {
    // Dispose öncesi idle timer iptal et, bekleyen kayıt varsa kaydet
    _idleTimer?.cancel();
    if (_degisiklikVar && !_readOnly) {
      // Controller'lar dispose edilmeden ÖNCE veriyi al
      final kayitVerisi = _otomatikKayitVerisi();
      final tarihKey = _tarihKey(_secilenTarih);
      final subeKodu = widget.subeKodu;
      FirebaseFirestore.instance
          .collection('subeler')
          .doc(subeKodu)
          .collection('gunluk')
          .doc(tarihKey)
          .set(kayitVerisi, SetOptions(merge: true))
          .catchError((_) {});
    }
    _tabController.dispose();
    for (var c in _pulseKiyasCtrl.values) c.dispose();
    for (var c in _myDomKiyasCtrl.values) c.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _kilitBirak();
    _kilitTimer?.cancel();
    _internetTimer?.cancel();
    _arkaPlanTimer?.cancel();
    // timer kaldırıldı
    _appBarMesajTimer?.cancel();
    _bekleyenTransferStream?.cancel();
    _scrollController.dispose();
    _sistemPosCtrl.dispose();
    _gunlukSatisCtrl.dispose();
    _devredenFlotCtrl.dispose();
    _ekrandaGorunenNakitCtrl.dispose();
    _bankayaYatiranCtrl.dispose();
    _manuelFlotCtrl.dispose();
    for (var p in _posListesi) p.dispose();
    for (var y in _yemekKartlari) y.dispose();
    for (var c in _sistemYemekKartiCtrl.values) c.dispose();
    for (var o in _onlineOdemeler) {
      (o['ctrl'] as TextEditingController).dispose();
    }
    for (var h in _harcamalar) h.dispose();
    for (var h in _anaKasaHarcamalari) h.dispose();
    for (var h in _nakitCikislar) h.dispose();
    for (var d in _nakitDovizler) {
      (d['ctrl'] as TextEditingController).dispose();
      (d['aciklamaCtrl'] as TextEditingController?)?.dispose();
    }
    for (var c in _banknotCtrl.values) c.dispose();
    for (var c in _dovizBankayaYatiranCtrl.values) c.dispose();
    for (var d in _dovizler) {
      (d['miktarCtrl'] as TextEditingController).dispose();
      (d['kurCtrl'] as TextEditingController).dispose();
    }
    for (var d in _bankaDovizler) {
      (d['ctrl'] as TextEditingController).dispose();
    }
    for (var t in _transferler) {
      (t['aciklamaCtrl'] as TextEditingController).dispose();
      (t['tutarCtrl'] as TextEditingController).dispose();
    }
    for (var t in _digerAlimlar) {
      (t['aciklamaCtrl'] as TextEditingController).dispose();
      (t['tutarCtrl'] as TextEditingController).dispose();
    }
    super.dispose();
  }

  // ── Kaydedilmemiş değişiklik uyarısı ──────────────────────────────────────
  // Dönüş: true = devam et, false = iptal
  // Gün kapatılmamışsa uyarı ver ve geçişi engelle
  // true = geçiş yapılabilir, false = engellendi
  Future<bool> _gunuKapatUyar() async {
    // Yönetici — kısıt yok, her zaman serbest
    if (widget.gecmisGunHakki == -1) return true;
    // Bugünse veya gün kapatılmışsa serbest
    if (_bugunSecili || _gunuKapatildi) return true;
    // Şubenin açılış tarihinden önceyse serbest (o gün çalışılmamış)
    if (_ilkKapaliTarih != null) {
      final secilen = DateTime(
        _secilenTarih.year,
        _secilenTarih.month,
        _secilenTarih.day,
      );
      if (secilen.isBefore(_ilkKapaliTarih!)) return true;
    }
    // Geçmiş tarih ve gün kapatılmamış — engelle
    if (!mounted) return false;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.lock_clock, color: Colors.red),
            SizedBox(width: 8),
            Text('Günü Kapatın'),
          ],
        ),
        content: Text(
          '${_tarihGoster(_secilenTarih)} tarihi kapatılmadan '
          'başka bir işlem yapamazsınız.\n\n'
          'Lütfen önce bu günü kapatın.',
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0288D1),
              foregroundColor: Colors.white,
            ),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
    return false;
  }

  Future<bool> _degisiklikUyar({required String gecisMetni}) async {
    // Yönetici — düzenleme açıksa değişiklikleri otomatik kaydet ve serbest geç
    if (_duzenlemeAcik && widget.gecmisGunHakki == -1) {
      if (_degisiklikVar) {
        try {
          await FirebaseFirestore.instance
              .collection('subeler')
              .doc(widget.subeKodu)
              .collection('gunluk')
              .doc(_tarihKey(_secilenTarih))
              .set(_otomatikKayitVerisi(), SetOptions(merge: true));
        } catch (e) {
          if (mounted) _appBarMesajGoster('✗ Kayıt hatası');
        }
      }
      return true;
    }
    // Düzenleme açıksa — zorunlu alanlar dolu olsa da Günü Kapat zorunlu
    if (_duzenlemeAcik) {
      final sonuc = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.lock_open, color: Colors.orange),
              SizedBox(width: 8),
              Text('Günü Kapatmadınız'),
            ],
          ),
          content: Text(
            _bugunTamamlandi
                ? 'Düzenleme modundasınız. Devam etmek için günü kapatın veya değişiklikleri iptal edin.'
                : _bugunSecili
                    ? 'Düzenleme modundasınız. Zorunlu alanlar eksik olduğu için günü kapatılamıyor. Değişiklikleri iptal edip ayrılabilirsiniz.'
                    : 'Geçmiş kayıt düzenlemesinde zorunlu alanlar eksik. Lütfen zorunlu alanları doldurup günü kapatın.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'geri'),
              child: const Text('Geri Dön'),
            ),
            if (_bugunTamamlandi)
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(context, 'kapat'),
                icon: const Icon(Icons.lock_clock, size: 16),
                label: const Text('Günü Kapat'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0288D1),
                  foregroundColor: Colors.white,
                ),
              )
            else if (_bugunSecili)
              TextButton(
                onPressed: () => Navigator.pop(context, 'iptal'),
                child: const Text(
                  'Değişiklikleri İptal Et',
                  style: TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
      );
      if (sonuc == 'kapat') {
        await _kaydet();
        return true;
      }
      if (sonuc == 'iptal') {
        await _mevcutKaydiYukleYaDaTemizle();
        return true;
      }
      return false;
    }
    // Bekleyen değişiklik varsa hemen kaydet
    if (_degisiklikVar) {
      try {
        final tarihKey = _tarihKey(_secilenTarih);
        await FirebaseFirestore.instance
            .collection('subeler')
            .doc(widget.subeKodu)
            .collection('gunluk')
            .doc(tarihKey)
            .set(_otomatikKayitVerisi(), SetOptions(merge: true));
        if (mounted) setState(() => _degisiklikVar = false);
      } catch (e) {
        if (mounted) _appBarMesajGoster('✗ Kayıt hatası');
      }
    }
    if (!_degisiklikVar) return true;
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .doc(tarihKey)
          .set(_otomatikKayitVerisi(), SetOptions(merge: true));
      if (mounted) setState(() => _degisiklikVar = false);
    } catch (e) {
      if (mounted) _appBarMesajGoster('✗ Kayıt hatası');
    }
    await _kilitBirak();
    return true;
  }

  // ── Tarih seç ──────────────────────────────────────────────────────────────

  // Bugünün kaydı tamamlanmış mı?
  // Gün kapatılmış, düzenleme açılmamış VEYA başkası kilitlemiş ise readonly
  bool get _readOnly {
    if (_kilitTutanKullanici != null) return true;
    if (_gunuKapatildi && !_duzenlemeAcik) return true;
    // Geçmiş gün yetki sınırı — sadece kapatılmış günler için geçerli
    // Kapanmamış günler her zaman düzenlenebilir (veri girilmeli)
    if (!_bugunSecili && _gunuKapatildi) {
      final yonetici = widget.gecmisGunHakki == -1;
      if (!yonetici && _sonKapaliTarih != null) {
        // Referans: en son kapatılan gün (bugün değil)
        final fark = _sonKapaliTarih!
            .difference(
              DateTime(
                _secilenTarih.year,
                _secilenTarih.month,
                _secilenTarih.day,
              ),
            )
            .inDays;
        if (fark > widget.gecmisGunHakki) return true;
      }
    }
    return false;
  }

  bool get _bugunTamamlandi {
    return _toplamPos > 0 &&
        _parseDouble(_ekrandaGorunenNakitCtrl.text) > 0 &&
        _parseDouble(_gunlukSatisCtrl.text) > 0 &&
        _toplamNakitTL > 0;
  }

  // Seçilen tarih bugünün tarihi mi?
  bool get _bugunSecili {
    final bugun = _bugunuHesapla();
    return _secilenTarih.year == bugun.year &&
        _secilenTarih.month == bugun.month &&
        _secilenTarih.day == bugun.day;
  }

  Future<void> _tarihSec() async {
    // Tarih penceresi: lastDate kapanmamış günü geçemez (maxTarih kontrolü)
    // Bugünün kaydı kapatılmamışsa engelle (yönetici hariç)
    if (_bugunSecili && !_gunuKapatildi) {
      final yonetici = widget.gecmisGunHakki == -1;
      if (!yonetici) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.orange),
                SizedBox(width: 8),
                Text('Kayıt Tamamlanmadı'),
              ],
            ),
            content: const Text(
              'Bugünün kaydı tamamlanmadan başka güne geçemezsiniz.\n\nLütfen önce zorunlu alanları doldurun:\n• POS tutarı\n• Ekranda Görünen Nakit\n• Günlük Satış Toplamı\n• En az 1 banknot',
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0288D1),
                  foregroundColor: Colors.white,
                ),
                child: const Text('Tamam'),
              ),
            ],
          ),
        );
        return;
      }
    }

    if (!await _degisiklikUyar(gecisMetni: 'Başka tarihe geçmeden')) return;

    final yonetici = widget.gecmisGunHakki == -1;

    // lastDate: kapatılmış son gün (yönetici için bugün)
    DateTime maxTarih = _bugunuHesapla();
    if (!yonetici) {
      // Bugünden geriye doğru kapatılmış son günü bul
      maxTarih = _secilenTarih; // en azından mevcut tarih seçilebilir
      for (int i = 0; i <= 60; i++) {
        final gun = _bugunuHesapla().subtract(Duration(days: i));
        final key = _tarihKey(gun);
        try {
          final doc = await FirebaseFirestore.instance
              .collection('subeler')
              .doc(widget.subeKodu)
              .collection('gunluk')
              .doc(key)
              .get();
          if (doc.exists && doc.data()?['tamamlandi'] == true) {
            maxTarih = gun;
            break;
          }
          if (!doc.exists && i == 0) {
            // Bugün kaydı yok — dünü kontrol et
            continue;
          }
          if (!doc.exists && i > 0) {
            // Boşluk var — bir önceki kapatılmış güne kadar izin ver
            break;
          }
        } catch (_) {
          break;
        }
      }
    }

    // firstDate: sonKapaliTarih - gecmisGunHakki ve açılış tarihi kısıtlarının daha büyüğü
    final referansTarih = (!yonetici && _sonKapaliTarih != null)
        ? _sonKapaliTarih!
        : _secilenTarih; // null ise mevcut tarih
    DateTime firstDate = yonetici
        ? DateTime(2020)
        : referansTarih.subtract(Duration(days: widget.gecmisGunHakki));
    if (!yonetici &&
        _ilkKapaliTarih != null &&
        _ilkKapaliTarih!.isAfter(firstDate)) {
      firstDate = _ilkKapaliTarih!;
    }

    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _secilenTarih,
      firstDate: firstDate,
      lastDate: maxTarih,
      helpText: 'Tarih Seçin',
      cancelText: 'İptal',
      confirmText: 'Seç',
    );
    if (picked != null && picked != _secilenTarih) {
      // Önce devam eden kayıt beklenir: eski _otomatikKaydet tamamlanmadan
      // _tarihOncesiKaydet çalışırsa eski veri daha sonra üzerine yazabilir.
      while (_otomatikKaydediliyor && mounted) {
        await Future.delayed(const Duration(milliseconds: 30));
      }
      // Kaydedilmemiş değişiklik varsa şimdi kaydet (tüm paralel yazma bitti)
      await _tarihOncesiKaydet();

      await _kilitBirak();
      setState(() {
        _secilenTarih = picked;
        _kilitTutanKullanici = null;
      });
      await _mevcutKaydiYukleYaDaTemizle();
    }
  }

  Future<void> _cikisYap() async {
    if (!await _degisiklikUyar(gecisMetni: 'Çıkmadan')) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const GirisEkrani()),
      );
    }
  }

  bool _yukleniyor = false; // Yükleme sırasında listener'ları sustur

  Future<void> _mevcutKaydiYukleYaDaTemizle() async {
    setState(() {
      _degisiklikVar = false;
      _yukleniyor = true;
    });
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      final doc = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .doc(tarihKey)
          .get();

      if (doc.exists) {
        _mevcutKaydiYukle(doc.data()!);
        // _oncekiGundenDovizYukle burada çağrılmaz:
        // _mevcutKaydiYukle zaten oncekiDovizAnaKasaKalanlari alanını
        // doğrudan kayıttan okuyor. Tekrar çağırmak dovizAnaKasaKalanlari'nı
        // (bitiş değeri) alıp devredenin üzerine yazar — hatalı zincirleme.
      } else {
        await _formlariTemizle();
        await _oncekiGundenYukle();
      }
      // Bekleyen transfer bildirimi kontrol et
      // Flagi sıfırla — önceki çağrıdan takılı kalmış olabilir
      _bildirimIsleniyor = false;
      await _bekleyenTransferleriBildir();
    } catch (_) {
      await _formlariTemizle();
      await _oncekiGundenYukle();
    } finally {
      if (mounted)
        setState(() {
          _degisiklikVar = false;
          _yukleniyor = false;
        });
      // Veri yükleme bittiğinden sonra listener'lar tarafından tetiklenen
      // değişiklikleri geri sıfırla — tarih değişimi sırasında state temizdir kalsin
      if (mounted && !_yukleniyor && !_degisiklikVar) {
        // Listener callback'leştirildi ise, önceki duruma dön
        if (mounted) setState(() => _degisiklikVar = false);
      }
    }
  }

  Future<void> _bekleyenTransferleriGoster() async {
    if (!mounted) return;
    try {
      final bekleyenler = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('bekleyen_transferler')
          .get();

      // GELEN ve bekletilmiş RET'leri göster
      final aktifler = bekleyenler.docs
          .where(
            (d) =>
                d.data()['kategori'] == 'GELEN' ||
                (d.data()['kategori'] == 'RET' &&
                    d.data()['bekletildi'] == true),
          )
          .toList();

      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.swap_horiz, color: Colors.orange),
              SizedBox(width: 8),
              Text('Bekleyen Transferler'),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: aktifler.isEmpty
                ? const Text('Bekleyen transfer yok.')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: aktifler.length,
                    itemBuilder: (_, i) {
                      final d = aktifler[i].data();
                      final kategori = d['kategori'] as String? ?? 'GELEN';
                      final isRet = kategori == 'RET';
                      final kaynakAd = isRet
                          ? (d['hedefSubeAd'] as String? ?? '')
                          : (d['kaynakSubeAd'] as String? ?? '');
                      final tutar = (d['tutar'] as num? ?? 0).toDouble();
                      final tarih = d['tarih'] as String? ?? '';
                      final aciklama = d['aciklama'] as String? ?? '';
                      final bekletildi = d['bekletildi'] == true;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isRet
                              ? Icons.cancel_outlined
                              : (bekletildi
                                  ? Icons.hourglass_empty
                                  : Icons.pending),
                          color: isRet
                              ? Colors.red[700]
                              : (bekletildi ? Colors.orange : Colors.blue),
                        ),
                        title: Text(
                          isRet
                              ? '$kaynakAd — Reddedildi'
                              : '$kaynakAd → ${_formatTL(tutar)}',
                        ),
                        subtitle: Text(
                          [
                            if (isRet) _formatTL(tutar),
                            tarih,
                            if (aciklama.isNotEmpty) aciklama,
                            if (bekletildi && !isRet) 'Bekletildi',
                          ].join(' • '),
                        ),
                        trailing: TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            _bekleyenTransferleriBildir();
                          },
                          child: const Text('İşle'),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Kapat'),
            ),
          ],
        ),
      );
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  // ── Bekleyen transferleri bildir ────────────────────────────────────────────
  Future<void> _bekleyenTransferleriBildir() async {
    if (_bildirimIsleniyor) return;
    _bildirimIsleniyor = true;
    try {
      final bekleyenler = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('bekleyen_transferler')
          .get();

      if (!mounted || bekleyenler.docs.isEmpty) return;

      // Rozet sayısını güncelle
      final rozetSayisi = bekleyenler.docs
          .where(
            (d) =>
                d.data()['kategori'] == 'GELEN' ||
                d.data()['kategori'] == 'ONAY_BILDIRIMI' ||
                d.data()['kategori'] == 'RET' ||
                d.data()['kategori'] == 'BEKLET_BILDIRIMI',
          )
          .length;
      if (mounted) setState(() => _bekleyenTransferSayisi = rozetSayisi);

      if (!mounted || bekleyenler.docs.isEmpty) return;

      // ── 1. Aya gelen bildirimler: ONAY, RET, BEKLET ──────────────────────
      // ONAY_BILDIRIMI — transfer onaylandı, GİDEN kaydı güncelle
      for (final doc in bekleyenler.docs.where(
        (d) => d.data()['kategori'] == 'ONAY_BILDIRIMI',
      )) {
        if (!mounted) break;
        final data = doc.data();
        final transferId = data['transferId'] as String? ?? '';
        await doc.reference.delete();
        if (transferId.isNotEmpty) {
          setState(() {
            for (final t in _transferler) {
              if ((t['transferId'] as String? ?? '') == transferId) {
                t['onaylandi'] = true;
                t['reddedildi'] = false;
                t['bekletildi'] = false;
              }
            }
          });
          await _transferKaydet();
        }
      }

      if (!mounted) return;

      // RET — transfer reddedildi, GİDEN kaydı güncelle (tekrar gönderilebilir)
      // bekletildi=true olanları atla — kullanıcı daha sonra bakmak istiyor
      for (final doc in bekleyenler.docs.where(
        (d) => d.data()['kategori'] == 'RET' && d.data()['bekletildi'] != true,
      )) {
        if (!mounted) break;
        final data = doc.data();
        final transferId = data['transferId'] as String? ?? '';
        final retTarih = data['tarih'] as String? ?? '';
        final retTutar = (data['tutar'] as num? ?? 0).toDouble();
        final retHedefAd = data['hedefSubeAd'] as String? ?? '';
        await doc.reference.delete();
        if (transferId.isNotEmpty) {
          // A'ya dialog ile bildir — reddedildi henüz set edilmez
          if (mounted && retTarih.isNotEmpty) {
            final sonuc = await showDialog<String>(
              context: context,
              barrierDismissible: false,
              builder: (_) => AlertDialog(
                title: Row(
                  children: [
                    Icon(Icons.cancel_outlined, color: Colors.red[700]),
                    const SizedBox(width: 8),
                    const Flexible(child: Text('Transfer Reddedildi')),
                  ],
                ),
                content: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red[200]!),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reddeden Şube:',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                      Text(
                        retHedefAd,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tutar:',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                      Text(
                        _formatTL(retTutar),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                          color: Colors.red[700],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tarih: $retTarih',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context, 'beklet'),
                    icon: Icon(
                      Icons.hourglass_empty,
                      color: Colors.orange[700],
                    ),
                    label: Text(
                      'Beklet',
                      style: TextStyle(color: Colors.orange[700]),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context, 'goruntule'),
                    icon: const Icon(
                      Icons.visibility,
                      color: Color(0xFF0288D1),
                    ),
                    label: const Text(
                      'Görüntüle',
                      style: TextStyle(color: Color(0xFF0288D1)),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context, 'dogru'),
                    icon: const Icon(Icons.check_circle),
                    label: const Text('Tamam, Kapat'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green[700],
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            );
            if (sonuc == 'goruntule' && mounted) {
              // Sadece o tarihe git — reddedildi henüz set edilmez
              final parcalar = retTarih.split('-');
              if (parcalar.length == 3) {
                await _tarihOncesiKaydet();

                final tarih = DateTime(
                  int.tryParse(parcalar[0]) ?? 2000,
                  int.tryParse(parcalar[1]) ?? 1,
                  int.tryParse(parcalar[2]) ?? 1,
                );
                await _kilitBirak();
                setState(() {
                  _secilenTarih = tarih;
                  _degisiklikVar = false;
                });
                await _mevcutKaydiYukleYaDaTemizle();
              }
            } else if (sonuc == 'beklet' && mounted) {
              // Rozette göster, sonra tekrar işlenebilir
              await FirebaseFirestore.instance
                  .collection('subeler')
                  .doc(widget.subeKodu)
                  .collection('bekleyen_transferler')
                  .doc('ret_beklet_$transferId')
                  .set({
                'kategori': 'RET',
                'hedefSubeAd': retHedefAd,
                'tutar': retTutar,
                'tarih': retTarih,
                'transferId': transferId,
                'bekletildi': true,
                'zaman': FieldValue.serverTimestamp(),
              });
              setState(() => _bekleyenTransferSayisi++);
            } else if (sonuc == 'dogru' && mounted) {
              // Doğru seçilince reddedildi olarak Firestore'a yaz
              bool eslesti = false;
              setState(() {
                for (final t in _transferler) {
                  if ((t['transferId'] as String? ?? '') == transferId) {
                    t['reddedildi'] = true;
                    t['onaylandi'] = false;
                    t['bekletildi'] = false;
                    t['gonderildi'] = false;
                    eslesti = true;
                  }
                }
              });
              if (eslesti) {
                await _transferKaydet();
              } else if (retTarih.isNotEmpty) {
                try {
                  final gunRef = FirebaseFirestore.instance
                      .collection('subeler')
                      .doc(widget.subeKodu)
                      .collection('gunluk')
                      .doc(retTarih);
                  final gunDoc = await gunRef.get();
                  if (gunDoc.exists) {
                    final transferler =
                        (gunDoc.data()?['transferler'] as List?)?.cast<Map>() ??
                            [];
                    final guncel = transferler.map((t) {
                      if ((t['transferId'] as String? ?? '') == transferId) {
                        return {
                          ...t,
                          'reddedildi': true,
                          'onaylandi': false,
                          'bekletildi': false,
                          'gonderildi': false,
                        };
                      }
                      return t;
                    }).toList();
                    await gunRef.update({'transferler': guncel});
                  }
                } catch (e) {
                  if (mounted) _appBarMesajGoster('✗ Kayıt hatası');
                }
              }
            }
          }
        }
      }

      if (!mounted) return;

      // BEKLET_BILDIRIMI — transfer bekletildi, sadece durum güncelle
      for (final doc in bekleyenler.docs.where(
        (d) => d.data()['kategori'] == 'BEKLET_BILDIRIMI',
      )) {
        if (!mounted) break;
        final data = doc.data();
        final transferId = data['transferId'] as String? ?? '';
        await doc.reference.delete();
        if (transferId.isNotEmpty) {
          setState(() {
            for (final t in _transferler) {
              if ((t['transferId'] as String? ?? '') == transferId) {
                t['bekletildi'] = true;
                t['onaylandi'] = false;
                t['reddedildi'] = false;
              }
            }
          });
          await _transferKaydet();
        }
      }

      if (!mounted) return;

      // ── 2. Bye gelen transferler: Onayla / Reddet / Beklet dialog ────────
      final gelenler = bekleyenler.docs
          .where((d) => d.data()['kategori'] == 'GELEN')
          .toList();
      final bekletilmemisler =
          gelenler.where((d) => d.data()['bekletildi'] != true).toList();

      for (final doc in bekletilmemisler) {
        if (!mounted) return;
        final data = doc.data();
        final kaynakAd = data['kaynakSubeAd'] as String? ??
            data['kaynakSube'] as String? ??
            '';
        final tutar = (data['tutar'] as num? ?? 0).toDouble();
        final aciklama = data['aciklama'] as String? ?? '';
        final tarih = data['tarih'] as String? ?? '';
        final transferId = data['transferId'] as String? ?? '';
        final manuelGelen = data['manuelGelen'] == true;

        final sonuc = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.swap_horiz, color: Colors.orange[700]),
                const SizedBox(width: 8),
                Text(manuelGelen ? 'Giden Transfer' : 'Gelen Transfer'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue[200]!),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Gönderen Şube:',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                      Text(
                        kaynakAd,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tutar:',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                      Text(
                        _formatTL(tutar),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                          color: Color(0xFF0288D1),
                        ),
                      ),
                      if (aciklama.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Açıklama:',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                        Text(aciklama, style: const TextStyle(fontSize: 14)),
                      ],
                      if (tarih.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Tarih: $tarih',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Bu transferi ne yapmak istiyorsunuz?'),
              ],
            ),
            actions: [
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'red'),
                icon: const Icon(Icons.cancel, color: Colors.red),
                label: const Text(
                  'Reddet',
                  style: TextStyle(color: Colors.red),
                ),
              ),
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'beklet'),
                icon: Icon(Icons.hourglass_empty, color: Colors.orange[700]),
                label: Text(
                  'Beklet',
                  style: TextStyle(color: Colors.orange[700]),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(context, 'onayla'),
                icon: const Icon(Icons.check_circle),
                label: const Text('Onayla'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        );

        if (sonuc == 'onayla') {
          await _transferiKaydeEkle(doc.id, data);
        } else if (sonuc == 'red') {
          await _transferiReddetVeKaydet(doc.id, data, transferId: transferId);
        } else if (sonuc == 'beklet') {
          // Beklet: Firestoreda bekletildi=true yap, bildirimi alacak şubeye gönder
          await doc.reference.update({
            'bekletildi': true,
            'bekletmeTarihi': FieldValue.serverTimestamp(),
          });
          // manuelGelen: bildirim Aya (hedefSube), normal: Aya (kaynakSube)
          final manuelGelen = data['manuelGelen'] == true;
          final bildirimAlacakSube = manuelGelen
              ? (data['hedefSube'] as String? ?? '')
              : (data['kaynakSube'] as String? ?? '');
          if (bildirimAlacakSube.isNotEmpty && transferId.isNotEmpty) {
            final buSubeAd = _subeAdlari[widget.subeKodu] ?? widget.subeKodu;
            await FirebaseFirestore.instance
                .collection('subeler')
                .doc(bildirimAlacakSube)
                .collection('bekleyen_transferler')
                .doc('beklet_$transferId')
                .set({
              'kategori': 'BEKLET_BILDIRIMI',
              'kaynakSubeAd': buSubeAd,
              'kaynakSube': widget.subeKodu,
              'transferId': transferId,
              'tutar': tutar,
              'aciklama': aciklama,
              'tarih': tarih,
              'olusturmaTarihi': FieldValue.serverTimestamp(),
            });
          }
        }
      }

      if (!mounted) return;

      // ── 3. Bekletilmiş transferler: tekrar işle ────────────────────────────
      final bekletilmisler =
          gelenler.where((d) => d.data()['bekletildi'] == true).toList();

      for (final doc in bekletilmisler) {
        if (!mounted) return;
        final data = doc.data();
        final kaynakAd = data['kaynakSubeAd'] as String? ??
            data['kaynakSube'] as String? ??
            '';
        final tutar = (data['tutar'] as num? ?? 0).toDouble();
        final aciklama = data['aciklama'] as String? ?? '';
        final tarih = data['tarih'] as String? ?? '';
        final transferId = data['transferId'] as String? ?? '';

        final sonuc = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.hourglass_empty, color: Colors.orange[700]),
                const SizedBox(width: 8),
                const Text('Bekletilen Transfer'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange[300]!),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.hourglass_empty,
                        size: 14,
                        color: Colors.orange[700],
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Daha önce bekletilmişti',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange[800],
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue[200]!),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Gönderen Şube:',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                      Text(
                        kaynakAd,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tutar:',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                      Text(
                        _formatTL(tutar),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                          color: Color(0xFF0288D1),
                        ),
                      ),
                      if (aciklama.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Açıklama:',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                        Text(aciklama, style: const TextStyle(fontSize: 14)),
                      ],
                      if (tarih.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Tarih: $tarih',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Ne yapmak istiyorsunuz?'),
              ],
            ),
            actions: [
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'red'),
                icon: const Icon(Icons.cancel, color: Colors.red),
                label: const Text(
                  'Reddet',
                  style: TextStyle(color: Colors.red),
                ),
              ),
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'beklet'),
                icon: Icon(Icons.hourglass_empty, color: Colors.orange[700]),
                label: Text(
                  'Bekletmeye Devam',
                  style: TextStyle(color: Colors.orange[700]),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(context, 'onayla'),
                icon: const Icon(Icons.check_circle),
                label: const Text('Onayla'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        );

        if (sonuc == 'onayla') {
          await _transferiKaydeEkle(doc.id, data);
        } else if (sonuc == 'red') {
          await _transferiReddetVeKaydet(doc.id, data, transferId: transferId);
        }
        // beklet → hiçbir şey yapma, Firestoreda bekletildi=true kalır
      }

      if (!mounted) return;

      // ── 4. Bekletilmiş RET bildirimleri: tekrar isle ──────────────────────
      final retBekletilmisler = bekleyenler.docs
          .where(
            (d) =>
                d.data()['kategori'] == 'RET' && d.data()['bekletildi'] == true,
          )
          .toList();

      for (final doc in retBekletilmisler) {
        if (!mounted) return;
        final data = doc.data();
        final transferId = data['transferId'] as String? ?? '';
        final retTarih = data['tarih'] as String? ?? '';
        final retTutar = (data['tutar'] as num? ?? 0).toDouble();
        final retHedefAd = data['hedefSubeAd'] as String? ?? '';

        await doc.reference.delete();

        final sonuc = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.cancel_outlined, color: Colors.red[700]),
                const SizedBox(width: 8),
                const Flexible(child: Text('Transfer Reddedildi')),
              ],
            ),
            content: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red[200]!),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reddeden Sube:',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                  Text(
                    retHedefAd,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tutar:',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                  Text(
                    _formatTL(retTutar),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                      color: Colors.red[700],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tarih: $retTarih',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'beklet'),
                icon: Icon(Icons.hourglass_empty, color: Colors.orange[700]),
                label: Text(
                  'Beklet',
                  style: TextStyle(color: Colors.orange[700]),
                ),
              ),
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'goruntule'),
                icon: const Icon(Icons.visibility, color: Color(0xFF0288D1)),
                label: const Text(
                  'Goruntule',
                  style: TextStyle(color: Color(0xFF0288D1)),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(context, 'tamam'),
                icon: const Icon(Icons.check_circle),
                label: const Text('Tamam, Kapat'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        );

        if (sonuc == 'goruntule' && mounted) {
          final parcalar = retTarih.split('-');
          if (parcalar.length == 3) {
            await _tarihOncesiKaydet();

            final tarih = DateTime(
              int.tryParse(parcalar[0]) ?? 2000,
              int.tryParse(parcalar[1]) ?? 1,
              int.tryParse(parcalar[2]) ?? 1,
            );
            await _kilitBirak();
            setState(() {
              _secilenTarih = tarih;
              _degisiklikVar = false;
            });
            await _mevcutKaydiYukleYaDaTemizle();
          }
        } else if (sonuc == 'beklet' && mounted) {
          await FirebaseFirestore.instance
              .collection('subeler')
              .doc(widget.subeKodu)
              .collection('bekleyen_transferler')
              .doc('ret_beklet_$transferId')
              .set({
            'kategori': 'RET',
            'hedefSubeAd': retHedefAd,
            'tutar': retTutar,
            'tarih': retTarih,
            'transferId': transferId,
            'bekletildi': true,
            'zaman': FieldValue.serverTimestamp(),
          });
          setState(() => _bekleyenTransferSayisi++);
        } else if (sonuc == 'tamam' && mounted) {
          // Reddedildi olarak Firestore'a yaz
          bool eslesti = false;
          setState(() {
            for (final t in _transferler) {
              if ((t['transferId'] as String? ?? '') == transferId) {
                t['reddedildi'] = true;
                t['onaylandi'] = false;
                t['bekletildi'] = false;
                t['gonderildi'] = false;
                eslesti = true;
              }
            }
          });
          if (eslesti) {
            await _transferKaydet();
          } else if (retTarih.isNotEmpty) {
            try {
              final gunRef = FirebaseFirestore.instance
                  .collection('subeler')
                  .doc(widget.subeKodu)
                  .collection('gunluk')
                  .doc(retTarih);
              final gunDoc = await gunRef.get();
              if (gunDoc.exists) {
                final transferler =
                    (gunDoc.data()?['transferler'] as List?)?.cast<Map>() ?? [];
                final guncel = transferler.map((t) {
                  if ((t['transferId'] as String? ?? '') == transferId) {
                    return {
                      ...t,
                      'reddedildi': true,
                      'onaylandi': false,
                      'bekletildi': false,
                      'gonderildi': false,
                    };
                  }
                  return t;
                }).toList();
                await gunRef.update({'transferler': guncel});
              }
            } catch (e) {
              if (mounted) _appBarMesajGoster('✗ Kayıt hatası');
            }
          }
        }
      }
    } catch (_) {
    } finally {
      _bildirimIsleniyor = false;
    }
  }

  // Onaylanan transferi günlük kayda ekle
  Future<void> _transferiKaydeEkle(
    String docId,
    Map<String, dynamic> transferData,
  ) async {
    try {
      final transferTarih =
          transferData['tarih'] as String? ?? _tarihKey(_secilenTarih);
      final subeRef = FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .doc(transferTarih);

      final mevcutKayit = await subeRef.get();
      List<Map<String, dynamic>> transferler = [];
      final gunuKapatilmisti =
          mevcutKayit.exists && mevcutKayit.data()?['tamamlandi'] == true;

      if (mevcutKayit.exists) {
        transferler =
            ((mevcutKayit.data()?['transferler'] as List?)?.cast<Map>() ?? [])
                .map((t) => Map<String, dynamic>.from(t))
                .toList();
      }

      // gidecegiKategori varsa onu kullan (manuelGelen durumunda GİDEN),
      // yoksa standart GELEN
      final kayitKategori =
          (transferData['gidecegiKategori'] as String?)?.isNotEmpty == true
              ? transferData['gidecegiKategori'] as String
              : 'GELEN';
      final manuelGelen = transferData['manuelGelen'] == true;

      // Duplicate kontrolü — transferId bazlı (güvenilir)
      final aciklamaKisa = (transferData['aciklama'] ?? '')
          .toString()
          .replaceAll(RegExp(r'[^a-zA-Z0-9ğüşıöçĞÜŞİÖÇ]'), '_');
      final onayDocId = '${transferTarih}_${transferData['kaynakSube']}_'
          '${widget.subeKodu}_${transferData['tutar']}_$aciklamaKisa';

      final transferIdStr = transferData['transferId'] as String? ?? '';
      final zatenEkli = transferler.any(
        (t) =>
            (t['onayDocId'] as String? ?? '') == onayDocId ||
            (transferIdStr.isNotEmpty &&
                (t['transferId'] as String? ?? '') == transferIdStr),
      );

      if (!zatenEkli) {
        if (kayitKategori == 'GİDEN') {
          // Bnin GİDEN kaydı: B → A yönünde
          transferler.add({
            'kategori': 'GİDEN',
            'hedefSube': transferData['hedefSube'] ?? widget.subeKodu,
            'hedefSubeAd': transferData['hedefSubeAd'] ??
                _subeAdlari[widget.subeKodu] ??
                widget.subeKodu,
            'kaynakSube': widget.subeKodu,
            'kaynakSubeAd': _subeAdlari[widget.subeKodu] ?? widget.subeKodu,
            'aciklama': transferData['aciklama'] ?? '',
            'tutar': transferData['tutar'] ?? 0,
            'gonderildi': true,
            'onaylandi': true,
            'onayDocId': onayDocId,
            'transferId': transferData['transferId'] ?? '',
          });
        } else {
          transferler.add({
            'kategori': 'GELEN',
            'kaynakSube': transferData['kaynakSube'] ?? '',
            'kaynakSubeAd': transferData['kaynakSubeAd'] ?? '',
            'hedefSube': widget.subeKodu,
            'hedefSubeAd': _subeAdlari[widget.subeKodu] ?? widget.subeKodu,
            'aciklama': transferData['aciklama'] ?? '',
            'tutar': transferData['tutar'] ?? 0,
            'gonderildi': true,
            'onaylandi': true,
            'onayDocId': onayDocId,
            'transferId': transferData['transferId'] ?? '',
          });
        }
      }

      if (mevcutKayit.exists) {
        await subeRef.update({
          'transferler': transferler,
          if (gunuKapatilmisti) 'tamamlandi': true,
        });
      } else {
        await subeRef.set({
          'transferler': transferler,
          'tarih': transferTarih,
          'subeKodu': widget.subeKodu,
        }, SetOptions(merge: true));
      }

      // Bekleyen transferi sil
      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('bekleyen_transferler')
          .doc(docId)
          .delete();

      // Gönderen şubeye ONAY_BILDIRIMI
      // manuelGelen: Anın eklediği GELEN → bildirim Aya (hedefSube) gider
      // normal GİDEN: bildirim Aya (kaynakSube) gider
      final transferId = transferData['transferId'] as String? ?? '';
      final bildirimAlacakSube = manuelGelen
          ? (transferData['hedefSube'] as String? ?? '')
          : (transferData['kaynakSube'] as String? ?? '');
      if (bildirimAlacakSube.isNotEmpty) {
        final buSubeAd = _subeAdlari[widget.subeKodu] ?? widget.subeKodu;
        final bildirimId = transferId.isNotEmpty ? 'onay_$transferId' : null;
        final bildirimRef = bildirimId != null
            ? FirebaseFirestore.instance
                .collection('subeler')
                .doc(bildirimAlacakSube)
                .collection('bekleyen_transferler')
                .doc(bildirimId)
            : FirebaseFirestore.instance
                .collection('subeler')
                .doc(bildirimAlacakSube)
                .collection('bekleyen_transferler')
                .doc();
        await bildirimRef.set({
          'kategori': 'ONAY_BILDIRIMI',
          'kaynakSubeAd': buSubeAd,
          'kaynakSube': widget.subeKodu,
          'transferId': transferId,
          'tutar': transferData['tutar'] ?? 0,
          'aciklama': transferData['aciklama'] ?? '',
          'tarih': transferTarih,
          'olusturmaTarihi': FieldValue.serverTimestamp(),
        });
      }

      // Formu güncelle — o günü görüntülüyorsak listeye ekle veya güncelle
      final aktifTarihKey = _tarihKey(_secilenTarih);
      if (aktifTarihKey == transferTarih) {
        // transferId ile eşleşen mevcut kayıt varsa güncelle (hem A hem B için)
        final mevcutIdx = transferIdStr.isNotEmpty
            ? _transferler.indexWhere(
                (t) => (t['transferId'] as String? ?? '') == transferIdStr,
              )
            : -1;

        if (mevcutIdx >= 0) {
          // Mevcut kaydı onaylandı olarak güncelle
          setState(() {
            _transferler[mevcutIdx]['onaylandi'] = true;
            _transferler[mevcutIdx]['reddedildi'] = false;
            _transferler[mevcutIdx]['bekletildi'] = false;
            _transferler[mevcutIdx]['onayDocId'] = onayDocId;
            if (_bekleyenTransferSayisi > 0) _bekleyenTransferSayisi--;
            _degisiklikVar = false;
          });
        } else if (!zatenEkli) {
          // Formda yok, Firestoreda da yok — yeni ekle
          setState(() {
            if (kayitKategori == 'GİDEN') {
              _transferler.add({
                'kategori': 'GİDEN',
                'hedefSube': transferData['hedefSube'] ?? '',
                'hedefSubeAd': transferData['hedefSubeAd'] ??
                    _subeAdlari[transferData['hedefSube'] ?? ''] ??
                    '',
                'kaynakSube': widget.subeKodu,
                'kaynakSubeAd': _subeAdlari[widget.subeKodu] ?? widget.subeKodu,
                'aciklamaCtrl': TextEditingController(
                  text: transferData['aciklama'] as String? ?? '',
                ),
                'tutarCtrl': TextEditingController(
                  text: _sifirTemizle(transferData['tutar']),
                ),
                'gonderildi': true,
                'onaylandi': true,
                'reddedildi': false,
                'bekletildi': false,
                'transferId': transferIdStr,
                'onayDocId': onayDocId,
              });
            } else {
              _transferler.add({
                'kategori': 'GELEN',
                'kaynakSube': transferData['kaynakSube'] ?? '',
                'kaynakSubeAd': transferData['kaynakSubeAd'] ?? '',
                'hedefSube': widget.subeKodu,
                'hedefSubeAd': _subeAdlari[widget.subeKodu] ?? widget.subeKodu,
                'aciklamaCtrl': TextEditingController(
                  text: transferData['aciklama'] as String? ?? '',
                ),
                'tutarCtrl': TextEditingController(
                  text: _sifirTemizle(transferData['tutar']),
                ),
                'gonderildi': true,
                'onaylandi': true,
                'reddedildi': false,
                'bekletildi': false,
                'transferId': transferIdStr,
                'onayDocId': onayDocId,
              });
            }
            if (_bekleyenTransferSayisi > 0) _bekleyenTransferSayisi--;
            _degisiklikVar = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Transfer eklenirken hata: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Reddedilen transferi işle
  // B şubesi red edince: bekleyen_transferlerdan sil, B'nin günlük kaydına reddedildi olarak ekle
  Future<void> _transferiReddetVeKaydet(
    String docId,
    Map<String, dynamic> transferData, {
    String transferId = '',
  }) async {
    try {
      final tarihKey =
          transferData['tarih'] as String? ?? _tarihKey(_secilenTarih);
      final kaynakSube = transferData['kaynakSube'] as String? ?? '';
      final kaynakSubeAd = transferData['kaynakSubeAd'] as String? ?? '';
      final tutar = (transferData['tutar'] as num? ?? 0).toDouble();
      final aciklama = transferData['aciklama'] as String? ?? '';
      final manuelGelen = transferData['manuelGelen'] == true;

      // B'nin günlük kaydına reddedildi transferi ekle
      final subeRef = FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .doc(tarihKey);

      final mevcut = await subeRef.get();
      final mevcutTransferler = mevcut.exists
          ? (mevcut.data()?['transferler'] as List?)?.cast<Map>() ?? []
          : [];

      // Aynı transferId zaten eklenmişse ekleme
      final zatenVar = mevcutTransferler.any(
        (t) => (t['transferId'] as String? ?? '') == transferId,
      );

      if (!zatenVar) {
        final yeniTransfer = {
          'kategori': manuelGelen ? 'GİDEN' : 'GELEN',
          'kaynakSube': kaynakSube,
          'kaynakSubeAd': kaynakSubeAd,
          'hedefSube': widget.subeKodu,
          'hedefSubeAd': _subeAdlari[widget.subeKodu] ?? widget.subeKodu,
          'aciklama': aciklama,
          'tutar': tutar,
          'gonderildi': true,
          'onaylandi': false,
          'reddedildi': true,
          'bekletildi': false,
          'transferId': transferId,
          'onayDocId': '',
        };
        final guncelTransferler = [...mevcutTransferler, yeniTransfer];
        if (mevcut.exists) {
          await subeRef.update({'transferler': guncelTransferler});
        } else {
          await subeRef.set({
            'tarih': tarihKey,
            'subeKodu': widget.subeKodu,
            'transferler': guncelTransferler,
          }, SetOptions(merge: true));
        }
      }

      // Bekleyen transferi sil
      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('bekleyen_transferler')
          .doc(docId)
          .delete();

      // A'ya RET bildirimi gönder
      final bildirimAlacakSube = manuelGelen
          ? (transferData['hedefSube'] as String? ?? '')
          : kaynakSube;

      if (bildirimAlacakSube.isNotEmpty) {
        final retId = transferId.isNotEmpty ? 'ret_$transferId' : null;
        final retRef = retId != null
            ? FirebaseFirestore.instance
                .collection('subeler')
                .doc(bildirimAlacakSube)
                .collection('bekleyen_transferler')
                .doc(retId)
            : FirebaseFirestore.instance
                .collection('subeler')
                .doc(bildirimAlacakSube)
                .collection('bekleyen_transferler')
                .doc();
        await retRef.set({
          'kategori': 'RET',
          'hedefSube': widget.subeKodu,
          'hedefSubeAd': _subeAdlari[widget.subeKodu] ?? widget.subeKodu,
          'aciklama': aciklama,
          'tutar': tutar,
          'tarih': tarihKey,
          'transferId': transferId,
          'zaman': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) {
        setState(() {
          if (_bekleyenTransferSayisi > 0) _bekleyenTransferSayisi--;
        });
      }
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  Future<void> _transferiReddet(
    String docId,
    Map<String, dynamic> transferData, {
    String transferId = '',
  }) async {
    try {
      // Bekleyen transferi sil
      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('bekleyen_transferler')
          .doc(docId)
          .delete();

      // Bildirimi alacak şube:
      // manuelGelen: Anın eklediği GELEN → bildirim Aya (hedefSube) gider
      // normal: bildirim gönderen şubeye (kaynakSube) gider
      final manuelGelen = transferData['manuelGelen'] == true;
      final bildirimAlacakSube = manuelGelen
          ? (transferData['hedefSube'] as String? ?? '')
          : (transferData['kaynakSube'] as String? ?? '');

      if (bildirimAlacakSube.isNotEmpty) {
        final retId = transferId.isNotEmpty ? 'ret_$transferId' : null;
        final retRef = retId != null
            ? FirebaseFirestore.instance
                .collection('subeler')
                .doc(bildirimAlacakSube)
                .collection('bekleyen_transferler')
                .doc(retId)
            : FirebaseFirestore.instance
                .collection('subeler')
                .doc(bildirimAlacakSube)
                .collection('bekleyen_transferler')
                .doc();
        await retRef.set({
          'kategori': 'RET',
          'hedefSube': widget.subeKodu,
          'hedefSubeAd': _subeAdlari[widget.subeKodu] ?? widget.subeKodu,
          'aciklama': transferData['aciklama'] ?? '',
          'tutar': transferData['tutar'] ?? 0,
          'tarih': transferData['tarih'] ?? _tarihKey(_secilenTarih),
          'transferId': transferId,
          'zaman': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) {
        setState(() {
          if (_bekleyenTransferSayisi > 0) _bekleyenTransferSayisi--;
        });
      }
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  void _mevcutKaydiYukle(Map<String, dynamic> data) {
    final bugun = _bugunuHesapla();
    final bugunMu = _secilenTarih.year == bugun.year &&
        _secilenTarih.month == bugun.month &&
        _secilenTarih.day == bugun.day;
    // tamamlandi alanı yoksa: zorunlu alanların tümü doluysa kapatılmış say
    bool _zorunluDolu(Map<String, dynamic> d) {
      final ekrandaNakit = (d['ekrandaGorunenNakit'] as num? ?? 0).toDouble();
      final gunlukSatis = (d['gunlukSatisToplami'] as num? ?? 0).toDouble();
      final sistemPos = (d['sistemPos'] ?? '').toString().trim();
      final toplamPos = (d['toplamPos'] as num? ?? 0).toDouble();
      final nakitTL = (d['toplamNakitTL'] as num? ?? 0).toDouble();
      return ekrandaNakit > 0 &&
          gunlukSatis > 0 &&
          sistemPos.isNotEmpty &&
          toplamPos > 0 &&
          nakitTL > 0;
    }

    final tamamlandi = data.containsKey('tamamlandi')
        ? data['tamamlandi'] == true
        : !bugunMu && _zorunluDolu(data);
    // _duzenlemeAcik sadece "Düzenlemeyi Aç" butonuyla set edilir.
    // Kapatılmamış geçmiş gün normal durum — _duzenlemeAcik false kalır,
    // _gunuKapatildi false olduğu için zaten düzenlenebilir.
    final yonetici = widget.gecmisGunHakki == -1;
    setState(() {
      _gunuKapatildi = tamamlandi;
      _duzenlemeAcik = false; // Sadece "Düzenlemeyi Aç" butonuyla açılır
      // Flot sınırı — günlük kayıttan oku, yoksa mevcut değeri koru
      final kayitliFlotSiniri = data['flotSiniri'] as int?;
      if (kayitliFlotSiniri != null) _flotSiniri = kayitliFlotSiniri;
      // POS
      for (var p in _posListesi) p.dispose();
      _posListesi.clear();
      final posList = (data['posListesi'] as List?)?.cast<Map>() ?? [];
      if (posList.isEmpty) {
        final yeniPos = PosGirisi(ad: 'POS 1');
        _posListesi.add(yeniPos);
        _pulseCtrlBagla(yeniPos.tutarCtrl);
      } else {
        for (var p in posList) {
          final tutar = p['tutar'];
          final yeniPos = PosGirisi(
            ad: p['ad'] ?? '',
            tutar: _sifirTemizle(tutar),
          );
          _posListesi.add(yeniPos);
          _pulseCtrlBagla(yeniPos.tutarCtrl);
        }
      }
      _sistemPosCtrl.text = _sifirTemizle(data['sistemPos']);
      // Yemek Kartları
      for (var y in _yemekKartlari) y.dispose();
      _yemekKartlari.clear();
      final yemekList = (data['yemekKartlari'] as List?)?.cast<Map>() ?? [];
      if (yemekList.isEmpty && _yemekKartiCinsleri.isNotEmpty) {
        final yeniYemek = YemekKartiGirisi(cins: _yemekKartiCinsleri.first);
        _yemekKartlari.add(yeniYemek);
        _pulseCtrlBagla(yeniYemek.tutarCtrl);
      } else {
        for (var y in yemekList) {
          final yeniYemek = YemekKartiGirisi(
            cins: y['cins'] as String? ?? '',
            tutar: _sifirTemizle(y['tutar']),
          );
          _yemekKartlari.add(yeniYemek);
          _pulseCtrlBagla(yeniYemek.tutarCtrl);
        }
      }
      final sistemYemek = data['sistemYemekKartlari'] as Map?;
      for (var c in _yemekKartiCinsleri) {
        _sistemYemekKartiCtrl[c] ??= TextEditingController();
        _sistemYemekKartiCtrl[c]!.text = _sifirTemizle(sistemYemek?[c]);
      }
      _gunlukSatisCtrl.text = _sifirTemizle(data['gunlukSatisToplami']);

      // Pulse kıyas verileri yükle — önce temizle (eski tarih kalıntısı önle)
      for (var c in _pulseKiyasCtrl.values) c.clear();
      for (var c in _myDomKiyasCtrl.values) c.clear();
      // Otomatik okuma verilerini temizle
      _myDominosOkunan.clear();
      final pulseKiyas =
          (data['pulseKiyasVerileri'] as Map<String, dynamic>?) ?? {};
      for (var e in pulseKiyas.entries) {
        _pulseKiyasCtrl.putIfAbsent(e.key, () => TextEditingController());
        _pulseKiyasCtrl[e.key]!.text = e.value.toString();
      }
      // My Dominos kıyas verileri yükle
      final myDomKiyas =
          (data['myDomKiyasVerileri'] as Map<String, dynamic>?) ?? {};
      _pulseKontrolOnaylandi = data['pulseKontrolOnaylandi'] == true;
      _pulseOkundu = data['pulseResmiOkundu'] == true;
      _myDomOkundu = data['myDomResmiOkundu'] == true;
      _posKontrolOnaylandi = data['posKontrolOnaylandi'] == true;
      _posOkundu = data['posResmiOkundu'] == true;
      for (var e in myDomKiyas.entries) {
        _myDomKiyasCtrl.putIfAbsent(e.key, () => TextEditingController());
        _myDomKiyasCtrl[e.key]!.text = e.value.toString();
        // FIX: Resim daha önce okunmuşsa _myDominosOkunan'ı da doldur.
        // Tarih değiştirince _myDominosOkunan temizleniyor ama _myDomOkundu=true
        // kalıyordu; eşleştirme mantığı containsKey false bulup yanlış daldan
        // hesaplıyordu. Flag'ı önce set edip buraya yazarak tutarlılık sağlanır.
        if (_myDomOkundu) {
          _myDominosOkunan[e.key] = _parseDouble(e.value.toString());
        }
      }
      if (myDomKiyas.isNotEmpty) _myDominosYuklendi = true;
      // Yeni yüklenen ctrl'lere listener bağla
      for (var c in _pulseKiyasCtrl.values) _pulseCtrlBagla(c);
      for (var c in _myDomKiyasCtrl.values) _pulseCtrlBagla(c);
      // Online ödemeler
      final onlineList = (data['onlineOdemeler'] as List?)?.cast<Map>() ?? [];
      for (var o in _onlineOdemeler) {
        final kayitli = onlineList.firstWhere(
          (k) => k['ad'] == o['ad'],
          orElse: () => {},
        );
        (o['ctrl'] as TextEditingController).text = _sifirTemizle(
          kayitli['tutar'],
        );
      }

      // Harcamalar
      for (var h in _harcamalar) h.dispose();
      _harcamalar.clear();
      final harcList = (data['harcamalar'] as List?)?.cast<Map>() ?? [];
      if (harcList.isEmpty) {
        _harcamalar.add(HarcamaGirisi());
      } else {
        for (var h in harcList) {
          _harcamalar.add(
            HarcamaGirisi(
              aciklama: h['aciklama'] ?? '',
              tutar: _sifirTemizle(h['tutar']),
            ),
          );
        }
      }

      // Nakit sayım
      for (var c in _banknotCtrl.values) c.clear();
      final banknotlar = data['banknotlar'] as Map?;
      if (banknotlar != null) {
        for (var b in _banknotlar) {
          final adet = banknotlar[b.toString()];
          if (adet != null && adet != 0) {
            _banknotCtrl[b]!.text = adet.toString();
          }
        }
      }
      _manuelFlotCtrl.text = _sifirTemizle(data['manuelFlot']);

      // Ek bilgiler
      _devredenFlotCtrl.text = _sifirTemizle(data['devredenFlot']);
      _otomatikDevredenFlot = (data['devredenFlot'] ?? 0).toDouble();
      _ekrandaGorunenNakitCtrl.text = _sifirTemizle(
        data['ekrandaGorunenNakit'],
      );
      _oncekiAnaKasaKalani = (data['oncekiAnaKasaKalani'] ?? 0).toDouble();

      // Ana kasa harcamaları
      for (var h in _anaKasaHarcamalari) h.dispose();
      _anaKasaHarcamalari.clear();
      final anaHarcList =
          (data['anaKasaHarcamalari'] as List?)?.cast<Map>() ?? [];
      if (anaHarcList.isEmpty) {
        _anaKasaHarcamalari.add(HarcamaGirisi());
      } else {
        for (var h in anaHarcList) {
          _anaKasaHarcamalari.add(
            HarcamaGirisi(
              aciklama: h['aciklama'] ?? '',
              tutar: _sifirTemizle(h['tutar']),
            ),
          );
        }
      }
      _bankayaYatiranCtrl.text = _sifirTemizle(data['bankayaYatirilan']);

      // Nakit Çıkışlar
      for (var h in _nakitCikislar) h.dispose();
      _nakitCikislar.clear();
      final nakitList = (data['nakitCikislar'] as List?)?.cast<Map>() ?? [];
      if (nakitList.isEmpty) {
        _nakitCikislar.add(HarcamaGirisi());
      } else {
        for (var h in nakitList) {
          _nakitCikislar.add(
            HarcamaGirisi(
              aciklama: h['aciklama'] ?? '',
              tutar: _sifirTemizle(h['tutar']),
            ),
          );
        }
      }
      // Nakit Çıkış dövizler
      for (var d in _nakitDovizler) {
        (d['ctrl'] as TextEditingController).dispose();
        (d['aciklamaCtrl'] as TextEditingController?)?.dispose();
      }
      _nakitDovizler.clear();
      final nakitDovizList =
          (data['nakitDovizler'] as List?)?.cast<Map>() ?? [];
      for (var d in nakitDovizList) {
        final miktar = d['miktar'];
        if (miktar != null && miktar != 0) {
          _nakitDovizler.add({
            'cins': d['cins'] ?? 'USD',
            'ctrl': TextEditingController(text: _sifirTemizle(miktar)),
            'aciklamaCtrl': TextEditingController(
              text: d['aciklama'] as String? ?? '',
            ),
          });
        }
      }

      // Dövizleri yükle
      for (var d in _dovizler) {
        (d['miktarCtrl'] as TextEditingController).dispose();
        (d['kurCtrl'] as TextEditingController).dispose();
      }
      _dovizler.clear();
      final dovizList = (data['dovizler'] as List?)?.cast<Map>() ?? [];
      for (var d in dovizList) {
        final miktar = d['miktar'];
        final kur = d['kur'];
        if (miktar != null && miktar != 0) {
          _dovizler.add({
            'cins': d['cins'] ?? 'USD',
            'miktarCtrl': TextEditingController(text: _sifirTemizle(miktar)),
            'kurCtrl': TextEditingController(text: _sifirTemizle(kur)),
          });
        }
      }

      // Döviz bankaya yatırılan — yeni format (List) önce, eski format (Map) fallback
      for (var d in _bankaDovizler) {
        (d['ctrl'] as TextEditingController).dispose();
      }
      _bankaDovizler.clear();
      final bankaDovizList =
          (data['bankaDovizler'] as List?)?.cast<Map>() ?? [];
      if (bankaDovizList.isNotEmpty) {
        // Yeni format
        for (var d in bankaDovizList) {
          final cins = d['cins'] as String? ?? 'USD';
          final miktar = d['miktar'];
          _bankaDovizler.add({
            'cins': cins,
            'ctrl': TextEditingController(text: _sifirTemizle(miktar)),
          });
        }
      } else {
        // Eski format fallback
        final dovizBanka = data['dovizBankayaYatirilan'] as Map?;
        for (var t in _dovizTurleri) {
          _dovizBankayaYatiranCtrl[t]!.text = _sifirTemizle(dovizBanka?[t]);
        }
      }
      // Döviz devreden = o günün kaydındaki oncekiDovizAnaKasaKalanlari
      // TL mantığıyla aynı: alan varsa kullan, yoksa 0
      final oncekiDovizKalanlar = data['oncekiDovizAnaKasaKalanlari'] as Map?;
      for (var t in _dovizTurleri) {
        _devredenDovizMiktarlari[t] = (oncekiDovizKalanlar?[t] ?? 0).toDouble();
      }

      // Transferler
      for (var t in _transferler) {
        (t['aciklamaCtrl'] as TextEditingController).dispose();
        (t['tutarCtrl'] as TextEditingController).dispose();
      }
      _transferler.clear();
      final transferList = (data['transferler'] as List?)?.cast<Map>() ?? [];
      for (var t in transferList) {
        _transferler.add({
          'kategori': t['kategori'] ?? 'GİDEN',
          'hedefSube': t['hedefSube'] ?? '',
          'hedefSubeAd': t['hedefSubeAd'] ?? '',
          'kaynakSube': t['kaynakSube'] ?? '',
          'kaynakSubeAd': t['kaynakSubeAd'] ?? '',
          'aciklamaCtrl': TextEditingController(text: t['aciklama'] ?? ''),
          'tutarCtrl': TextEditingController(text: _sifirTemizle(t['tutar'])),
          'gonderildi': t['gonderildi'] ?? false,
          'onaylandi': t['onaylandi'] ?? t['otomatik'] ?? false,
          'reddedildi': t['reddedildi'] ?? false,
          'bekletildi': t['bekletildi'] ?? false,
          'transferId': t['transferId'] ?? '',
          'onayDocId': t['onayDocId'] ?? '',
        });
      }

      // Diğer Alımlar
      for (var t in _digerAlimlar) {
        (t['aciklamaCtrl'] as TextEditingController).dispose();
        (t['tutarCtrl'] as TextEditingController).dispose();
      }
      _digerAlimlar.clear();
      final digerList = (data['digerAlimlar'] as List?)?.cast<Map>() ?? [];
      for (var t in digerList) {
        _digerAlimlar.add({
          'aciklamaCtrl': TextEditingController(text: t['aciklama'] ?? ''),
          'tutarCtrl': TextEditingController(text: _sifirTemizle(t['tutar'])),
        });
      }
    });
  }

  String _sifirTemizle(dynamic val) {
    if (val == null || val == 0 || val == 0.0) return '';
    final double d = (val as num).toDouble();
    // Bin ayraçlı formata çevir: 3.250,00 → ama virgülden sonraki sıfırları temizle
    final parts = d.toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final decPart = parts[1];
    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write('.');
      buffer.write(intPart[i]);
    }
    // Ondalık kısım sıfırsa sadece tam sayı göster
    if (decPart == '00') return buffer.toString();
    return '${buffer.toString()},$decPart';
  }

  // ── Aktif sekmeyi temizle ───────────────────────────────────────────────────
  Future<void> _aktifSekmeTemizle() async {
    final sekme = _tabController.index;
    setState(() {
      switch (sekme) {
        case 0: // POS & Y. Kartı
          for (var p in _posListesi) p.dispose();
          _posListesi.clear();
          _posListesi.add(PosGirisi(ad: 'POS 1'));
          _sistemPosCtrl.clear();
          for (var y in _yemekKartlari) y.dispose();
          _yemekKartlari.clear();
          if (_yemekKartiCinsleri.isNotEmpty)
            _yemekKartlari.add(
              YemekKartiGirisi(cins: _yemekKartiCinsleri.first),
            );
          for (var c in _sistemYemekKartiCtrl.values) c.clear();
          for (var o in _onlineOdemeler)
            (o['ctrl'] as TextEditingController).clear();
          _gunlukSatisCtrl.clear();
          _posOkundu = false;
          _posKontrolOnaylandi = false;
          break;
        case 1: // Pulse / My Dom.
          for (var c in _pulseKiyasCtrl.values) c.clear();
          for (var c in _myDomKiyasCtrl.values) c.clear();
          _myDominosOkunan.clear();
          _myDominosYuklendi = false;
          _pulseOkundu = false;
          _myDomOkundu = false;
          _pulseKontrolOnaylandi = false;
          _okumaMesaji = '';
          _pulseBankaParasi = 0;
          break;
        case 2: // Günlük Kasa
          for (var h in _harcamalar) h.dispose();
          _harcamalar.clear();
          _harcamalar.add(HarcamaGirisi());
          for (var c in _banknotCtrl.values) c.clear();
          _manuelFlotCtrl.clear();
          _ekrandaGorunenNakitCtrl.clear();
          for (var d in _dovizler) {
            (d['miktarCtrl'] as TextEditingController).dispose();
            (d['kurCtrl'] as TextEditingController).dispose();
          }
          _dovizler.clear();
          for (var c in _dovizBankayaYatiranCtrl.values) c.clear();
          break;
        case 3: // Ana Kasa
          for (var h in _anaKasaHarcamalari) h.dispose();
          _anaKasaHarcamalari.clear();
          _anaKasaHarcamalari.add(HarcamaGirisi());
          for (var h in _nakitCikislar) h.dispose();
          _nakitCikislar.clear();
          _nakitCikislar.add(HarcamaGirisi());
          for (var d in _nakitDovizler) {
            (d['ctrl'] as TextEditingController).dispose();
            (d['aciklamaCtrl'] as TextEditingController?)?.dispose();
          }
          _nakitDovizler.clear();
          for (var d in _bankaDovizler)
            (d['ctrl'] as TextEditingController).dispose();
          _bankaDovizler.clear();
          _bankayaYatiranCtrl.clear();
          break;
        case 4: // Transfer / D. Alım
          for (var t in _transferler) {
            (t['aciklamaCtrl'] as TextEditingController).dispose();
            (t['tutarCtrl'] as TextEditingController).dispose();
          }
          _transferler.clear();
          for (var t in _digerAlimlar) {
            (t['aciklamaCtrl'] as TextEditingController).dispose();
            (t['tutarCtrl'] as TextEditingController).dispose();
          }
          _digerAlimlar.clear();
          break;
        case 5: // Özet & Kapat — temizlenecek veri yok
          break;
      }
      _degisiklikVar = true;
    });
  }

  static const _sekmeAdlari = [
    'POS & Y. Kartı',
    'Pulse / My Dom.',
    'Günlük Kasa',
    'Ana Kasa',
    'Transfer/D. Alım',
    'Özet & Kapat',
  ];

  Future<void> _formlariTemizle() async {
    final bugun = _bugunuHesapla();
    final bugunMu = _secilenTarih.year == bugun.year &&
        _secilenTarih.month == bugun.month &&
        _secilenTarih.day == bugun.day;
    setState(() {
      _gunuKapatildi = false; // Kayıt yok = kapatılmamış, veri girilebilir
      _duzenlemeAcik = false;
      for (var p in _posListesi) p.dispose();
      _posListesi.clear();
      _posListesi.add(PosGirisi(ad: 'POS 1'));
      _sistemPosCtrl.clear();
      for (var y in _yemekKartlari) y.dispose();
      _yemekKartlari.clear();
      if (_yemekKartiCinsleri.isNotEmpty) {
        _yemekKartlari.add(YemekKartiGirisi(cins: _yemekKartiCinsleri.first));
      }
      for (var c in _sistemYemekKartiCtrl.values) c.clear();
      for (var o in _onlineOdemeler) {
        (o['ctrl'] as TextEditingController).clear();
      }
      _gunlukSatisCtrl.clear();
      // Pulse ve MyDom kıyas verilerini temizle
      for (var c in _pulseKiyasCtrl.values) c.clear();
      for (var c in _myDomKiyasCtrl.values) c.clear();
      _myDominosOkunan.clear();
      _myDominosYuklendi = false;
      _pulseOkundu = false;
      _myDomOkundu = false;
      _pulseKontrolOnaylandi = false;
      _posOkundu = false;
      _posKontrolOnaylandi = false;
      _okumaMesaji = '';
      _pulseBankaParasi = 0;

      for (var h in _harcamalar) h.dispose();
      _harcamalar.clear();
      _harcamalar.add(HarcamaGirisi());

      for (var c in _banknotCtrl.values) c.clear();
      _manuelFlotCtrl.clear();
      _ekrandaGorunenNakitCtrl.clear();

      for (var d in _dovizler) {
        (d['miktarCtrl'] as TextEditingController).dispose();
        (d['kurCtrl'] as TextEditingController).dispose();
      }
      _dovizler.clear();
      for (var c in _dovizBankayaYatiranCtrl.values) c.clear();

      for (var h in _anaKasaHarcamalari) h.dispose();
      _anaKasaHarcamalari.clear();
      _anaKasaHarcamalari.add(HarcamaGirisi());
      for (var h in _nakitCikislar) h.dispose();
      _nakitCikislar.clear();
      _nakitCikislar.add(HarcamaGirisi());
      for (var d in _nakitDovizler) {
        (d['ctrl'] as TextEditingController).dispose();
        (d['aciklamaCtrl'] as TextEditingController?)?.dispose();
      }
      _nakitDovizler.clear();
      for (var d in _bankaDovizler) {
        (d['ctrl'] as TextEditingController).dispose();
      }
      _bankaDovizler.clear();
      for (var t in _transferler) {
        (t['aciklamaCtrl'] as TextEditingController).dispose();
        (t['tutarCtrl'] as TextEditingController).dispose();
      }
      _transferler.clear();
      for (var t in _digerAlimlar) {
        (t['aciklamaCtrl'] as TextEditingController).dispose();
        (t['tutarCtrl'] as TextEditingController).dispose();
      }
      _digerAlimlar.clear();
      _bankayaYatiranCtrl.clear();
      // Devreden Flot ve Ana Kasa korunur
    });

    // Firestoredaki transfer alanını da temizle
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      final subeRef = FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .doc(tarihKey);
      final mevcut = await subeRef.get();
      if (mevcut.exists) {
        await subeRef.update({'transferler': []});
      }
    } catch (e) {
      if (mounted) _appBarMesajGoster('✗ Kayıt hatası');
    }
  }

  Future<void> _oncekiGundenDovizYukle() async {
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      final kayitlar = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .where('tarih', isLessThan: tarihKey)
          .orderBy('tarih', descending: true)
          .limit(1)
          .get();

      if (kayitlar.docs.isNotEmpty) {
        final data = kayitlar.docs.first.data();
        final dovizKalanlar = data['dovizAnaKasaKalanlari'] as Map?;
        final dovizAnaKasaMap = data['dovizAnaKasa'] as Map?;
        final dovizListesi = (data['dovizler'] as List?)?.cast<Map>() ?? [];

        setState(() {
          for (var t in _dovizTurleri) {
            if (dovizKalanlar != null && dovizKalanlar[t] != null) {
              _devredenDovizMiktarlari[t] =
                  (dovizKalanlar[t] as num).toDouble();
            } else if (dovizAnaKasaMap != null && dovizAnaKasaMap[t] != null) {
              _devredenDovizMiktarlari[t] =
                  (dovizAnaKasaMap[t] as num).toDouble();
            } else if (dovizListesi.isNotEmpty) {
              double toplamMiktar = 0;
              for (var d in dovizListesi) {
                if (d['cins'] == t) {
                  toplamMiktar += (d['miktar'] as num? ?? 0).toDouble();
                }
              }
              _devredenDovizMiktarlari[t] = toplamMiktar;
            } else {
              _devredenDovizMiktarlari[t] = 0;
            }
          }
        });
      } else {
        setState(() {
          for (var t in _dovizTurleri) {
            _devredenDovizMiktarlari[t] = 0;
          }
        });
      }
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  // Sadece devredenFlot ve oncekiAnaKasaKalanini bir önceki günden yükle
  // Kayıt varken de çağrılır — geçmiş gün düzenlemesi sonrası güncel değeri alır
  Future<void> _oncekiGundenFlotYukle() async {
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      final kayitlar = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .where('tarih', isLessThan: tarihKey)
          .orderBy('tarih', descending: true)
          .limit(1)
          .get();

      if (kayitlar.docs.isNotEmpty) {
        final data = kayitlar.docs.first.data();
        final flot = data['gunlukFlot'];
        final anaKasaKalani = data['anaKasaKalani'];
        if (mounted) {
          setState(() {
            if (flot != null) {
              final flotDeger = (flot as num).toDouble();
              _devredenFlotCtrl.text = _formatTL(
                flotDeger,
              ).replaceAll(' ₺', '');
              _otomatikDevredenFlot = flotDeger;
            }
            if (anaKasaKalani != null) {
              _oncekiAnaKasaKalani = (anaKasaKalani as num).toDouble();
            }
          });
        }
      }
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  Future<void> _oncekiGundenYukle() async {
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      final kayitlar = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .where('tarih', isLessThan: tarihKey)
          .orderBy('tarih', descending: true)
          .limit(3)
          .get();

      // Sadece kapatılmış günden devir al — kapatılmamış günü atla
      Map<String, dynamic>? kapatilmisGun;
      for (final doc in kayitlar.docs) {
        final tam = doc.data()['tamamlandi'];
        if (tam == true || tam == 1 || tam?.toString() == 'true') {
          kapatilmisGun = doc.data();
          break;
        }
      }

      if (kapatilmisGun != null) {
        final data = kapatilmisGun;
        final flot = data['gunlukFlot'];
        if (flot != null) {
          final flotDeger = (flot as num).toDouble();
          setState(() {
            _devredenFlotCtrl.text = _formatTL(flotDeger).replaceAll(' ₺', '');
            _otomatikDevredenFlot = flotDeger;
          });
        }
        final anaKasaKalani = data['anaKasaKalani'];
        if (anaKasaKalani != null) {
          setState(
            () => _oncekiAnaKasaKalani = (anaKasaKalani as num).toDouble(),
          );
        }
        // Döviz devreden
        final dovizKalanlar = data['dovizAnaKasaKalanlari'] as Map?;
        final dovizAnaKasaMap = data['dovizAnaKasa'] as Map?;
        final dovizListesi = (data['dovizler'] as List?)?.cast<Map>() ?? [];

        setState(() {
          for (var t in _dovizTurleri) {
            if (dovizKalanlar != null && dovizKalanlar[t] != null) {
              _devredenDovizMiktarlari[t] =
                  (dovizKalanlar[t] as num).toDouble();
            } else if (dovizAnaKasaMap != null && dovizAnaKasaMap[t] != null) {
              _devredenDovizMiktarlari[t] =
                  (dovizAnaKasaMap[t] as num).toDouble();
            } else if (dovizListesi.isNotEmpty) {
              double toplamMiktar = 0;
              for (var d in dovizListesi) {
                if (d['cins'] == t) {
                  toplamMiktar += (d['miktar'] as num? ?? 0).toDouble();
                }
              }
              _devredenDovizMiktarlari[t] = toplamMiktar;
            } else {
              _devredenDovizMiktarlari[t] = 0;
            }
          }
        });
      } else {
        setState(() {
          _devredenFlotCtrl.clear();
          _oncekiAnaKasaKalani = 0;
          for (var t in _dovizTurleri) {
            _devredenDovizMiktarlari[t] = 0;
          }
        });
      }
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  // ── Hesaplamalar ────────────────────────────────────────────────────────────

  // Banka Parası = Brüt Satış - Sonuç toplamları (Pulse/MyDom sekmesinden)
  double get _bankaParasi {
    // Pulse onaylanmamışsa Günlük Kasa ve Kasa Özeti'ne 0 aktar
    if (!_pulseKontrolOnaylandi) return 0;
    // Pulse sayfasında hesaplanan banka parasını kullan (Pulse verileri bazlı)
    if (_pulseBankaParasi != 0)
      return _pulseBankaParasi.clamp(0, double.infinity);
    // Pulse verisi yoksa program değerlerinden hesapla
    final brutSatis = _parseDouble(_gunlukSatisCtrl.text);
    if (brutSatis <= 0) return 0;
    double toplamSonuc = _toplamPos;
    for (var c in _yemekKartlari) {
      toplamSonuc += _parseDouble(c.tutarCtrl.text);
    }
    for (var o in _onlineOdemeler) {
      toplamSonuc += _parseDouble((o['ctrl'] as TextEditingController).text);
    }
    return (brutSatis - toplamSonuc).clamp(0, double.infinity);
  }

  double get _toplamPos {
    double t = 0;
    for (var p in _posListesi) t += _parseDouble(p.tutarCtrl.text);
    return t;
  }

  double get _posFarki => _toplamPos - _parseDouble(_sistemPosCtrl.text);

  // Yemek kartı cins renkleri
  static const List<Color> _yemekKartiRenkleri = [
    Color(0xFF6A1B9A), // mor
    Color(0xFF0288D1), // mavi
    Color(0xFF2E7D32), // yeşil
    Color(0xFFE65100), // turuncu
    Color(0xFF00838F), // teal
    Color(0xFFC62828), // kırmızı
  ];

  Color _yemekKartiRenk(String cins) {
    final idx = _yemekKartiCinsleri.indexOf(cins);
    if (idx < 0) return const Color(0xFF6A1B9A);
    return _yemekKartiRenkleri[idx % _yemekKartiRenkleri.length];
  }

  // Belirli bir yemek kartı cinsinin toplam tutarı
  double _yemekKartiCinsToplam(String cins) {
    double t = 0;
    for (var y in _yemekKartlari) {
      if (y.cins == cins) t += _parseDouble(y.tutarCtrl.text);
    }
    return t;
  }

  // Tüm yemek kartları genel toplamı
  double get _toplamYemekKarti {
    double t = 0;
    for (var y in _yemekKartlari) t += _parseDouble(y.tutarCtrl.text);
    return t;
  }

  // Ekranda Görünen Nakit otomatik hesaplama
  // Günlük Satış − POS − Yemek Kartı − Online Ödemeler
  double get _hesaplananNakit {
    final satis = _parseDouble(_gunlukSatisCtrl.text);
    if (satis <= 0) return 0;
    return satis - _toplamPos - _toplamYemekKarti - _toplamOnlineOdeme;
  }

  // Online ödemeler toplamı
  double get _toplamOnlineOdeme {
    double t = 0;
    for (var o in _onlineOdemeler) {
      t += _parseDouble((o['ctrl'] as TextEditingController).text);
    }
    return t;
  }

  // Yemek kartı farkı (cins bazlı)
  double _yemekKartiFarki(String cins) =>
      _yemekKartiCinsToplam(cins) -
      _parseDouble(_sistemYemekKartiCtrl[cins]?.text ?? '');

  double get _toplamHarcama {
    double t = 0;
    for (var h in _harcamalar) t += _parseDouble(h.tutarCtrl.text);
    return t;
  }

  double get _toplamNakitTL {
    double t = 0;
    for (var b in _banknotlar) t += b * _parseInt(_banknotCtrl[b]!.text);
    return t;
  }

  double get _toplamDovizTL {
    double t = 0;
    for (var d in _dovizler) {
      final miktar = _parseDouble(
        (d['miktarCtrl'] as TextEditingController).text,
      );
      final kur = _parseDouble((d['kurCtrl'] as TextEditingController).text);
      t += miktar * kur;
    }
    return t;
  }

  // Ana Kasa hesaplamalarında sadece TL nakit kullanılır
  double get _toplamNakit => _toplamNakitTL;

  double get _flotOtomatik {
    double t = 0;
    for (var b in _banknotlar) {
      if (b <= _flotSiniri) t += b * _parseInt(_banknotCtrl[b]!.text);
    }
    return t;
  }

  double get _flotTutari => _flotOtomatik + _parseDouble(_manuelFlotCtrl.text);

  double get _olmasiGereken =>
      _parseDouble(_ekrandaGorunenNakitCtrl.text) +
      _parseDouble(_devredenFlotCtrl.text) -
      _toplamHarcama;

  double get _kasaFarki => (_toplamNakitTL + _toplamDovizTL) - _olmasiGereken;

  // Günlük Kasa Kalanı = Olması Gereken + Kasa Farkı - Toplam Flot
  double get _gunlukKasaKalani => _olmasiGereken + _kasaFarki - _flotTutari;

  // Günlük Kasa Kalanı TL = Günlük Kasa Kalanı - Döviz TL Karşılığı
  double get _gunlukKasaKalaniTL => _gunlukKasaKalani - _toplamDovizTL;

  // Ana Kasa = Önceki TL Ana Kasa Kalanı + Günlük Kasa Kalanı TL
  double get _anaKasa => _oncekiAnaKasaKalani + _gunlukKasaKalaniTL;

  double get _toplamAnaKasaHarcama {
    double t = 0;
    for (var h in _anaKasaHarcamalari) t += _parseDouble(h.tutarCtrl.text);
    return t;
  }

  // Kaydet butonu için 4 zorunlu alan kontrolü
  bool get _kaydetButonuAktif {
    final yonetici = widget.gecmisGunHakki == -1;
    final temelKosullar = !_kaydediliyor &&
        !_dovizLimitiAsildi &&
        _internetVar &&
        _pulseKontrolOnaylandi &&
        _posKontrolOnaylandi &&
        _bankaParasi > 0 &&
        _gunlukSatisCtrl.text.isNotEmpty &&
        _parseDouble(_gunlukSatisCtrl.text) > 0 &&
        _toplamPos > 0 &&
        _toplamNakitTL > 0;
    if (!temelKosullar) return false;
    // Döviz eklenmiş ama kur girilmemiş → kapanışa engel (her zaman, yönetici dahil)
    final kurEksik = _dovizler.any((d) {
      final kur = _parseDouble((d['kurCtrl'] as TextEditingController).text);
      return kur <= 0;
    });
    if (kurEksik) return false;
    // Kullanıcı için limit kontrolleri — yönetici uyarı alır ama kapat yapabilir
    if (!yonetici) {
      if (_anaKasaLimitiAsildi) return false;
    }
    return true;
  }

  bool get _dovizLimitiAsildi {
    // Bankaya yatırılan döviz kasayı geçiyor mu?
    for (var d in _bankaDovizler) {
      final cins = d['cins'] as String;
      final girilen = _parseDouble((d['ctrl'] as TextEditingController).text);
      final maks = _dovizAnaKasa(cins);
      if (girilen > maks) return true;
    }
    // Döviz Ana Kasa kalanı eksi düşüyor mu?
    for (var t in _dovizTurleri) {
      if (_dovizAnaKasaKalani(t) < -0.01) return true;
    }
    return false;
  }

  double get _toplamNakitCikis {
    double t = 0;
    for (var h in _nakitCikislar) t += _parseDouble(h.tutarCtrl.text);
    return t;
  }

  double get _anaKasaKalani =>
      _anaKasa -
      _parseDouble(_bankayaYatiranCtrl.text) -
      _toplamAnaKasaHarcama -
      _toplamNakitCikis;

  // Kasa harcama limiti aşıldı mı?
  // Günlük harcamalar nakit TL'den fazla olamaz
  bool get _kasaHarcamaLimitiAsildi =>
      _toplamHarcama > _toplamNakitTL && _toplamNakitTL > 0;

  // Ana Kasa limiti aşıldı mı?
  // AK Harcama + Bankaya Yatan + Nakit Çıkış > Ana Kasa (önceki + günlük TL)
  bool get _anaKasaLimitiAsildi => _anaKasaKalani < 0;

  // Döviz Ana Kasa hesaplamaları
  double _buGunDovizMiktari(String cins) {
    double t = 0;
    for (var d in _dovizler) {
      if (d['cins'] == cins) {
        t += _parseDouble((d['miktarCtrl'] as TextEditingController).text);
      }
    }
    return t;
  }

  double _dovizAnaKasa(String cins) =>
      (_devredenDovizMiktarlari[cins] ?? 0) + _buGunDovizMiktari(cins);

  double _dovizBankayaYatirilan(String cins) {
    double toplam = 0;
    for (var d in _bankaDovizler) {
      if (d['cins'] == cins) {
        toplam += _parseDouble((d['ctrl'] as TextEditingController).text);
      }
    }
    return toplam;
  }

  double _nakitDovizCikis(String cins) {
    double t = 0;
    for (var d in _nakitDovizler) {
      if (d['cins'] == cins)
        t += _parseDouble((d['ctrl'] as TextEditingController).text);
    }
    return t;
  }

  double _dovizAnaKasaKalani(String cins) =>
      _dovizAnaKasa(cins) -
      _dovizBankayaYatirilan(cins) -
      _nakitDovizCikis(cins);

  // O günkü döviz için ortalama kur
  double _dovizKur(String cins) {
    double toplamTL = 0;
    double toplamMiktar = 0;
    for (var d in _dovizler) {
      if (d['cins'] == cins) {
        final miktar = _parseDouble(
          (d['miktarCtrl'] as TextEditingController).text,
        );
        final kur = _parseDouble((d['kurCtrl'] as TextEditingController).text);
        toplamTL += miktar * kur;
        toplamMiktar += miktar;
      }
    }
    if (toplamMiktar == 0) return 0;
    return toplamTL / toplamMiktar;
  }

  double _parseDouble(String s) =>
      double.tryParse(
        s.replaceAll(' ', '').replaceAll('.', '').replaceAll(',', '.'),
      ) ??
      0;
  int _parseInt(String s) => int.tryParse(s) ?? 0;
  String _formatTL(double val) {
    final parts = val.toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final decPart = parts[1];
    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write('.');
      buffer.write(intPart[i]);
    }
    return '${buffer.toString()},$decPart ₺';
  }

  String _tarihKey(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  String _tarihGoster(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';

  // ── Kaydet ─────────────────────────────────────────────────────────────────

  // ── Yönetici kilit zorla kaldır ─────────────────────────────────────────
  Future<void> _kilidiZorlaKaldir() async {
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('kilitler')
          .doc(tarihKey)
          .delete();
      if (mounted) setState(() => _kilitTutanKullanici = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kilit kaldırıldı'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (_) {
      /* sessiz — yükleme/işlem başarısız */
    }
  }

  Future<void> _kaydet() async {
    // ── Geçmiş gün düzenlemesinde değişiklik onayı ───────────────────────────
    // Düzenleme modu açıkken (_duzenlemeAcik) ve değişiklik yapıldıysa
    // (_degisiklikVar) kullanıcıdan onay al.
    if (_duzenlemeAcik && _gercekDegisiklikVar && mounted) {
      final tarihGoster = _tarihGoster(_secilenTarih);
      final onay = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Değişiklik Onayı'),
          content: Text(
            '$tarihGoster tarihli kayıtta değişiklik yaptınız.\n'
            'Günü kapatmak istiyor musunuz?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('İptal', style: TextStyle(color: Colors.red)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Onayla'),
            ),
          ],
        ),
      );
      if (onay != true) return; // İptal — kaydetme
    }
    // ─────────────────────────────────────────────────────────────────────────

    // ── Önceki kapanmış günle tutarsızlık kontrolü ───────────────────────────
    if (mounted) {
      try {
        final tarihKeyKontrol = _tarihKey(_secilenTarih);
        // Sadece bir önceki günü çek — composite index gerekmez
        final tumOnce = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(widget.subeKodu)
            .collection('gunluk')
            .where('tarih', isLessThan: tarihKeyKontrol)
            .orderBy('tarih', descending: true)
            .limit(1)
            .get();
        // Kapanmış mı kontrol et
        Map<String, dynamic>? od;
        for (final d in tumOnce.docs) {
          final tam = d.data()['tamamlandi'];
          if (tam == true || tam == 1 || tam?.toString() == 'true') {
            od = d.data();
            break;
          }
        }

        if (od != null) {
          final oncekiFlot = (od['gunlukFlot'] as num? ?? 0).toDouble();
          final oncekiAnaKasa = (od['anaKasaKalani'] as num? ?? 0).toDouble();
          final oncekiDovizMap = (od['dovizAnaKasaKalanlari'] as Map?) ?? {};

          const tolerance = 0.02;
          final bugunFlot = _parseDouble(_devredenFlotCtrl.text);
          final flotFark = (bugunFlot - oncekiFlot).abs();
          final anaKasaFark = (_oncekiAnaKasaKalani - oncekiAnaKasa).abs();

          bool dovizUyusmuyor = false;
          String dovizDetay = '';
          for (var t in _dovizTurleri) {
            final onceki = (oncekiDovizMap[t] as num? ?? 0).toDouble();
            final bugun = _devredenDovizMiktarlari[t] ?? 0;
            if ((bugun - onceki).abs() > tolerance) {
              dovizUyusmuyor = true;
              final sembol = t == 'USD'
                  ? r'$'
                  : t == 'EUR'
                      ? '€'
                      : t == 'GBP'
                          ? '£'
                          : t;
              dovizDetay += '\n  $sembol Önceki: ${onceki.toStringAsFixed(2)}'
                  ' → Şu an: ${bugun.toStringAsFixed(2)}';
            }
          }

          final tutarsiz =
              flotFark > tolerance || anaKasaFark > tolerance || dovizUyusmuyor;

          if (tutarsiz && mounted) {
            final oncekiTarihGoster = od['tarihGoster'] as String? ?? '';
            String detay = '';
            if (flotFark > tolerance)
              detay +=
                  '\n  Devreden Flot — Önceki: ${oncekiFlot.toStringAsFixed(2)}'
                  ' → Şu an: ${bugunFlot.toStringAsFixed(2)}';
            if (anaKasaFark > tolerance)
              detay +=
                  '\n  Ana Kasa — Önceki: ${oncekiAnaKasa.toStringAsFixed(2)}'
                  ' → Şu an: ${_oncekiAnaKasaKalani.toStringAsFixed(2)}';
            if (dovizUyusmuyor) detay += dovizDetay;

            final onay = await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (ctx) => AlertDialog(
                title: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.orange),
                    SizedBox(width: 8),
                    Flexible(child: Text('Aktarım Uyuşmazlığı')),
                  ],
                ),
                content: Text(
                  '$oncekiTarihGoster tarihli kapanmış günden\n'
                  'aktarılan değerler bu güne yansımamış:$detay\n\n'
                  'Değerler otomatik düzeltilerek gün kapatılsın mı?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text(
                      'İptal',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Düzelt ve Kapat'),
                  ),
                ],
              ),
            );
            if (onay != true) return; // İptal — kapatmayı engelle
            // Değerleri Firestore'daki doğru değerlerle güncelle
            setState(() {
              _oncekiAnaKasaKalani = oncekiAnaKasa;
              _devredenFlotCtrl.text = _formatTL(
                oncekiFlot,
              ).replaceAll(' ₺', '');
              _otomatikDevredenFlot = oncekiFlot;
              for (var t in _dovizTurleri) {
                _devredenDovizMiktarlari[t] =
                    (oncekiDovizMap[t] as num? ?? 0).toDouble();
              }
            });
            // Devam et — kapatma işlemi aşağıda sürecek
          }
        }
      } catch (_) {
        // Kontrol başarısız olursa sessizce devam et
      }
    }
    // ─────────────────────────────────────────────────────────────────────────

    // ── Bekletilmiş RET bildirimi varsa uyar ────────────────────────────────
    if (mounted) {
      try {
        final retBekleyen = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(widget.subeKodu)
            .collection('bekleyen_transferler')
            .where('kategori', isEqualTo: 'RET')
            .where('bekletildi', isEqualTo: true)
            .get();
        if (retBekleyen.docs.isNotEmpty && mounted) {
          final devamEt = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange),
                  SizedBox(width: 8),
                  Flexible(child: Text('Bekletilmiş Transfer Bildirimi')),
                ],
              ),
              content: Text(
                '${retBekleyen.docs.length} adet bekletilmis transfer red bildirimi var.\n\n'
                'Bunlari islemeden gunu kapatmak ister misiniz?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text(
                    'İptal',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx, false);
                    _bekleyenTransferleriGoster();
                  },
                  child: const Text('Bildirimleri Gör'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Yine de Kapat'),
                ),
              ],
            ),
          );
          if (devamEt != true) return;
        }
      } catch (_) {
        /* sessiz — yükleme/işlem başarısız */
      }
    }
    // ─────────────────────────────────────────────────────────────────────────

    setState(() => _kaydediliyor = true);
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      final data = {
        'tarih': tarihKey,
        'tarihGoster': _tarihGoster(_secilenTarih),
        'subeKodu': widget.subeKodu,
        'kayitZamani': FieldValue.serverTimestamp(),
        'kaydeden': _mevcutKullanici,
        'versiyon': appVersiyon,
        'posListesi': _posListesi
            .map(
              (p) => {
                'ad': p.adCtrl.text,
                'tutar': _parseDouble(p.tutarCtrl.text),
              },
            )
            .toList(),
        'toplamPos': _toplamPos,
        'sistemPos': _parseDouble(_sistemPosCtrl.text),
        'yemekKartlari': _yemekKartlari
            .map(
              (y) => {'cins': y.cins, 'tutar': _parseDouble(y.tutarCtrl.text)},
            )
            .toList(),
        'sistemYemekKartlari': {
          for (var c in _yemekKartiCinsleri)
            c: _parseDouble(_sistemYemekKartiCtrl[c]?.text ?? ''),
        },
        'onlineOdemeler': _onlineOdemeler
            .map(
              (o) => {
                'ad': o['ad'],
                'tutar': _parseDouble(
                  (o['ctrl'] as TextEditingController).text,
                ),
              },
            )
            .toList(),
        'gunlukSatisToplami': _parseDouble(_gunlukSatisCtrl.text),
        'pulseKiyasVerileri': Map.fromEntries(
          _pulseKiyasCtrl.entries
              .where((e) => e.value.text.isNotEmpty)
              .map((e) => MapEntry(e.key, e.value.text)),
        ),
        'myDomKiyasVerileri': Map.fromEntries(
          _myDomKiyasCtrl.entries
              .where((e) => e.value.text.isNotEmpty)
              .map((e) => MapEntry(e.key, e.value.text)),
        ),
        'pulseKontrolOnaylandi': _pulseKontrolOnaylandi,
        'pulseResmiOkundu': _pulseOkundu,
        'myDomResmiOkundu': _myDomOkundu,
        'posKontrolOnaylandi': _posKontrolOnaylandi,
        'posResmiOkundu': _posOkundu,
        'harcamalar': _harcamalar
            .map(
              (h) => {
                'aciklama': h.aciklamaCtrl.text,
                'tutar': _parseDouble(h.tutarCtrl.text),
              },
            )
            .toList(),
        'toplamHarcama': _toplamHarcama,
        'banknotlar': {
          for (var b in _banknotlar)
            b.toString(): _parseInt(_banknotCtrl[b]!.text),
        },
        'toplamNakit': _toplamNakit,
        'toplamNakitTL': _toplamNakitTL,
        'toplamDovizTL': _toplamDovizTL,
        'dovizler': _dovizler
            .map(
              (d) => {
                'cins': d['cins'],
                'miktar': _parseDouble(
                  (d['miktarCtrl'] as TextEditingController).text,
                ),
                'kur': _parseDouble(
                  (d['kurCtrl'] as TextEditingController).text,
                ),
                'tlKarsiligi': _parseDouble(
                      (d['miktarCtrl'] as TextEditingController).text,
                    ) *
                    _parseDouble((d['kurCtrl'] as TextEditingController).text),
              },
            )
            .toList(),
        'gunlukFlot': _flotTutari,
        'flotSiniri': _flotSiniri,
        'manuelFlot': _parseDouble(_manuelFlotCtrl.text),
        'devredenFlot': _parseDouble(_devredenFlotCtrl.text),
        'ekrandaGorunenNakit': _parseDouble(_ekrandaGorunenNakitCtrl.text),
        'olmasiGereken': _olmasiGereken,
        'kasaFarki': _kasaFarki,
        'gunlukKasaKalani': _gunlukKasaKalani,
        'gunlukKasaKalaniTL': _gunlukKasaKalaniTL,
        'oncekiAnaKasaKalani': _oncekiAnaKasaKalani,
        'anaKasa': _anaKasa,
        'anaKasaHarcamalari': _anaKasaHarcamalari
            .map(
              (h) => {
                'aciklama': h.aciklamaCtrl.text,
                'tutar': _parseDouble(h.tutarCtrl.text),
              },
            )
            .toList(),
        'toplamAnaKasaHarcama': _toplamAnaKasaHarcama,
        'bankayaYatirilan': _parseDouble(_bankayaYatiranCtrl.text),
        'nakitCikislar': _nakitCikislar
            .map(
              (h) => {
                'aciklama': h.aciklama,
                'tutar': _parseDouble(h.tutarCtrl.text),
              },
            )
            .where((h) => (h['tutar'] as double) > 0)
            .toList(),
        'nakitDovizler': _nakitDovizler
            .map(
              (d) => {
                'cins': d['cins'],
                'miktar': _parseDouble(
                  (d['ctrl'] as TextEditingController).text,
                ),
                'aciklama': (d['aciklamaCtrl'] as TextEditingController?)
                        ?.text
                        .trim() ??
                    '',
              },
            )
            .where((d) => (d['miktar'] as double) > 0)
            .toList(),
        'toplamNakitCikis': _toplamNakitCikis,
        'bankaDovizler': _bankaDovizler
            .map(
              (d) => {
                'cins': d['cins'],
                'miktar': _parseDouble(
                  (d['ctrl'] as TextEditingController).text,
                ),
              },
            )
            .toList(),
        'transferler': _transferler
            .map(
              (t) => {
                'kategori': t['kategori'],
                'hedefSube': t['hedefSube'] ?? '',
                'hedefSubeAd':
                    t['hedefSubeAd'] ?? _subeAdlari[t['hedefSube'] ?? ''] ?? '',
                'kaynakSube': t['kaynakSube'] ?? '',
                'kaynakSubeAd': t['kaynakSubeAd'] ??
                    _subeAdlari[t['kaynakSube'] ?? ''] ??
                    '',
                'aciklama': (t['aciklamaCtrl'] as TextEditingController).text,
                'tutar': _parseDouble(
                  (t['tutarCtrl'] as TextEditingController).text,
                ),
                'gonderildi': t['gonderildi'] ?? false,
                'onaylandi': t['onaylandi'] ?? false,
                'reddedildi': t['reddedildi'] ?? false,
                'bekletildi': t['bekletildi'] ?? false,
                'transferId': t['transferId'] ?? '',
                'onayDocId': t['onayDocId'] ?? '',
              },
            )
            .toList(),
        'digerAlimlar': _digerAlimlar
            .map(
          (t) => {
            'aciklama': (t['aciklamaCtrl'] as TextEditingController).text,
            'tutar': _parseDouble(
              (t['tutarCtrl'] as TextEditingController).text,
            ),
          },
        )
            .where((t) {
          final aciklama = (t['aciklama'] as String).trim();
          final tutar = t['tutar'] as double;
          return aciklama.isNotEmpty || tutar > 0;
        }).toList(),
        'anaKasaKalani': _anaKasaKalani,
        'dovizAnaKasa': {for (var t in _dovizTurleri) t: _dovizAnaKasa(t)},
        'dovizBankayaYatirilan': {
          for (var t in _dovizTurleri) t: _dovizBankayaYatirilan(t),
        },
        'dovizAnaKasaKalanlari': {
          for (var t in _dovizTurleri) t: _dovizAnaKasaKalani(t),
        },
        'oncekiDovizAnaKasaKalanlari': {
          for (var t in _dovizTurleri) t: _devredenDovizMiktarlari[t] ?? 0,
        },
        'tamamlandi': true, // Günü Kapat yapıldı
        'aktiviteLog': FieldValue.arrayUnion([
          {
            'islem': 'Günü Kapat',
            'kullanici': _mevcutKullanici,
            'zaman': Timestamp.now(),
          },
        ]),
      };

      // ── Düzenleme modu açıkken Günü Kapat engellensin ────────────────────
      final duzenlemeAcikTransfer = _transferler.any(
        (t) => t['duzenlemeModunda'] == true,
      );
      if (duzenlemeAcikTransfer && mounted) {
        setState(() => _kaydediliyor = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Açık transfer düzenlemesi var — önce kaydedin veya iptal edin.',
            ),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }

      // ── Bekleyen onaysız GELEN transfer varsa BİLGİLENDİR (engellemez) ──────
      final bekleyenSnap = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('bekleyen_transferler')
          .where('kategori', isEqualTo: 'GELEN')
          .get();
      final islemsizGelen =
          bekleyenSnap.docs.where((d) => d.data()['bekletildi'] != true).length;
      if (islemsizGelen > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$islemsizGelen adet işlenmemiş gelen transfer var — günü kapattınız.',
            ),
            backgroundColor: Colors.orange[700],
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Göster',
              textColor: Colors.white,
              onPressed: _bekleyenTransferleriGoster,
            ),
          ),
        );
      }

      // ── Gönderilmemiş / bildirilmemiş transfer varsa ENGELLE ─────────────
      final gonderilmemisler = _transferler.where((t) {
        final kategori = t['kategori'] as String;
        final tutar = _parseDouble(
          (t['tutarCtrl'] as TextEditingController).text,
        );
        if (tutar <= 0) return false;
        if (t['gonderildi'] == true) return false;
        if (kategori == 'GİDEN') {
          final hedef = t['hedefSube'] as String? ?? '';
          return hedef.isNotEmpty && hedef != 'diger';
        } else if (kategori == 'GELEN') {
          final kaynak = t['kaynakSube'] as String? ?? '';
          return kaynak.isNotEmpty;
        }
        return false;
      }).toList();

      if (gonderilmemisler.isNotEmpty && mounted) {
        if (mounted) setState(() => _kaydediliyor = false);
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => StatefulBuilder(
            builder: (ctx, setDlgState) {
              final bekleyenler = _transferler.where((t) {
                final kategori = t['kategori'] as String;
                final tutar = _parseDouble(
                  (t['tutarCtrl'] as TextEditingController).text,
                );
                if (tutar <= 0) return false;
                if (t['gonderildi'] == true) return false;
                if (kategori == 'GİDEN') {
                  final hedef = t['hedefSube'] as String? ?? '';
                  return hedef.isNotEmpty && hedef != 'diger';
                } else if (kategori == 'GELEN') {
                  final kaynak = t['kaynakSube'] as String? ?? '';
                  return kaynak.isNotEmpty;
                }
                return false;
              }).toList();

              if (bekleyenler.isEmpty) {
                Navigator.pop(ctx);
                return const SizedBox.shrink();
              }

              return AlertDialog(
                title: Row(
                  children: [
                    Icon(Icons.send_outlined, color: Colors.red[700]),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'İşlenmemiş Transfer',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red[200]!),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: Colors.red[700],
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Günü kapatmak için tüm transferler\ngönderilmeli/bildirilmeli veya silinmeli.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...bekleyenler.map((t) {
                      final idx = _transferler.indexOf(t);
                      final kategori = t['kategori'] as String;
                      final isGiden = kategori == 'GİDEN';
                      final subeAd = isGiden
                          ? (_subeAdlari[t['hedefSube'] as String? ?? ''] ??
                              (t['hedefSubeAd'] as String? ?? ''))
                          : (_subeAdlari[t['kaynakSube'] as String? ?? ''] ??
                              (t['kaynakSubeAd'] as String? ?? ''));
                      final tutar = _parseDouble(
                        (t['tutarCtrl'] as TextEditingController).text,
                      );
                      final aciklama =
                          (t['aciklamaCtrl'] as TextEditingController)
                              .text
                              .trim();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.orange[50],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange[200]!),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  isGiden
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                  color: isGiden
                                      ? Colors.red
                                      : const Color(0xFF0288D1),
                                  size: 14,
                                ),
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isGiden
                                        ? Colors.red[100]
                                        : const Color(0xFFE3F2FD),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    kategori,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: isGiden
                                          ? Colors.red[800]
                                          : const Color(0xFF0288D1),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    subeAd.isNotEmpty ? subeAd : '—',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                Text(
                                  _formatTL(tutar),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            if (aciklama.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 2,
                                  left: 18,
                                ),
                                child: Text(
                                  aciklama,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      if (isGiden) {
                                        await _transferiGonder(idx);
                                      } else {
                                        await _gelenTransferBildir(idx);
                                      }
                                      await _kaydet();
                                    },
                                    icon: Icon(
                                      isGiden
                                          ? Icons.send
                                          : Icons.mark_email_unread,
                                      size: 14,
                                    ),
                                    label: Text(
                                      isGiden ? 'Gönder' : 'Bildir',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF0288D1),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 6,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () {
                                      (t['aciklamaCtrl']
                                              as TextEditingController)
                                          .dispose();
                                      (t['tutarCtrl'] as TextEditingController)
                                          .dispose();
                                      setState(() => _transferler.remove(t));
                                      _transferKaydet();
                                      setDlgState(() {});
                                    },
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 14,
                                      color: Colors.red,
                                    ),
                                    label: const Text(
                                      'Sil',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.red,
                                      ),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Colors.red),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 6,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Geri Dön'),
                  ),
                ],
              );
            },
          ),
        );
        return;
      }

      // ── Transfer şube adı zorunlu kontrolü ────────────────────────────────
      for (int i = 0; i < _transferler.length; i++) {
        final t = _transferler[i];
        final kategori = t['kategori'] as String;
        final hedef = t['hedefSube'] as String? ?? '';
        final tutar = _parseDouble(
          (t['tutarCtrl'] as TextEditingController).text,
        );
        if (tutar > 0 &&
            (hedef.isEmpty || hedef == 'diger') &&
            kategori == 'GİDEN') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${i + 1}. transfer için şube seçilmedi!'),
                backgroundColor: Colors.red,
                action: SnackBarAction(
                  label: 'Git',
                  textColor: Colors.white,
                  onPressed: () {
                    Scrollable.ensureVisible(
                      _transferKey.currentContext!,
                      duration: const Duration(milliseconds: 400),
                    );
                  },
                ),
              ),
            );
          }
          if (mounted) setState(() => _kaydediliyor = false);
          return;
        }
      }

      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .doc(tarihKey)
          .set(data);

      // ── Zincirleme güncelleme
      await _zincirGuncelle(
        baslangicTarihi: _secilenTarih,
        yeniAnaKasaKalani: _anaKasaKalani,
        baslangicGunlukFlot: _flotTutari,
        yeniDovizKalanlari: {
          for (var t in _dovizTurleri) t: _dovizAnaKasaKalani(t),
        },
      );

      if (mounted) {
        setState(() {
          _degisiklikVar = false;
          _gunuKapatildi = true;
          _duzenlemeAcik = false;
        });
        await _kilitBirak();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_tarihGoster(_secilenTarih)} günü kapatıldı ✓'),
            backgroundColor: Colors.green,
          ),
        );
        // Sonraki kapanmamış güne geç
        await _sonrakiKapanmamisGuneGec();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _kaydediliyor = false);
    }
  }

  // ── Günü kapattıktan sonra sonraki kapanmamış güne geç ─────────────────────
  Future<void> _sonrakiKapanmamisGuneGec() async {
    if (!mounted) return;
    final bugun = _bugunuHesapla();
    final kapattiginGun = _secilenTarih;

    // Kapatılan günden sonraki günden başlayarak tara
    DateTime kontrol = kapattiginGun.add(const Duration(days: 1));

    while (!kontrol.isAfter(bugun)) {
      final key = _tarihKey(kontrol);

      // Bugünse direkt git, sormadan
      if (kontrol.year == bugun.year &&
          kontrol.month == bugun.month &&
          kontrol.day == bugun.day) {
        await _kilitBirak();
        setState(() {
          _secilenTarih = kontrol;
          _kilitTutanKullanici = null;
          _degisiklikVar = false;
        });
        await _mevcutKaydiYukleYaDaTemizle();
        return;
      }

      // Geçmiş gün — kayıt var mı ve kapalı mı kontrol et
      try {
        final doc = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(widget.subeKodu)
            .collection('gunluk')
            .doc(key)
            .get();

        final kapali = doc.exists && doc.data()?['tamamlandi'] == true;

        if (!kapali) {
          // Kapanmamış gün bulundu — kullanıcıya sor
          if (!mounted) return;
          final sonuc = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.calendar_today, color: Color(0xFF0288D1)),
                  SizedBox(width: 8),
                  Text('Kapanmamış Gün'),
                ],
              ),
              content: Text(
                '${_tarihGoster(kontrol)} tarihi kapatılmamış.\n'
                'Bu tarihe geçilsin mi?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Daha Sonra'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0288D1),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Geç'),
                ),
              ],
            ),
          );

          if (sonuc == true && mounted) {
            await _kilitBirak();
            setState(() {
              _secilenTarih = kontrol;
              _kilitTutanKullanici = null;
              _degisiklikVar = false;
            });
            await _mevcutKaydiYukleYaDaTemizle();
          }
          return;
        }
      } catch (_) {
        /* sessiz — yükleme/işlem başarısız */
      }

      kontrol = kontrol.add(const Duration(days: 1));
    }
  }

  // ── Zincirleme Ana Kasa güncelleme ─────────────────────────────────────────
  // Verilen tarihten sonraki tüm kayıtlı günlerin oncekiAnaKasaKalani ve
  // oncekiDovizAnaKasaKalanlari alanlarını günceller; her günün yeni
  // anaKasaKalani hesaplanıp bir sonraki güne devredilir.
  Future<void> _zincirGuncelle({
    required DateTime baslangicTarihi,
    required double yeniAnaKasaKalani,
    required double baslangicGunlukFlot,
    required Map<String, double> yeniDovizKalanlari,
  }) async {
    double oncekiKalan = yeniAnaKasaKalani;
    double oncekiFlot = baslangicGunlukFlot; // başlangıç gününün flotü
    Map<String, double> oncekiDoviz = Map.from(yeniDovizKalanlari);

    // Başlangıç tarihinden sonraki tüm kayıtları küçükten büyüğe çek
    final baslangicKey = _tarihKey(baslangicTarihi);
    final snapshot = await FirebaseFirestore.instance
        .collection('subeler')
        .doc(widget.subeKodu)
        .collection('gunluk')
        .where('tarih', isGreaterThan: baslangicKey)
        .orderBy('tarih')
        .get();

    for (final doc in snapshot.docs) {
      final data = doc.data();

      // Bu günün kendi hesaplanan değerleri
      final bankayaYatirilan =
          (data['bankayaYatirilan'] as num? ?? 0).toDouble();
      final toplamAnaKasaHarcama =
          (data['toplamAnaKasaHarcama'] as num? ?? 0).toDouble();
      final gunlukKasaKalaniTL =
          (data['gunlukKasaKalaniTL'] as num? ?? 0).toDouble();
      final gunlukFlot = (data['gunlukFlot'] as num? ?? 0).toDouble();

      // Yeni Ana Kasa Kalanı
      final toplamNakitCikis =
          (data['toplamNakitCikis'] as num? ?? 0).toDouble();
      final yeniKalan = oncekiKalan +
          gunlukKasaKalaniTL -
          toplamAnaKasaHarcama -
          bankayaYatirilan -
          toplamNakitCikis;

      // Döviz hesapla
      final Map<String, double> yeniDoviz = {};
      for (var t in _dovizTurleri) {
        final devreden = oncekiDoviz[t] ?? 0;
        final dovizler = (data['dovizler'] as List?)?.cast<Map>() ?? [];
        double bugunMiktar = 0;
        for (var d in dovizler) {
          if (d['cins'] == t)
            bugunMiktar += (d['miktar'] as num? ?? 0).toDouble();
        }
        final bankaDovizler =
            (data['bankaDovizler'] as List?)?.cast<Map>() ?? [];
        double bankaYatan = 0;
        if (bankaDovizler.isNotEmpty) {
          for (var bd in bankaDovizler) {
            if (bd['cins'] == t)
              bankaYatan += (bd['miktar'] as num? ?? 0).toDouble();
          }
        } else {
          final eskiBanka = data['dovizBankayaYatirilan'] as Map?;
          if (eskiBanka != null && eskiBanka[t] != null) {
            bankaYatan = (eskiBanka[t] as num).toDouble();
          }
        }
        // Nakit döviz çıkışını da düş
        double nakitDovizCikis = 0;
        final nakitDovizlerList =
            (data['nakitDovizler'] as List?)?.cast<Map>() ?? [];
        for (var nd in nakitDovizlerList) {
          if (nd['cins'] == t)
            nakitDovizCikis += (nd['miktar'] as num? ?? 0).toDouble();
        }
        yeniDoviz[t] = devreden + bugunMiktar - bankaYatan - nakitDovizCikis;
      }

      // Firestoreu güncelle — devredenFlot her zaman yazılır
      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .doc(doc.id)
          .update({
        'oncekiAnaKasaKalani': oncekiKalan,
        'oncekiDovizAnaKasaKalanlari': oncekiDoviz,
        'anaKasaKalani': yeniKalan,
        'dovizAnaKasaKalanlari': yeniDoviz,
        'devredenFlot': oncekiFlot,
      });

      // Bir sonraki güne devret
      oncekiKalan = yeniKalan;
      // Kapatılmamış günde gunlukFlot henüz hesaplanmamış (0/null) —
      // oncekiFlot'u değiştirme, bir sonraki güne aynı değeri devret
      final buGunKapali = data['tamamlandi'] == true;
      if (buGunKapali && gunlukFlot > 0) oncekiFlot = gunlukFlot;
      oncekiDoviz = yeniDoviz;
    }
  }

  // ── GİDEN transferi karşı şubeye bildir ──────────────────────────────────────
  Future<void> _transferiGonder(int idx) async {
    if (idx < 0 || idx >= _transferler.length) return;
    final t = _transferler[idx];
    final hedef = t['hedefSube'] as String? ?? '';
    if (hedef.isEmpty || hedef == 'diger') return;
    final tutar = _parseDouble((t['tutarCtrl'] as TextEditingController).text);
    if (tutar <= 0) return;

    final buSube = widget.subeKodu;
    final buSubeAd = _subeAdlari[buSube] ?? buSube;
    final aciklama = (t['aciklamaCtrl'] as TextEditingController).text.trim();
    final tarihKey = _tarihKey(_secilenTarih);
    final aciklamaKisa = aciklama.replaceAll(
      RegExp(r'[^a-zA-Z0-9ğüşıöçĞÜŞİÖÇ]'),
      '_',
    );
    final transferId =
        '${tarihKey}_${buSube}_${hedef}_${tutar.toStringAsFixed(2)}_$aciklamaKisa';

    try {
      final bekleyenRef = FirebaseFirestore.instance
          .collection('subeler')
          .doc(hedef)
          .collection('bekleyen_transferler')
          .doc(transferId);

      // Beklemede olan veya yeni bildirim yaz
      await bekleyenRef.set({
        'kategori': 'GELEN',
        'kaynakSube': buSube,
        'kaynakSubeAd': buSubeAd,
        'hedefSube': hedef,
        'tutar': tutar,
        'aciklama': aciklama,
        'tarih': tarihKey,
        'transferId': transferId,
        'olusturmaTarihi': FieldValue.serverTimestamp(),
        'bekletildi': false,
      });

      setState(() {
        t['gonderildi'] = true;
        t['reddedildi'] = false;
        t['onaylandi'] = false;
        t['bekletildi'] = false;
        t['transferId'] = transferId;
      });

      await _transferKaydet();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gönderim hatası: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Manuel GELEN transferi karşı şubeye bildir ────────────────────────────
  // A şubesi manuel GELEN ekleyip Kaydete basınca B şubesine bildirim gider.
  // B: Onayla / Reddet / Beklet → Aya bildirim döner.
  Future<void> _gelenTransferBildir(int idx) async {
    if (idx < 0 || idx >= _transferler.length) return;
    final t = _transferler[idx];
    if (t['kategori'] != 'GELEN') return;
    final kaynakSube = t['kaynakSube'] as String? ?? '';
    if (kaynakSube.isEmpty) return;
    final tutar = _parseDouble((t['tutarCtrl'] as TextEditingController).text);
    if (tutar <= 0) return;

    final buSube = widget.subeKodu;
    final buSubeAd = _subeAdlari[buSube] ?? buSube;
    final aciklama = (t['aciklamaCtrl'] as TextEditingController).text.trim();
    final tarihKey = _tarihKey(_secilenTarih);
    final aciklamaKisa = aciklama.replaceAll(
      RegExp(r'[^a-zA-Z0-9ğüşıöçĞÜŞİÖÇ]'),
      '_',
    );
    // transferId: kaynakSube→buSube yönünde
    final transferId =
        '${tarihKey}_${kaynakSube}_${buSube}_${tutar.toStringAsFixed(2)}_$aciklamaKisa';

    try {
      // B şubesine bildirim — B açısından bu bir GİDEN transfer
      // (Bden Aya para gidiyor, B onaylayarak GİDEN olarak kaydeder)
      final bildirimRef = FirebaseFirestore.instance
          .collection('subeler')
          .doc(kaynakSube)
          .collection('bekleyen_transferler')
          .doc(transferId);

      await bildirimRef.set({
        'kategori': 'GELEN', // bekleyen_transferler koleksiyonundaki tip
        'gidecegiKategori': 'GİDEN', // B onaylayınca GİDEN olarak kaydedecek
        'kaynakSube': kaynakSube, // B = gönderen
        'kaynakSubeAd': _subeAdlari[kaynakSube] ?? kaynakSube,
        'hedefSube': buSube, // A = alan
        'hedefSubeAd': buSubeAd,
        'tutar': tutar,
        'aciklama': aciklama,
        'tarih': tarihKey,
        'transferId': transferId,
        'olusturmaTarihi': FieldValue.serverTimestamp(),
        'bekletildi': false,
        'manuelGelen': true, // A'nın manuel eklediği kayıt
      });

      setState(() {
        t['gonderildi'] = true;
        t['transferId'] = transferId;
      });
      await _transferKaydet();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Bildirim gönderilemedi: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Transferleri bağımsız kaydet (ana _degisiklikVara dokunmaz) ──────────
  // Transfer ekleme, düzenleme, silme sonrası çağrılır
  Future<void> _transferKaydet() async {
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      final subeRef = FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .doc(tarihKey);

      final transferVerisi = _transferler
          .map(
            (t) => {
              'kategori': t['kategori'],
              'hedefSube': t['hedefSube'] ?? '',
              'hedefSubeAd':
                  t['hedefSubeAd'] ?? _subeAdlari[t['hedefSube'] ?? ''] ?? '',
              'kaynakSube': t['kaynakSube'] ?? '',
              'kaynakSubeAd':
                  t['kaynakSubeAd'] ?? _subeAdlari[t['kaynakSube'] ?? ''] ?? '',
              'aciklama': (t['aciklamaCtrl'] as TextEditingController).text,
              'tutar': _parseDouble(
                (t['tutarCtrl'] as TextEditingController).text,
              ),
              'gonderildi': t['gonderildi'] ?? false,
              'onaylandi': t['onaylandi'] ?? false,
              'reddedildi': t['reddedildi'] ?? false,
              'bekletildi': t['bekletildi'] ?? false,
              'transferId': t['transferId'] ?? '',
              'onayDocId': t['onayDocId'] ?? '',
            },
          )
          .toList();

      // Mevcut kayıt varsa sadece transferler alanını güncelle
      final mevcut = await subeRef.get();
      if (mevcut.exists) {
        final kapali = mevcut.data()?['tamamlandi'] == true;
        await subeRef.update({
          'transferler': transferVerisi,
          if (kapali) 'tamamlandi': true,
        });
      } else {
        // Kayıt yok — sadece transfer alanıyla oluştur
        await subeRef.set({
          'tarih': tarihKey,
          'subeKodu': widget.subeKodu,
          'transferler': transferVerisi,
        }, SetOptions(merge: true));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Transfer kaydedilemedi: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── UI Yardımcıları ─────────────────────────────────────────────────────────

  Widget _sectionTitle(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF0288D1), size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF0288D1),
            ),
          ),
        ],
      ),
    );
  }

  // Transferler bölümü başlığı — mor/indigo
  Widget _sectionTitleTransfer(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F0FF),
          borderRadius: BorderRadius.circular(8),
          border: const Border(
            left: BorderSide(color: Color(0xFF4F46E5), width: 4),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF4F46E5), size: 20),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF4F46E5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Diğer Alımlar bölümü başlığı — amber/turuncu
  Widget _sectionTitleDigerAlim(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(8),
          border: const Border(
            left: BorderSide(color: Color(0xFFD97706), width: 4),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFFD97706), size: 20),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFFD97706),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _zorunluIkon(bool dolu) {
    if (dolu) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.red[50],
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: Colors.red[300]!),
        ),
        child: Text(
          'ZORUNLU',
          style: TextStyle(
            fontSize: 9,
            color: Colors.red[700],
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _sectionTitleZorunlu(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF0288D1), size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF0288D1),
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.red[50],
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.red[300]!),
            ),
            child: Text(
              '* Zorunlu',
              style: TextStyle(
                fontSize: 10,
                color: Colors.red[700],
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitleNakit(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFF0288D1), size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0288D1),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2, bottom: 8),
            child: Text(
              '* En az 1 banknot girilmesi zorunludur',
              style: TextStyle(fontSize: 11, color: Colors.red[600]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _farkSatiri(String label, double fark, {bool buyukFont = false}) {
    Color renk = fark >= 0 ? Colors.green[700]! : Colors.red[700]!;
    String ikon = fark >= 0 ? '▲' : '▼';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: renk.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: renk.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: renk,
              fontSize: buyukFont ? 15 : 14,
            ),
          ),
          Text(
            '$ikon ${_formatTL(fark.abs())}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: renk,
              fontSize: buyukFont ? 17 : 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bilgiSatiri(String label, String deger, {Color? renkDeger}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.black54, fontSize: 14),
          ),
          Text(
            deger,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: renkDeger ?? Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  // ── Tarih Kartı ─────────────────────────────────────────────────────────────

  Widget _tarihSeciciSection() {
    final bugun = _bugunuHesapla();
    final yonetici = widget.gecmisGunHakki == -1;
    final hakki = widget.gecmisGunHakki;

    // İleri: yönetici için gün kapatılma şartı yok, sadece bugünü geçmesin
    // Kullanıcı için gün kapatılmış olmalı
    final ileriAktif = !_duzenlemeAcik &&
        _secilenTarih.isBefore(bugun) &&
        (yonetici || _gunuKapatildi);

    // Geri: yönetici sınırsız, diğerleri sonKapaliTarih - gecmisGunHakki
    // Referans nokta bugün değil, en son kapatılan gün
    final referansTarih = (!yonetici && _sonKapaliTarih != null)
        ? _sonKapaliTarih!
        : _secilenTarih; // null ise mevcut tarih — en azından geri gidebilsin
    DateTime enEskiTarih = yonetici
        ? DateTime(2020)
        : referansTarih.subtract(Duration(days: hakki));
    // Açılış tarihinden öncesine gidemez
    if (!yonetici &&
        _ilkKapaliTarih != null &&
        _ilkKapaliTarih!.isAfter(enEskiTarih)) {
      enEskiTarih = _ilkKapaliTarih!;
    }
    final geriAktif = !_duzenlemeAcik && _secilenTarih.isAfter(enEskiTarih);

    return Card(
      color: Colors.red[700],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            // Geri ok
            IconButton(
              icon: const Icon(Icons.chevron_left, color: Colors.white),
              onPressed: geriAktif ? () => _tarihDegistir(-1) : null,
              disabledColor: Colors.white30,
              tooltip: !geriAktif && hakki == 0
                  ? 'Geçmiş kayıtlara erişim yetkiniz yok'
                  : !geriAktif
                      ? '$hakki günden daha eski kayıtlara gidemezsiniz'
                      : null,
            ),
            const Icon(Icons.calendar_today, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _tarihGoster(_secilenTarih),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            // İleri ok
            IconButton(
              icon: const Icon(Icons.chevron_right, color: Colors.white),
              onPressed: ileriAktif ? () => _tarihDegistir(1) : null,
              disabledColor: Colors.white30,
              tooltip:
                  !_gunuKapatildi ? 'Günü kapatmadan ileri geçemezsiniz' : null,
            ),
            // Değiştir butonu — sadece geriye gitmek için
            TextButton(
              onPressed: () => _tarihSec(),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: Size.zero,
              ),
              child: const Text(
                'Değiştir',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Tarih değişimi öncesi bekleyen değişiklikleri kaydet (await ile)
  Future<void> _tarihOncesiKaydet() async {
    if (!_degisiklikVar) return;
    if (mounted) _appBarMesajGoster('⏳ Kaydediliyor...');
    try {
      final tarihKey = _tarihKey(_secilenTarih);
      await FirebaseFirestore.instance
          .collection('subeler')
          .doc(widget.subeKodu)
          .collection('gunluk')
          .doc(tarihKey)
          .set(_otomatikKayitVerisi(), SetOptions(merge: true));
      if (mounted) {
        setState(() => _degisiklikVar = false);
        _appBarMesajGoster('✓ Kaydedildi');
      }
    } catch (_) {
      if (mounted) _appBarMesajGoster('✗ Kayıt hatası');
    }
  }

  Future<void> _tarihDegistir(int gunFarki) async {
    // İleri git: kapanmamış günden sonrasına geçilemez (ileri ok zaten pasif)
    // Geri git: serbest — kapanmamış günden geriye gidilebilir
    // Önce devam eden kayıt beklenir: eski _otomatikKaydet tamamlanmadan
    // _tarihOncesiKaydet çalışırsa eski veri daha sonra üzerine yazabilir.
    while (_otomatikKaydediliyor && mounted) {
      await Future.delayed(const Duration(milliseconds: 30));
    }
    // Kaydedilmemiş değişiklik varsa şimdi kaydet (tüm paralel yazma bitti)
    await _tarihOncesiKaydet();
    if (!await _degisiklikUyar(gecisMetni: 'Başka tarihe geçmeden')) return;
    final yeniTarih = _secilenTarih.add(Duration(days: gunFarki));
    final bugun = _bugunuHesapla();
    if (yeniTarih.isAfter(bugun)) return;
    await _kilitBirak();
    setState(() {
      _secilenTarih = yeniTarih;
      _kilitTutanKullanici = null;
      _degisiklikVar = false;
    });
    await _mevcutKaydiYukleYaDaTemizle();
  }

  // ── Yemek Kartları Bölümü ────────────────────────────────────────────────────

  Widget _yemekKartiSection() {
    if (_yemekKartiCinsleri.isEmpty) return const SizedBox.shrink();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Color(0xFF7C3AED), width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('Yemek Kartları', Icons.credit_card),
              ..._yemekKartlari.asMap().entries.map((e) {
                final idx = e.key;
                final y = e.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: DropdownButtonFormField<String>(
                          value: _yemekKartiCinsleri.isEmpty
                              ? null
                              : _yemekKartiCinsleri.contains(y.cins)
                                  ? y.cins
                                  : _yemekKartiCinsleri.first,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Kart',
                            isDense: true,
                          ),
                          items: _yemekKartiCinsleri
                              .toSet()
                              .map(
                                (c) => DropdownMenuItem(
                                  value: c,
                                  child: Text(
                                    c,
                                    style: const TextStyle(fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _readOnly
                              ? null
                              : (v) {
                                  if (v != null) {
                                    setState(() {
                                      _yemekKartlari[idx].cins = v;
                                      _degisiklikVar = true;
                                      if (_duzenlemeAcik)
                                        _gercekDegisiklikVar = true;
                                    });
                                  }
                                },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: y.tutarCtrl,
                          readOnly: _readOnly,
                          autofocus: y.yeni,
                          decoration: const InputDecoration(
                            labelText: 'Tutar (₺)',
                            suffixText: '₺',
                            isDense: true,
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          inputFormatters: [BinAraciFormatter()],
                          onChanged: (_) {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      if (_yemekKartlari.length > 1)
                        IconButton(
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            color: Colors.red,
                          ),
                          onPressed: _readOnly
                              ? null
                              : () {
                                  setState(() {
                                    _yemekKartlari[idx].dispose();
                                    _yemekKartlari.removeAt(idx);
                                    _degisiklikVar = true;
                                    if (_pulseKontrolOnaylandi)
                                      _pulseKontrolOnaylandi = false;
                                  });
                                },
                        ),
                    ],
                  ),
                );
              }),
              TextButton.icon(
                onPressed: _readOnly || _yemekKartiCinsleri.isEmpty
                    ? null
                    : () {
                        final yeniYemek = YemekKartiGirisi(
                          cins: _yemekKartiCinsleri.first,
                          yeni: true,
                        );
                        _pulseCtrlBagla(yeniYemek.tutarCtrl);
                        setState(() {
                          _yemekKartlari.add(yeniYemek);
                          if (_pulseKontrolOnaylandi)
                            _pulseKontrolOnaylandi = false;
                        });
                      },
                icon: const Icon(Icons.add),
                label: const Text('Satır Ekle'),
              ),
              const Divider(),
              // Cins bazlı toplam + Pulse karşılaştırması
              ...() {
                final cinsler = _yemekKartiCinsleri
                    .where(
                      (c) =>
                          _yemekKartiCinsToplam(c) > 0 ||
                          (_sistemYemekKartiCtrl[c]?.text.isNotEmpty == true),
                    )
                    .toList();
                return cinsler.map((cins) {
                  final toplam = _yemekKartiCinsToplam(cins);
                  final cinsRenk = _yemekKartiRenk(cins);
                  return Column(
                    children: [
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: cinsRenk.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '$cins Toplam',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: cinsRenk,
                              ),
                            ),
                            Text(
                              _formatTL(toplam),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: cinsRenk,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }).toList();
              }(),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C3AED),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Toplam Yemek Kartı',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      _formatTL(_toplamYemekKarti),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── POS Bölümü ──────────────────────────────────────────────────────────────

  Widget _posSection() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Color(0xFF0369A1), width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Spacer(),
                SizedBox(
                  width: 160,
                  child: _posOkunuyor
                      ? ElevatedButton.icon(
                          onPressed: () => setState(() {
                            _posIptalEdildi = true;
                            _posOkunuyor = false;
                          }),
                          icon: const Icon(Icons.cancel, size: 15),
                          label: const Text('İptal',
                              style: TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red[700],
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                        )
                      : ElevatedButton.icon(
                          onPressed: _readOnly || _posOkunuyor
                              ? null
                              : () async {
                                  setState(() => _posIptalEdildi = false);
                                  final src = await _resimKaynagiSec(context);
                                  if (src != null) _posResmiOku(source: src);
                                },
                          icon: Icon(
                              _posOkundu
                                  ? Icons.check_circle
                                  : Icons.camera_alt,
                              size: 15),
                          label: Text(_posOkundu ? 'POS ✓' : 'POS Görüntüsü',
                              style: const TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _posOkundu
                                ? Colors.green[700]
                                : const Color(0xFF0288D1),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                ),
              ]),
              const SizedBox(height: 10),
              _sectionTitleZorunlu('POS Cihazları', Icons.credit_card),
              ..._posListesi.asMap().entries.map((e) {
                int idx = e.key;
                PosGirisi pos = e.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: pos.adCtrl,
                          readOnly: _readOnly,
                          decoration: const InputDecoration(
                            labelText: 'Cihaz Adı',
                          ),
                          onChanged: (_) {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: TextFormField(
                          controller: pos.tutarCtrl,
                          readOnly: _readOnly,
                          autofocus: pos.yeni,
                          decoration: const InputDecoration(
                            labelText: 'Tutar (₺)',
                            suffixText: '₺',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          inputFormatters: [BinAraciFormatter()],
                          onChanged: (_) {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                                if (_posKontrolOnaylandi)
                                  _posKontrolOnaylandi = false;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      if (_posListesi.length > 1)
                        IconButton(
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            color: Colors.red,
                          ),
                          onPressed: _readOnly
                              ? null
                              : () {
                                  setState(() {
                                    _posListesi[idx].dispose();
                                    _posListesi.removeAt(idx);
                                    _degisiklikVar = true;
                                    if (_pulseKontrolOnaylandi)
                                      _pulseKontrolOnaylandi = false;
                                    if (_posKontrolOnaylandi)
                                      _posKontrolOnaylandi = false;
                                  });
                                },
                        ),
                    ],
                  ),
                );
              }),
              TextButton.icon(
                onPressed: _readOnly
                    ? null
                    : () {
                        final yeniPos = PosGirisi(
                          ad: 'POS ${_posListesi.length + 1}',
                          yeni: true,
                        );
                        _pulseCtrlBagla(yeniPos.tutarCtrl);
                        setState(() {
                          _posListesi.add(yeniPos);
                          if (_pulseKontrolOnaylandi)
                            _pulseKontrolOnaylandi = false;
                          if (_posKontrolOnaylandi)
                            _posKontrolOnaylandi = false;
                        });
                      },
                icon: const Icon(Icons.add),
                label: const Text('POS Ekle'),
              ),
              const Divider(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF0369A1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Toplam POS',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      _formatTL(_toplamPos),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: _posKontrolOnaylandi
                    ? Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.green[100],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green[400]!),
                        ),
                        child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.verified,
                                  color: Colors.green[700], size: 18),
                              const SizedBox(width: 8),
                              Text('POS kontrol edildi ✓',
                                  style: TextStyle(
                                      color: Colors.green[700],
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14)),
                            ]),
                      )
                    : ElevatedButton.icon(
                        onPressed: (_toplamPos > 0 && !_readOnly)
                            ? () => setState(() => _posKontrolOnaylandi = true)
                            : null,
                        icon: const Icon(Icons.check_circle_outline),
                        label: Text(_toplamPos <= 0
                            ? 'POS tutarı girilmemiş'
                            : 'POS verilerini kontrol ettim, veriler doğru'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _toplamPos > 0
                              ? Colors.orange[700]
                              : Colors.grey[400],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  // ── Online Ödemeler Bölümü ──────────────────────────────────────────────────────

  Widget _onlineOdemeSection() {
    if (_onlineOdemeler.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.language, size: 18, color: Color(0xFF0288D1)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Online Ödemeler',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Color(0xFF0288D1),
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _readOnly
                      ? null
                      : () async {
                          final src = await _resimKaynagiSec(context);
                          if (src != null) _pulseResmiOku(source: src);
                        },
                  icon: const Icon(Icons.camera_alt_outlined, size: 16),
                  label: const Text(
                    'Pulse Resmi',
                    style: TextStyle(fontSize: 12),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0288D1),
                    side: const BorderSide(color: Color(0xFF0288D1)),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ..._onlineOdemeler.map((o) {
              final ad = o['ad'] as String;
              final ctrl = o['ctrl'] as TextEditingController;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(ad, style: const TextStyle(fontSize: 13)),
                    ),
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: ctrl,
                        readOnly: _readOnly,
                        decoration: const InputDecoration(
                          suffixText: '₺',
                          isDense: true,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [BinAraciFormatter()],
                        textAlign: TextAlign.right,
                        onChanged: (_) {
                          if (mounted && !_yukleniyor) {
                            setState(() {
                              _degisiklikVar = true;
                              if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                            });
                            if (_kilitTutuyorum) {
                              _kilitTimer?.cancel();
                              _kilitTimer = Timer(
                                const Duration(minutes: 20),
                                _kilitBirak,
                              );
                            } else {
                              _kilitAl();
                            }
                          }
                        },
                      ),
                    ),
                  ],
                ),
              );
            }),
            const Divider(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0288D1).withOpacity(0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Toplam Online',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Color(0xFF0288D1),
                    ),
                  ),
                  Text(
                    _formatTL(_toplamOnlineOdeme),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF0288D1),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Günlük Satış Bölümü ──────────────────────────────────────────────────────

  Widget _gunlukSatisSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.red[50],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red[700]!, width: 1.5),
          ),
          child: TextFormField(
            controller: _gunlukSatisCtrl,
            readOnly: _readOnly,
            decoration: InputDecoration(
              labelText: 'Günlük Satış Toplamı (₺)',
              suffixIcon: _zorunluIkon(_parseDouble(_gunlukSatisCtrl.text) > 0),
              suffixText: '₺',
              hintText: 'Mutlaka girilmeli!',
              prefixIcon: Icon(Icons.trending_up, color: Colors.red[700]),
              labelStyle: TextStyle(
                color: Colors.red[700],
                fontWeight: FontWeight.bold,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            inputFormatters: [BinAraciFormatter()],
            onChanged: (_) => setState(() {
              if (!_yukleniyor) {
                _degisiklikVar = true;
                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
              }
            }),
          ),
        ),
      ),
    );
  }

  // ── Ekranda Görünen Nakit Bölümü ─────────────────────────────────────────────

  Widget _ekrandaGorunenNakitSection() {
    final banka = _bankaParasi;
    final pulseOnaylandi = _pulseKontrolOnaylandi;
    final rawBanka = _pulseBankaParasi;
    final negatif = pulseOnaylandi && rawBanka < 0;

    // Otomatik doldur — Banka Parası değişince ctrl'e yaz
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final hedef = banka > 0 ? _formatTL(banka).replaceAll(' ₺', '') : '';
      if (_ekrandaGorunenNakitCtrl.text != hedef) {
        _ekrandaGorunenNakitCtrl.text = hedef;
        if (!_yukleniyor && hedef.isNotEmpty) {
          _degisiklikVar = true;
          _otomatikKaydetBaslat();
        }
      }
    });

    Color boxBg;
    Color boxBorder;
    Color iconColor;
    Color textColor;
    String displayText;

    if (!pulseOnaylandi) {
      boxBg = const Color(0xFFFFF7ED);
      boxBorder = const Color(0xFFFB923C);
      iconColor = const Color(0xFFF97316);
      textColor = const Color(0xFFEA580C);
      displayText = 'Pulse onaylanmamış';
    } else if (negatif) {
      boxBg = const Color(0xFFFEF2F2);
      boxBorder = const Color(0xFFFCA5A5);
      iconColor = const Color(0xFFDC2626);
      textColor = const Color(0xFFDC2626);
      displayText = 'Hesaplanan değer negatif (0 alındı)';
    } else if (banka > 0) {
      boxBg = const Color(0xFFE0F2FE);
      boxBorder = const Color(0xFF0369A1);
      iconColor = const Color(0xFF0369A1);
      textColor = const Color(0xFF0369A1);
      displayText = _formatTL(banka);
    } else {
      boxBg = Colors.grey[50]!;
      boxBorder = Colors.grey[300]!;
      iconColor = Colors.grey[400]!;
      textColor = Colors.grey[400]!;
      displayText = 'Pulse/MyDom sekmesinden hesaplanacak';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.monitor, color: const Color(0xFF0369A1), size: 18),
                const SizedBox(width: 8),
                Text(
                  'Banka Parası (Kasa Nakiti)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0369A1),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Otomatik',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: boxBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: boxBorder, width: 1.5),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.account_balance_wallet,
                    color: iconColor,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      displayText,
                      style: TextStyle(
                        fontSize: banka > 0 && pulseOnaylandi ? 18 : 14,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!pulseOnaylandi) ...[
              const SizedBox(height: 8),
              Text(
                'Pulse/MyDom sekmesinde "Pulse kontrol ettim" onaylandıktan sonra hesaplanır.',
                style: TextStyle(fontSize: 12, color: const Color(0xFFF97316)),
              ),
            ] else if (negatif) ...[
              const SizedBox(height: 8),
              Text(
                'Brüt satış, POS + Yemek + Online toplamından düşük — farkı kontrol edin.',
                style: TextStyle(fontSize: 12, color: const Color(0xFFDC2626)),
              ),
            ] else if (banka <= 0) ...[
              const SizedBox(height: 8),
              Text(
                'Pulse/MyDom sekmesinde değerler girilince otomatik hesaplanır.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Harcamalar ──────────────────────────────────────────────────────────────

  Widget _harcamalarSection() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Color(0xFFF97316), width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('Harcamalar', Icons.receipt_long),
              ..._harcamalar.asMap().entries.map((e) {
                int idx = e.key;
                HarcamaGirisi h = e.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: GiderAdiAlani(
                          ctrl: h.aciklamaCtrl,
                          secenekler: _giderTurleriListesi,
                          readOnly: _readOnly,
                          labelText: 'Açıklama ${idx + 1}',
                          onChanged: () {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: h.tutarCtrl,
                          readOnly: _readOnly,
                          decoration: const InputDecoration(
                            labelText: 'Tutar (₺)',
                            suffixText: '₺',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          inputFormatters: [BinAraciFormatter()],
                          onChanged: (_) {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      if (_harcamalar.length > 1)
                        IconButton(
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            color: Colors.red,
                          ),
                          onPressed: _readOnly
                              ? null
                              : () {
                                  setState(() {
                                    _harcamalar[idx].dispose();
                                    _harcamalar.removeAt(idx);
                                    _degisiklikVar = true;
                                  });
                                },
                        ),
                    ],
                  ),
                );
              }),
              TextButton.icon(
                onPressed: _readOnly
                    ? null
                    : () => setState(
                          () => _harcamalar.add(HarcamaGirisi(yeni: true)),
                        ),
                icon: const Icon(Icons.add),
                label: const Text('Harcama Ekle'),
              ),
              const Divider(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF97316),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Toplam Harcama',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      _formatTL(_toplamHarcama),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Nakit Sayım ─────────────────────────────────────────────────────────────

  Widget _nakitSayimSection() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Color(0xFF0284C7), width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitleNakit('Nakit Sayım', Icons.account_balance_wallet),
              Table(
                columnWidths: const {
                  0: FlexColumnWidth(2),
                  1: FlexColumnWidth(2),
                  2: FlexColumnWidth(2),
                },
                children: [
                  TableRow(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0288D1).withOpacity(0.1),
                    ),
                    children: const [
                      Padding(
                        padding: EdgeInsets.all(8),
                        child: Text(
                          'Banknot',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.all(8),
                        child: Text(
                          'Adet',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.all(8),
                        child: Text(
                          'Tutar',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  ..._banknotlar.map((b) {
                    int adet = _parseInt(_banknotCtrl[b]!.text);
                    double tutar = b * adet.toDouble();
                    bool isFlot = b <= _flotSiniri;
                    return TableRow(
                      decoration: isFlot
                          ? BoxDecoration(color: Colors.green.withOpacity(0.05))
                          : null,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Row(
                            children: [
                              Text(
                                '$b ₺',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: isFlot ? Colors.green[700] : null,
                                ),
                              ),
                              if (isFlot)
                                Icon(
                                  Icons.fiber_manual_record,
                                  size: 8,
                                  color: Colors.green[700],
                                ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: SizedBox(
                            height: 36,
                            child: TextFormField(
                              controller: _banknotCtrl[b],
                              readOnly: _readOnly,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.number,
                              textInputAction: TextInputAction.next,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              onChanged: (_) => setState(() {
                                if (!_yukleniyor) {
                                  _degisiklikVar = true;
                                  if (_duzenlemeAcik)
                                    _gercekDegisiklikVar = true;
                                }
                              }),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              '${tutar.toStringAsFixed(0)} ₺',
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  }),
                ],
              ),
              const SizedBox(height: 8),
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Toplam TL Nakit:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    _formatTL(_toplamNakitTL),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.fiber_manual_record,
                        size: 10,
                        color: Colors.green[700],
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Flot (≤$_flotSiniri ₺):',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.green[700],
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _formatTL(_flotOtomatik),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green[700],
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _manuelFlotCtrl,
                readOnly: _readOnly,
                decoration: InputDecoration(
                  labelText: 'Flot Ek Tutar (₺)',
                  suffixText: '₺',
                  hintText: 'Manuel ek flot tutarı',
                  prefixIcon: Icon(
                    Icons.add_circle_outline,
                    color: Colors.green[700],
                  ),
                  labelStyle: TextStyle(color: Colors.green[700]),
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                inputFormatters: [BinAraciFormatter()],
                onChanged: (_) => setState(() {
                  if (!_yukleniyor) {
                    _degisiklikVar = true;
                    if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                  }
                }),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Toplam Flot:',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green[700],
                    ),
                  ),
                  Text(
                    _formatTL(_flotTutari),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green[700],
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(),
              // ── Döviz ──────────────────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFFF5F3FF),
                  border: Border(
                    left: BorderSide(color: Color(0xFF7C3AED), width: 4),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      onPressed: _readOnly ? null : () => _dovizEkle(),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Döviz Ekle'),
                    ),
                    const Text(
                      'Döviz',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Color(0xFF5B21B6),
                      ),
                    ),
                  ],
                ),
              ),
              ..._dovizler.asMap().entries.map((e) {
                int idx = e.key;
                Map<String, dynamic> d = e.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      // Döviz cinsi
                      SizedBox(
                        width: 70,
                        child: DropdownButtonFormField<String>(
                          value: d['cins'] as String,
                          isExpanded: true,
                          menuMaxHeight: 200,
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(),
                          ),
                          items: ['USD', 'EUR', 'GBP', 'CHF', 'SAR']
                              .map(
                                (c) => DropdownMenuItem(
                                  value: c,
                                  child: Text(
                                    c,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setState(() => d['cins'] = v),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Miktar
                      Expanded(
                        child: TextFormField(
                          controller: d['miktarCtrl'] as TextEditingController,
                          readOnly: _readOnly,
                          decoration: const InputDecoration(
                            labelText: 'Miktar',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          inputFormatters: [BinAraciFormatter()],
                          onChanged: (_) {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Kur
                      Expanded(
                        child: TextFormField(
                          controller: d['kurCtrl'] as TextEditingController,
                          readOnly: _readOnly,
                          decoration: const InputDecoration(
                            labelText: 'Kur (₺)',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          inputFormatters: [BinAraciFormatter()],
                          onChanged: (_) {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      // TL karşılığı
                      SizedBox(
                        width: 70,
                        child: Text(
                          _formatTL(
                            _parseDouble(
                                  (d['miktarCtrl'] as TextEditingController)
                                      .text,
                                ) *
                                _parseDouble(
                                  (d['kurCtrl'] as TextEditingController).text,
                                ),
                          ),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.remove_circle_outline,
                          color: Colors.red,
                          size: 20,
                        ),
                        onPressed: _readOnly
                            ? null
                            : () {
                                setState(() {
                                  (d['miktarCtrl'] as TextEditingController)
                                      .dispose();
                                  (d['kurCtrl'] as TextEditingController)
                                      .dispose();
                                  _dovizler.removeAt(idx);
                                  _degisiklikVar = true;
                                });
                              },
                      ),
                    ],
                  ),
                );
              }),
              if (_dovizler.isNotEmpty) ...[
                const Divider(),
                // TL Nakit
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0284C7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Toplam TL Nakit',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        _formatTL(_toplamNakitTL),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                // Döviz TL Karşılığı
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Döviz TL Karşılığı',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        _formatTL(_toplamDovizTL),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                // Genel Toplam
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Genel Toplam',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        _formatTL(_toplamNakitTL + _toplamDovizTL),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                const Divider(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0284C7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Toplam Nakit',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        _formatTL(_toplamNakitTL),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _dovizEkle() {
    setState(() {
      _dovizler.add({
        'cins': 'USD',
        'miktarCtrl': TextEditingController(),
        'kurCtrl': TextEditingController(),
      });
    });
  }

  void _banknotEkleDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Banknot Ekle'),
        content: TextFormField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Banknot değeri (₺)',
            suffixText: '₺',
          ),
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          TextButton(
            onPressed: () {
              final val = int.tryParse(ctrl.text);
              if (val != null && val > 0 && !_banknotlar.contains(val)) {
                setState(() {
                  _banknotlar.add(val);
                  _banknotlar.sort((a, b) => b.compareTo(a));
                  _banknotCtrl[val] = TextEditingController();
                  _banknotAyarlariniKaydet();
                });
              }
              Navigator.pop(context);
            },
            child: const Text('Ekle'),
          ),
        ],
      ),
    );
  }

  void _flotSiniriDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Flot Sınırı Seç'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _banknotlar
              .map(
                (b) => ListTile(
                  title: Text('$b ₺ ve altı'),
                  leading: Radio<int>(
                    value: b,
                    groupValue: _flotSiniri,
                    onChanged: (v) {
                      setState(() => _flotSiniri = v!);
                      // Global kayıt YOK — sadece bu günün otomatik kaydına yazılır
                      Navigator.pop(context);
                    },
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  // ── Kasa Özeti ─────────────────────────────────────────────────────────────

  Widget _ekBilgilerSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Kasa Özeti', Icons.summarize),
            // Devreden Flot - otomatik, readonly
            Container(
              decoration: BoxDecoration(
                color: Colors.green[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green[300]!, width: 1),
              ),
              child: TextFormField(
                controller: _devredenFlotCtrl,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: 'Devreden Flot (₺)',
                  suffixText: '₺',
                  hintText: 'Önceki günden otomatik gelir',
                  prefixIcon: Icon(Icons.autorenew, color: Colors.green[700]),
                  labelStyle: TextStyle(
                    color: Colors.green[800],
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                style: TextStyle(
                  color: Colors.green[900],
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF0288D1).withOpacity(0.07),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF0288D1).withOpacity(0.2),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.calculate_outlined,
                        color: Color(0xFF0288D1),
                        size: 18,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Kasada Olması Gereken',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0288D1),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _formatTL(_olmasiGereken),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF0288D1),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _farkSatiri('Kasa Farkı', _kasaFarki),
            const SizedBox(height: 8),
            _farkSatiri(
              'Günlük Kasa Kalanı',
              _gunlukKasaKalani,
              buyukFont: true,
            ),
          ],
        ),
      ),
    );
  }

  // ── Kasa Özeti ──────────────────────────────────────────────────────────────

  // ── Özet & Kapat Sekmesi — PDF ile aynı sıra ve koşullar ──────────────────
  Widget _ozetKapatSekmesi() {
    final gunlukSatis = _parseDouble(_gunlukSatisCtrl.text);
    final toplamHarcama = _toplamHarcama;
    final toplamAnaKasaHarcama = _toplamAnaKasaHarcama;
    final toplamNakitCikis = _toplamNakitCikis;

    // _bolumKart: özet&kapat için standart kart widget'ı
    Widget bolumKart({
      required Color renk,
      required IconData ikon,
      required String baslik,
      String? toplam,
      required Widget child,
    }) {
      return Container(
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: renk,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                ),
              ),
              child: Row(
                children: [
                  Icon(ikon, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    baslik,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      letterSpacing: 1,
                    ),
                  ),
                  const Spacer(),
                  if (toplam != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        toplam,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(padding: const EdgeInsets.all(14), child: child),
          ],
        ),
      );
    }

    Widget kalemSatir(String label, String deger) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.black54, fontSize: 14),
              ),
              Text(
                deger,
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ],
          ),
        );

    Widget kalemSatirRenk(String label, String deger, Color renk) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: TextStyle(color: renk, fontSize: 14)),
              Text(
                deger,
                style: TextStyle(
                  color: renk,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // 1. GÜNLÜK SATIŞ
          if (gunlukSatis > 0) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.red[700],
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.red.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.trending_up, color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'GÜNLÜK SATIŞ',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _formatTL(gunlukSatis),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // 2. POS TOPLAMI
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0288D1),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0288D1).withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.credit_card, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    'POS TOPLAMI',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      letterSpacing: 1,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _formatTL(_toplamPos),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 3. ÖDEME KANALLARI (Pulse okunmuşsa)
          _pulseKanallarWidgeti(),
          if (_pulseOkundu) const SizedBox(height: 12),

          // 4. HARCAMALAR (varsa)
          if (toplamHarcama > 0) ...[
            bolumKart(
              renk: const Color(0xFFE53935),
              ikon: Icons.receipt_long,
              baslik: 'HARCAMALAR',
              toplam: _formatTL(toplamHarcama),
              child: Column(
                children: _harcamalar
                    .where((h) => _parseDouble(h.tutarCtrl.text) > 0)
                    .map(
                      (h) => kalemSatir(
                        h.aciklamaCtrl.text.isEmpty
                            ? 'Harcama'
                            : h.aciklamaCtrl.text,
                        _formatTL(_parseDouble(h.tutarCtrl.text)),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // 5. KASA ÖZETİ
          _kasaOzetiSection(),
          const SizedBox(height: 12),

          // 6. ANA KASA HARCAMALAR (varsa)
          if (toplamAnaKasaHarcama > 0) ...[
            bolumKart(
              renk: const Color(0xFFE65100),
              ikon: Icons.money_off,
              baslik: 'ANA KASA HARCAMALAR',
              toplam: _formatTL(toplamAnaKasaHarcama),
              child: Column(
                children: _anaKasaHarcamalari
                    .where((h) => _parseDouble(h.tutarCtrl.text) > 0)
                    .map(
                      (h) => kalemSatir(
                        h.aciklamaCtrl.text.isEmpty
                            ? 'Harcama'
                            : h.aciklamaCtrl.text,
                        _formatTL(_parseDouble(h.tutarCtrl.text)),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // 7. NAKİT ÇIKIŞ (varsa)
          if (toplamNakitCikis > 0 ||
              _nakitDovizler.any(
                (d) =>
                    _parseDouble((d['ctrl'] as TextEditingController).text) > 0,
              )) ...[
            bolumKart(
              renk: const Color(0xFF7B1FA2),
              ikon: Icons.payments_outlined,
              baslik: 'NAKİT ÇIKIŞ',
              toplam: toplamNakitCikis > 0 ? _formatTL(toplamNakitCikis) : null,
              child: Column(
                children: [
                  ..._nakitCikislar
                      .where((h) => _parseDouble(h.tutarCtrl.text) > 0)
                      .map((h) {
                    final aciklama = h.aciklamaCtrl.text.trim();
                    return kalemSatir(
                      aciklama.isNotEmpty ? 'TL - $aciklama' : 'Nakit Çıkış TL',
                      _formatTL(_parseDouble(h.tutarCtrl.text)),
                    );
                  }),
                  ..._nakitDovizler
                      .where(
                    (d) =>
                        _parseDouble(
                          (d['ctrl'] as TextEditingController).text,
                        ) >
                        0,
                  )
                      .map((d) {
                    final cins = d['cins'] as String;
                    final sembol = cins == 'USD'
                        ? r'$'
                        : cins == 'EUR'
                            ? '€'
                            : cins == 'GBP'
                                ? '£'
                                : cins;
                    final aciklama =
                        (d['aciklamaCtrl'] as TextEditingController?)
                                ?.text
                                .trim() ??
                            '';
                    return kalemSatir(
                      aciklama.isNotEmpty
                          ? '$cins - $aciklama'
                          : 'Nakit Çıkış $cins',
                      '$sembol ${(d['ctrl'] as TextEditingController).text}',
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // 8. ANA KASA ÖZETİ
          _anaKasaSection(),
          const SizedBox(height: 12),

          // 9. TRANSFERLER (varsa)
          Builder(
            builder: (context) {
              final sadeceTrf = _transferler
                  .where(
                    (t) => t['kategori'] == 'GİDEN' || t['kategori'] == 'GELEN',
                  )
                  .toList();
              if (sadeceTrf.isEmpty) return const SizedBox.shrink();
              final gidenler =
                  sadeceTrf.where((t) => t['kategori'] == 'GİDEN').toList();
              final gelenler =
                  sadeceTrf.where((t) => t['kategori'] == 'GELEN').toList();
              final toplamGiden = gidenler.fold(
                0.0,
                (s, t) =>
                    s +
                    _parseDouble(
                      (t['tutarCtrl'] as TextEditingController).text,
                    ),
              );
              final toplamGelen = gelenler.fold(
                0.0,
                (s, t) =>
                    s +
                    _parseDouble(
                      (t['tutarCtrl'] as TextEditingController).text,
                    ),
              );
              final netTransfer = toplamGelen - toplamGiden;

              return bolumKart(
                renk: const Color(0xFF546E7A),
                ikon: Icons.swap_horiz,
                baslik: 'TRANSFERLER',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (gidenler.isNotEmpty) ...[
                      Text(
                        'GİDEN',
                        style: TextStyle(
                          color: Colors.red[700],
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      ...gidenler.map((t) {
                        final hedefAd =
                            (t['hedefSubeAd'] as String?)?.isNotEmpty == true
                                ? t['hedefSubeAd'] as String
                                : (t['hedefSube'] as String? ?? '');
                        final aciklama = t['aciklama'] as String? ?? '';
                        final aciklamaTemiz =
                            aciklama == hedefAd ? '' : aciklama;
                        final label = [
                          if (hedefAd.isNotEmpty) hedefAd,
                          if (aciklamaTemiz.isNotEmpty) aciklamaTemiz,
                        ].join(' - ');
                        return kalemSatirRenk(
                          label.isEmpty ? 'Transfer' : label,
                          '- ${_formatTL(_parseDouble((t['tutarCtrl'] as TextEditingController).text))}',
                          Colors.red[700]!,
                        );
                      }),
                      const SizedBox(height: 4),
                    ],
                    if (gelenler.isNotEmpty) ...[
                      const Text(
                        'GELEN',
                        style: TextStyle(
                          color: Color(0xFF0288D1),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      ...gelenler.map((t) {
                        final kaynakAd =
                            (t['kaynakSubeAd'] as String?)?.isNotEmpty == true
                                ? t['kaynakSubeAd'] as String
                                : (_subeAdlari[t['kaynakSube'] ?? ''] ??
                                    t['kaynakSube'] as String? ??
                                    '');
                        final aciklama = t['aciklama'] as String? ?? '';
                        final aciklamaTemiz =
                            aciklama == kaynakAd ? '' : aciklama;
                        final label = [
                          if (kaynakAd.isNotEmpty) kaynakAd,
                          if (aciklamaTemiz.isNotEmpty) aciklamaTemiz,
                        ].join(' - ');
                        return kalemSatirRenk(
                          label.isEmpty ? 'Transfer' : label,
                          '+ ${_formatTL(_parseDouble((t['tutarCtrl'] as TextEditingController).text))}',
                          const Color(0xFF0288D1),
                        );
                      }),
                      const SizedBox(height: 4),
                    ],
                    if (toplamGiden > 0 || toplamGelen > 0) ...[
                      const Divider(),
                      if (toplamGiden > 0)
                        kalemSatirRenk(
                          'Toplam Giden',
                          '- ${_formatTL(toplamGiden)}',
                          Colors.red[700]!,
                        ),
                      if (toplamGelen > 0)
                        kalemSatirRenk(
                          'Toplam Gelen',
                          '+ ${_formatTL(toplamGelen)}',
                          const Color(0xFF0288D1),
                        ),
                      if (toplamGiden > 0 && toplamGelen > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Net Transfer',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: netTransfer >= 0
                                      ? const Color(0xFF0288D1)
                                      : Colors.red[700],
                                ),
                              ),
                              Text(
                                '${netTransfer >= 0 ? '+' : '-'} ${_formatTL(netTransfer.abs())}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: netTransfer >= 0
                                      ? const Color(0xFF0288D1)
                                      : Colors.red[700],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              );
            },
          ),

          // 10. DİĞER ALIMLAR (varsa)
          Builder(
            builder: (context) {
              final digerListesi = _digerAlimlar.where((da) {
                final aciklama =
                    ((da['aciklamaCtrl'] as TextEditingController?)?.text ?? '')
                        .trim();
                final tutar = _parseDouble(
                  (da['tutarCtrl'] as TextEditingController?)?.text ?? '0',
                );
                return aciklama.isNotEmpty || tutar > 0;
              }).toList();
              if (digerListesi.isEmpty) return const SizedBox.shrink();
              final toplam = digerListesi.fold(
                0.0,
                (s, da) =>
                    s +
                    _parseDouble(
                      (da['tutarCtrl'] as TextEditingController?)?.text ?? '0',
                    ),
              );
              return Column(
                children: [
                  const SizedBox(height: 12),
                  bolumKart(
                    renk: Colors.grey[700]!,
                    ikon: Icons.shopping_bag_outlined,
                    baslik: 'DİĞER ALIMLAR',
                    toplam: _formatTL(toplam),
                    child: Column(
                      children: digerListesi
                          .where(
                        (da) =>
                            _parseDouble(
                              (da['tutarCtrl'] as TextEditingController?)
                                      ?.text ??
                                  '0',
                            ) >
                            0,
                      )
                          .map((da) {
                        final aciklama =
                            ((da['aciklamaCtrl'] as TextEditingController?)
                                        ?.text ??
                                    '')
                                .trim();
                        final tutar = _parseDouble(
                          (da['tutarCtrl'] as TextEditingController?)?.text ??
                              '0',
                        );
                        return kalemSatir(
                          aciklama.isEmpty ? '—' : aciklama,
                          _formatTL(tutar),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              );
            },
          ),

          // Uyarılar
          const SizedBox(height: 12),
          if (_dovizLimitiAsildi)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red[300]!),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red[700], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Bankaya yatırılan döviz miktarı kasadakinden fazla!',
                      style: TextStyle(
                        color: Colors.red[700],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_anaKasaLimitiAsildi)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.deepOrange[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.deepOrange[300]!),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.account_balance_wallet,
                    color: Colors.deepOrange[700],
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Ana Kasa eksi kalıyor (${_formatTL(_anaKasaKalani)})!',
                      style: TextStyle(
                        color: Colors.deepOrange[800],
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (!_internetVar)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange[400]!),
              ),
              child: Row(
                children: [
                  Icon(Icons.wifi_off, color: Colors.orange[800], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'İnternet bağlantısı yok. Kayıt yapılamaz.',
                      style: TextStyle(
                        color: Colors.orange[900],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── PDF Oluştur — Özet & Kapat sekmesinden çağrılır ───────────────────────
  Future<void> _pdfOlustur() async {
    final pdf = pw.Document();
    final subeAd = _subeAdlari[widget.subeKodu] ?? widget.subeKodu;
    final font = await PdfGoogleFonts.notoSansRegular();
    final fontBold = await PdfGoogleFonts.notoSansBold();

    String fmt(double val) {
      final parts = val.toStringAsFixed(2).split('.');
      final buf = StringBuffer();
      for (int i = 0; i < parts[0].length; i++) {
        if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write('.');
        buf.write(parts[0][i]);
      }
      return '${buf.toString()},${parts[1]}';
    }

    final koyu = pw.TextStyle(
      font: fontBold,
      fontFallback: [font],
      fontSize: 10,
    );
    final normal = pw.TextStyle(
      font: font,
      fontFallback: [fontBold],
      fontSize: 10,
    );

    pw.Widget bolumBaslik(String baslik, PdfColor renk, {String? toplam}) =>
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: renk,
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                baslik,
                style: pw.TextStyle(
                  font: fontBold,
                  color: PdfColors.white,
                  fontSize: 11,
                ),
              ),
              if (toplam != null)
                pw.Text(
                  toplam,
                  style: pw.TextStyle(
                    font: fontBold,
                    color: PdfColors.white,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        );

    pw.Widget satir(String label, String deger, {pw.TextStyle? style}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(label, style: normal),
              pw.Text(deger, style: style ?? koyu),
            ],
          ),
        );

    pw.Widget satirGirinti(String label, String deger, {PdfColor? renk}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.only(left: 10, top: 1, bottom: 1),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                '  $label',
                style: pw.TextStyle(
                  font: font,
                  fontSize: 9,
                  color: renk ?? PdfColors.grey700,
                ),
              ),
              pw.Text(
                deger,
                style: pw.TextStyle(
                  font: fontBold,
                  fontSize: 9,
                  color: renk ?? PdfColors.grey700,
                ),
              ),
            ],
          ),
        );

    // Pulse kanalları
    final yemeklerPdf = <String, double>{};
    final onlinelerPdf = <String, double>{};
    // docId → ad lookup
    final yemekIdAdPdf = {
      for (final t in _yemekKartiTanimlari)
        t['id'] as String: t['ad'] as String,
    };
    final onlineIdAdPdf = {
      for (final o in _onlineOdemeler) o['id'] as String: o['ad'] as String,
    };

    for (final entry in _pulseKiyasCtrl.entries) {
      final key = entry.key;
      final val = _parseDouble(entry.value.text);
      if (val <= 0) continue;
      if (key.startsWith('yemek_')) {
        final docId = key.substring(6);
        yemeklerPdf[yemekIdAdPdf[docId] ?? docId] = val;
      } else if (key.startsWith('online_')) {
        final docId = key.substring(7);
        onlinelerPdf[onlineIdAdPdf[docId] ?? docId] = val;
      }
    }
    final yemekToplamPdf = yemeklerPdf.values.fold(0.0, (s, v) => s + v);
    final onlineToplamPdf = onlinelerPdf.values.fold(0.0, (s, v) => s + v);

    final icerik = <pw.Widget>[
      // Başlık
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(10),
        color: PdfColor.fromHex('#7B1F2E'),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              '$subeAd Günlük Özet',
              style: pw.TextStyle(
                font: fontBold,
                color: PdfColors.white,
                fontSize: 14,
              ),
            ),
            pw.Text(
              _tarihGoster(_secilenTarih),
              style: pw.TextStyle(
                font: font,
                color: PdfColors.white,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 8),

      // 1. Günlük Satış
      if (_parseDouble(_gunlukSatisCtrl.text) > 0)
        pw.Container(
          width: double.infinity,
          color: PdfColors.red700,
          child: pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'GÜNLÜK SATIŞ',
                  style: pw.TextStyle(
                    font: fontBold,
                    color: PdfColors.white,
                    fontSize: 12,
                  ),
                ),
                pw.Text(
                  fmt(_parseDouble(_gunlukSatisCtrl.text)),
                  style: pw.TextStyle(
                    font: fontBold,
                    color: PdfColors.white,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      pw.SizedBox(height: 4),

      // 2. POS
      bolumBaslik(
        'POS TOPLAMI',
        PdfColors.blueGrey700,
        toplam: fmt(_toplamPos),
      ),
      pw.SizedBox(height: 4),

      // 3. Ödeme Kanalları
      if (_pulseOkundu &&
          (yemeklerPdf.isNotEmpty || onlinelerPdf.isNotEmpty)) ...[
        bolumBaslik(
          'ÖDEME KANALLARI (Pulse)',
          PdfColor.fromHex('#006064'),
          toplam: fmt(yemekToplamPdf + onlineToplamPdf),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.teal200),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (yemeklerPdf.isNotEmpty) ...[
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Yemek Kartları',
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 10,
                        color: PdfColor.fromHex('#2E7D32'),
                      ),
                    ),
                    pw.Text(
                      fmt(yemekToplamPdf),
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 10,
                        color: PdfColor.fromHex('#2E7D32'),
                      ),
                    ),
                  ],
                ),
                ...yemeklerPdf.entries.map(
                  (e) => satirGirinti(
                    e.key,
                    fmt(e.value),
                    renk: PdfColor.fromHex('#388E3C'),
                  ),
                ),
              ],
              if (onlinelerPdf.isNotEmpty) ...[
                if (yemeklerPdf.isNotEmpty) pw.SizedBox(height: 4),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Online Ödemeler',
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 10,
                        color: PdfColor.fromHex('#1565C0'),
                      ),
                    ),
                    pw.Text(
                      fmt(onlineToplamPdf),
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 10,
                        color: PdfColor.fromHex('#1565C0'),
                      ),
                    ),
                  ],
                ),
                ...onlinelerPdf.entries.map(
                  (e) => satirGirinti(
                    e.key,
                    fmt(e.value),
                    renk: PdfColor.fromHex('#1976D2'),
                  ),
                ),
              ],
            ],
          ),
        ),
        pw.SizedBox(height: 4),
      ],

      // 4. Harcamalar
      if (_toplamHarcama > 0) ...[
        bolumBaslik(
          'HARCAMALAR',
          PdfColors.red700,
          toplam: fmt(_toplamHarcama),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300),
          ),
          child: pw.Column(
            children: _harcamalar
                .where((h) => _parseDouble(h.tutarCtrl.text) > 0)
                .map(
                  (h) => satir(
                    h.aciklamaCtrl.text.isEmpty
                        ? 'Harcama'
                        : h.aciklamaCtrl.text,
                    fmt(_parseDouble(h.tutarCtrl.text)),
                  ),
                )
                .toList(),
          ),
        ),
        pw.SizedBox(height: 4),
      ],

      // 5. Kasa Özeti
      bolumBaslik('KASA ÖZETİ', PdfColors.green700),
      pw.SizedBox(height: 4),
      pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 6),
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          color: PdfColors.blue50,
          border: pw.Border.all(color: PdfColors.blue200),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'TL',
              style: pw.TextStyle(
                font: fontBold,
                fontSize: 10,
                color: PdfColor.fromHex('#1565C0'),
              ),
            ),
            pw.SizedBox(height: 4),
            satir('Banka Parası', fmt(_bankaParasi)),
            if (_parseDouble(_devredenFlotCtrl.text) > 0)
              satir('Devreden Flot', fmt(_parseDouble(_devredenFlotCtrl.text))),
            if (_toplamHarcama > 0) satir('Harcamalar', fmt(_toplamHarcama)),
            if (_flotTutari > 0) satir('Günlük Flot', fmt(_flotTutari)),
            satir('Toplam Nakit', fmt(_toplamNakitTL)),
            if (_kasaFarki.abs() >= 0.01)
              pw.Container(
                margin: const pw.EdgeInsets.symmetric(vertical: 4),
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                color: _kasaFarki >= 0 ? PdfColors.green600 : PdfColors.red600,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Kasa Farkı',
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 10,
                        color: PdfColors.white,
                      ),
                    ),
                    pw.Text(
                      fmt(_kasaFarki),
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 10,
                        color: PdfColors.white,
                      ),
                    ),
                  ],
                ),
              ),
            pw.Divider(color: PdfColors.blue200),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Günlük Kasa Kalanı',
                  style: pw.TextStyle(
                    font: fontBold,
                    fontSize: 10,
                    color: PdfColor.fromHex('#1565C0'),
                  ),
                ),
                pw.Text(
                  fmt(_gunlukKasaKalaniTL),
                  style: pw.TextStyle(
                    font: fontBold,
                    fontSize: 10,
                    color: _gunlukKasaKalaniTL >= 0
                        ? PdfColor.fromHex('#1565C0')
                        : PdfColors.red700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        color: _gunlukKasaKalani >= 0 ? PdfColors.green700 : PdfColors.red700,
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Günlük Toplam Kasa Kalanı',
              style: pw.TextStyle(
                font: fontBold,
                fontSize: 11,
                color: PdfColors.white,
              ),
            ),
            pw.Text(
              fmt(_gunlukKasaKalani),
              style: pw.TextStyle(
                font: fontBold,
                fontSize: 11,
                color: PdfColors.white,
              ),
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 6),

      // 6. Ana Kasa Harcamalar
      if (_toplamAnaKasaHarcama > 0) ...[
        bolumBaslik(
          'ANA KASA HARCAMALAR',
          PdfColors.orange700,
          toplam: fmt(_toplamAnaKasaHarcama),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300),
          ),
          child: pw.Column(
            children: _anaKasaHarcamalari
                .where((h) => _parseDouble(h.tutarCtrl.text) > 0)
                .map(
                  (h) => satir(
                    h.aciklamaCtrl.text.isEmpty
                        ? 'Harcama'
                        : h.aciklamaCtrl.text,
                    fmt(_parseDouble(h.tutarCtrl.text)),
                  ),
                )
                .toList(),
          ),
        ),
        pw.SizedBox(height: 4),
      ],

      // 7. Nakit Çıkış
      if (_toplamNakitCikis > 0 ||
          _nakitDovizler.any(
            (d) => _parseDouble((d['ctrl'] as TextEditingController).text) > 0,
          )) ...[
        bolumBaslik(
          'NAKİT ÇIKIŞ',
          PdfColor.fromHex('#7B1FA2'),
          toplam: _toplamNakitCikis > 0 ? fmt(_toplamNakitCikis) : null,
        ),
        ..._nakitCikislar.where((h) => _parseDouble(h.tutarCtrl.text) > 0).map((
          h,
        ) {
          final aciklama = h.aciklamaCtrl.text.trim();
          return satir(
            aciklama.isNotEmpty ? 'TL - $aciklama' : 'Nakit Çıkış TL',
            fmt(_parseDouble(h.tutarCtrl.text)),
          );
        }),
        ..._nakitDovizler
            .where(
          (d) => _parseDouble((d['ctrl'] as TextEditingController).text) > 0,
        )
            .map((d) {
          final cins = d['cins'] as String;
          final sembol = cins == 'USD'
              ? r'$'
              : cins == 'EUR'
                  ? '€'
                  : cins == 'GBP'
                      ? '£'
                      : cins;
          final aciklama =
              (d['aciklamaCtrl'] as TextEditingController?)?.text.trim() ?? '';
          return satir(
            aciklama.isNotEmpty ? '$cins - $aciklama' : 'Nakit Çıkış $cins',
            '$sembol ${_parseDouble((d['ctrl'] as TextEditingController).text).toStringAsFixed(2)}',
          );
        }),
        pw.SizedBox(height: 4),
      ],

      // 8. Ana Kasa Özeti
      bolumBaslik(
        'ANA KASA ÖZETİ',
        PdfColors.blue900,
        toplam: fmt(_anaKasaKalani),
      ),
      pw.Container(
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300),
        ),
        child: pw.Column(
          children: [
            pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 4),
              padding: const pw.EdgeInsets.all(6),
              decoration: pw.BoxDecoration(
                color: PdfColors.blue50,
                border: pw.Border.all(color: PdfColors.blue200),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'TL',
                    style: pw.TextStyle(
                      font: fontBold,
                      fontSize: 10,
                      color: PdfColor.fromHex('#1565C0'),
                    ),
                  ),
                  pw.SizedBox(height: 4),
                  satir('Devreden Ana Kasa', fmt(_oncekiAnaKasaKalani)),
                  satir('Günlük Kasa Kalanı (TL)', fmt(_gunlukKasaKalaniTL)),
                  if (_parseDouble(_bankayaYatiranCtrl.text) > 0)
                    satir(
                      'Bankaya Yatırılan',
                      fmt(_parseDouble(_bankayaYatiranCtrl.text)),
                    ),
                  if (_toplamAnaKasaHarcama > 0)
                    satir('Ana Kasa Harcamalar', fmt(_toplamAnaKasaHarcama)),
                  if (_toplamNakitCikis > 0)
                    satir('Nakit Çıkış', fmt(_toplamNakitCikis)),
                  pw.Divider(color: PdfColors.blue200),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    color: _anaKasaKalani >= 0
                        ? PdfColors.green700
                        : PdfColors.red700,
                    child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(
                          'Ana Kasa Kalanı',
                          style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: PdfColors.white,
                          ),
                        ),
                        pw.Text(
                          fmt(_anaKasaKalani),
                          style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: PdfColors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 6),

      // 9. Transferler
      if (_transferler.any(
        (t) => t['kategori'] == 'GİDEN' || t['kategori'] == 'GELEN',
      )) ...[
        () {
          final trf = _transferler
              .where(
                (t) => t['kategori'] == 'GİDEN' || t['kategori'] == 'GELEN',
              )
              .toList();
          double netT = 0;
          for (final t in trf) {
            final kat = t['kategori'] as String;
            final tutar = _parseDouble(
              (t['tutarCtrl'] as TextEditingController).text,
            );
            if (kat == 'GELEN') netT += tutar;
            if (kat == 'GİDEN') netT -= tutar;
          }
          return bolumBaslik(
            'TRANSFERLER',
            PdfColors.blueGrey600,
            toplam: '${netT >= 0 ? '+' : '-'} ${fmt(netT.abs())}',
          );
        }(),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300),
          ),
          child: pw.Column(
            children: _transferler
                .where(
              (t) => t['kategori'] == 'GİDEN' || t['kategori'] == 'GELEN',
            )
                .map((t) {
              final kat = t['kategori'] as String;
              final isGiden = kat == 'GİDEN';
              final renk = isGiden ? PdfColors.red700 : PdfColors.blue900;
              final prefix = isGiden ? '- ' : '+ ';
              final tutar = _parseDouble(
                (t['tutarCtrl'] as TextEditingController).text,
              );
              final aciklama =
                  (t['aciklamaCtrl'] as TextEditingController).text;
              final subeAd = isGiden
                  ? (t['hedefSubeAd'] as String? ?? '')
                  : (t['kaynakSubeAd'] as String? ?? '');
              final label = [
                kat,
                if (subeAd.isNotEmpty) subeAd,
                if (aciklama.isNotEmpty && aciklama != subeAd) aciklama,
              ].join(' - ');
              return pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 2),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      label,
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 10,
                        color: renk,
                      ),
                    ),
                    pw.Text(
                      '$prefix${fmt(tutar)}',
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 10,
                        color: renk,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        pw.SizedBox(height: 4),
      ],

      // 10. Diğer Alımlar
      if (_digerAlimlar.any(
        (da) =>
            _parseDouble((da['tutarCtrl'] as TextEditingController).text) > 0,
      )) ...[
        () {
          final toplam = _digerAlimlar.fold(
            0.0,
            (s, da) =>
                s +
                _parseDouble((da['tutarCtrl'] as TextEditingController).text),
          );
          return bolumBaslik(
            'DİĞER ALIMLAR',
            PdfColors.grey,
            toplam: fmt(toplam),
          );
        }(),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300),
          ),
          child: pw.Column(
            children: _digerAlimlar
                .where(
                  (da) =>
                      _parseDouble(
                        (da['tutarCtrl'] as TextEditingController).text,
                      ) >
                      0,
                )
                .map(
                  (da) => satir(
                    ((da['aciklamaCtrl'] as TextEditingController).text).isEmpty
                        ? '—'
                        : (da['aciklamaCtrl'] as TextEditingController).text,
                    fmt(
                      _parseDouble(
                        (da['tutarCtrl'] as TextEditingController).text,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    ];

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(16),
        build: (context) {
          final pageW = PdfPageFormat.a4.availableWidth - 32;
          return pw.Center(
            child: pw.FittedBox(
              fit: pw.BoxFit.contain,
              alignment: pw.Alignment.center,
              child: pw.SizedBox(
                width: pageW,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  mainAxisSize: pw.MainAxisSize.min,
                  children: icerik,
                ),
              ),
            ),
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (_) => pdf.save());
  }

  // ── Pulse Ödeme Kanalları — Özet & Kapat sekmesi için ─────────────────────
  // pulseResmiOkundu=true ise yemek kartları ve online kanalları gösterir
  Widget _pulseKanallarWidgeti() {
    if (!_pulseOkundu) return const SizedBox.shrink();

    // pulseKiyasCtrl'den yemek ve online kanalları ayır
    final yemekler = <String, double>{};
    final onlineler = <String, double>{};

    // docId → ad lookup map'leri
    final yemekIdAd = {
      for (final t in _yemekKartiTanimlari)
        t['id'] as String: t['ad'] as String,
    };
    final onlineIdAd = {
      for (final o in _onlineOdemeler) o['id'] as String: o['ad'] as String,
    };

    for (final entry in _pulseKiyasCtrl.entries) {
      final key = entry.key;
      final val = _parseDouble(entry.value.text);
      if (val <= 0) continue;
      if (key.startsWith('yemek_')) {
        final docId = key.substring(6);
        final ad = yemekIdAd[docId] ?? docId;
        yemekler[ad] = val;
      } else if (key.startsWith('online_')) {
        final docId = key.substring(7);
        final ad = onlineIdAd[docId] ?? docId;
        onlineler[ad] = val;
      }
      // 'pulse_', 'pulsePos', 'pulseBrut', 'pulseBanka' — widget'a dahil değil
    }

    if (yemekler.isEmpty && onlineler.isEmpty) return const SizedBox.shrink();

    final yemekToplam = yemekler.values.fold(0.0, (s, v) => s + v);
    final onlineToplam = onlineler.values.fold(0.0, (s, v) => s + v);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00695C).withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF00695C),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.account_balance_wallet_outlined,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                const Text(
                  'ÖDEME KANALLARI',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _formatTL(yemekToplam + onlineToplam),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Yemek Kartları
                if (yemekler.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Yemek Kartları',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFF2E7D32),
                        ),
                      ),
                      Text(
                        _formatTL(yemekToplam),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFF2E7D32),
                        ),
                      ),
                    ],
                  ),
                  ...yemekler.entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(left: 12, top: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            e.key,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[700],
                            ),
                          ),
                          Text(
                            _formatTL(e.value),
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[700],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                // Online Ödemeler
                if (onlineler.isNotEmpty) ...[
                  if (yemekler.isNotEmpty) const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Online Ödemeler',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFF1565C0),
                        ),
                      ),
                      Text(
                        _formatTL(onlineToplam),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFF1565C0),
                        ),
                      ),
                    ],
                  ),
                  ...onlineler.entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(left: 12, top: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            e.key,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[700],
                            ),
                          ),
                          Text(
                            _formatTL(e.value),
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[700],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kasaOzetiSection() {
    final devredenFlot = _parseDouble(_devredenFlotCtrl.text);
    final kasaFarki = _kasaFarki;
    // Günlük Kasa Kalanı sadece TL (döviz dahil değil)
    final gunlukKasaKalaniSadeceTL = _gunlukKasaKalaniTL;
    // Toplam Kasa Kalanı = TL + dövizler
    final toplamKasaKalani = _gunlukKasaKalani;
    final herhangiDovizVar = _dovizTurleri.any(
      (t) => _buGunDovizMiktari(t) > 0,
    );

    return Card(
      color: const Color(0xFFF0F4F8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Kasa Özeti', Icons.summarize),

            // ── TL Kartı ──
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFE3F2FD),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF90CAF9)),
              ),
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Text(
                          'TL',
                          style: TextStyle(
                            color: Color(0xFF1565C0),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Banka Parası
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Banka Parası',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1976D2),
                        ),
                      ),
                      Text(
                        _formatTL(_bankaParasi),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1565C0),
                        ),
                      ),
                    ],
                  ),
                  // Devreden Flot
                  if (devredenFlot > 0) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Devreden Flot',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1976D2),
                          ),
                        ),
                        Text(
                          _formatTL(devredenFlot),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // Harcamalar
                  if (_toplamHarcama > 0) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Harcamalar',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1976D2),
                          ),
                        ),
                        Text(
                          _formatTL(_toplamHarcama),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // Günlük Flot
                  if (_flotTutari > 0) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Günlük Flot',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1976D2),
                          ),
                        ),
                        Text(
                          _formatTL(_flotTutari),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // Toplam Nakit
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Toplam Nakit',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1976D2),
                        ),
                      ),
                      Text(
                        _formatTL(_toplamNakitTL),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1565C0),
                        ),
                      ),
                    ],
                  ),
                  // Kasa Farkı — şerit içinde belirgin
                  if (kasaFarki.abs() >= 0.01) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: kasaFarki >= 0
                            ? Colors.green[600]
                            : Colors.red[600],
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Kasa Farkı',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            _formatTL(kasaFarki),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const Divider(height: 12, color: Color(0xFF90CAF9)),
                  // Günlük Kasa Kalanı — sadece TL
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Günlük Kasa Kalanı',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1976D2),
                        ),
                      ),
                      Text(
                        _formatTL(gunlukKasaKalaniSadeceTL),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: gunlukKasaKalaniSadeceTL >= 0
                              ? const Color(0xFF1565C0)
                              : Colors.red[700],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Döviz Kartları ──
            ..._dovizTurleri.where((t) => _buGunDovizMiktari(t) > 0).map((t) {
              final sembol = t == 'USD'
                  ? r'$'
                  : t == 'EUR'
                      ? '€'
                      : '£';
              final bgRenk = dovizBgRenk(t);
              final yaziRenk = dovizRenk(t);
              final borderRenk = t == 'USD'
                  ? const Color(0xFFFFCC80)
                  : t == 'EUR'
                      ? const Color(0xFFCE93D8)
                      : const Color(0xFFA5D6A7);
              final miktar = _buGunDovizMiktari(t);
              final kur = _dovizKur(t);
              final tlKarsiligi = miktar * kur;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: bgRenk,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: borderRenk),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '$sembol $t',
                          style: TextStyle(
                            color: yaziRenk,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '$sembol ${miktar.toStringAsFixed(2)}',
                          style: TextStyle(
                            color: yaziRenk,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                    if (kur > 0) ...[
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'TL Karşılığı',
                            style: TextStyle(
                              fontSize: 11,
                              color: yaziRenk.withOpacity(0.8),
                            ),
                          ),
                          Text(
                            _formatTL(tlKarsiligi),
                            style: TextStyle(fontSize: 11, color: yaziRenk),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            }),

            // ── Günlük Toplam Kasa Kalanı — her zaman göster ──
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color:
                    toplamKasaKalani >= 0 ? Colors.green[700] : Colors.red[700],
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Günlük Toplam Kasa Kalanı',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    _formatTL(toplamKasaKalani),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Transferler ──────────────────────────────────────────────────────────────

  Widget _transferlerSection() {
    return KeyedSubtree(key: _transferKey, child: _transferlerIcerik());
  }

  Widget _transferlerIcerik() {
    final gidenler =
        _transferler.where((t) => t['kategori'] == 'GİDEN').toList();
    final gelenler =
        _transferler.where((t) => t['kategori'] == 'GELEN').toList();
    final digerSubeler =
        _subeAdlari.entries.where((e) => e.key != widget.subeKodu).toList();

    double toplamGiden = gidenler.fold(
      0.0,
      (s, t) =>
          s + _parseDouble((t['tutarCtrl'] as TextEditingController).text),
    );
    double toplamGelen = gelenler.fold(
      0.0,
      (s, t) =>
          s + _parseDouble((t['tutarCtrl'] as TextEditingController).text),
    );
    double netTransfer = toplamGelen - toplamGiden;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitleTransfer('Transferler', Icons.swap_horiz),
            ..._transferler.asMap().entries.map((e) {
              final idx = e.key;
              final t = e.value;
              final kategori = t['kategori'] as String;
              final gonderildi = t['gonderildi'] == true;
              final onaylandi = t['onaylandi'] == true;
              final reddedildi = t['reddedildi'] == true;
              final bekletildi = t['bekletildi'] == true;
              final duzenlemeModunda = t['duzenlemeModunda'] == true;

              // Renk: GİDEN = kırmızı, GELEN = mavi
              final Color renk = kategori == 'GİDEN'
                  ? Colors.red[700]!
                  : const Color(0xFF0288D1);

              // Durum badge rengi ve metni (GİDEN ve GELEN için)
              Color durumRenk = Colors.grey[400]!;
              String durumMetin = '';
              IconData durumIkon = Icons.circle_outlined;
              if (onaylandi) {
                durumRenk = Colors.green[700]!;
                durumMetin = 'Onaylandı';
                durumIkon = Icons.check_circle;
              } else if (reddedildi) {
                durumRenk = Colors.red[700]!;
                durumMetin = 'Reddedildi';
                durumIkon = Icons.cancel;
              } else if (bekletildi) {
                durumRenk = Colors.orange[700]!;
                durumMetin = 'Bekletildi';
                durumIkon = Icons.hourglass_empty;
              } else if (gonderildi) {
                durumRenk = Colors.blue[600]!;
                durumMetin = kategori == 'GİDEN' ? 'Gönderildi' : 'Bildirildi';
                durumIkon =
                    kategori == 'GİDEN' ? Icons.send : Icons.mark_email_read;
              }

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: reddedildi ? Colors.red[50] : renk.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        reddedildi ? Colors.red[300]! : renk.withOpacity(0.25),
                  ),
                ),
                child: duzenlemeModunda
                    ? _transferDuzenlemeFormu(idx, t, renk, digerSubeler)
                    : _transferGoruntule(
                        idx,
                        t,
                        kategori,
                        renk,
                        durumRenk,
                        durumMetin,
                        durumIkon,
                        gonderildi,
                        onaylandi,
                        reddedildi,
                        digerSubeler,
                      ),
              );
            }),
            const SizedBox(height: 8),
            if (!_readOnly)
              TextButton.icon(
                onPressed: () => _transferEkle(),
                icon: const Icon(Icons.add),
                label: const Text('Transfer Ekle'),
              ),
            if (toplamGiden > 0 || toplamGelen > 0) ...[
              const Divider(),
              if (toplamGiden > 0)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Toplam Giden',
                      style: TextStyle(
                        color: Colors.red[700],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '- ${_formatTL(toplamGiden)}',
                      style: TextStyle(
                        color: Colors.red[700],
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              if (toplamGelen > 0)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Toplam Gelen',
                      style: TextStyle(
                        color: Color(0xFF0288D1),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '+ ${_formatTL(toplamGelen)}',
                      style: const TextStyle(
                        color: Color(0xFF0288D1),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              if (toplamGiden > 0 && toplamGelen > 0) ...[
                const Divider(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: netTransfer >= 0
                        ? const Color(0xFF0288D1).withOpacity(0.1)
                        : Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Net Transfer',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${netTransfer >= 0 ? "+" : ""} ${_formatTL(netTransfer.abs())}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: netTransfer >= 0
                              ? const Color(0xFF0288D1)
                              : Colors.red[700],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  // ── Transfer satırı görüntüleme (normal mod) ───────────────────────────────
  Widget _transferGoruntule(
    int idx,
    Map<String, dynamic> t,
    String kategori,
    Color renk,
    Color durumRenk,
    String durumMetin,
    IconData durumIkon,
    bool gonderildi,
    bool onaylandi,
    bool reddedildi,
    List<MapEntry<String, dynamic>> digerSubeler,
  ) {
    final hedefAd = _subeAdlari[t['hedefSube'] as String? ?? ''] ??
        (t['hedefSubeAd'] as String? ?? '');
    final kaynakAd = _subeAdlari[t['kaynakSube'] as String? ?? ''] ??
        (t['kaynakSubeAd'] as String? ?? '');
    final subeAd = kategori == 'GİDEN' ? hedefAd : kaynakAd;
    final tutar = _parseDouble((t['tutarCtrl'] as TextEditingController).text);
    final aciklama = (t['aciklamaCtrl'] as TextEditingController).text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Kategori badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: renk,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                kategori,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Şube adı
            Expanded(
              child: Text(
                subeAd.isNotEmpty ? subeAd : '—',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: renk,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Durum badge (GİDEN ve GELEN için)
            if (durumMetin.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: durumRenk.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: durumRenk.withOpacity(0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(durumIkon, size: 11, color: durumRenk),
                    const SizedBox(width: 3),
                    Text(
                      durumMetin,
                      style: TextStyle(
                        fontSize: 10,
                        color: durumRenk,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            if (!_readOnly) ...[
              const SizedBox(width: 6),
              // Düzenle butonu
              InkWell(
                onTap: () => setState(() => t['duzenlemeModunda'] = true),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: Colors.grey[600],
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            if (aciklama.isNotEmpty)
              Expanded(
                child: Text(
                  aciklama,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Expanded(child: SizedBox()),
            Text(
              tutar > 0
                  ? '${kategori == 'GİDEN' ? '-' : '+'} ${_formatTL(tutar)}'
                  : '—',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: tutar > 0 ? renk : Colors.grey[400],
              ),
            ),
          ],
        ),
        // GİDEN — Gönder butonu
        // Reddedildiyse: aktif "Tekrar Gönder" butonu
        // Henüz gönderilmediyse: aktif "Gönder" butonu
        // Gönderildi veya onaylandıysa: buton yok (badge gösteriyor)
        if (kategori == 'GİDEN' &&
            !onaylandi &&
            (!gonderildi || reddedildi)) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _readOnly
                  ? null
                  : () {
                      final hedef = t['hedefSube'] as String? ?? '';
                      final tutar0 = _parseDouble(
                        (t['tutarCtrl'] as TextEditingController).text,
                      );
                      final hazir =
                          hedef.isNotEmpty && hedef != 'diger' && tutar0 > 0;
                      if (hazir) _transferiGonder(idx);
                    },
              icon: Icon(reddedildi ? Icons.refresh : Icons.send, size: 15),
              label: Text(
                reddedildi ? 'Tekrar Gönder' : 'Gönder',
                style: const TextStyle(fontSize: 13),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: reddedildi
                    ? Colors.red[700]
                    : () {
                        final hedef = t['hedefSube'] as String? ?? '';
                        final tutar0 = _parseDouble(
                          (t['tutarCtrl'] as TextEditingController).text,
                        );
                        final hazir =
                            hedef.isNotEmpty && hedef != 'diger' && tutar0 > 0;
                        return hazir
                            ? const Color(0xFF0288D1)
                            : Colors.grey[400];
                      }(),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
        ],
        // GELEN — Bildir butonu (Gönder ile aynı mantık, sadece isim farklı)
        // Reddedildiyse: aktif "Tekrar Bildir" butonu
        // Henüz bildirilmediyse: aktif "Bildir" butonu
        // Bildirildi veya onaylandıysa: buton yok (badge gösteriyor)
        if (kategori == 'GELEN' &&
            !onaylandi &&
            (!gonderildi || reddedildi)) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _readOnly
                  ? null
                  : () {
                      final kaynak = t['kaynakSube'] as String? ?? '';
                      final tutar0 = _parseDouble(
                        (t['tutarCtrl'] as TextEditingController).text,
                      );
                      final hazir = kaynak.isNotEmpty && tutar0 > 0;
                      if (hazir) _gelenTransferBildir(idx);
                    },
              icon: Icon(
                reddedildi ? Icons.refresh : Icons.mark_email_unread,
                size: 15,
              ),
              label: Text(
                reddedildi ? 'Tekrar Bildir' : 'Bildir',
                style: const TextStyle(fontSize: 13),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: reddedildi
                    ? Colors.red[700]
                    : () {
                        final kaynak = t['kaynakSube'] as String? ?? '';
                        final tutar0 = _parseDouble(
                          (t['tutarCtrl'] as TextEditingController).text,
                        );
                        return kaynak.isNotEmpty && tutar0 > 0
                            ? const Color(0xFF0288D1)
                            : Colors.grey[400];
                      }(),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ── Transfer düzenleme formu ───────────────────────────────────────────────
  Widget _transferDuzenlemeFormu(
    int idx,
    Map<String, dynamic> t,
    Color renk,
    List<MapEntry<String, dynamic>> digerSubeler,
  ) {
    final kategori = t['kategori'] as String;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Başlık satırı
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: renk,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                kategori,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Spacer(),
            // Sil butonu
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.red,
                size: 20,
              ),
              onPressed: () {
                (t['aciklamaCtrl'] as TextEditingController).dispose();
                (t['tutarCtrl'] as TextEditingController).dispose();
                setState(() => _transferler.removeAt(idx));
                _transferKaydet();
              },
              tooltip: 'Sil',
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Şube seçimi — yeni kayıtta odaklanmış açılır
        DropdownButtonFormField<String>(
          autofocus: t['yeni'] == true,
          value: () {
            final val = kategori == 'GİDEN'
                ? (t['hedefSube'] as String? ?? '')
                : (t['kaynakSube'] as String? ?? '');
            return val.isNotEmpty && digerSubeler.any((s) => s.key == val)
                ? val
                : null;
          }(),
          onChanged: (v) => setState(() {
            if (kategori == 'GİDEN') {
              t['hedefSube'] = v ?? '';
              t['hedefSubeAd'] = _subeAdlari[v ?? ''] ?? v ?? '';
            } else {
              t['kaynakSube'] = v ?? '';
              t['kaynakSubeAd'] = _subeAdlari[v ?? ''] ?? v ?? '';
            }
            _transferKaydet();
          }),
          decoration: InputDecoration(
            labelText: kategori == 'GİDEN' ? 'Hedef Şube' : 'Gönderen Şube',
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            labelStyle: TextStyle(color: renk, fontSize: 12),
          ),
          items: digerSubeler
              .map(
                (s) => DropdownMenuItem(
                  value: s.key,
                  child: Text(s.value, style: const TextStyle(fontSize: 13)),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 8),
        // Açıklama + Tutar
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: t['aciklamaCtrl'] as TextEditingController,
                inputFormatters: [IlkHarfBuyukFormatter()],
                decoration: const InputDecoration(
                  labelText: 'Açıklama',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                ),
                textInputAction: TextInputAction.next,
                onChanged: (_) => _transferKaydet(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextFormField(
                controller: t['tutarCtrl'] as TextEditingController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [BinAraciFormatter()],
                decoration: const InputDecoration(
                  labelText: 'Tutar (₺)',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                ),
                onChanged: (_) => _transferKaydet(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Kaydet + İptal
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () async {
                  final kat = t['kategori'] as String;
                  final daha_once_gonderildi = t['gonderildi'] == true;
                  final yeni = t['yeni'] == true;

                  // Daha önce gönderilmiş/bildirilmişse uyarı dialogu göster
                  if (daha_once_gonderildi && !yeni) {
                    final eylem = kat == 'GİDEN' ? 'Gönder' : 'Bildir';
                    final sonuc = await showDialog<String>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Row(
                          children: [
                            Icon(
                              Icons.warning_amber,
                              color: Colors.orange[700],
                            ),
                            const SizedBox(width: 8),
                            Text('Düzenleme Uyarısı'),
                          ],
                        ),
                        content: Text(
                          'Bu transfer daha önce $eylem\'e basılmıştı.\n\n'
                          'Kaydetmeniz halinde karşı şubeye tekrar $eylem '
                          'basmanız gerekecek.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, 'iptal'),
                            child: Text(
                              'İptal — $eylem\'me',
                              style: TextStyle(color: Colors.grey[700]),
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () => Navigator.pop(context, 'kaydet'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0288D1),
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('Kaydet'),
                          ),
                        ],
                      ),
                    );
                    if (sonuc != 'kaydet') return;
                  }

                  setState(() {
                    t['duzenlemeModunda'] = false;
                    t['yeni'] = false;
                    // Düzenleme sonrası gönderim sıfırla (yeniden Gönder/Bildir gerekli)
                    t['gonderildi'] = false;
                    t['onaylandi'] = false;
                    t['bekletildi'] = false;
                    t['reddedildi'] = false;
                  });
                  await _transferKaydet();
                },
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Kaydet', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0288D1),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(() => t['duzenlemeModunda'] = false),
                icon: const Icon(Icons.close, size: 16, color: Colors.grey),
                label: const Text(
                  'İptal',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.grey),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Transfer ekle — GİDEN / GELEN seç ────────────────────────────────────
  void _transferEkle() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Transfer Türü Seç'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.arrow_upward, color: Colors.red),
              title: const Text(
                'GİDEN',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: const Text('Bu şubeden çıkan para'),
              onTap: () {
                Navigator.pop(context);
                setState(
                  () => _transferler.add({
                    'kategori': 'GİDEN',
                    'hedefSube': '',
                    'hedefSubeAd': '',
                    'kaynakSube': widget.subeKodu,
                    'kaynakSubeAd':
                        _subeAdlari[widget.subeKodu] ?? widget.subeKodu,
                    'aciklamaCtrl': TextEditingController(),
                    'tutarCtrl': TextEditingController(),
                    'gonderildi': false,
                    'onaylandi': false,
                    'reddedildi': false,
                    'bekletildi': false,
                    'transferId': '',
                    'duzenlemeModunda': true,
                    'yeni': true,
                  }),
                );
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.arrow_downward,
                color: Color(0xFF0288D1),
              ),
              title: const Text(
                'GELEN',
                style: TextStyle(
                  color: Color(0xFF0288D1),
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: const Text('Bu şubeye gelen para'),
              onTap: () {
                Navigator.pop(context);
                setState(
                  () => _transferler.add({
                    'kategori': 'GELEN',
                    'kaynakSube': '',
                    'kaynakSubeAd': '',
                    'hedefSube': widget.subeKodu,
                    'hedefSubeAd':
                        _subeAdlari[widget.subeKodu] ?? widget.subeKodu,
                    'aciklamaCtrl': TextEditingController(),
                    'tutarCtrl': TextEditingController(),
                    'gonderildi': false,
                    'onaylandi': false,
                    'reddedildi': false,
                    'bekletildi': false,
                    'transferId': '',
                    'duzenlemeModunda': true,
                    'yeni': true,
                  }),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Diğer Alımlar ─────────────────────────────────────────────────────────────

  Widget _digerAlimlarSection() {
    double toplam = _digerAlimlar.fold(
      0.0,
      (s, t) =>
          s + _parseDouble((t['tutarCtrl'] as TextEditingController).text),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitleDigerAlim(
              'Diğer Alımlar',
              Icons.shopping_bag_outlined,
            ),
            ..._digerAlimlar.asMap().entries.map((e) {
              int idx = e.key;
              Map<String, dynamic> t = e.value;
              const renk = Colors.grey;

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _readOnly
                          ? TextFormField(
                              controller:
                                  t['aciklamaCtrl'] as TextEditingController,
                              readOnly: true,
                              decoration: const InputDecoration(
                                labelText: 'Açıklama',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                              ),
                            )
                          : DigerAlimAciklamaAlani(
                              ctrl: t['aciklamaCtrl'] as TextEditingController,
                              secenekler: _giderTurleriListesi,
                              onChanged: () {
                                if (mounted && !_yukleniyor) {
                                  setState(() {
                                    _degisiklikVar = true;
                                    if (_duzenlemeAcik)
                                      _gercekDegisiklikVar = true;
                                  });
                                  if (_kilitTutuyorum) {
                                    _kilitTimer?.cancel();
                                    _kilitTimer = Timer(
                                      const Duration(minutes: 20),
                                      _kilitBirak,
                                    );
                                  } else {
                                    _kilitAl();
                                  }
                                }
                              },
                            ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: t['tutarCtrl'] as TextEditingController,
                        readOnly: _readOnly,
                        decoration: const InputDecoration(
                          labelText: 'Tutar',
                          suffixText: '₺',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [BinAraciFormatter()],
                        onChanged: (_) {
                          if (mounted && !_yukleniyor) {
                            setState(() {
                              _degisiklikVar = true;
                              if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                            });
                            if (_kilitTutuyorum) {
                              _kilitTimer?.cancel();
                              _kilitTimer = Timer(
                                const Duration(minutes: 20),
                                _kilitBirak,
                              );
                            } else {
                              _kilitAl();
                            }
                          }
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.remove_circle_outline,
                        color: Colors.red,
                        size: 20,
                      ),
                      onPressed: _readOnly
                          ? null
                          : () {
                              setState(() {
                                (t['aciklamaCtrl'] as TextEditingController)
                                    .dispose();
                                (t['tutarCtrl'] as TextEditingController)
                                    .dispose();
                                _digerAlimlar.removeAt(idx);
                                _degisiklikVar = true;
                              });
                            },
                    ),
                  ],
                ),
              );
            }),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _readOnly
                      ? null
                      : () => setState(
                            () => _digerAlimlar.add({
                              'aciklamaCtrl': TextEditingController(),
                              'tutarCtrl': TextEditingController(),
                              'yeni': true,
                            }),
                          ),
                  icon: const Icon(Icons.add),
                  label: const Text('Ekle'),
                ),
              ],
            ),
            if (toplam > 0) ...[
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Toplam',
                    style: TextStyle(
                      color: Colors.grey[700],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _formatTL(toplam),
                    style: TextStyle(
                      color: Colors.grey[700],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _anaKasaHarcamalarSection() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Color(0xFFDC2626), width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('Ana Kasa Harcamalar', Icons.money_off),
              ..._anaKasaHarcamalari.asMap().entries.map((e) {
                int idx = e.key;
                HarcamaGirisi h = e.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: GiderAdiAlani(
                          ctrl: h.aciklamaCtrl,
                          secenekler: _giderTurleriListesi,
                          readOnly: _readOnly,
                          labelText: 'Açıklama ${idx + 1}',
                          onChanged: () {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: h.tutarCtrl,
                          readOnly: _readOnly,
                          decoration: const InputDecoration(
                            labelText: 'Tutar (₺)',
                            suffixText: '₺',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          inputFormatters: [BinAraciFormatter()],
                          onChanged: (_) {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      if (_anaKasaHarcamalari.length > 1)
                        IconButton(
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            color: Colors.red,
                          ),
                          onPressed: _readOnly
                              ? null
                              : () {
                                  setState(() {
                                    _anaKasaHarcamalari[idx].dispose();
                                    _anaKasaHarcamalari.removeAt(idx);
                                    _degisiklikVar = true;
                                  });
                                },
                        ),
                    ],
                  ),
                );
              }),
              TextButton.icon(
                onPressed: _readOnly
                    ? null
                    : () => setState(
                          () => _anaKasaHarcamalari
                              .add(HarcamaGirisi(yeni: true)),
                        ),
                icon: const Icon(Icons.add),
                label: const Text('Harcama Ekle'),
              ),
              if (_toplamAnaKasaHarcama > 0) ...[
                const Divider(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDC2626),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Toplam Harcama',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        _formatTL(_toplamAnaKasaHarcama),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Nakit Çıkış ──────────────────────────────────────────────────────────────

  Widget _nakitCikisSection() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Color(0xFFDC2626), width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('Nakit Çıkış', Icons.payments_outlined),
              ..._nakitCikislar.asMap().entries.map((e) {
                int idx = e.key;
                HarcamaGirisi h = e.value;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: GiderAdiAlani(
                          ctrl: h.aciklamaCtrl,
                          secenekler: _giderTurleriListesi,
                          readOnly: _readOnly,
                          labelText: 'Açıklama ${idx + 1}',
                          onChanged: () {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: h.tutarCtrl,
                          readOnly: _readOnly,
                          decoration: const InputDecoration(
                            labelText: 'Tutar (₺)',
                            suffixText: '₺',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.next,
                          inputFormatters: [BinAraciFormatter()],
                          onChanged: (_) {
                            if (mounted && !_yukleniyor) {
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                              if (_kilitTutuyorum) {
                                _kilitTimer?.cancel();
                                _kilitTimer = Timer(
                                  const Duration(minutes: 20),
                                  _kilitBirak,
                                );
                              } else {
                                _kilitAl();
                              }
                            }
                          },
                        ),
                      ),
                      if (_nakitCikislar.length > 1)
                        IconButton(
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            color: Colors.red,
                          ),
                          onPressed: _readOnly
                              ? null
                              : () {
                                  setState(() {
                                    _nakitCikislar[idx].dispose();
                                    _nakitCikislar.removeAt(idx);
                                    _degisiklikVar = true;
                                  });
                                },
                        ),
                    ],
                  ),
                );
              }),
              TextButton.icon(
                onPressed: _readOnly
                    ? null
                    : () => setState(
                          () => _nakitCikislar.add(HarcamaGirisi(yeni: true)),
                        ),
                icon: const Icon(Icons.add),
                label: const Text('Nakit Çıkış Ekle'),
              ),
              // Döviz nakit çıkışlar
              ..._nakitDovizler.asMap().entries.map((e) {
                final idx = e.key;
                final d = e.value;
                final cins = d['cins'] as String;
                final sembol = cins == 'USD'
                    ? r'$'
                    : cins == 'EUR'
                        ? '€'
                        : cins == 'GBP'
                            ? '£'
                            : cins;
                final dovizAnaKasa = _dovizAnaKasa(cins);
                final girilen = _parseDouble(
                  (d['ctrl'] as TextEditingController).text,
                );
                final fazla = dovizAnaKasa <= 0;
                final limitAsti = girilen > dovizAnaKasa && dovizAnaKasa > 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 80,
                            child: DropdownButtonFormField<String>(
                              value: cins,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                                border: OutlineInputBorder(),
                              ),
                              items: ['USD', 'EUR', 'GBP', 'CHF', 'SAR']
                                  .map(
                                    (c) => DropdownMenuItem(
                                      value: c,
                                      child: Text(
                                        c,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _readOnly
                                  ? null
                                  : (v) => setState(() => d['cins'] = v),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: d['ctrl'] as TextEditingController,
                              enabled: !fazla && !_readOnly,
                              decoration: InputDecoration(
                                labelText: fazla
                                    ? 'Kasada $cins yok'
                                    : 'Miktar ($sembol) — Max: ${dovizAnaKasa.toStringAsFixed(2)}',
                                suffixText: sembol,
                                prefixIcon: Icon(
                                  Icons.payments_outlined,
                                  color: fazla
                                      ? Colors.grey
                                      : limitAsti
                                          ? Colors.red[700]
                                          : Colors.purple[700],
                                ),
                                labelStyle: TextStyle(
                                  color: fazla
                                      ? Colors.grey
                                      : limitAsti
                                          ? Colors.red[700]
                                          : Colors.purple[700],
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderSide: BorderSide(
                                    color: limitAsti
                                        ? Colors.red[700]!
                                        : Colors.grey[300]!,
                                  ),
                                ),
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              inputFormatters: [BinAraciFormatter()],
                              onChanged: (_) {
                                if (!_yukleniyor)
                                  setState(() {
                                    _degisiklikVar = true;
                                    if (_duzenlemeAcik)
                                      _gercekDegisiklikVar = true;
                                  });
                              },
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.remove_circle_outline,
                              color: Colors.red,
                            ),
                            onPressed: _readOnly
                                ? null
                                : () {
                                    setState(() {
                                      (d['ctrl'] as TextEditingController)
                                          .dispose();
                                      _nakitDovizler.removeAt(idx);
                                      _degisiklikVar = true;
                                    });
                                  },
                          ),
                        ],
                      ),
                      if (limitAsti)
                        Padding(
                          padding: const EdgeInsets.only(left: 8, top: 2),
                          child: Row(
                            children: [
                              Icon(
                                Icons.warning_amber,
                                color: Colors.red[700],
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Kasada yalnizca $sembol ${dovizAnaKasa.toStringAsFixed(2)} var!',
                                style: TextStyle(
                                  color: Colors.red[700],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (fazla)
                        Padding(
                          padding: const EdgeInsets.only(left: 8, top: 2),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: Colors.grey[600],
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Kasada $cins bulunmuyor',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      // Açıklama alanı
                      if (!fazla) ...[
                        const SizedBox(height: 6),
                        TextFormField(
                          controller:
                              d['aciklamaCtrl'] as TextEditingController? ??
                                  TextEditingController(),
                          enabled: !_readOnly,
                          decoration: InputDecoration(
                            labelText: 'Açıklama (isteğe bağlı)',
                            isDense: true,
                            prefixIcon: Icon(
                              Icons.notes,
                              color: Colors.purple[300],
                              size: 18,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            border: const OutlineInputBorder(),
                          ),
                          inputFormatters: [IlkHarfBuyukFormatter()],
                          onChanged: (_) {
                            if (!_yukleniyor)
                              setState(() {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              });
                          },
                        ),
                      ],
                    ],
                  ),
                );
              }),
              TextButton.icon(
                onPressed: _readOnly
                    ? null
                    : () => setState(
                          () => _nakitDovizler.add({
                            'cins': 'USD',
                            'ctrl': TextEditingController(),
                            'aciklamaCtrl': TextEditingController(),
                          }),
                        ),
                icon: Icon(
                  Icons.add,
                  color: _readOnly ? Colors.grey : Colors.purple[700],
                ),
                label: Text(
                  'Döviz Çıkış Ekle',
                  style: TextStyle(
                    color: _readOnly ? Colors.grey : Colors.purple[700],
                  ),
                ),
              ),
              if (_toplamNakitCikis > 0 ||
                  _nakitDovizler.any(
                    (d) =>
                        _parseDouble(
                          (d['ctrl'] as TextEditingController).text,
                        ) >
                        0,
                  )) ...[
                const Divider(),
                // TL toplam şeridi
                if (_toplamNakitCikis > 0)
                  Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Toplam Nakit Çıkış (TL)',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          _formatTL(_toplamNakitCikis),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                // Döviz şeritleri — kendi renkleriyle
                ..._nakitDovizler
                    .where(
                      (d) =>
                          _parseDouble(
                            (d['ctrl'] as TextEditingController).text,
                          ) >
                          0,
                    )
                    .fold<Map<String, double>>({}, (map, d) {
                      final cins = d['cins'] as String;
                      map[cins] = (map[cins] ?? 0) +
                          _parseDouble(
                            (d['ctrl'] as TextEditingController).text,
                          );
                      return map;
                    })
                    .entries
                    .map((entry) {
                      final cins = entry.key;
                      final sembol = cins == 'USD'
                          ? r'$'
                          : cins == 'EUR'
                              ? '€'
                              : cins == 'GBP'
                                  ? '£'
                                  : cins;
                      final bgRenk = dovizBgRenk(cins);
                      final yaziRenk = dovizRenk(cins);
                      final borderRenk = cins == 'USD'
                          ? const Color(0xFFFFCC80)
                          : cins == 'EUR'
                              ? const Color(0xFFCE93D8)
                              : const Color(0xFFA5D6A7);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: bgRenk,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: borderRenk),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Nakit Çıkış ($cins)',
                              style: TextStyle(
                                color: yaziRenk,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              '$sembol ${entry.value.toStringAsFixed(2)}',
                              style: TextStyle(
                                color: yaziRenk,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Bankaya Yatan ────────────────────────────────────────────────────────────

  Widget _bankayaYatanSection() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Color(0xFF0369A1), width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('Bankaya Yatan', Icons.account_balance),
              // TL
              TextFormField(
                controller: _bankayaYatiranCtrl,
                readOnly: _readOnly,
                decoration: const InputDecoration(
                  labelText: 'TL (₺)',
                  suffixText: '₺',
                  prefixIcon: Icon(
                    Icons.account_balance,
                    color: Color(0xFF0288D1),
                  ),
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                inputFormatters: [BinAraciFormatter()],
                onChanged: (_) => setState(() {
                  if (!_yukleniyor) {
                    _degisiklikVar = true;
                    if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                  }
                }),
              ),
              const SizedBox(height: 8),
              // Döviz - dinamik
              ..._bankaDovizler.asMap().entries.map((e) {
                int idx = e.key;
                Map<String, dynamic> d = e.value;
                final cins = d['cins'] as String;
                final sembol = cins == 'USD'
                    ? '\$'
                    : cins == 'EUR'
                        ? '€'
                        : '£';
                final dovizAnaKasa = _dovizAnaKasa(cins);
                final girilen = _parseDouble(
                  (d['ctrl'] as TextEditingController).text,
                );
                final fazla = dovizAnaKasa <= 0;
                final limitAsti = girilen > dovizAnaKasa && dovizAnaKasa > 0;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 80,
                            child: DropdownButtonFormField<String>(
                              value: cins,
                              isExpanded: true,
                              menuMaxHeight: 200,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                                border: OutlineInputBorder(),
                              ),
                              items: ['USD', 'EUR', 'GBP', 'CHF', 'SAR']
                                  .map(
                                    (c) => DropdownMenuItem(
                                      value: c,
                                      child: Text(
                                        c,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) => setState(() => d['cins'] = v),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: d['ctrl'] as TextEditingController,
                              enabled: !fazla,
                              decoration: InputDecoration(
                                labelText: fazla
                                    ? 'Kasada $cins yok'
                                    : 'Miktar ($sembol) — Max: ${dovizAnaKasa.toStringAsFixed(2)}',
                                suffixText: sembol,
                                prefixIcon: Icon(
                                  Icons.account_balance,
                                  color: fazla
                                      ? Colors.grey
                                      : limitAsti
                                          ? Colors.red[700]
                                          : Colors.orange[700],
                                ),
                                labelStyle: TextStyle(
                                  color: fazla
                                      ? Colors.grey
                                      : limitAsti
                                          ? Colors.red[700]
                                          : Colors.orange[700],
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderSide: BorderSide(
                                    color: limitAsti
                                        ? Colors.red[700]!
                                        : Colors.grey[300]!,
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderSide: BorderSide(
                                    color: limitAsti
                                        ? Colors.red[700]!
                                        : Colors.orange[700]!,
                                  ),
                                ),
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              textInputAction: TextInputAction.next,
                              inputFormatters: [BinAraciFormatter()],
                              onChanged: (_) => setState(() {
                                if (!_yukleniyor) {
                                  _degisiklikVar = true;
                                  if (_duzenlemeAcik)
                                    _gercekDegisiklikVar = true;
                                }
                              }),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.remove_circle_outline,
                              color: Colors.red,
                            ),
                            onPressed: _readOnly
                                ? null
                                : () {
                                    setState(() {
                                      (d['ctrl'] as TextEditingController)
                                          .dispose();
                                      _bankaDovizler.removeAt(idx);
                                      _degisiklikVar = true;
                                    });
                                  },
                          ),
                        ],
                      ),
                      if (limitAsti)
                        Padding(
                          padding: const EdgeInsets.only(left: 8, top: 2),
                          child: Row(
                            children: [
                              Icon(
                                Icons.warning_amber,
                                color: Colors.red[700],
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Kasada yalnızca $sembol ${dovizAnaKasa.toStringAsFixed(2)} var!',
                                style: TextStyle(
                                  color: Colors.red[700],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (fazla)
                        Padding(
                          padding: const EdgeInsets.only(left: 8, top: 2),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: Colors.grey[600],
                                size: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Kasada $cins bulunmuyor',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              }),
              TextButton.icon(
                onPressed: _readOnly
                    ? null
                    : () => setState(
                          () => _bankaDovizler.add({
                            'cins': 'USD',
                            'ctrl': TextEditingController(),
                          }),
                        ),
                icon: Icon(
                  Icons.add,
                  color: _readOnly ? Colors.grey : const Color(0xFF0369A1),
                ),
                label: Text(
                  'Döviz Ekle',
                  style: TextStyle(
                    color: _readOnly ? Colors.grey : const Color(0xFF0369A1),
                  ),
                ),
              ),
              // ── Toplam Şeritleri ──
              if (_parseDouble(_bankayaYatiranCtrl.text) > 0 ||
                  _bankaDovizler.any(
                    (d) =>
                        _parseDouble(
                          (d['ctrl'] as TextEditingController).text,
                        ) >
                        0,
                  )) ...[
                const Divider(),
                // TL şeridi
                if (_parseDouble(_bankayaYatiranCtrl.text) > 0)
                  Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0369A1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Bankaya Yatan (TL)',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          _formatTL(_parseDouble(_bankayaYatiranCtrl.text)),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                // Döviz şeritleri — kendi renkleriyle
                ..._bankaDovizler
                    .where(
                      (d) =>
                          _parseDouble(
                            (d['ctrl'] as TextEditingController).text,
                          ) >
                          0,
                    )
                    .fold<Map<String, double>>({}, (map, d) {
                      final cins = d['cins'] as String;
                      map[cins] = (map[cins] ?? 0) +
                          _parseDouble(
                            (d['ctrl'] as TextEditingController).text,
                          );
                      return map;
                    })
                    .entries
                    .map((entry) {
                      final cins = entry.key;
                      final sembol = cins == 'USD'
                          ? r'$'
                          : cins == 'EUR'
                              ? '€'
                              : cins == 'GBP'
                                  ? '£'
                                  : cins;
                      final bgRenk = dovizBgRenk(cins);
                      final yaziRenk = dovizRenk(cins);
                      final borderRenk = cins == 'USD'
                          ? const Color(0xFFFFCC80)
                          : cins == 'EUR'
                              ? const Color(0xFFCE93D8)
                              : const Color(0xFFA5D6A7);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: bgRenk,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: borderRenk),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Bankaya Yatan ($cins)',
                              style: TextStyle(
                                color: yaziRenk,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              '$sembol ${entry.value.toStringAsFixed(2)}',
                              style: TextStyle(
                                color: yaziRenk,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Ana Kasa Özeti ───────────────────────────────────────────────────────────

  Widget _anaKasaSection() {
    return Card(
      color: const Color(0xFFF0F4F8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Ana Kasa Özeti', Icons.account_balance),

            // ── TL Kartı ──
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFE3F2FD),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF90CAF9)),
              ),
              child: Column(
                children: [
                  // Başlık
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Text(
                          'TL',
                          style: TextStyle(
                            color: Color(0xFF1565C0),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Devreden Ana Kasa
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Devreden Ana Kasa',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1976D2),
                        ),
                      ),
                      Text(
                        _formatTL(_oncekiAnaKasaKalani),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1565C0),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // Günlük Kasa Kalanı
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Günlük Kasa Kalanı (TL)',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1976D2),
                        ),
                      ),
                      Text(
                        _formatTL(_gunlukKasaKalaniTL),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1565C0),
                        ),
                      ),
                    ],
                  ),
                  if (_parseDouble(_bankayaYatiranCtrl.text) > 0) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Bankaya Yatırılan',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1976D2),
                          ),
                        ),
                        Text(
                          _formatTL(_parseDouble(_bankayaYatiranCtrl.text)),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (_toplamAnaKasaHarcama > 0) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Ana Kasa Harcamalar',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1976D2),
                          ),
                        ),
                        Text(
                          _formatTL(_toplamAnaKasaHarcama),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // Nakit Çıkış TL — toplam (açıklama yok)
                  if (_nakitCikislar.any((h) => _parseDouble(h.tutar) > 0)) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Nakit Çıkış',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1976D2),
                          ),
                        ),
                        Text(
                          _formatTL(
                            _nakitCikislar.fold(
                              0.0,
                              (s, h) => s + _parseDouble(h.tutar),
                            ),
                          ),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const Divider(height: 10, color: Color(0xFF90CAF9)),
                  // Ana Kasa Kalanı — yeşil/kırmızı bant
                  Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _anaKasaKalani >= 0
                          ? Colors.green[700]
                          : Colors.red[700],
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Ana Kasa Kalanı',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          _formatTL(_anaKasaKalani),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ..._dovizTurleri
                .where(
              (t) =>
                  _dovizAnaKasaKalani(t) != 0 ||
                  _buGunDovizMiktari(t) > 0 ||
                  (_devredenDovizMiktarlari[t] ?? 0) > 0,
            )
                .map((t) {
              final sembol = t == 'USD'
                  ? r'$'
                  : t == 'EUR'
                      ? '€'
                      : '£';
              final kalan = _dovizAnaKasaKalani(t);
              // Cins bazlı renkler: USD turuncu, EUR mor, GBP koyu yeşil
              final bgRenk = t == 'USD'
                  ? const Color(0xFFFFF8E1)
                  : t == 'EUR'
                      ? const Color(0xFFF3E5F5)
                      : const Color(0xFFE8F5E9);
              final yaziRenk = t == 'USD'
                  ? const Color(0xFFE65100)
                  : t == 'EUR'
                      ? const Color(0xFF6A1B9A)
                      : const Color(0xFF1B5E20);
              final borderRenk = t == 'USD'
                  ? const Color(0xFFFFCC80)
                  : t == 'EUR'
                      ? const Color(0xFFCE93D8)
                      : const Color(0xFFA5D6A7);
              final nakitCikisT = _nakitDovizCikis(t);
              return Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: bgRenk,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderRenk),
                ),
                child: Column(
                  children: [
                    // Başlık
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Text(
                            '$sembol $t',
                            style: TextStyle(
                              color: yaziRenk,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Devreden
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Devreden Ana Kasa',
                          style: TextStyle(
                            fontSize: 12,
                            color: yaziRenk.withOpacity(0.8),
                          ),
                        ),
                        Text(
                          '$sembol ${(_devredenDovizMiktarlari[t] ?? 0).toStringAsFixed(2)}',
                          style: TextStyle(fontSize: 12, color: yaziRenk),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    // Günlük Kasa Kalanı
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Günlük Kasa Kalanı',
                          style: TextStyle(
                            fontSize: 12,
                            color: yaziRenk.withOpacity(0.8),
                          ),
                        ),
                        Text(
                          '$sembol ${_buGunDovizMiktari(t).toStringAsFixed(2)}',
                          style: TextStyle(fontSize: 12, color: yaziRenk),
                        ),
                      ],
                    ),
                    if (_dovizBankayaYatirilan(t) > 0) ...[
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Bankaya Yatırılan',
                            style: TextStyle(
                              fontSize: 12,
                              color: yaziRenk.withOpacity(0.8),
                            ),
                          ),
                          Text(
                            '$sembol ${_dovizBankayaYatirilan(t).toStringAsFixed(2)}',
                            style: TextStyle(fontSize: 12, color: yaziRenk),
                          ),
                        ],
                      ),
                    ],
                    // Döviz nakit çıkış — toplam (açıklama yok)
                    if (nakitCikisT > 0) ...[
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Nakit Çıkış',
                            style: TextStyle(
                              fontSize: 12,
                              color: yaziRenk.withOpacity(0.8),
                            ),
                          ),
                          Text(
                            '$sembol ${nakitCikisT.toStringAsFixed(2)}',
                            style: TextStyle(fontSize: 12, color: yaziRenk),
                          ),
                        ],
                      ),
                    ],
                    const Divider(height: 10),
                    // Ana Kasa Kalanı
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Ana Kasa Kalanı',
                          style: TextStyle(
                            color: yaziRenk,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '$sembol ${kalan.toStringAsFixed(2)}',
                          style: TextStyle(
                            color: kalan >= 0 ? yaziRenk : Colors.red[700],
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _altBaslik(String text, Color renk) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 13,
          color: renk,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _ozetSatiri(String label, String deger, Color renk) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('  $label', style: TextStyle(color: renk, fontSize: 14)),
          Text(
            deger,
            style: TextStyle(
              color: renk,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  // ── Döviz Ana Kasa ──────────────────────────────────────────────────────────

  Widget _dovizAnaKasaSection() {
    // Sadece herhangi bir döviz girişi varsa veya devreden varsa göster
    bool herhangiDovizVar = _dovizler.isNotEmpty ||
        _dovizTurleri.any((t) => (_devredenDovizMiktarlari[t] ?? 0) > 0) ||
        _dovizTurleri.any((t) => _dovizBankayaYatirilan(t) > 0);

    if (!herhangiDovizVar) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Döviz Ana Kasa', Icons.currency_exchange),
            ..._dovizTurleri.map((t) {
              final devreden = _devredenDovizMiktarlari[t] ?? 0;
              final bugun = _buGunDovizMiktari(t);
              final anaKasa = _dovizAnaKasa(t);
              final kalani = _dovizAnaKasaKalani(t);

              // Bu döviz türü için hiç veri yoksa gösterme
              if (devreden == 0 && bugun == 0 && _dovizBankayaYatirilan(t) == 0)
                return const SizedBox.shrink();

              String sembol = t == 'USD'
                  ? '\$'
                  : t == 'EUR'
                      ? '€'
                      : '£';

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0288D1).withOpacity(0.04),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFF0288D1).withOpacity(0.15),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '$sembol $t',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Color(0xFF0288D1),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _bilgiSatiri(
                      'Devreden',
                      '$sembol ${devreden.toStringAsFixed(2)}',
                    ),
                    _bilgiSatiri(
                      'Bu Gün Giren',
                      '$sembol ${bugun.toStringAsFixed(2)}',
                    ),
                    _bilgiSatiri(
                      'Ana Kasa',
                      '$sembol ${anaKasa.toStringAsFixed(2)}',
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Bankaya Yatırılan ($sembol):',
                            style: const TextStyle(
                              color: Colors.black54,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 120,
                          child: TextFormField(
                            controller: _dovizBankayaYatiranCtrl[t],
                            readOnly: _readOnly,
                            decoration: InputDecoration(
                              suffixText: sembol,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              border: const OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textInputAction: TextInputAction.next,
                            inputFormatters: [BinAraciFormatter()],
                            onChanged: (_) => setState(() {
                              if (!_yukleniyor) {
                                _degisiklikVar = true;
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
                              }
                            }),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color:
                            kalani >= 0 ? Colors.green[700] : Colors.red[700],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Kalan',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '$sembol ${kalani.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // İlk yükleme sırasında splash göster
    if (_banknotCtrl.isEmpty) {
      return Scaffold(
        backgroundColor: const Color(0xFF0288D1),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const KasaLogo(),
              const SizedBox(height: 24),
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                widget.subeKodu,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        // Web/telefon geri tuşu: önce kaydet, sonra çık
        if (_degisiklikVar && !_readOnly && !_duzenlemeAcik) {
          try {
            await FirebaseFirestore.instance
                .collection('subeler')
                .doc(widget.subeKodu)
                .collection('gunluk')
                .doc(_tarihKey(_secilenTarih))
                .set(_otomatikKayitVerisi(), SetOptions(merge: true));
            if (mounted) setState(() => _degisiklikVar = false);
          } catch (_) {}
        }
        if (!await _degisiklikUyar(gecisMetni: 'Çıkmadan')) return;
        // Geri tuşuna basınca uygulamayı minimize et, siyah ekran olmasın
        if (mounted) {
          final navigator = Navigator.of(context);
          if (navigator.canPop()) {
            navigator.pop();
          } else {
            // Arkada ekran yoksa minimize et
            SystemNavigator.pop();
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFF01579B),
                  Color(0xFF0288D1),
                  Color(0xFF29B6F6),
                ],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
          ),
          title: widget.subeler.length > 1
              ? DropdownButton<String>(
                  value: widget.subeKodu,
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
                  onChanged: (yeniSube) async {
                    if (yeniSube != null && yeniSube != widget.subeKodu) {
                      if (!await _degisiklikUyar(
                        gecisMetni: 'Şube değiştirmeden',
                      )) return;
                      if (mounted) {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => OnHazirlikEkrani(
                              subeKodu: yeniSube,
                              subeler: widget.subeler,
                              gecmisGunHakki: widget.gecmisGunHakki,
                            ),
                          ),
                        );
                      }
                    }
                  },
                )
              : Text('${_subeAdlari[widget.subeKodu] ?? widget.subeKodu} Kasa'),
          centerTitle: true,
          actions: [
            // Bekleyen transfer rozeti
            if (_bekleyenTransferSayisi > 0)
              Stack(
                children: [
                  IconButton(
                    icon: const Icon(Icons.swap_horiz),
                    tooltip: 'Bekleyen Transferler',
                    onPressed: () => _bekleyenTransferleriBildir(),
                  ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.orange,
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 14,
                        minHeight: 14,
                      ),
                      child: Text(
                        '$_bekleyenTransferSayisi',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            if (widget.raporYetkisi)
              IconButton(
                icon: const Icon(Icons.bar_chart),
                tooltip: 'Raporlar',
                onPressed: () async {
                  if (!await _degisiklikUyar(gecisMetni: 'Raporlara geçmeden'))
                    return;
                  if (mounted)
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => RaporlarEkrani(
                          subeler: widget.subeler.isNotEmpty
                              ? widget.subeler
                              : [widget.subeKodu],
                        ),
                      ),
                    );
                },
              ),
            IconButton(
              icon: const Icon(Icons.picture_as_pdf),
              tooltip: 'PDF',
              onPressed: () {
                if (!_gunuKapatildi) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('PDF için önce günü kapatın.'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                  return;
                }
                _pdfOlustur();
              },
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                switch (value) {
                  case 'sekme_temizle':
                    final sekmeAd = _sekmeAdlari[_tabController.index];
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text('$sekmeAd Temizle'),
                        content: Text(
                          '"$sekmeAd" sekmesindeki veriler silinecek. Emin misiniz?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('İptal'),
                          ),
                          TextButton(
                            onPressed: () async {
                              Navigator.pop(context);
                              await _aktifSekmeTemizle();
                            },
                            child: const Text(
                              'Temizle',
                              style: TextStyle(color: Color(0xFFB45309)),
                            ),
                          ),
                        ],
                      ),
                    );
                    break;
                  case 'temizle':
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Tümünü Temizle'),
                        content: const Text(
                          'Tüm girilen veriler silinecek. Emin misiniz?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('İptal'),
                          ),
                          TextButton(
                            onPressed: () async {
                              Navigator.pop(context);
                              await _formlariTemizle();
                            },
                            child: const Text(
                              'Temizle',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                    break;
                  case 'gecmis':
                    _degisiklikUyar(
                      gecisMetni: 'Geçmiş kayıtlara geçmeden',
                    ).then((devam) {
                      if (devam && mounted)
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => GecmisKayitlarEkrani(
                              subeKodu: widget.subeKodu,
                              subeler: widget.subeler,
                              gecmisGunHakki: widget.gecmisGunHakki,
                              sonKapaliTarih: _sonKapaliTarih,
                            ),
                          ),
                        );
                    });
                    break;
                  case 'cikis':
                    _cikisYap();
                    break;
                }
              },
              itemBuilder: (_) => [
                if ((_bugunSecili || _duzenlemeAcik || !_gunuKapatildi) &&
                    !_readOnly)
                  PopupMenuItem(
                    value: 'sekme_temizle',
                    child: Row(
                      children: [
                        const Icon(
                          Icons.cleaning_services_outlined,
                          color: Color(0xFFB45309),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Sayfayı Temizle (${_sekmeAdlari[_tabController.index]})',
                          style: const TextStyle(color: Color(0xFFB45309)),
                        ),
                      ],
                    ),
                  ),
                if ((_bugunSecili || _duzenlemeAcik || !_gunuKapatildi) &&
                    !_readOnly)
                  PopupMenuItem(
                    value: 'temizle',
                    child: const Row(
                      children: [
                        Icon(Icons.delete_sweep_outlined, color: Colors.red),
                        SizedBox(width: 12),
                        Text(
                          'Tümünü Temizle',
                          style: TextStyle(color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                const PopupMenuItem(
                  value: 'gecmis',
                  child: Row(
                    children: [
                      Icon(Icons.history, color: Color(0xFF0288D1)),
                      SizedBox(width: 12),
                      Text('Geçmiş Kayıtlar'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'cikis',
                  child: Row(
                    children: [
                      Icon(Icons.logout, color: Colors.red),
                      SizedBox(width: 12),
                      Text('Çıkış Yap', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            // Otomatik kayıt mesajı — StreamBuilder dışında, setState ile güvenli
            if (_appBarMesaj.isNotEmpty)
              Container(
                width: double.infinity,
                color: _appBarMesaj.contains('Hata')
                    ? Colors.red[700]
                    : _appBarMesaj.contains('Kaydediliyor')
                        ? Colors.blue[700]
                        : Colors.green[700],
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Icon(
                      _appBarMesaj.contains('Hata')
                          ? Icons.error_outline
                          : _appBarMesaj.contains('Kaydediliyor')
                              ? Icons.sync
                              : Icons.cloud_done,
                      color: Colors.white,
                      size: 15,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _appBarMesaj,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: StreamBuilder<DocumentSnapshot>(
                stream: _kilitStream(),
                builder: (context, kilitSnap) {
                  // Kilit verisi
                  String? kilitTutan;
                  if (kilitSnap.hasData && kilitSnap.data!.exists) {
                    final kilitData =
                        kilitSnap.data!.data() as Map<String, dynamic>?;
                    final k = kilitData?['kullanici'] as String? ?? '';
                    if (k != _mevcutKullanici && k.isNotEmpty) {
                      kilitTutan = k;
                    }
                  }
                  // Kilit durumunu güncelle
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && kilitTutan != _kilitTutanKullanici) {
                      setState(() => _kilitTutanKullanici = kilitTutan);
                    }
                  });

                  return Column(
                    children: [
                      // Kilit uyarı bandı
                      if (kilitTutan != null)
                        Container(
                          width: double.infinity,
                          color: Colors.orange[700],
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.lock,
                                color: Colors.white,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '🔒 $kilitTutan bu kayıtta işlem yapıyor — düzenleme kapalı.',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              // Yönetici kilidi zorla kaldırabilir
                              // (yönetici kontrolü — widget.subeler.length > 1 yönetici demek değil,
                              //  ama OnHazirlikEkraninda yonetici flagi yok; geçici olarak
                              //  tüm kullanıcılara göster, gelecekte rol sistemi ile kısıtlanacak)
                              TextButton(
                                onPressed: _kilidiZorlaKaldir,
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                ),
                                child: const Text(
                                  'Kilidi Kaldır',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    decoration: TextDecoration.underline,
                                    decorationColor: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      // Düzenleme modu bannerı
                      if (_duzenlemeAcik)
                        Container(
                          width: double.infinity,
                          color: Colors.orange[800],
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.edit,
                                color: Colors.white,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'Düzenleme Modundasınız — Değişiklik yaptıktan sonra Günü Kapat zorunludur',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // Tarih uyarı bannerı — bugün değilse veya tamamlanmamışsa
                      Builder(
                        builder: (context) {
                          final bugun = _bugunuHesapla();
                          final bugunMu = _secilenTarih.year == bugun.year &&
                              _secilenTarih.month == bugun.month &&
                              _secilenTarih.day == bugun.day;
                          final tamamlandi = _bugunTamamlandi;

                          if ((_gunuKapatildi || !bugunMu) && !_duzenlemeAcik) {
                            // Gün kapatılmış veya geçmiş tarih — banner göster
                          } else if (bugunMu && !_gunuKapatildi) {
                            // Bugün kapatılmamış — turuncu banner göster
                          } else {
                            return const SizedBox.shrink();
                          }

                          Color bannerRenk;
                          String bannerMetin;
                          IconData bannerIkon;

                          if (_gunuKapatildi && !_duzenlemeAcik) {
                            // Kayıt var ve kapatılmış
                            bannerRenk = Colors.green[700]!;
                            bannerIkon = Icons.lock;
                            bannerMetin =
                                '${_tarihGoster(_secilenTarih)} günü kapatıldı ✓';
                          } else if (!bugunMu &&
                              !_gunuKapatildi &&
                              !_duzenlemeAcik) {
                            // Geçmiş tarih, kapanmamış — gerçek bugünü de göster
                            bannerRenk = Colors.orange[700]!;
                            bannerIkon = Icons.warning_amber;
                            bannerMetin = 'Bugün ${_tarihGoster(bugun)} — '
                                '${_tarihGoster(_secilenTarih)} tarihini kapatmayı unutmayın';
                          } else if (!bugunMu && _duzenlemeAcik) {
                            bannerRenk = Colors.blue[700]!;
                            bannerIkon = Icons.edit;
                            bannerMetin =
                                '${_tarihGoster(_secilenTarih)} tarihini düzenliyorsunuz — bugün ${_tarihGoster(bugun)}';
                          } else {
                            bannerRenk = Colors.orange[700]!;
                            bannerIkon = Icons.warning_amber;
                            bannerMetin =
                                'Bugünün kaydı kapatılmadı — zorunlu alanları doldurup günü kapatın';
                          }

                          return Container(
                            width: double.infinity,
                            color: bannerRenk,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 7,
                            ),
                            child: Row(
                              children: [
                                Icon(bannerIkon, color: Colors.white, size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    bannerMetin,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      // Tarih seçici — her zaman görünür
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: _tarihSeciciSection(),
                      ),
                      // Günü Kapat / Düzenlemeyi Aç — tarih bandının altında sabit
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: _gunuKapatButonu(),
                      ),
                      // Sekme navigasyonu — yuvarlak chip sekmeler
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            // Sol ok
                            InkWell(
                              onTap: () {
                                if (_tabController.index > 0) {
                                  _tabController.animateTo(
                                    _tabController.index - 1,
                                  );
                                }
                              },
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFFCBD5E1),
                                    width: 1,
                                  ),
                                  color: Colors.white,
                                ),
                                child: const Icon(
                                  Icons.chevron_left,
                                  size: 18,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // Chip listesi
                            Expanded(
                              child: TabBar(
                                controller: _tabController,
                                isScrollable: true,
                                tabAlignment: TabAlignment.start,
                                indicator: const BoxDecoration(
                                  color: Colors.transparent,
                                ),
                                indicatorSize: TabBarIndicatorSize.tab,
                                dividerColor: Colors.transparent,
                                labelColor: Colors.transparent,
                                unselectedLabelColor: Colors.transparent,
                                labelStyle: const TextStyle(fontSize: 10),
                                unselectedLabelStyle: const TextStyle(
                                  fontSize: 10,
                                ),
                                splashBorderRadius: BorderRadius.circular(10),
                                overlayColor: WidgetStateProperty.all(
                                  Colors.transparent,
                                ),
                                padding: const EdgeInsets.only(
                                  bottom: 4,
                                  top: 4,
                                ),
                                tabs: [
                                  _chipTab('POS & Y. Kartı'),
                                  _chipTab('Pulse / My Dom.'),
                                  _chipTab('Günlük Kasa'),
                                  _chipTab('Ana Kasa'),
                                  _chipTab('Transfer/D. Alım'),
                                  _chipTab('Özet & Kapat'),
                                ],
                              ),
                            ),
                            const SizedBox(width: 4),
                            // Sağ ok
                            InkWell(
                              onTap: () {
                                if (_tabController.index < 5) {
                                  _tabController.animateTo(
                                    _tabController.index + 1,
                                  );
                                }
                              },
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFFCBD5E1),
                                    width: 1,
                                  ),
                                  color: Colors.white,
                                ),
                                child: const Icon(
                                  Icons.chevron_right,
                                  size: 18,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            // ── Sekme 1: POS & Yemek Kartı ──
                            SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  _posSection(),
                                  const SizedBox(height: 12),
                                  _yemekKartiSection(),
                                  const SizedBox(height: 32),
                                ],
                              ),
                            ),
                            // ── Sekme 2: Pulse / My Dominos ──
                            _pulseKiyasSekmesi(),
                            // ── Sekme 3: Şube Kasa ──
                            SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  _ekrandaGorunenNakitSection(),
                                  const SizedBox(height: 12),
                                  _harcamalarSection(),
                                  const SizedBox(height: 12),
                                  _nakitSayimSection(),
                                  const SizedBox(height: 12),
                                  _kasaOzetiSection(),
                                  const SizedBox(height: 32),
                                ],
                              ),
                            ),
                            // ── Sekme 4: Ana Kasa ──
                            SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  _anaKasaHarcamalarSection(),
                                  const SizedBox(height: 12),
                                  _bankayaYatanSection(),
                                  const SizedBox(height: 12),
                                  _nakitCikisSection(),
                                  const SizedBox(height: 12),
                                  _anaKasaSection(),
                                  const SizedBox(height: 32),
                                ],
                              ),
                            ),
                            // ── Sekme 5: Transfer / Diğer Alım ──
                            SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  _transferlerSection(),
                                  const SizedBox(height: 12),
                                  _digerAlimlarSection(),
                                  const SizedBox(height: 32),
                                ],
                              ),
                            ),
                            // ── Sekme 6: Özet & Kapat ──
                            _ozetKapatSekmesi(),
                          ], // TabBarView children kapanış
                        ), // TabBarView kapanış
                      ), // Expanded kapanış
                    ],
                  );
                },
              ),
            ), // Expanded kapanış
            // ── Global okuma bandı — tüm sekmelerde görünür ──
            if (_pulseOkunuyor ||
                _myDominosOkunuyor ||
                _posOkunuyor ||
                _okumaMesaji.isNotEmpty)
              Container(
                color: _pulseOkunuyor || _myDominosOkunuyor || _posOkunuyor
                    ? Colors.blue[700]
                    : Colors.green[700],
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    if (_pulseOkunuyor || _myDominosOkunuyor || _posOkunuyor)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    else
                      const Icon(Icons.check_circle,
                          color: Colors.white, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _pulseOkunuyor
                            ? 'Pulse verileri okunuyor...'
                            : _myDominosOkunuyor
                                ? 'My Dominos verileri okunuyor...'
                                : _posOkunuyor
                                    ? 'POS fişleri okunuyor...'
                                    : _okumaMesaji,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
          ], // Column children kapanış
        ), // Column kapanış
      ), // PopScope kapanış
    );
  }
}
