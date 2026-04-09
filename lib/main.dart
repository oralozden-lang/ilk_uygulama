import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:excel/excel.dart' as xl;
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'excel_download.dart';
import 'firebase_options.dart';

// ─── İlk Harf Büyük Formatter ───────────────────────────────────────────────

class IlkHarfBuyukFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;
    final words = newValue.text.split(' ');
    final result = words
        .map((word) {
          if (word.isEmpty) return word;
          // Türkçe i → İ
          final ilk = word[0] == 'i' ? 'İ' : word[0].toUpperCase();
          return ilk + word.substring(1);
        })
        .join(' ');
    return newValue.copyWith(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
  }
}

// ─── Bin Ayracı Formatter ────────────────────────────────────────────────────

class BinAraciFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;

    // Nokta (bin ayracı) kaldır, virgülü noktaya çevir
    String raw = newValue.text.replaceAll('.', '').replaceAll(',', '.');

    // Virgülden sonra 2 karakterden fazla girişi engelle
    final parts = raw.split('.');
    String intPart = parts[0];
    String decPart = parts.length > 1 ? parts[1] : '';
    if (decPart.length > 2) decPart = decPart.substring(0, 2);

    // Bin ayracı ekle
    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write('.');
      buffer.write(intPart[i]);
    }

    String result = buffer.toString();
    if (parts.length > 1) result += ',$decPart';

    return TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
  }
}

// ─── Kullanıcı Yetki Modeli ──────────────────────────────────────────────────

class KullaniciYetki {
  final bool yoneticiPaneli; // Yönetici paneline giriş
  final bool analizGor; // Analiz tab (Tahmin/Gerçekleşen)
  final bool merkziGiderGor; // Dönem Raporu merkezi giderler
  final bool subeEkle; // Şube ekle/düzenle
  final bool kullaniciEkle; // Kullanıcı yönetimi
  final bool ayarlar; // Ayarlar tab
  final bool raporGoruntuleme; // Raporlar ekranı
  final int gecmisGunHakki; // -1 = sınırsız
  final String? rolAdi; // Gösterim için

  const KullaniciYetki({
    this.yoneticiPaneli = false,
    this.analizGor = false,
    this.merkziGiderGor = false,
    this.subeEkle = false,
    this.kullaniciEkle = false,
    this.ayarlar = false,
    this.raporGoruntuleme = false,
    this.gecmisGunHakki = 3,
    this.rolAdi,
  });

  // Firestore rol dökümanından oluştur
  factory KullaniciYetki.fromRol(
    Map<String, dynamic> rol, {
    int? gecmisGunHakkiOverride,
  }) {
    final y = (rol['yetkiler'] as Map<String, dynamic>?) ?? {};
    return KullaniciYetki(
      yoneticiPaneli: y['yoneticiPaneli'] == true,
      analizGor: y['analizGor'] == true,
      merkziGiderGor: y['merkziGiderGor'] == true,
      subeEkle: y['subeEkle'] == true,
      kullaniciEkle: y['kullaniciEkle'] == true,
      ayarlar: y['ayarlar'] == true,
      raporGoruntuleme: y['raporGoruntuleme'] == true,
      gecmisGunHakki:
          gecmisGunHakkiOverride ?? (y['gecmisGunHakki'] as int? ?? 3),
      rolAdi: rol['ad'] as String?,
    );
  }

  // Yönetici — tüm yetkiler
  static const KullaniciYetki yonetici = KullaniciYetki(
    yoneticiPaneli: true,
    analizGor: true,
    merkziGiderGor: true,
    subeEkle: true,
    kullaniciEkle: true,
    ayarlar: true,
    raporGoruntuleme: true,
    gecmisGunHakki: -1,
    rolAdi: 'Yönetici',
  );

  // Normal kullanıcı — minimum yetki
  static const KullaniciYetki kullanici = KullaniciYetki(rolAdi: 'Kullanıcı');
}

// Uygulama versiyonu — versiyon bildirimi ve aktivite logu için
const String _appVersiyon = 'v1.0.9';

// Döviz cins rengi — tüm ekranlarda ortak kullanım
Color dovizRenk(String cins) {
  if (cins == 'USD') return const Color(0xFFE65100); // turuncu
  if (cins == 'EUR') return const Color(0xFF6A1B9A); // mor
  if (cins == 'GBP') return const Color(0xFF1B5E20); // yeşil
  return Colors.blueGrey[700]!;
}

Color dovizBgRenk(String cins) {
  if (cins == 'USD') return const Color(0xFFFFF8E1);
  if (cins == 'EUR') return const Color(0xFFF3E5F5);
  if (cins == 'GBP') return const Color(0xFFE8F5E9);
  return Colors.grey[100]!;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {}
  runApp(const KasaTakipApp());
}

class KasaTakipApp extends StatelessWidget {
  const KasaTakipApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kasa Takip',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0288D1)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF0F9FF),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0288D1),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
      ),
      home: const GirisEkrani(),
    );
  }
}

// ─── Kasa Logo Widget ─────────────────────────────────────────────────────────

class _KasaLogo extends StatelessWidget {
  const _KasaLogo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: CustomPaint(painter: _KasaLogoPainter()),
    );
  }
}

class _KasaLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Dış daire
    final daiPaint = Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 56, daiPaint);

    // İç daire
    final icPaint = Paint()
      ..color = Colors.white.withOpacity(0.1)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 44, icPaint);

    // Kasa gövdesi
    final kasaPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final rr = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + 4), width: 52, height: 38),
      const Radius.circular(6),
    );
    canvas.drawRRect(rr, kasaPaint);

    // Kasa kapak çizgisi
    final cizgiPaint = Paint()
      ..color = const Color(0xFF0288D1)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(cx - 26, cy - 2),
      Offset(cx + 26, cy - 2),
      cizgiPaint,
    );

    // Kilit dairesi
    canvas.drawCircle(
      Offset(cx, cy + 8),
      6,
      Paint()
        ..color = const Color(0xFF0288D1)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(cx, cy + 8),
      3,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );

    // Para sembolleri
    final tp = TextPainter(
      text: const TextSpan(
        text: '₺',
        style: TextStyle(
          color: Color(0xFF0288D1),
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - 22, cy - 1));

    final tp2 = TextPainter(
      text: const TextSpan(
        text: '\$',
        style: TextStyle(
          color: Color(0xFF0288D1),
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp2.paint(canvas, Offset(cx + 12, cy - 1));

    // Üst çerçeve
    final cerceve = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy - 16), width: 36, height: 10),
      const Radius.circular(3),
    );
    canvas.drawRRect(
      cerceve,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );

    // Dış daire kenarlık
    canvas.drawCircle(
      Offset(cx, cy),
      56,
      Paint()
        ..color = Colors.white.withOpacity(0.4)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}

// ─── Giriş Ekranı ─────────────────────────────────────────────────────────────

class GirisEkrani extends StatefulWidget {
  const GirisEkrani({super.key});
  @override
  State<GirisEkrani> createState() => _GirisEkraniState();
}

class _GirisEkraniState extends State<GirisEkrani> {
  final _kullaniciCtrl = TextEditingController();
  final _parolaCtrl = TextEditingController();
  bool _yukleniyor = false;
  bool _parGoster = false;
  String? _hata;

  @override
  void initState() {
    super.initState();
    _otomatikGiris();
    _versiyonKontrol();
  }

  // GitHub'daki son versiyonu kontrol et
  Future<void> _versiyonKontrol() async {
    try {
      final resp = await http.get(Uri.parse(
        'https://raw.githubusercontent.com/oralozden-lang/ilk_uygulama/main/lib/main.dart',
      )).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final match = RegExp(r"_appVersiyon = '(v[\d.]+)'").firstMatch(resp.body);
        if (match != null) {
          final uzak = match.group(1)!;
          if (uzak != _appVersiyon && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Yeni güncelleme mevcut ($uzak). Sayfayı yenileyin.'),
                backgroundColor: Colors.orange[700],
                duration: const Duration(seconds: 6),
                action: SnackBarAction(
                  label: 'Tamam',
                  textColor: Colors.white,
                  onPressed: () {},
                ),
              ),
            );
          }
        }
      }
    } catch (_) {
      // İnternet yoksa sessiz geç
    }
  }

  // Kayıtlı oturum varsa otomatik giriş
  Future<void> _otomatikGiris() async {
    final prefs = await SharedPreferences.getInstance();
    final kullanici = prefs.getString('kullanici');
    final parola = prefs.getString('parola');
    if (kullanici != null && parola != null) {
      await _girisYap(kullanici, parola, otomatik: true);
    }
  }

  Future<void> _girisYap(
    String kullanici,
    String parola, {
    bool otomatik = false,
  }) async {
    setState(() {
      _yukleniyor = true;
      _hata = null;
    });
    try {
      final doc = await FirebaseFirestore.instance
          .collection('kullanicilar')
          .doc(kullanici.trim().toLowerCase())
          .get();

      if (!doc.exists) {
        setState(() => _hata = 'Kullanıcı bulunamadı');
        return;
      }

      final data = doc.data()!;

      // Aktif mi?
      if (data['aktif'] == false) {
        setState(() => _hata = 'Bu hesap devre dışı bırakılmıştır');
        return;
      }

      // Parola kontrolü
      if (data['parola'] != parola.trim()) {
        setState(() => _hata = 'Hatalı parola');
        return;
      }

      // Oturumu kaydet
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('kullanici', kullanici.trim().toLowerCase());
      await prefs.setString('parola', parola.trim());

      if (!mounted) return;

      final yonetici = data['yonetici'] == true;
      final subeler = List<String>.from(data['subeler'] ?? []);
      final rolId = data['rolId'] as String?;

      // Yetki objesi oluştur
      KullaniciYetki yetki;
      if (yonetici) {
        yetki = KullaniciYetki.yonetici;
      } else if (rolId != null) {
        // Rol Firestore'dan çek
        try {
          final rolDoc = await FirebaseFirestore.instance
              .collection('roller')
              .doc(rolId)
              .get();
          if (rolDoc.exists) {
            final kullaniciGunHakki = (data['gecmisGunHakki'] as int?);
            yetki = KullaniciYetki.fromRol(
              rolDoc.data()!,
              gecmisGunHakkiOverride: kullaniciGunHakki,
            );
          } else {
            yetki = KullaniciYetki(
              raporGoruntuleme: data['raporGoruntuleme'] == true,
              gecmisGunHakki: (data['gecmisGunHakki'] as int?) ?? 3,
            );
          }
        } catch (_) {
          yetki = KullaniciYetki(
            raporGoruntuleme: data['raporGoruntuleme'] == true,
            gecmisGunHakki: (data['gecmisGunHakki'] as int?) ?? 3,
          );
        }
      } else {
        // Eski format — rolId yok, mevcut alanlardan oku
        yetki = KullaniciYetki(
          raporGoruntuleme: data['raporGoruntuleme'] == true,
          gecmisGunHakki: (data['gecmisGunHakki'] as int?) ?? 3,
        );
      }

      // SharedPreferences'a kaydet (geriye dönük uyumluluk)
      await prefs.setInt('gecmisGunHakki', yetki.gecmisGunHakki);
      await prefs.setBool('yonetici', yonetici);

      if (yetki.yoneticiPaneli || yonetici) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => YoneticiPaneliEkrani(
              kullanici: kullanici.trim().toLowerCase(),
              yetki: yetki,
            ),
          ),
        );
      } else if (subeler.length == 1) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => OnHazirlikEkrani(
              subeKodu: subeler[0],
              subeler: subeler,
              raporYetkisi: yetki.raporGoruntuleme,
              gecmisGunHakki: yetki.gecmisGunHakki,
            ),
          ),
        );
      } else if (subeler.length > 1) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => SubeSecimEkrani(
              subeler: subeler,
              kullanici: kullanici.trim().toLowerCase(),
              raporYetkisi: yetki.raporGoruntuleme,
              gecmisGunHakki: yetki.gecmisGunHakki,
            ),
          ),
        );
      } else {
        setState(() => _hata = 'Hesabınıza tanımlı şube yok');
      }
    } catch (e) {
      if (!otomatik) setState(() => _hata = 'Bağlantı hatası');
    } finally {
      if (mounted) setState(() => _yukleniyor = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF01579B), Color(0xFF0288D1), Color(0xFF29B6F6)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _KasaLogo(),
              const SizedBox(height: 16),
              const Text(
                'Kasa Takip',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Kullanıcı adı ve parolanızla giriş yapın',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 40),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _kullaniciCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Kullanıcı Adı',
                          prefixIcon: Icon(Icons.person),
                        ),
                        onFieldSubmitted: (_) =>
                            _girisYap(_kullaniciCtrl.text, _parolaCtrl.text),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _parolaCtrl,
                        obscureText: !_parGoster,
                        decoration: InputDecoration(
                          labelText: 'Parola',
                          prefixIcon: const Icon(Icons.lock),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _parGoster
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                            onPressed: () =>
                                setState(() => _parGoster = !_parGoster),
                          ),
                        ),
                        onFieldSubmitted: (_) =>
                            _girisYap(_kullaniciCtrl.text, _parolaCtrl.text),
                      ),
                      if (_hata != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.error_outline,
                                color: Colors.red,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _hata!,
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _yukleniyor
                              ? null
                              : () => _girisYap(
                                  _kullaniciCtrl.text,
                                  _parolaCtrl.text,
                                ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0288D1),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: _yukleniyor
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  'Giriş Yap',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                _appVersiyon,
                style: TextStyle(color: Colors.white30, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

// ─── Şube Seçim Ekranı ────────────────────────────────────────────────────────

class SubeSecimEkrani extends StatelessWidget {
  final List<String> subeler;
  final String kullanici;
  final bool raporYetkisi;
  final int gecmisGunHakki;
  const SubeSecimEkrani({
    super.key,
    required this.subeler,
    required this.kullanici,
    this.raporYetkisi = false,
    this.gecmisGunHakki = 0,
  });

  Future<String> _subeAdi(String subeId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(subeId)
          .get();
      if (doc.exists) return doc.data()?['ad'] as String? ?? subeId;
    } catch (_) {}
    return subeId;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0288D1),
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
        title: const Text('Şube Seçin'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Çıkış',
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.clear();
              if (context.mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => const GirisEkrani()),
                );
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Merhaba $kullanici,',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 4),
            const Text(
              'Hangi şubeye giriş yapmak istiyorsunuz?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            ...subeler.map(
              (s) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: FutureBuilder<String>(
                  future: _subeAdi(s),
                  builder: (ctx, snap) {
                    final ad = snap.data ?? s;
                    return SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => OnHazirlikEkrani(
                              subeKodu: s,
                              subeler: subeler,
                              raporYetkisi: raporYetkisi,
                              gecmisGunHakki: gecmisGunHakki,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.store),
                        label: Text(
                          ad,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF0288D1),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Yönetici Paneli ──────────────────────────────────────────────────────────

class YoneticiPaneliEkrani extends StatefulWidget {
  final String kullanici;
  final KullaniciYetki yetki;
  const YoneticiPaneliEkrani({
    super.key,
    required this.kullanici,
    this.yetki = KullaniciYetki.yonetici,
  });

  @override
  State<YoneticiPaneliEkrani> createState() => _YoneticiPaneliEkraniState();
}

class _YoneticiPaneliEkraniState extends State<YoneticiPaneliEkrani>
    with WidgetsBindingObserver {
  int _sekme = 0; // 0: Şubeler, 1: Kullanıcılar
  Timer? _arkaPlanTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      _arkaPlanTimer?.cancel();
      _arkaPlanTimer = Timer(const Duration(minutes: 20), () {
        if (mounted) _oturumZamanAsimiYonetici();
      });
    } else if (state == AppLifecycleState.resumed) {
      _arkaPlanTimer?.cancel();
      _arkaPlanTimer = null;
    }
  }

  Future<void> _oturumZamanAsimiYonetici() async {
    if (!mounted) return;
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
            child: const Text('Çıkış Yap', style: TextStyle(color: Colors.red)),
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
    if (devamEt == false) _cikisYap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _arkaPlanTimer?.cancel();
    super.dispose();
  }

  Future<void> _cikisYap() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const GirisEkrani()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = widget.yetki;

    // Dinamik tab listesi — yetkiye göre
    final tabs = <Tab>[];
    final tabViews = <Widget>[];

    // Şubeler — subeEkle yetkisi olanlar görebilir
    if (y.subeEkle) {
      tabs.add(const Tab(icon: Icon(Icons.store), text: 'Şubeler'));
      tabViews.add(_subelerTab());
    }
    // Kullanıcılar
    if (y.kullaniciEkle) {
      tabs.add(const Tab(icon: Icon(Icons.people), text: 'Kullanıcılar'));
      tabViews.add(_kullanicilarTab());
    }
    // Raporlar
    if (y.raporGoruntuleme) {
      tabs.add(const Tab(icon: Icon(Icons.bar_chart), text: 'Raporlar'));
      tabViews.add(_raporlarTab(merkziGiderGor: y.merkziGiderGor));
    }
    // Analiz
    if (y.analizGor) {
      tabs.add(const Tab(icon: Icon(Icons.analytics), text: 'Analiz'));
      tabViews.add(_analizTab());
    }
    // Ayarlar
    if (y.ayarlar) {
      tabs.add(const Tab(icon: Icon(Icons.settings), text: 'Ayarlar'));
      tabViews.add(_ayarlarTab());
    }
    // Rol Yönetimi — sadece tam yönetici
    if (y == KullaniciYetki.yonetici) {
      tabs.add(
        const Tab(icon: Icon(Icons.admin_panel_settings), text: 'Roller'),
      );
      tabViews.add(_rollerTab());
    }
    // Aktivite Logu — sadece tam yönetici
    if (y == KullaniciYetki.yonetici) {
      tabs.add(
        const Tab(icon: Icon(Icons.history), text: 'Aktivite'),
      );
      tabViews.add(_aktiviteTab());
    }

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
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
          title: Text('${y.rolAdi ?? 'Yönetici'} Paneli'),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Çıkış',
              onPressed: _cikisYap,
            ),
          ],
          bottom: TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            indicatorColor: Colors.white,
            isScrollable: true,
            tabs: tabs,
          ),
        ),
        body: TabBarView(children: tabViews),
      ),
    );
  }

  Widget _subelerTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('subeler').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final subeler = snapshot.data!.docs;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Şube Ekle butonu
            ElevatedButton.icon(
              onPressed: () => _subeEkleDialog(),
              icon: const Icon(Icons.add_business),
              label: const Text('Yeni Şube Ekle'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0288D1),
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            ...subeler.map((s) {
              final data = s.data() as Map<String, dynamic>;
              final aktif = data['aktif'] != false;
              final ad = data['ad'] as String? ?? s.id;
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: aktif
                        ? const Color(0xFF0288D1)
                        : Colors.grey,
                    child: const Icon(
                      Icons.store,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  title: Text(
                    ad,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    aktif ? 'Aktif' : 'Pasif',
                    style: TextStyle(
                      fontSize: 12,
                      color: aktif ? Colors.green[700] : Colors.grey,
                    ),
                  ),
                  // Tıklayınca direkt şubeye gir
                  onTap: () async {
                    final tumSubeler = await FirebaseFirestore.instance
                        .collection('subeler')
                        .get();
                    final subeIdleri = tumSubeler.docs.map((d) => d.id).toList();
                    if (context.mounted) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => OnHazirlikEkrani(
                            subeKodu: s.id,
                            subeler: subeIdleri,
                            gecmisGunHakki: -1,
                          ),
                        ),
                      );
                    }
                  },
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, color: Color(0xFF0288D1)),
                    onSelected: (val) {
                      if (val == 'duzenle') _subeDuzenleDialog(s.id, ad);
                      if (val == 'sil') _subeSilDialog(s.id);
                      if (val == 'aktif') {
                        FirebaseFirestore.instance
                            .collection('subeler')
                            .doc(s.id)
                            .update({'aktif': !aktif});
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'aktif',
                        child: Row(
                          children: [
                            Icon(
                              aktif ? Icons.block : Icons.check_circle,
                              color: aktif ? Colors.orange : Colors.green,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(aktif ? 'Pasife Al' : 'Aktive Et'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'duzenle',
                        child: Row(
                          children: [
                            Icon(Icons.edit, color: Color(0xFF0288D1), size: 18),
                            SizedBox(width: 8),
                            Text('Adını Düzenle'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'sil',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline, color: Colors.red, size: 18),
                            SizedBox(width: 8),
                            Text('Sil', style: TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }

  void _subeDuzenleDialog(String id, String mevcutAd) {
    final adCtrl = TextEditingController(text: mevcutAd);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Şube Adını Düzenle'),
        content: TextFormField(
          controller: adCtrl,
          decoration: const InputDecoration(labelText: 'Şube Adı'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            onPressed: () async {
              final yeniAd = adCtrl.text.trim();
              if (yeniAd.isEmpty) return;
              await FirebaseFirestore.instance
                  .collection('subeler')
                  .doc(id)
                  .update({'ad': yeniAd});
              if (mounted) Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0288D1),
              foregroundColor: Colors.white,
            ),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }

  void _subeEkleDialog() {
    final adCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Yeni Şube Ekle'),
        content: TextFormField(
          controller: adCtrl,
          decoration: const InputDecoration(
            labelText: 'Şube Adı',
            hintText: 'Örn: Merkez Şube',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            onPressed: () async {
              final ad = adCtrl.text.trim();
              if (ad.isEmpty) return;
              // Şube adını hem ID hem de ad olarak kullan
              await FirebaseFirestore.instance
                  .collection('subeler')
                  .doc(ad)
                  .set({
                    'ad': ad,
                    'aktif': true,
                    'olusturulma': FieldValue.serverTimestamp(),
                  }, SetOptions(merge: true));
              if (mounted) Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0288D1),
              foregroundColor: Colors.white,
            ),
            child: const Text('Ekle'),
          ),
        ],
      ),
    );
  }

  void _subeSilDialog(String id) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Şubeyi Sil'),
        content: Text(
          '$id şubesi silinecek.\n\nDikkat: Şubeye ait tüm kayıtlar da silinir!',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          TextButton(
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection('subeler')
                  .doc(id)
                  .delete();
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Sil', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // Kullanıcı filtre state'i
  final TextEditingController _kullaniciAramaCtrl = TextEditingController();
  String _kullaniciArama = '';
  String? _filtreSube; // null = tümü
  String _filtreAktif = 'tumu'; // 'tumu', 'aktif', 'pasif'

  Widget _kullanicilarTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('kullanicilar').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final tumKullanicilar = snapshot.data!.docs;

        // Filtrele
        final kullanicilar = tumKullanicilar.where((k) {
          final data = k.data() as Map<String, dynamic>;
          final aktif = data['aktif'] != false;
          final subeler = List<String>.from(data['subeler'] ?? []);
          final yonetici = data['yonetici'] == true;

          // Arama
          if (_kullaniciArama.isNotEmpty &&
              !k.id.toLowerCase().contains(_kullaniciArama.toLowerCase()))
            return false;
          // Şube filtresi
          if (_filtreSube != null &&
              !yonetici &&
              !subeler.contains(_filtreSube))
            return false;
          // Durum filtresi
          if (_filtreAktif == 'aktif' && !aktif) return false;
          if (_filtreAktif == 'pasif' && aktif) return false;
          return true;
        }).toList();

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('subeler').snapshots(),
          builder: (context, subeSnap) {
            final subeAdlari = <String, String>{};
            if (subeSnap.hasData) {
              for (final d in subeSnap.data!.docs) {
                subeAdlari[d.id] =
                    (d.data() as Map<String, dynamic>)['ad'] as String? ?? d.id;
              }
            }
            final subeIdleri = subeAdlari.keys.toList()..sort();

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Filtre satırı ───────────────────────────────────────────
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Arama kutusu
                        TextField(
                          controller: _kullaniciAramaCtrl,
                          decoration: InputDecoration(
                            labelText: 'Kullanıcı Ara',
                            prefixIcon: const Icon(Icons.search, size: 18),
                            suffixIcon: _kullaniciArama.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 18),
                                    onPressed: () => setState(() {
                                      _kullaniciAramaCtrl.clear();
                                      _kullaniciArama = '';
                                    }),
                                  )
                                : null,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          onChanged: (v) => setState(() => _kullaniciArama = v),
                        ),
                        const SizedBox(height: 10),
                        // Şube filtresi
                        DropdownButtonFormField<String?>(
                          value: _filtreSube,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Şube',
                            border: OutlineInputBorder(),
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 10,
                            ),
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: null,
                              child: Text('Tüm Şubeler'),
                            ),
                            ...subeIdleri.map(
                              (s) => DropdownMenuItem(
                                value: s,
                                child: Text(
                                  subeAdlari[s] ?? s,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() => _filtreSube = v),
                        ),
                        const SizedBox(height: 8),
                        // Durum filtresi
                        DropdownButtonFormField<String>(
                          value: _filtreAktif,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Durum',
                            border: OutlineInputBorder(),
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 10,
                            ),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'tumu',
                              child: Text('Tümü'),
                            ),
                            DropdownMenuItem(
                              value: 'aktif',
                              child: Text('Aktif'),
                            ),
                            DropdownMenuItem(
                              value: 'pasif',
                              child: Text('Pasif'),
                            ),
                          ],
                          onChanged: (v) => setState(() => _filtreAktif = v!),
                        ),
                        const SizedBox(height: 8),
                        // Sonuç sayısı
                        Text(
                          '${kullanicilar.length} kullanıcı'
                          '${kullanicilar.length != tumKullanicilar.length ? ' (toplam ${tumKullanicilar.length})' : ''}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Yeni kullanıcı ekle butonu
                ElevatedButton.icon(
                  onPressed: () => _kullaniciEkleDialog(),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Yeni Kullanıcı Ekle'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0288D1),
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                if (kullanicilar.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Filtre kriterlerine uyan kullanıcı yok.',
                        style: TextStyle(color: Colors.grey[500]),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ...kullanicilar.map((k) {
                  final data = k.data() as Map<String, dynamic>;
                  final aktif = data['aktif'] != false;
                  final yonetici = data['yonetici'] == true;
                  final subeler = List<String>.from(data['subeler'] ?? []);
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: aktif
                            ? const Color(0xFF0288D1)
                            : Colors.grey,
                        child: Text(
                          k.id[0].toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Row(
                        children: [
                          Text(
                            k.id,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          if (yonetici) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.amber,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'YÖNETİCİ',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                          if (!yonetici && data['rolId'] != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF0288D1,
                                ).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                data['rolId'] as String,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF0288D1),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        yonetici
                            ? 'Tüm şubeler'
                            : subeler.map((s) => subeAdlari[s] ?? s).join(', '),
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (val) {
                          if (val == 'duzenle')
                            _kullaniciDuzenleDialog(k.id, data);
                          if (val == 'sil') _kullaniciSilDialog(k.id);
                          if (val == 'aktif') {
                            FirebaseFirestore.instance
                                .collection('kullanicilar')
                                .doc(k.id)
                                .update({'aktif': !aktif});
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'aktif',
                            child: Row(
                              children: [
                                Icon(
                                  aktif ? Icons.block : Icons.check_circle,
                                  color: aktif ? Colors.orange : Colors.green,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                Text(aktif ? 'Pasife Al' : 'Aktive Et'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'duzenle',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.edit,
                                  color: Color(0xFF0288D1),
                                  size: 18,
                                ),
                                SizedBox(width: 8),
                                Text('Düzenle'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'sil',
                            child: Row(
                              children: [
                                Icon(Icons.delete, color: Colors.red, size: 18),
                                SizedBox(width: 8),
                                Text(
                                  'Sil',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            );
          }, // inner StreamBuilder
        );
      },
    );
  }

  void _kullaniciEkleDialog() {
    final adCtrl = TextEditingController();
    final parolaCtrl = TextEditingController();
    bool yonetici = false;
    List<String> seciliSubeler = [];
    String? seciliRolId;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Yeni Kullanıcı'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: adCtrl,
                  decoration: const InputDecoration(labelText: 'Kullanıcı Adı'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: parolaCtrl,
                  decoration: const InputDecoration(labelText: 'Parola'),
                ),
                const SizedBox(height: 12),
                // Şube listesi
                if (!yonetici) ...[
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Şubeler:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 4),
                  FutureBuilder<QuerySnapshot>(
                    future: FirebaseFirestore.instance
                        .collection('subeler')
                        .get(),
                    builder: (ctx2, snap) {
                      if (!snap.hasData)
                        return const CircularProgressIndicator();
                      final subeler = snap.data!.docs;
                      return Column(
                        children: subeler.map((s) {
                          final data = s.data() as Map<String, dynamic>;
                          final ad = data['ad'] as String? ?? s.id;
                          return CheckboxListTile(
                            dense: true,
                            title: Text(ad),
                            value: seciliSubeler.contains(s.id),
                            onChanged: (v) => setS(() {
                              if (v == true)
                                seciliSubeler.add(s.id);
                              else
                                seciliSubeler.remove(s.id);
                            }),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Checkbox(
                      value: yonetici,
                      onChanged: (v) => setS(() {
                        yonetici = v!;
                        if (yonetici) seciliRolId = null;
                      }),
                    ),
                    const Text('Yönetici (tüm şubeler)'),
                  ],
                ),
                // Rol seçimi (yönetici değilse)
                if (!yonetici) ...[
                  const SizedBox(height: 8),
                  FutureBuilder<QuerySnapshot>(
                    future: FirebaseFirestore.instance
                        .collection('roller')
                        .get(),
                    builder: (ctx2, rolSnap) {
                      if (!rolSnap.hasData) return const SizedBox.shrink();
                      final roller = rolSnap.data!.docs;
                      return DropdownButtonFormField<String?>(
                        value: seciliRolId,
                        decoration: const InputDecoration(
                          labelText: 'Rol (opsiyonel)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('Rol Yok (standart)'),
                          ),
                          ...roller.map((r) {
                            final ad =
                                (r.data() as Map<String, dynamic>)['ad']
                                    as String? ??
                                r.id;
                            return DropdownMenuItem(
                              value: r.id,
                              child: Text(ad),
                            );
                          }),
                        ],
                        onChanged: (v) => setS(() => seciliRolId = v),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('İptal'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (adCtrl.text.trim().isEmpty) return;
                await FirebaseFirestore.instance
                    .collection('kullanicilar')
                    .doc(adCtrl.text.trim().toLowerCase())
                    .set({
                      'parola': parolaCtrl.text.trim(),
                      'subeler': yonetici ? ['TUM'] : seciliSubeler,
                      'yonetici': yonetici,
                      'aktif': true,
                      if (seciliRolId != null) 'rolId': seciliRolId,
                    });
                if (ctx.mounted) Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0288D1),
                foregroundColor: Colors.white,
              ),
              child: const Text('Ekle'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Projeksiyon Sekmesi ──────────────────────────────────────────────────────
  Widget _projeksiyonTab() {
    return _ProjeksiyonWidget(key: const ValueKey('projeksiyon'));
  }

  Widget _analizTab() {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            color: const Color(0xFF0288D1),
            child: const TabBar(
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white60,
              indicatorColor: Colors.white,
              indicatorWeight: 3,
              tabs: [
                Tab(icon: Icon(Icons.trending_up, size: 18), text: 'Tahmin'),
                Tab(
                  icon: Icon(Icons.check_circle_outline, size: 18),
                  text: 'Gerçekleşen',
                ),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [
                _ProjeksiyonWidget(key: ValueKey('tahmin')),
                _GerceklesenWidget(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _kullaniciDuzenleDialog(String id, Map<String, dynamic> data) {
    final parolaCtrl = TextEditingController(text: data['parola'] ?? '');
    List<String> seciliSubeler = List<String>.from(data['subeler'] ?? []);
    bool raporYetkisi = data['raporGoruntuleme'] == true;
    int gecmisGunHakki = (data['gecmisGunHakki'] as int?) ?? 3;
    String? seciliRolId = data['rolId'] as String?;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('Düzenle: $id'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: parolaCtrl,
                  decoration: const InputDecoration(labelText: 'Yeni Parola'),
                ),
                const SizedBox(height: 12),
                // Geçmiş gün hakkı
                Container(
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange[200]!),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Geçmiş Gün Erişim Hakkı',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Kullanıcı kaç gün geriye gidebilir: $gecmisGunHakki gün',
                        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                      ),
                      Slider(
                        value: gecmisGunHakki.toDouble(),
                        min: 0,
                        max: 30,
                        divisions: 30,
                        label: '$gecmisGunHakki gün',
                        activeColor: const Color(0xFF0288D1),
                        onChanged: (v) =>
                            setS(() => gecmisGunHakki = v.toInt()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Rapor yetkisi
                Container(
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue[200]!),
                  ),
                  child: SwitchListTile(
                    dense: true,
                    title: const Text(
                      'Rapor Görüntüleme Yetkisi',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text('Raporlar ekranına erişim'),
                    value: raporYetkisi,
                    activeColor: const Color(0xFF0288D1),
                    onChanged: (v) => setS(() => raporYetkisi = v),
                  ),
                ),
                const SizedBox(height: 12),
                // Rol seçimi
                FutureBuilder<QuerySnapshot>(
                  future: FirebaseFirestore.instance.collection('roller').get(),
                  builder: (ctx2, rolSnap) {
                    if (!rolSnap.hasData) return const SizedBox.shrink();
                    final roller = rolSnap.data!.docs;
                    if (roller.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DropdownButtonFormField<String?>(
                          value: seciliRolId,
                          decoration: const InputDecoration(
                            labelText: 'Rol',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: null,
                              child: Text('Rol Yok (standart)'),
                            ),
                            ...roller.map((r) {
                              final ad =
                                  (r.data() as Map<String, dynamic>)['ad']
                                      as String? ??
                                  r.id;
                              return DropdownMenuItem(
                                value: r.id,
                                child: Text(ad),
                              );
                            }),
                          ],
                          onChanged: (v) => setS(() => seciliRolId = v),
                        ),
                        const SizedBox(height: 12),
                      ],
                    );
                  },
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Şubeler:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 4),
                FutureBuilder<QuerySnapshot>(
                  future: FirebaseFirestore.instance
                      .collection('subeler')
                      .get(),
                  builder: (ctx2, snap) {
                    if (!snap.hasData) return const CircularProgressIndicator();
                    final subeler = snap.data!.docs;
                    return Column(
                      children: subeler.map((s) {
                        final data = s.data() as Map<String, dynamic>;
                        final ad = data['ad'] as String? ?? s.id;
                        return CheckboxListTile(
                          dense: true,
                          title: Text(ad),
                          value: seciliSubeler.contains(s.id),
                          onChanged: (v) => setS(() {
                            if (v == true)
                              seciliSubeler.add(s.id);
                            else
                              seciliSubeler.remove(s.id);
                          }),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('İptal'),
            ),
            ElevatedButton(
              onPressed: () async {
                await FirebaseFirestore.instance
                    .collection('kullanicilar')
                    .doc(id)
                    .update({
                      'parola': parolaCtrl.text.trim(),
                      'subeler': seciliSubeler,
                      'raporGoruntuleme': raporYetkisi,
                      'gecmisGunHakki': gecmisGunHakki,
                      'rolId': seciliRolId,
                    });
                if (mounted) Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0288D1),
                foregroundColor: Colors.white,
              ),
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Roller Sekmesi ────────────────────────────────────────────────────────
  Widget _rollerTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('roller').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final roller = snapshot.data!.docs;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ElevatedButton.icon(
              onPressed: () => _rolEkleDialog(),
              icon: const Icon(Icons.add),
              label: const Text('Yeni Rol Ekle'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0288D1),
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            // Varsayılan roller bilgisi
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: const Text(
                '• Yönetici: Tüm yetkiler (değiştirilemez)\n'
                '• Buradan eklenen roller kullanıcılara atanabilir.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            ...roller.map((r) {
              final data = r.data() as Map<String, dynamic>;
              final ad = data['ad'] as String? ?? r.id;
              final y = (data['yetkiler'] as Map<String, dynamic>?) ?? {};
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF0288D1),
                    child: Icon(Icons.badge, color: Colors.white, size: 18),
                  ),
                  title: Text(
                    ad,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      if (y['yoneticiPaneli'] == true)
                        _yetki('Panel', Colors.blue),
                      if (y['analizGor'] == true)
                        _yetki('Analiz', Colors.purple),
                      if (y['merkziGiderGor'] == true)
                        _yetki('M.Gider', Colors.orange),
                      if (y['subeEkle'] == true) _yetki('Şube', Colors.teal),
                      if (y['kullaniciEkle'] == true)
                        _yetki('Kullanıcı', Colors.indigo),
                      if (y['ayarlar'] == true) _yetki('Ayarlar', Colors.brown),
                      if (y['raporGoruntuleme'] == true)
                        _yetki('Rapor', Colors.green),
                      _yetki(
                        y['gecmisGunHakki'] == -1
                            ? 'Sınırsız Gün'
                            : '${y['gecmisGunHakki'] ?? 3} Gün',
                        Colors.grey[600]!,
                      ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.edit,
                          size: 18,
                          color: Color(0xFF0288D1),
                        ),
                        onPressed: () => _rolDuzenleDialog(r.id, data),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.delete,
                          size: 18,
                          color: Colors.red,
                        ),
                        onPressed: () => _rolSilDialog(r.id, ad),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }

  Widget _yetki(String label, Color renk) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: renk.withOpacity(0.15),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 10, color: renk, fontWeight: FontWeight.w600),
    ),
  );

  void _rolEkleDialog() => _rolDialog(null, null);
  void _rolDuzenleDialog(String id, Map<String, dynamic> data) =>
      _rolDialog(id, data);

  void _rolDialog(String? mevcut, Map<String, dynamic>? data) {
    final adCtrl = TextEditingController(text: data?['ad'] ?? '');
    final y = Map<String, dynamic>.from(
      (data?['yetkiler'] as Map<String, dynamic>?) ?? {},
    );
    // Varsayılan değerler
    y.putIfAbsent('yoneticiPaneli', () => false);
    y.putIfAbsent('analizGor', () => false);
    y.putIfAbsent('merkziGiderGor', () => false);
    y.putIfAbsent('subeEkle', () => false);
    y.putIfAbsent('kullaniciEkle', () => false);
    y.putIfAbsent('ayarlar', () => false);
    y.putIfAbsent('raporGoruntuleme', () => false);
    y.putIfAbsent('gecmisGunHakki', () => 3);

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(
            mevcut == null
                ? 'Yeni Rol'
                : 'Rol Düzenle: ${data?['ad'] ?? mevcut}',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: adCtrl,
                  decoration: const InputDecoration(labelText: 'Rol Adı'),
                ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Yetkiler',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 8),
                // Yetki toggle'ları
                ...([
                          (
                            'yoneticiPaneli',
                            'Yönetici Paneline Giriş',
                            Icons.dashboard,
                          ),
                          (
                            'analizGor',
                            'Analiz (Tahmin/Gerçekleşen)',
                            Icons.analytics,
                          ),
                          (
                            'merkziGiderGor',
                            'Merkezi Giderleri Gör',
                            Icons.account_balance,
                          ),
                          ('subeEkle', 'Şube Ekle/Düzenle', Icons.store),
                          ('kullaniciEkle', 'Kullanıcı Yönetimi', Icons.people),
                          ('ayarlar', 'Ayarlar', Icons.settings),
                          ('raporGoruntuleme', 'Raporlar', Icons.bar_chart),
                        ]
                        as List<(String, String, IconData)>)
                    .map(
                      (t) => SwitchListTile(
                        dense: true,
                        secondary: Icon(
                          t.$3,
                          size: 18,
                          color: const Color(0xFF0288D1),
                        ),
                        title: Text(t.$2, style: const TextStyle(fontSize: 13)),
                        value: y[t.$1] == true,
                        activeColor: const Color(0xFF0288D1),
                        onChanged: (v) => setS(() => y[t.$1] = v),
                      ),
                    ),
                // Geçmiş gün hakkı
                Container(
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange[200]!),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Geçmiş Gün Hakkı',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          Switch(
                            value: y['gecmisGunHakki'] == -1,
                            activeColor: const Color(0xFF0288D1),
                            onChanged: (v) =>
                                setS(() => y['gecmisGunHakki'] = v ? -1 : 3),
                          ),
                          Text(y['gecmisGunHakki'] == -1 ? 'Sınırsız' : ''),
                        ],
                      ),
                      if (y['gecmisGunHakki'] != -1) ...[
                        Text(
                          '${y['gecmisGunHakki']} gün',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        Slider(
                          value: (y['gecmisGunHakki'] as int).toDouble(),
                          min: 0,
                          max: 30,
                          divisions: 30,
                          label: '${y['gecmisGunHakki']} gün',
                          activeColor: const Color(0xFF0288D1),
                          onChanged: (v) =>
                              setS(() => y['gecmisGunHakki'] = v.toInt()),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('İptal'),
            ),
            ElevatedButton(
              onPressed: () async {
                final ad = adCtrl.text.trim();
                if (ad.isEmpty) return;
                final docId = mevcut ?? ad.toLowerCase().replaceAll(' ', '_');
                await FirebaseFirestore.instance
                    .collection('roller')
                    .doc(docId)
                    .set({'ad': ad, 'yetkiler': y});
                if (ctx.mounted) Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0288D1),
                foregroundColor: Colors.white,
              ),
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _aktiviteTab() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _aktiviteYukle(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        final kayitlar = snap.data ?? [];
        if (kayitlar.isEmpty)
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Son 24 saatte kayıt yok.',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          );
        return RefreshIndicator(
          onRefresh: () async => setState(() {}),
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: kayitlar.length,
            itemBuilder: (_, i) {
              final d = kayitlar[i];
              final kaydeden = d['kaydeden'] as String? ?? '';
              final kilitKullanici = d['_kilitKullanici'] as String? ?? '';
              final versiyon = d['_versiyon'] as String? ?? '';
              final subeKodu = d['subeKodu'] as String? ?? '';
              final tarih = d['tarihGoster'] ?? d['tarih'] ?? '';
              final zaman = (d['kayitZamani'] as Timestamp?)?.toDate();
              final zamanStr = zaman != null
                  ? '${zaman.day.toString().padLeft(2, '0')}.${zaman.month.toString().padLeft(2, '0')} '
                    '${zaman.hour.toString().padLeft(2, '0')}:${zaman.minute.toString().padLeft(2, '0')}'
                  : '';
              final satis = ((d['gunlukSatisToplami'] as num?) ?? 0).toDouble();
              final tamamlandi = d['tamamlandi'] == true || d['tamamlandi'] == 1;
              // Gösterilecek ad: kaydeden varsa o, yoksa kilit tutanı göster
              final gosterimAd = kaydeden.isNotEmpty
                  ? kaydeden
                  : kilitKullanici.isNotEmpty
                  ? kilitKullanici
                  : '—';

              // Badge rengi ve metni
              Color badgeRenk;
              String badgeMeyin;
              if (tamamlandi) {
                badgeRenk = Colors.green[700]!;
                badgeMeyin = 'Kapatıldı';
              } else if (kaydeden.isNotEmpty) {
                badgeRenk = Colors.orange[700]!;
                badgeMeyin = 'Açık Gün';
              } else {
                badgeRenk = Colors.blue[700]!;
                badgeMeyin = 'Otomatik';
              }

              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: tamamlandi
                        ? Colors.green[700]
                        : kaydeden.isNotEmpty
                        ? Colors.orange[700]
                        : const Color(0xFF0288D1),
                    radius: 18,
                    child: Text(
                      gosterimAd.isNotEmpty ? gosterimAd[0].toUpperCase() : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          gosterimAd,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: badgeRenk.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: badgeRenk.withOpacity(0.5)),
                        ),
                        child: Text(
                          badgeMeyin,
                          style: TextStyle(
                            fontSize: 10,
                            color: badgeRenk,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$subeKodu  •  $tarih  •  Satış: ${satis.toStringAsFixed(0)} ₺',
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (versiyon.isNotEmpty)
                        Text(
                          versiyon,
                          style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                        ),
                      if (kilitKullanici.isNotEmpty && kilitKullanici != kaydeden)
                        Text(
                          'Kilitleyen: $kilitKullanici',
                          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                        ),
                    ],
                  ),
                  trailing: Text(
                    zamanStr,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  isThreeLine: kilitKullanici.isNotEmpty && kilitKullanici != kaydeden,
                ),
              );
            },
          ),
        );
      },
    );
  }


  Future<List<Map<String, dynamic>>> _aktiviteYukle() async {
    try {
      final sinir = DateTime.now().subtract(const Duration(hours: 24));
      final subelerSnap = await FirebaseFirestore.instance
          .collection('subeler').get();
      final sonuclar = <Map<String, dynamic>>[];
      for (final subeDoc in subelerSnap.docs) {
        final snap = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(subeDoc.id)
            .collection('gunluk')
            .where('kayitZamani', isGreaterThan: Timestamp.fromDate(sinir))
            .orderBy('kayitZamani', descending: true)
            .get();
        for (final doc in snap.docs) {
          final d = doc.data();
          // Kilit bilgisini de ekle
          final kilitKullanici = d['kullanici'] as String? ?? '';
          final versiyon = d['versiyon'] as String? ?? '';
          sonuclar.add({...d, '_subeId': subeDoc.id, '_kilitKullanici': kilitKullanici, '_versiyon': versiyon});
        }
      }
      sonuclar.sort((a, b) {
        final za = (a['kayitZamani'] as Timestamp?)?.toDate() ?? DateTime(2000);
        final zb = (b['kayitZamani'] as Timestamp?)?.toDate() ?? DateTime(2000);
        return zb.compareTo(za);
      });
      return sonuclar;
    } catch (_) {
      return [];
    }
  }

  Future<void> _rolSilDialog(String id, String ad) async {
    final onay = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rol Sil'),
        content: Text(
          '"$ad" rolü silinecek. Bu role atanmış kullanıcılar etkilenebilir.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (onay == true) {
      await FirebaseFirestore.instance.collection('roller').doc(id).delete();
    }
  }

  Widget _ayarlarTab() {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('banknotlar')
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Hata: ${snap.error}'));
        }

        final data = snap.data?.data() as Map<String, dynamic>?;
        // Liste alanı — tüm sayısal değerleri inte çevir
        final List<int> mevcutBanknotlar;
        try {
          mevcutBanknotlar =
              (data?['liste'] as List?)
                  ?.map((e) => (e as num).toInt())
                  .toList() ??
              [200, 100, 50, 20, 10, 5];
        } catch (_) {
          return const Center(child: Text('Banknot listesi okunamadı.'));
        }
        mevcutBanknotlar.sort((a, b) => b.compareTo(a));
        final mevcutFlotSiniri = (data?['flotSiniri'] as num?)?.toInt() ?? 20;
        final tumBanknotlar = [200, 100, 50, 20, 10, 5, 1];

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Başlık
              const Text(
                'Genel Ayarlar',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0288D1),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Bu ayarlar yeni açılan günler için geçerlidir. Mevcut günler etkilenmez.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 20),

              // Banknot listesi
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Banknot Değerleri',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Kasada sayılacak banknot değerleri',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 12),

                      // Standart banknotlar — seç/kaldır
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: tumBanknotlar.map((b) {
                          final secili = mevcutBanknotlar.contains(b);
                          return FilterChip(
                            label: Text('$b ₺'),
                            selected: secili,
                            selectedColor: const Color(
                              0xFF0288D1,
                            ).withOpacity(0.15),
                            checkmarkColor: const Color(0xFF0288D1),
                            onSelected: (v) async {
                              final yeni = List<int>.from(mevcutBanknotlar);
                              if (v) {
                                yeni.add(b);
                              } else {
                                if (yeni.length <= 1) return; // en az 1 banknot
                                yeni.remove(b);
                              }
                              yeni.sort((a, b) => b.compareTo(a));
                              await FirebaseFirestore.instance
                                  .collection('ayarlar')
                                  .doc('banknotlar')
                                  .set({
                                    'liste': yeni,
                                    'flotSiniri': mevcutFlotSiniri,
                                  });
                            },
                          );
                        }).toList(),
                      ),

                      // Özel eklenen banknotlar (standart listede olmayanlar)
                      Builder(
                        builder: (context) {
                          final ozelBanknotlar = mevcutBanknotlar
                              .where((b) => !tumBanknotlar.contains(b))
                              .toList();
                          if (ozelBanknotlar.isEmpty)
                            return const SizedBox.shrink();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 10),
                              Text(
                                'Özel Değerler',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: ozelBanknotlar.map((b) {
                                  return Chip(
                                    label: Text(
                                      '$b ₺',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    backgroundColor: const Color(
                                      0xFF0288D1,
                                    ).withOpacity(0.08),
                                    side: BorderSide(
                                      color: const Color(
                                        0xFF0288D1,
                                      ).withOpacity(0.3),
                                    ),
                                    deleteIcon: const Icon(
                                      Icons.close,
                                      size: 16,
                                      color: Colors.redAccent,
                                    ),
                                    onDeleted: () async {
                                      if (mevcutBanknotlar.length <= 1) return;
                                      final yeni = List<int>.from(
                                        mevcutBanknotlar,
                                      )..remove(b);
                                      yeni.sort((a, b) => b.compareTo(a));
                                      await FirebaseFirestore.instance
                                          .collection('ayarlar')
                                          .doc('banknotlar')
                                          .set({
                                            'liste': yeni,
                                            'flotSiniri': mevcutFlotSiniri,
                                          });
                                    },
                                  );
                                }).toList(),
                              ),
                            ],
                          );
                        },
                      ),

                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 12),

                      // Özel banknot ekle — TextField + Ekle butonu
                      Builder(
                        builder: (context) {
                          final ctrl = TextEditingController();
                          Future<void> ekle() async {
                            final deger = int.tryParse(ctrl.text.trim());
                            if (deger == null || deger <= 0) return;
                            if (mevcutBanknotlar.contains(deger)) {
                              ctrl.clear();
                              return;
                            }
                            final yeni = List<int>.from(mevcutBanknotlar)
                              ..add(deger);
                            yeni.sort((a, b) => b.compareTo(a));
                            await FirebaseFirestore.instance
                                .collection('ayarlar')
                                .doc('banknotlar')
                                .set({
                                  'liste': yeni,
                                  'flotSiniri': mevcutFlotSiniri,
                                });
                            ctrl.clear();
                          }

                          return Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: ctrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Özel değer ekle (₺)',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                    suffixText: '₺',
                                  ),
                                  keyboardType: TextInputType.number,
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

              const SizedBox(height: 12),

              // Varsayılan flot sınırı
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Varsayılan Flot Sınırı',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Yeni açılan günlerde flot hesabı için kullanılır. '
                        'Her şube o gün için değiştirebilir.',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: mevcutBanknotlar.map((b) {
                          final secili = b == mevcutFlotSiniri;
                          return ChoiceChip(
                            label: Text('$b ₺ ve altı'),
                            selected: secili,
                            selectedColor: const Color(
                              0xFF0288D1,
                            ).withOpacity(0.15),
                            onSelected: (_) async {
                              await FirebaseFirestore.instance
                                  .collection('ayarlar')
                                  .doc('banknotlar')
                                  .set({
                                    'liste': mevcutBanknotlar,
                                    'flotSiniri': b,
                                  });
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Gider Türleri
              _GiderTurleriKart(),

              const SizedBox(height: 12),

              // KDV Oranı
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'KDV Oranı',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Şube Özet raporunda toplam cironun yanında '
                        'KDVsiz tutar gösterilir.',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 12),
                      StatefulBuilder(
                        builder: (ctx, setKdv) {
                          // Firestore'dan gelen mevcut oran
                          final mevcutOran =
                              (data?['kdvOrani'] as num?)?.toDouble() ?? 10.0;
                          double seciliOran = mevcutOran;
                          return Column(
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.percent,
                                    size: 18,
                                    color: Color(0xFF0288D1),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Oran: %${seciliOran.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    'KDVsiz = Ciro ÷ (1 + %${seciliOran.toStringAsFixed(0)})',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ],
                              ),
                              Slider(
                                value: seciliOran,
                                min: 1,
                                max: 25,
                                divisions: 24,
                                label: '%${seciliOran.toStringAsFixed(0)}',
                                activeColor: const Color(0xFF0288D1),
                                onChanged: (v) => setKdv(() => seciliOran = v),
                                onChangeEnd: (v) async {
                                  await FirebaseFirestore.instance
                                      .collection('ayarlar')
                                      .doc('banknotlar')
                                      .update({'kdvOrani': v.roundToDouble()});
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _raporlarTab({bool merkziGiderGor = true}) {
    return FutureBuilder<List<String>>(
      future: FirebaseFirestore.instance
          .collection('subeler')
          .get()
          .then((snap) => snap.docs.map((d) => d.id).toList()),
      builder: (context, snap) {
        final subeler = snap.data ?? [];
        return DefaultTabController(
          length: 2,
          child: Column(
            children: [
              Container(
                color: const Color(0xFF0288D1),
                child: const TabBar(
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white60,
                  indicatorColor: Colors.white,
                  tabs: [
                    Tab(
                      icon: Icon(Icons.bar_chart, size: 18),
                      text: 'Dönem Raporu',
                    ),
                    Tab(icon: Icon(Icons.store, size: 18), text: 'Şube Özet'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _RaporlarWidget(
                      subeler: subeler,
                      merkziGiderGor: merkziGiderGor,
                    ),
                    _SubeOzetTablosu(subeler: subeler),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _kullaniciSilDialog(String id) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Kullanıcı Sil'),
        content: Text('$id kullanıcısı silinecek. Emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          TextButton(
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection('kullanicilar')
                  .doc(id)
                  .delete();
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Sil', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// ─── Veri Modelleri ───────────────────────────────────────────────────────────

class PosGirisi {
  TextEditingController adCtrl;
  TextEditingController tutarCtrl;
  bool yeni;

  PosGirisi({String ad = '', String tutar = '', this.yeni = false})
    : adCtrl = TextEditingController(text: ad),
      tutarCtrl = TextEditingController(text: tutar);

  String get ad => adCtrl.text;
  String get tutar => tutarCtrl.text;

  void dispose() {
    adCtrl.dispose();
    tutarCtrl.dispose();
  }
}

class HarcamaGirisi {
  TextEditingController aciklamaCtrl;
  TextEditingController tutarCtrl;
  bool yeni;

  HarcamaGirisi({String aciklama = '', String tutar = '', this.yeni = false})
    : aciklamaCtrl = TextEditingController(text: aciklama),
      tutarCtrl = TextEditingController(text: tutar);

  String get aciklama => aciklamaCtrl.text;
  String get tutar => tutarCtrl.text;

  void dispose() {
    aciklamaCtrl.dispose();
    tutarCtrl.dispose();
  }
}

// ─── Ön Hazırlık Ekranı ───────────────────────────────────────────────────────

class OnHazirlikEkrani extends StatefulWidget {
  final String subeKodu;
  final List<String> subeler;
  final bool raporYetkisi;
  final DateTime? baslangicTarihi;
  final int gecmisGunHakki;
  const OnHazirlikEkrani({
    super.key,
    required this.subeKodu,
    this.subeler = const [],
    this.raporYetkisi = false,
    this.baslangicTarihi,
    this.gecmisGunHakki = 0,
  });
  @override
  State<OnHazirlikEkrani> createState() => _OnHazirlikEkraniState();
}

class _OnHazirlikEkraniState extends State<OnHazirlikEkrani>
    with WidgetsBindingObserver {
  DateTime _secilenTarih = DateTime.now();
  Map<String, String> _subeAdlari = {}; // subeId -> subeAdi

  final List<PosGirisi> _posListesi = [PosGirisi(ad: 'POS 1')];
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
  Timer? _otomatikKaydetTimer; // Debounce timer
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
  bool _bildirimIsleniyor = false; // Bildirim döngüsü yeniden tetiklenmesin
  StreamSubscription<QuerySnapshot>? _bekleyenTransferStream; // Realtime rozet
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _transferKey = GlobalKey(); // Transfer bölümüne scroll

  // ── Gün kesim saati: 05:00 öncesi = önceki gün ─────────────────────────────
  static DateTime _bugunuHesapla() {
    final simdi = DateTime.now();
    if (simdi.hour < 5) {
      return DateTime(simdi.year, simdi.month, simdi.day - 1);
    }
    return DateTime(simdi.year, simdi.month, simdi.day);
  }

  @override
  void initState() {
    super.initState();
    _banknotlariYukle();
    _giderTurleriYukle();
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
        if (mounted && !_yukleniyor && !_readOnly) {
          setState(() {
            _degisiklikVar = true;
            if (_duzenlemeAcik) _gercekDegisiklikVar = true;
          });
          _otomatikKaydetBaslat();
          _kilitAl();
        }
      });
    }
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
            .limit(2)
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
                int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
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
        final kapali =
            tamamlandi == true ||
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
        final kapali =
            tamamlandi == true ||
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
    } catch (_) {}
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
      // Arka plana atıldı — 20 dakika timer başlat
      _arkaPlanTimer?.cancel();
      _arkaPlanTimer = Timer(const Duration(minutes: 20), () {
        if (mounted) _oturumZamanAsimi();
      });
    } else if (state == AppLifecycleState.resumed) {
      // Geri dönüldü — timerı iptal et
      _arkaPlanTimer?.cancel();
      _arkaPlanTimer = null;
      // Düzenleme açıksa uyar
      if (_duzenlemeAcik && mounted) {
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
  void _otomatikKaydetBaslat() {
    // readOnly modda otomatik kayıt çalışmasın
    if (_readOnly) return;
    _otomatikKaydetTimer?.cancel();
    // 3 sn debounce başlayınca hemen "Kaydediliyor..." göster
    if (mounted) _appBarMesajGoster('⏳ Kaydediliyor...');
    _otomatikKaydetTimer = Timer(const Duration(seconds: 3), () async {
      if (!mounted || _otomatikKaydediliyor) return;
      setState(() => _otomatikKaydediliyor = true);
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
          setState(() => _degisiklikVar = false);
          _appBarMesajGoster('✓ Otomatik Kaydedildi');
          await _kilitBirak();
        }
      } catch (_) {
        if (mounted) _appBarMesajGoster('✗ Kayıt Hatası');
      } finally {
        if (mounted) setState(() => _otomatikKaydediliyor = false);
      }
    });
  }

  // Otomatik kayıt için veri — zincirleme gerektirmez
  Map<String, dynamic> _otomatikKayitVerisi() {
    return {
      'tarih': _tarihKey(_secilenTarih),
      'tarihGoster': _tarihGoster(_secilenTarih),
      'subeKodu': widget.subeKodu,
      'otomatikKayit': true,
      'kayitZamani': FieldValue.serverTimestamp(),
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
      'gunlukSatisToplami': _parseDouble(_gunlukSatisCtrl.text),
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
              'kur': _parseDouble((d['kurCtrl'] as TextEditingController).text),
              'tlKarsiligi':
                  _parseDouble(
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
          })
          .toList(),
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
    } catch (_) {}
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
    } catch (_) {}
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
      final snapshot = await FirebaseFirestore.instance
          .collection('subeler')
          .get();
      for (var doc in snapshot.docs) {
        adlar[doc.id] = doc.data()['ad'] as String? ?? doc.id;
      }
      if (mounted) setState(() => _subeAdlari = adlar);
    } catch (_) {}
  }

  Future<void> _banknotlariYukle() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('banknotlar')
          .get();
      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        final list = (data['liste'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList();
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
      final liste = (doc.data()?['liste'] as List?)
          ?.map((e) => e.toString())
          .toList();
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
    } catch (_) {}
  }

  Future<void> _banknotAyarlariniKaydet() async {
    try {
      await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('banknotlar')
          .set({'liste': _banknotlar, 'flotSiniri': _flotSiniri});
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _kilitBirak();
    _kilitTimer?.cancel();
    _internetTimer?.cancel();
    _arkaPlanTimer?.cancel();
    _otomatikKaydetTimer?.cancel();
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
    for (var h in _harcamalar) h.dispose();
    for (var h in _anaKasaHarcamalari) h.dispose();
    for (var h in _nakitCikislar) h.dispose();
    for (var d in _nakitDovizler) {
      (d['ctrl'] as TextEditingController).dispose();
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
        } catch (_) {}
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
    // Otomatik kayıt timerı aktifse hemen kaydet
    if (_otomatikKaydetTimer?.isActive == true) {
      _otomatikKaydetTimer?.cancel();
      try {
        final tarihKey = _tarihKey(_secilenTarih);
        await FirebaseFirestore.instance
            .collection('subeler')
            .doc(widget.subeKodu)
            .collection('gunluk')
            .doc(tarihKey)
            .set(_otomatikKayitVerisi(), SetOptions(merge: true));
        if (mounted) setState(() => _degisiklikVar = false);
      } catch (_) {}
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
    } catch (_) {}
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

      // Sadece GELEN (bekletilmiş dahil) göster
      final aktifler = bekleyenler.docs
          .where((d) => d.data()['kategori'] == 'GELEN')
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
                      final kaynakAd = d['kaynakSubeAd'] as String? ?? '';
                      final tutar = (d['tutar'] as num? ?? 0).toDouble();
                      final tarih = d['tarih'] as String? ?? '';
                      final aciklama = d['aciklama'] as String? ?? '';
                      final bekletildi = d['bekletildi'] == true;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          bekletildi ? Icons.hourglass_empty : Icons.pending,
                          color: bekletildi ? Colors.orange : Colors.blue,
                        ),
                        title: Text('$kaynakAd → ${_formatTL(tutar)}'),
                        subtitle: Text(
                          [
                            tarih,
                            if (aciklama.isNotEmpty) aciklama,
                            if (bekletildi) 'Bekletildi',
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
    } catch (_) {}
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
      for (final doc in bekleyenler.docs.where(
        (d) => d.data()['kategori'] == 'RET',
      )) {
        if (!mounted) break;
        final data = doc.data();
        final transferId = data['transferId'] as String? ?? '';
        await doc.reference.delete();
        if (transferId.isNotEmpty) {
          setState(() {
            for (final t in _transferler) {
              if ((t['transferId'] as String? ?? '') == transferId) {
                t['reddedildi'] = true;
                t['onaylandi'] = false;
                t['bekletildi'] = false;
                t['gonderildi'] = false;
              }
            }
          });
          await _transferKaydet();
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
      final bekletilmemisler = gelenler
          .where((d) => d.data()['bekletildi'] != true)
          .toList();

      for (final doc in bekletilmemisler) {
        if (!mounted) return;
        final data = doc.data();
        final kaynakAd =
            data['kaynakSubeAd'] as String? ??
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
          await _transferiReddet(doc.id, data, transferId: transferId);
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
      final bekletilmisler = gelenler
          .where((d) => d.data()['bekletildi'] == true)
          .toList();

      for (final doc in bekletilmisler) {
        if (!mounted) return;
        final data = doc.data();
        final kaynakAd =
            data['kaynakSubeAd'] as String? ??
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
          await _transferiReddet(doc.id, data, transferId: transferId);
        }
        // beklet → hiçbir şey yapma, Firestoreda bekletildi=true kalır
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
      final onayDocId =
          '${transferTarih}_${transferData['kaynakSube']}_'
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
            'hedefSubeAd':
                transferData['hedefSubeAd'] ??
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
                'hedefSubeAd':
                    transferData['hedefSubeAd'] ??
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
    } catch (_) {}
  }

  void _mevcutKaydiYukle(Map<String, dynamic> data) {
    final bugun = _bugunuHesapla();
    final bugunMu =
        _secilenTarih.year == bugun.year &&
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
        _posListesi.add(PosGirisi(ad: 'POS 1'));
      } else {
        for (var p in posList) {
          final tutar = p['tutar'];
          _posListesi.add(
            PosGirisi(ad: p['ad'] ?? '', tutar: _sifirTemizle(tutar)),
          );
        }
      }
      _sistemPosCtrl.text = _sifirTemizle(data['sistemPos']);
      _gunlukSatisCtrl.text = _sifirTemizle(data['gunlukSatisToplami']);

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

  Future<void> _formlariTemizle() async {
    final bugun = _bugunuHesapla();
    final bugunMu =
        _secilenTarih.year == bugun.year &&
        _secilenTarih.month == bugun.month &&
        _secilenTarih.day == bugun.day;
    setState(() {
      _gunuKapatildi = false; // Kayıt yok = kapatılmamış, veri girilebilir
      _duzenlemeAcik = false;
      for (var p in _posListesi) p.dispose();
      _posListesi.clear();
      _posListesi.add(PosGirisi(ad: 'POS 1'));
      _sistemPosCtrl.clear();
      _gunlukSatisCtrl.clear();

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
    } catch (_) {}
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
              _devredenDovizMiktarlari[t] = (dovizKalanlar[t] as num)
                  .toDouble();
            } else if (dovizAnaKasaMap != null && dovizAnaKasaMap[t] != null) {
              _devredenDovizMiktarlari[t] = (dovizAnaKasaMap[t] as num)
                  .toDouble();
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
    } catch (_) {}
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
    } catch (_) {}
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
          .limit(1)
          .get();

      if (kayitlar.docs.isNotEmpty) {
        final data = kayitlar.docs.first.data();
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
              _devredenDovizMiktarlari[t] = (dovizKalanlar[t] as num)
                  .toDouble();
            } else if (dovizAnaKasaMap != null && dovizAnaKasaMap[t] != null) {
              _devredenDovizMiktarlari[t] = (dovizAnaKasaMap[t] as num)
                  .toDouble();
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
    } catch (_) {}
  }

  // ── Hesaplamalar ────────────────────────────────────────────────────────────

  double get _toplamPos {
    double t = 0;
    for (var p in _posListesi) t += _parseDouble(p.tutarCtrl.text);
    return t;
  }

  double get _posFarki => _toplamPos - _parseDouble(_sistemPosCtrl.text);

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
    final temelKosullar =
        !_kaydediliyor &&
        !_dovizLimitiAsildi &&
        _internetVar &&
        _ekrandaGorunenNakitCtrl.text.isNotEmpty &&
        _parseDouble(_ekrandaGorunenNakitCtrl.text) > 0 &&
        _sistemPosCtrl.text.isNotEmpty &&
        _gunlukSatisCtrl.text.isNotEmpty &&
        _parseDouble(_gunlukSatisCtrl.text) > 0 &&
        _toplamPos > 0 &&
        _toplamNakitTL > 0;
    if (!temelKosullar) return false;
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
      double.tryParse(s.replaceAll('.', '').replaceAll(',', '.')) ?? 0;
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
    } catch (_) {}
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
              dovizDetay +=
                  '\n  $sembol Önceki: ${onceki.toStringAsFixed(2)}'
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

            await showDialog<void>(
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
                  'Lütfen $oncekiTarihGoster tarihine gidip\n'
                  'günü tekrar kapatın, sonra buraya dönün.',
                ),
                actions: [
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Tamam'),
                  ),
                ],
              ),
            );
            return; // Kapatmayı engelle
          }
        }
      } catch (_) {
        // Kontrol başarısız olursa sessizce devam et
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
        'versiyon': _appVersiyon,
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
        'gunlukSatisToplami': _parseDouble(_gunlukSatisCtrl.text),
        'posFarki': _posFarki,
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
                'tlKarsiligi':
                    _parseDouble(
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
                'kaynakSubeAd':
                    t['kaynakSubeAd'] ??
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
            })
            .toList(),
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
      final islemsizGelen = bekleyenSnap.docs
          .where((d) => d.data()['bekletildi'] != true)
          .length;
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
                          (t['aciklamaCtrl'] as TextEditingController).text
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
      } catch (_) {}

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
      final bankayaYatirilan = (data['bankayaYatirilan'] as num? ?? 0)
          .toDouble();
      final toplamAnaKasaHarcama = (data['toplamAnaKasaHarcama'] as num? ?? 0)
          .toDouble();
      final gunlukKasaKalaniTL = (data['gunlukKasaKalaniTL'] as num? ?? 0)
          .toDouble();
      final gunlukFlot = (data['gunlukFlot'] as num? ?? 0).toDouble();

      // Yeni Ana Kasa Kalanı
      final toplamNakitCikis = (data['toplamNakitCikis'] as num? ?? 0)
          .toDouble();
      final yeniKalan =
          oncekiKalan +
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
              tooltip: !_gunuKapatildi
                  ? 'Günü kapatmadan ileri geçemezsiniz'
                  : null,
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

  Future<void> _tarihDegistir(int gunFarki) async {
    // İleri git: kapanmamış günden sonrasına geçilemez (ileri ok zaten pasif)
    // Geri git: serbest — kapanmamış günden geriye gidilebilir
    // Değişiklik varsa önce otomatik kaydet (timer beklemeden)
    if (_degisiklikVar || _otomatikKaydetTimer?.isActive == true) {
      _otomatikKaydetTimer?.cancel();
      try {
        final tarihKey = _tarihKey(_secilenTarih);
        await FirebaseFirestore.instance
            .collection('subeler')
            .doc(widget.subeKodu)
            .collection('gunluk')
            .doc(tarihKey)
            .set(_otomatikKayitVerisi(), SetOptions(merge: true));
        if (mounted) setState(() => _degisiklikVar = false);
      } catch (_) {}
    }
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

  // ── POS Bölümü ──────────────────────────────────────────────────────────────

  Widget _posSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                            _otomatikKaydetBaslat();
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
                            });
                            _otomatikKaydetBaslat();
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
                                });
                                _otomatikKaydetBaslat();
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
                      () => _posListesi.add(
                        PosGirisi(
                          ad: 'POS ${_posListesi.length + 1}',
                          yeni: true,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.add),
              label: const Text('POS Ekle'),
            ),
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
                    'Toplam POS',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Color(0xFF0288D1),
                    ),
                  ),
                  Text(
                    _formatTL(_toplamPos),
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
            // Sistemdeki POS — zorunlu, belirgin
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0288D1).withOpacity(0.07),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF0288D1), width: 1.5),
              ),
              child: TextFormField(
                controller: _sistemPosCtrl,
                readOnly: _readOnly,
                decoration: InputDecoration(
                  labelText: 'Sistemdeki POS Rakamı (₺)',
                  suffixIcon: _zorunluIkon(
                    _parseDouble(_sistemPosCtrl.text) > 0,
                  ),
                  hintText: 'Mutlaka girilmeli!',
                  prefixIcon: const Icon(
                    Icons.point_of_sale,
                    color: Color(0xFF0288D1),
                  ),
                  labelStyle: const TextStyle(
                    color: Color(0xFF0288D1),
                    fontWeight: FontWeight.bold,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
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
            ),
            const SizedBox(height: 8),
            _farkSatiri('POS Farkı', _posFarki),
            const SizedBox(height: 12),
            // Ekranda Görünen Nakit — zorunlu
            Container(
              decoration: BoxDecoration(
                color: Colors.amber[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber[700]!, width: 1.5),
              ),
              child: TextFormField(
                controller: _ekrandaGorunenNakitCtrl,
                readOnly: _readOnly,
                decoration: InputDecoration(
                  labelText: 'Ekranda Görünen Nakit (₺)',
                  suffixIcon: _zorunluIkon(
                    _parseDouble(_ekrandaGorunenNakitCtrl.text) > 0,
                  ),
                  suffixText: '₺',
                  hintText: 'Mutlaka girilmeli!',
                  prefixIcon: Icon(Icons.monitor, color: Colors.amber[700]),
                  labelStyle: TextStyle(
                    color: Colors.amber[800],
                    fontWeight: FontWeight.bold,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
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
            ),
            const SizedBox(height: 8),
            // Günlük Satış Toplamı — zorunlu, kırmızı
            Container(
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
                  suffixIcon: _zorunluIkon(
                    _parseDouble(_gunlukSatisCtrl.text) > 0,
                  ),
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
      ),
    );
  }

  // ── Harcamalar ──────────────────────────────────────────────────────────────

  Widget _harcamalarSection() {
    return Card(
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
                      child: _GiderAdiAlani(
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
                            _otomatikKaydetBaslat();
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
                            _otomatikKaydetBaslat();
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
                                _otomatikKaydetBaslat();
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Toplam Harcama',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Colors.red[700],
                    ),
                  ),
                  Text(
                    _formatTL(_toplamHarcama),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.red[700],
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

  // ── Nakit Sayım ─────────────────────────────────────────────────────────────

  Widget _nakitSayimSection() {
    return Card(
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
                                if (_duzenlemeAcik) _gercekDegisiklikVar = true;
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
                            style: const TextStyle(fontWeight: FontWeight.w500),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Döviz',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: Colors.red,
                  ),
                ),
                TextButton.icon(
                  onPressed: _readOnly ? null : () => _dovizEkle(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Döviz Ekle'),
                ),
              ],
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
                        decoration: const InputDecoration(labelText: 'Miktar'),
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
                            _otomatikKaydetBaslat();
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
                        decoration: const InputDecoration(labelText: 'Kur (₺)'),
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
                            _otomatikKaydetBaslat();
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
                                (d['miktarCtrl'] as TextEditingController).text,
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
                                (d['kurCtrl'] as TextEditingController).dispose();
                                _dovizler.removeAt(idx);
                                _degisiklikVar = true;
                              });
                              _otomatikKaydetBaslat();
                            },
                    ),
                  ],
                ),
              );
            }),
            if (_dovizler.isNotEmpty) ...[
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
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Döviz TL Karşılığı (bilgi):',
                    style: TextStyle(
                      color: Colors.orange[700],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    _formatTL(_toplamDovizTL),
                    style: TextStyle(
                      color: Colors.orange[700],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Genel Toplam:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    _formatTL(_toplamNakitTL + _toplamDovizTL),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ] else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Toplam Nakit:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    _formatTL(_toplamNakitTL),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
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

  // ── Kasa Durumu ─────────────────────────────────────────────────────────────

  Widget _ekBilgilerSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Kasa Durumu', Icons.account_balance_wallet),
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

  Widget _kasaOzetiSection() {
    return Card(
      color: const Color(0xFFF0F4F8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Kasa Özeti', Icons.summarize),
            _bilgiSatiri('Toplam TL Nakit', _formatTL(_toplamNakitTL)),
            if (_toplamDovizTL > 0)
              _bilgiSatiri('Döviz TL Karşılığı', _formatTL(_toplamDovizTL)),
            _bilgiSatiri('Harcamalar', _formatTL(_toplamHarcama)),
            if (_toplamNakitCikis > 0)
              _bilgiSatiri('Nakit Çıkış', _formatTL(_toplamNakitCikis)),
            ..._nakitDovizler
                .where(
                  (d) =>
                      _parseDouble((d['ctrl'] as TextEditingController).text) >
                      0,
                )
                .map((d) {
                  final cins = d['cins'] as String;
                  final sembol = cins == 'USD'
                      ? r'$'
                      : cins == 'EUR'
                      ? '€'
                      : '£';
                  final miktar = _parseDouble(
                    (d['ctrl'] as TextEditingController).text,
                  );
                  return _bilgiSatiri(
                    'Nakit Çıkış ($cins)',
                    '$sembol ${miktar.toStringAsFixed(2)}',
                  );
                }),
            _bilgiSatiri('Toplam Flot', _formatTL(_flotTutari)),
            const Divider(),
            _farkSatiri(
              'Günlük Kasa Kalanı',
              _gunlukKasaKalani,
              buyukFont: true,
            ),
            if (_toplamDovizTL > 0) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 4),
                        Text(
                          '  ↳ TL Kısmı:',
                          style: TextStyle(
                            color: Colors.green[700],
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _formatTL(_gunlukKasaKalaniTL),
                      style: TextStyle(
                        color: Colors.green[700],
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              ..._dovizTurleri.where((t) => _buGunDovizMiktari(t) > 0).map((t) {
                String sembol = t == 'USD'
                    ? r'$'
                    : t == 'EUR'
                    ? '€'
                    : '£';
                final cinsRenk = dovizRenk(t);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '  ↳ $t Kısmı:',
                        style: TextStyle(
                          color: cinsRenk,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '$sembol ${_buGunDovizMiktari(t).toStringAsFixed(2)} '
                        '(${_formatTL(_buGunDovizMiktari(t) * _dovizKur(t))})',
                        style: TextStyle(
                          color: cinsRenk,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
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
    );
  }

  // ── Transferler ──────────────────────────────────────────────────────────────

  Widget _transferlerSection() {
    return KeyedSubtree(key: _transferKey, child: _transferlerIcerik());
  }

  Widget _transferlerIcerik() {
    final gidenler = _transferler
        .where((t) => t['kategori'] == 'GİDEN')
        .toList();
    final gelenler = _transferler
        .where((t) => t['kategori'] == 'GELEN')
        .toList();
    final digerSubeler = _subeAdlari.entries
        .where((e) => e.key != widget.subeKodu)
        .toList();

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
            _sectionTitle('Transferler', Icons.swap_horiz),
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
                durumIkon = kategori == 'GİDEN'
                    ? Icons.send
                    : Icons.mark_email_read;
              }

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: reddedildi ? Colors.red[50] : renk.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: reddedildi
                        ? Colors.red[300]!
                        : renk.withOpacity(0.25),
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
    final hedefAd =
        _subeAdlari[t['hedefSube'] as String? ?? ''] ??
        (t['hedefSubeAd'] as String? ?? '');
    final kaynakAd =
        _subeAdlari[t['kaynakSube'] as String? ?? ''] ??
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
        if (kategori == 'GİDEN' && !onaylandi && (!gonderildi || reddedildi)) ...[
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
              icon: Icon(
                reddedildi ? Icons.refresh : Icons.send,
                size: 15,
              ),
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
          if (reddedildi)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Karşı şube reddetti — düzenleyip tekrar gönderebilirsiniz',
                style: TextStyle(color: Colors.red[700], fontSize: 11),
              ),
            ),
        ],
        // GELEN — Bildir butonu (Gönder ile aynı mantık, sadece isim farklı)
        // Reddedildiyse: aktif "Tekrar Bildir" butonu
        // Henüz bildirilmediyse: aktif "Bildir" butonu
        // Bildirildi veya onaylandıysa: buton yok (badge gösteriyor)
        if (kategori == 'GELEN' && !onaylandi && (!gonderildi || reddedildi)) ...[
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
          if (reddedildi)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Karşı şube reddetti — düzenleyip tekrar bildirebilirsiniz',
                style: TextStyle(color: Colors.red[700], fontSize: 11),
              ),
            ),
        ],

        if (kategori == 'GELEN' && reddedildi)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Karşı şube bu transferi reddetti',
              style: TextStyle(color: Colors.red[700], fontSize: 11),
            ),
          ),
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
            _sectionTitle('Diğer Alımlar', Icons.shopping_bag_outlined),
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
                          : _DigerAlimAciklamaAlani(
                              ctrl: t['aciklamaCtrl'] as TextEditingController,
                              secenekler: _giderTurleriListesi,
                              onChanged: () {
                                if (mounted && !_yukleniyor) {
                                  setState(() {
                                    _degisiklikVar = true;
                                    if (_duzenlemeAcik)
                                      _gercekDegisiklikVar = true;
                                  });
                                  _otomatikKaydetBaslat();
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
                            _otomatikKaydetBaslat();
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
                              _otomatikKaydetBaslat();
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
                      child: _GiderAdiAlani(
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
                            _otomatikKaydetBaslat();
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
                            _otomatikKaydetBaslat();
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
                                _otomatikKaydetBaslat();
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
                      () => _anaKasaHarcamalari.add(HarcamaGirisi(yeni: true)),
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
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Toplam Harcama',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Colors.orange[800],
                      ),
                    ),
                    Text(
                      _formatTL(_toplamAnaKasaHarcama),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.orange[800],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Nakit Çıkış ──────────────────────────────────────────────────────────────

  Widget _nakitCikisSection() {
    return Card(
      color: Colors.purple[50],
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
                      child: _GiderAdiAlani(
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
                            _otomatikKaydetBaslat();
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
                            _otomatikKaydetBaslat();
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
                                _otomatikKaydetBaslat();
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
                            keyboardType: const TextInputType.numberWithOptions(
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
                              _otomatikKaydetBaslat();
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
                                  _otomatikKaydetBaslat();
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
                      _parseDouble((d['ctrl'] as TextEditingController).text) >
                      0,
                )) ...[
              const Divider(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.purple[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_toplamNakitCikis > 0)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Toplam Nakit Çıkış (TL)',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: Colors.purple[800],
                            ),
                          ),
                          Text(
                            _formatTL(_toplamNakitCikis),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: Colors.purple[800],
                            ),
                          ),
                        ],
                      ),
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
                          final miktar = _parseDouble(
                            (d['ctrl'] as TextEditingController).text,
                          );
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Nakit Çıkış ($cins)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: Colors.purple[700],
                                ),
                              ),
                              Text(
                                '$sembol ${miktar.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: Colors.purple[700],
                                ),
                              ),
                            ],
                          );
                        }),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Bankaya Yatan ────────────────────────────────────────────────────────────

  Widget _bankayaYatanSection() {
    return Card(
      color: Colors.red[50],
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
                                  _otomatikKaydetBaslat();
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
                color: _readOnly ? Colors.grey : Colors.orange[700],
              ),
              label: Text(
                'Döviz Ekle',
                style: TextStyle(
                  color: _readOnly ? Colors.grey : Colors.orange[700],
                ),
              ),
            ),
          ],
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

            // Devreden Ana Kasa
            _altBaslik('Devreden Ana Kasa', Colors.blueGrey[700]!),
            _ozetSatiri(
              'TL',
              _formatTL(_oncekiAnaKasaKalani),
              Colors.blue[700]!,
            ),
            ..._dovizTurleri
                .where((t) => (_devredenDovizMiktarlari[t] ?? 0) > 0)
                .map((t) {
                  final sembol = t == 'USD'
                      ? '\$'
                      : t == 'EUR'
                      ? '€'
                      : '£';
                  return _ozetSatiri(
                    t,
                    '$sembol ${(_devredenDovizMiktarlari[t] ?? 0).toStringAsFixed(2)}',
                    dovizRenk(t),
                  );
                }),
            const Divider(),

            // Bu Günün Kasa Kalanı
            _altBaslik('Bu Günün Kasa Kalanı', Colors.blueGrey[700]!),
            _ozetSatiri(
              'TL',
              _formatTL(_gunlukKasaKalaniTL),
              Colors.blue[700]!,
            ),
            ..._dovizTurleri.where((t) => _buGunDovizMiktari(t) > 0).map((t) {
              final sembol = t == 'USD'
                  ? '\$'
                  : t == 'EUR'
                  ? '€'
                  : '£';
              return _ozetSatiri(
                t,
                '$sembol ${_buGunDovizMiktari(t).toStringAsFixed(2)}',
                dovizRenk(t),
              );
            }),
            const Divider(),

            // Ana Kasa Harcamalar (varsa)
            if (_toplamAnaKasaHarcama > 0) ...[
              _altBaslik('Ana Kasa Harcamalar', Colors.blueGrey[700]!),
              _ozetSatiri(
                'Toplam',
                _formatTL(_toplamAnaKasaHarcama),
                Colors.orange[800]!,
              ),
              const Divider(),
            ],

            // Bankaya Yatırılan
            _altBaslik('Bankaya Yatan', Colors.blueGrey[700]!),
            _ozetSatiri(
              'TL',
              _formatTL(_parseDouble(_bankayaYatiranCtrl.text)),
              Colors.blue[700]!,
            ),
            ..._bankaDovizler
                .where(
                  (d) =>
                      _parseDouble((d['ctrl'] as TextEditingController).text) >
                      0,
                )
                .map((d) {
                  final cins = d['cins'] as String;
                  final sembol = cins == 'USD'
                      ? r'$'
                      : cins == 'EUR'
                      ? '€'
                      : '£';
                  final miktar = _parseDouble(
                    (d['ctrl'] as TextEditingController).text,
                  );
                  return _ozetSatiri(
                    cins,
                    '$sembol ${miktar.toStringAsFixed(2)}',
                    dovizRenk(cins),
                  );
                }),
            // Nakit Çıkış (varsa)
            if (_toplamNakitCikis > 0 ||
                _nakitDovizler.any(
                  (d) =>
                      _parseDouble((d['ctrl'] as TextEditingController).text) >
                      0,
                )) ...[
              _altBaslik('Nakit Çıkış', Colors.purple[700]!),
              if (_toplamNakitCikis > 0)
                _ozetSatiri(
                  'TL',
                  _formatTL(_toplamNakitCikis),
                  Colors.purple[700]!,
                ),
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
                        : '£';
                    final miktar = _parseDouble(
                      (d['ctrl'] as TextEditingController).text,
                    );
                    return _ozetSatiri(
                      cins,
                      '$sembol ${miktar.toStringAsFixed(2)}',
                      Colors.purple[600]!,
                    );
                  }),
            ],
            const Divider(),

            // Toplam Ana Kasa Kalanı
            _altBaslik('Toplam Ana Kasa Kalanı', const Color(0xFF0288D1)),
            Container(
              margin: const EdgeInsets.only(top: 4, bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _anaKasaKalani >= 0
                    ? Colors.green[700]
                    : Colors.red[700],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'TL',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    _formatTL(_anaKasaKalani),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
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
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          t,
                          style: TextStyle(
                            color: yaziRenk,
                            fontWeight: FontWeight.bold,
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
    bool herhangiDovizVar =
        _dovizler.isNotEmpty ||
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
                        color: kalani >= 0
                            ? Colors.green[700]
                            : Colors.red[700],
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
              const _KasaLogo(),
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
              colors: [Color(0xFF01579B), Color(0xFF0288D1), Color(0xFF29B6F6)],
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
                      ))
                        return;
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
              icon: const Icon(Icons.summarize),
              tooltip: 'Günlük Özet',
              onPressed: () async {
                if (_duzenlemeAcik) {
                  if (!await _degisiklikUyar(gecisMetni: 'Özete geçmeden'))
                    return;
                }
                if (!_gunuKapatildi) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Özeti görmek için önce günü kapatın.'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                  return;
                }
                if (mounted)
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => OzetEkrani(
                        subeKodu: widget.subeKodu,
                        baslangicTarihi: _secilenTarih,
                        subeler: widget.subeler,
                        gecmisGunHakki: widget.gecmisGunHakki,
                      ),
                    ),
                  );
              },
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                switch (value) {
                  case 'temizle':
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Formu Temizle'),
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
                if ((_bugunSecili || _duzenlemeAcik) && !_readOnly)
                  PopupMenuItem(
                    value: 'temizle',
                    child: const Row(
                      children: [
                        Icon(Icons.delete_outline, color: Colors.red),
                        SizedBox(width: 12),
                        Text(
                          'Formu Temizle',
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
                          final bugunMu =
                              _secilenTarih.year == bugun.year &&
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
                            bannerMetin =
                                'Bugün ${_tarihGoster(bugun)} — '
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
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              _tarihSeciciSection(),
                              const SizedBox(height: 12),
                              _posSection(),
                              const SizedBox(height: 12),
                              _harcamalarSection(),
                              const SizedBox(height: 12),
                              _nakitSayimSection(),
                              const SizedBox(height: 12),
                              _ekBilgilerSection(),
                              const SizedBox(height: 12),
                              _anaKasaHarcamalarSection(),
                              const SizedBox(height: 12),
                              _bankayaYatanSection(),
                              const SizedBox(height: 12),
                              _nakitCikisSection(),
                              const SizedBox(height: 12),
                              _transferlerSection(),
                              const SizedBox(height: 12),
                              _digerAlimlarSection(),
                              const SizedBox(height: 12),
                              _kasaOzetiSection(),
                              const SizedBox(height: 12),
                              _anaKasaSection(),
                              const SizedBox(height: 24),
                              if (_dovizLimitiAsildi)
                                Container(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.red[50],
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.red[300]!),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.error_outline,
                                        color: Colors.red[700],
                                        size: 20,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Bankaya yatırılan döviz miktarı kasadakinden fazla! Lütfen düzeltin.',
                                          style: TextStyle(
                                            color: Colors.red[700],
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              // İnternet yok uyarısı
                              // Ana Kasa limit uyarısı
                              if (_anaKasaLimitiAsildi)
                                Container(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.deepOrange[50],
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.deepOrange[300]!,
                                    ),
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
                                          'Ana Kasa eksi kalıyor (${_formatTL(_anaKasaKalani)})! Yapılan işlemler Ana Kasayı aşıyor.',
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
                                  margin: const EdgeInsets.only(bottom: 12),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.orange[50],
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.orange[400]!,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.wifi_off,
                                        color: Colors.orange[800],
                                        size: 20,
                                      ),
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
                              // Günü Kapat / Düzenlemeyi Aç — dönüşümlü
                              if (_gunuKapatildi && !_duzenlemeAcik)
                                // Gün kapatılmış — Düzenlemeyi Aç
                                SizedBox(
                                  width: double.infinity,
                                  height: 52,
                                  child: OutlinedButton.icon(
                                    onPressed: () async {
                                      final hakki = widget.gecmisGunHakki;
                                      // Yönetici (hakki == -1) sınırsız
                                      if (hakki >= 0) {
                                        // Referans: en son kapatılan gün
                                        // (navigasyon limiti ile aynı mantık)
                                        final referans =
                                            _sonKapaliTarih ?? _bugunuHesapla();
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
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
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
                                          .update({'tamamlandi': false});
                                      if (mounted) {
                                        setState(() {
                                          _gunuKapatildi = false;
                                          _duzenlemeAcik = true;
                                          _degisiklikVar = true;
                                          _gercekDegisiklikVar = false;
                                        });
                                      }
                                    },
                                    icon: const Icon(Icons.lock_open),
                                    label: const Text(
                                      'Düzenlemeyi Aç',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.orange[700],
                                      side: BorderSide(
                                        color: Colors.orange[700]!,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                  ),
                                )
                              else ...[
                                // Düzenleme modu — uyarı + Günü Kapat
                                Builder(
                                  builder: (ctx) {
                                    final islemsiz = _transferler.where((t) {
                                      final kategori = t['kategori'] as String;
                                      final tutar = _parseDouble(
                                        (t['tutarCtrl']
                                                as TextEditingController)
                                            .text,
                                      );
                                      if (tutar <= 0) return false;
                                      if (t['gonderildi'] == true) return false;
                                      if (kategori == 'GİDEN') {
                                        final hedef =
                                            t['hedefSube'] as String? ?? '';
                                        return hedef.isNotEmpty &&
                                            hedef != 'diger';
                                      } else if (kategori == 'GELEN') {
                                        final kaynak =
                                            t['kaynakSube'] as String? ?? '';
                                        return kaynak.isNotEmpty;
                                      }
                                      return false;
                                    }).length;
                                    if (islemsiz == 0)
                                      return const SizedBox.shrink();
                                    return Container(
                                      margin: const EdgeInsets.only(bottom: 10),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.orange[50],
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: Colors.orange[400]!,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.send_outlined,
                                            color: Colors.orange[800],
                                            size: 18,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              '$islemsiz adet transfer gönderilmedi/bildirilmedi — '
                                              'işleyin veya silin',
                                              style: TextStyle(
                                                color: Colors.orange[900],
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                                // Günü Kapat butonu
                                SizedBox(
                                  width: double.infinity,
                                  height: 52,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: (_kaydetButonuAktif && _kilitTutanKullanici == null)
                                          ? const LinearGradient(
                                              colors: [Color(0xFF01579B), Color(0xFF0288D1), Color(0xFF29B6F6)],
                                              begin: Alignment.centerLeft,
                                              end: Alignment.centerRight,
                                            )
                                          : const LinearGradient(
                                              colors: [Colors.grey, Colors.grey],
                                            ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: ElevatedButton.icon(
                                      onPressed:
                                          (_kaydetButonuAktif &&
                                              _kilitTutanKullanici == null)
                                          ? _kaydet
                                          : null,
                                      icon: _kaydediliyor
                                          ? const SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                color: Colors.white,
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : Icon(
                                              !_internetVar
                                                  ? Icons.wifi_off
                                                  : Icons.lock_clock,
                                            ),
                                      label: Text(
                                        _kaydediliyor
                                            ? 'Kaydediliyor...'
                                            : !_internetVar
                                            ? 'Bağlantı Yok'
                                            : 'Günü Kapat',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.transparent,
                                        shadowColor: Colors.transparent,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 32),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ), // Expanded kapanış
          ], // Column children kapanış
        ), // Column kapanış
      ), // PopScope kapanış
    );
  }
}

// ─── Gider Türleri Kartı ──────────────────────────────────────────────────────

// ─── Gider Düzenle Sheet ─────────────────────────────────────────────────────

class _GiderDuzenleSheet extends StatefulWidget {
  final Map<String, dynamic> v;
  final List<String> giderTurleri;
  final Future<void> Function(Map<String, dynamic>) onKaydet;

  const _GiderDuzenleSheet({
    required this.v,
    required this.giderTurleri,
    required this.onKaydet,
  });

  @override
  State<_GiderDuzenleSheet> createState() => _GiderDuzenleSheetState();
}

class _GiderDuzenleSheetState extends State<_GiderDuzenleSheet> {
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
              'oran':
                  double.tryParse(
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

// ─── Ek Gider Sheet ──────────────────────────────────────────────────────────

class _EkGiderSheet extends StatefulWidget {
  final String subeAd;
  final String donemKey;
  final List<Map<String, dynamic>> satirlar;
  final List<String> giderTurleri;
  final Future<void> Function(List<Map<String, dynamic>>) onKaydet;

  const _EkGiderSheet({
    required this.subeAd,
    required this.donemKey,
    required this.satirlar,
    required this.giderTurleri,
    required this.onKaydet,
  });

  @override
  State<_EkGiderSheet> createState() => _EkGiderSheetState();
}

class _EkGiderSheetState extends State<_EkGiderSheet> {
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
    final kaydedilecek = _satirlar
        .where((s) {
          final ad = (s['adCtrl'] as TextEditingController).text.trim();
          final tStr = (s['tutarCtrl'] as TextEditingController).text.trim();
          final tutar =
              double.tryParse(tStr.replaceAll('.', '').replaceAll(',', '.')) ??
              0.0;
          return ad.isNotEmpty && tutar > 0;
        })
        .map((s) {
          final tutar =
              double.tryParse(
                (s['tutarCtrl'] as TextEditingController).text
                    .replaceAll('.', '')
                    .replaceAll(',', '.'),
              ) ??
              0.0;
          return {
            'ad': (s['adCtrl'] as TextEditingController).text.trim(),
            'tutar': tutar,
          };
        })
        .toList();

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
                                        () =>
                                            (s['adCtrl']
                                                        as TextEditingController)
                                                    .text =
                                                val,
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

// ─── Gerçekleşen Widget ───────────────────────────────────────────────────────

class _GerceklesenWidget extends StatefulWidget {
  const _GerceklesenWidget();
  @override
  State<_GerceklesenWidget> createState() => _GerceklesenWidgetState();
}

class _GerceklesenWidgetState extends State<_GerceklesenWidget>
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
  int _karsilastirmaYil = DateTime.now().month == 1
      ? DateTime.now().year - 1
      : DateTime.now().year;
  int _karsilastirmaAy = DateTime.now().month == 1
      ? 12
      : DateTime.now().month - 1;
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
      final liste = (doc.data()?['liste'] as List?)
          ?.map((e) => e.toString())
          .toList();
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
    final hedefSubeler = _secilenSube != null
        ? [_secilenSube!]
        : _subeAdlari.keys.toList();
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
      final tutar = mevcut.isNotEmpty
          ? (mevcut['tutar'] as num? ?? 0).toDouble()
          : 0.0;
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
      builder: (ctx) => _EkGiderSheet(
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
                            color: kar >= 0
                                ? Colors.green[700]
                                : Colors.red[700],
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
      Text(etiket, style: const TextStyle(color: Colors.white54, fontSize: 11)),
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
                          final oncekiAy = simdi.month == 1
                              ? 12
                              : simdi.month - 1;
                          final oncekiYil = simdi.month == 1
                              ? simdi.year - 1
                              : simdi.year;
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
                              items:
                                  List.generate(
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

class _GiderAdiAlani extends StatefulWidget {
  final TextEditingController ctrl;
  final List<String> secenekler;
  final String labelText;
  final VoidCallback? onChanged;
  final bool readOnly;

  const _GiderAdiAlani({
    required this.ctrl,
    required this.secenekler,
    this.labelText = 'Gider Adı',
    this.onChanged,
    this.readOnly = false,
  });

  @override
  State<_GiderAdiAlani> createState() => _GiderAdiAlaniState();
}

class _GiderAdiAlaniState extends State<_GiderAdiAlani> {
  @override
  void dispose() {
    super.dispose();
  }

  void _secimYap() {
    if (widget.readOnly || widget.secenekler.isEmpty) return;
    final ctrl = TextEditingController(text: widget.ctrl.text);

    void kaydetVeKapat(BuildContext ctx, String deger) {
      final temiz = deger.trim();
      widget.ctrl.text = temiz;
      widget.ctrl.selection = TextSelection.collapsed(offset: temiz.length);
      widget.onChanged?.call();
      Navigator.pop(ctx);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final q = ctrl.text.toLowerCase().trim();
          final filtreli = q.isEmpty
              ? widget.secenekler
              : widget.secenekler
                    .where((t) => t.toLowerCase().contains(q))
                    .toList();
          return GestureDetector(
            // Boşluğa tıklayınca yazdığını kaydet ve kapat
            onTap: () => kaydetVeKapat(ctx, ctrl.text),
            behavior: HitTestBehavior.opaque,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: GestureDetector(
                      onTap: () {}, // iç tapa engel — dışarı bubble etmesin
                      child: TextField(
                        controller: ctrl,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: widget.labelText,
                          prefixIcon: const Icon(Icons.search, size: 18),
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        textCapitalization: TextCapitalization.words,
                        inputFormatters: [IlkHarfBuyukFormatter()],
                        onChanged: (_) => setS(() {}),
                        // Enter'a basınca yazdığını kaydet
                        onSubmitted: (v) => kaydetVeKapat(ctx, v),
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * 0.45,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtreli.length + 1,
                      itemBuilder: (_, i) {
                        if (i == filtreli.length) {
                          // Serbest metin ile devam et
                          if (ctrl.text.trim().isEmpty)
                            return const SizedBox.shrink();
                          final serbest = ctrl.text.trim();
                          return ListTile(
                            leading: const Icon(
                              Icons.edit,
                              size: 18,
                              color: Colors.grey,
                            ),
                            title: Text(
                              '"$serbest" olarak kullan',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.grey,
                              ),
                            ),
                            onTap: () => kaydetVeKapat(ctx, serbest),
                          );
                        }
                        final item = filtreli[i];
                        final secili = widget.ctrl.text == item;
                        return ListTile(
                          leading: Icon(
                            secili ? Icons.check_circle : Icons.label_outline,
                            size: 18,
                            color: secili
                                ? const Color(0xFF0288D1)
                                : Colors.grey,
                          ),
                          title: Text(
                            item,
                            style: const TextStyle(fontSize: 14),
                          ),
                          onTap: () => kaydetVeKapat(ctx, item),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    ).then((_) {
      ctrl.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.ctrl,
      readOnly: widget.readOnly || widget.secenekler.isNotEmpty,
      decoration: InputDecoration(
        labelText: widget.labelText,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        suffixIcon: widget.secenekler.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_drop_down, size: 20),
                padding: EdgeInsets.zero,
                onPressed: _secimYap,
              ),
      ),
      onTap: widget.secenekler.isNotEmpty ? _secimYap : null,
      textInputAction: TextInputAction.next,
      textCapitalization: TextCapitalization.words,
      inputFormatters: [IlkHarfBuyukFormatter()],
      onChanged: widget.secenekler.isEmpty
          ? (_) => widget.onChanged?.call()
          : null,
    );
  }
}

// _DigerAlimAciklamaAlani artık _GiderAdiAlaninin ince sarmalayıcısı —
// onChanged callbacki ve labelText farkı dışında aynı widget.
class _DigerAlimAciklamaAlani extends StatelessWidget {
  final TextEditingController ctrl;
  final List<String> secenekler;
  final VoidCallback onChanged;

  const _DigerAlimAciklamaAlani({
    required this.ctrl,
    required this.secenekler,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _GiderAdiAlani(
      ctrl: ctrl,
      secenekler: secenekler,
      labelText: 'Açıklama',
      onChanged: onChanged,
    );
  }
}

class _GiderTurleriKart extends StatefulWidget {
  const _GiderTurleriKart();

  @override
  State<_GiderTurleriKart> createState() => _GiderTurleriKartState();
}

class _GiderTurleriKartState extends State<_GiderTurleriKart> {
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
    final doc = await FirebaseFirestore.instance
        .collection(_docPath)
        .doc(_docId)
        .get();
    if (!doc.exists || doc.data() == null) return List.from(_varsayilanlar);
    final liste = (doc.data()!['liste'] as List?)
        ?.map((e) => e.toString())
        .toList();
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

// ─── Projeksiyon Widget ───────────────────────────────────────────────────────

class _ProjeksiyonWidget extends StatefulWidget {
  const _ProjeksiyonWidget({super.key});
  @override
  State<_ProjeksiyonWidget> createState() => _ProjeksiyonWidgetState();
}

class _ProjeksiyonWidgetState extends State<_ProjeksiyonWidget>
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
      final liste = (doc.data()?['liste'] as List?)
          ?.map((e) => e.toString())
          .toList();
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
      final aktifSubeler = subelerSnap.docs
          .where((d) => subeAdlari.containsKey(d.id))
          .toList();

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
          gerceklesenHarcama += (d['toplamAnaKasaHarcama'] as num? ?? 0)
              .toDouble();
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
        final personelBasi = (ayar['personelBasiMaliyet'] as num? ?? 0)
            .toDouble();
        final personelEkstra = (ayar['personelEkstraMaliyet'] as num? ?? 0)
            .toDouble();
        final sabitGiderler =
            (ayar['sabitGiderler'] as List?)?.cast<Map>() ?? [];
        double sabitToplami = 0;
        for (final g in sabitGiderler) {
          sabitToplami += (g['tutar'] as num? ?? 0).toDouble();
        }
        final personelMaliyet = (personelSayi * personelBasi) + personelEkstra;

        List<Map<String, dynamic>> ciroBazliGiderler;
        if (ayar.containsKey('ciroBazliGiderler')) {
          ciroBazliGiderler = (ayar['ciroBazliGiderler'] as List)
              .cast<Map<String, dynamic>>();
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
            final enSonGun = parcalar.length == 3
                ? int.tryParse(parcalar[2]) ?? 0
                : 0;
            // Kalan = ayın son günü - en son kapatılmış gün
            kalanGun = (secilenAyBitis.day - enSonGun).clamp(0, 31);
          } else {
            // Hiç kapatılmış kayıt yoksa tüm ay kalan
            kalanGun = secilenAyBitis.day;
          }
        }
        // ─────────────────────────────────────────────────────────────────────

        final otomatikTahmin = kayitSayisi > 0
            ? gerceklesenCiro / kayitSayisi
            : 0.0;
        // Controller yoksa: kaydedilmiş manuel tahmin varsa onu kullan,
        // yoksa otomatik ortalamayı kullan. Varsa dokunma.
        if (!_tahminCtrl.containsKey(subeId)) {
          final kayitliTahmin = (ayar['tahminliGunlukCiro'] as num?)
              ?.toDouble();
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
      builder: (_) => _GiderDuzenleSheet(
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
            v['personelMaliyet'] =
                (sonuc['personelSayisi'] as int) *
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
      final toplamGiderSube =
          ciroBazliToplam +
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
    final toplamGider =
        ciroBazliToplam +
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
                        child: _detayBlok('Personel', [
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
                        ], Colors.blue[700]!),
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
                        child: _detayBlok('Diğer', [
                          _detayKalemData('Gerçekleşen Harc.', gercekHarcama),
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
                        ], Colors.red[700]!),
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
                          final temiz = val
                              .replaceAll('.', '')
                              .replaceAll(',', '.');
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
      Text(etiket, style: const TextStyle(fontSize: 10, color: Colors.white54)),
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
  }) => {'ad': ad, 'tutar': tutar, 'renk': renk};
}

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
            sonKapali = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
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
    final enSonKey = (!yonetici && aktifReferans != null)
        ? _tarihKey(aktifReferans)
        : null;

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
                              _seciliAy == simdi.month)
                            return;
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
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
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
              final anaKasaKalani = ((data['anaKasaKalani'] as num?) ?? 0)
                  .toDouble();
              final gunlukSatis = ((data['gunlukSatisToplami'] as num?) ?? 0)
                  .toDouble();
              final bankayaYatirilan = ((data['bankayaYatirilan'] as num?) ?? 0)
                  .toDouble();
              final anaKasaHarcama =
                  ((data['toplamAnaKasaHarcama'] as num?) ?? 0).toDouble();
              final nakitCikis = ((data['toplamNakitCikis'] as num?) ?? 0)
                  .toDouble();
              // Nakit döviz çıkışı özeti
              final nakitDovizRaw =
                  (data['nakitDovizler'] as List?)?.cast<Map>() ?? [];
              // Nakit döviz çıkışı — cins bazlı renkli liste
              final List<Map<String, dynamic>> nakitDovizListesiGecmis = [];
              for (final nd in nakitDovizRaw) {
                final miktar = (nd['miktar'] as num? ?? 0).toDouble();
                final cins = nd['cins'] as String? ?? '';
                if (miktar > 0 && cins.isNotEmpty)
                  nakitDovizListesiGecmis.add({'cins': cins, 'miktar': miktar});
              }
              final gunlukKasaKalani = ((data['gunlukKasaKalani'] as num?) ?? 0)
                  .toDouble();
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
              final akDovizMap = (data['dovizAnaKasaKalanlari'] as Map?) ?? {};
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
              final ayKey = parts3.length == 3
                  ? '${parts3[0]}-${parts3[1]}'
                  : '';

              // Descending listede bir önceki elemanın ayı farklıysa
              // veya bu ilk eleman ise → bu ayın en son günü → aylık göster
              final oncekiAyKey = index > 0
                  ? (() {
                      final oncekiTarih =
                          (docs[index - 1].data()
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
              final aylikToplam = buAyinSonGunu
                  ? (_aylikToplam[ayKey] ?? 0)
                  : 0.0;

              // Tarih format: 2026-03-22 → 22.03.2026
              String tarihGoster = tarih;
              if (tarih.length == 10) {
                final p = tarih.split('-');
                if (p.length == 3) tarihGoster = '${p[2]}.${p[1]}.${p[0]}';
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
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                                          children: dovizKasaOzet.map((d) {
                                            final c = d['cins'] as String;
                                            final sem = c == 'USD' ? r'$' : c == 'EUR' ? '€' : c == 'GBP' ? '£' : c;
                                            final m = d['miktar'] as double;
                                            return Text(
                                              '$sem${_binAyracSade(m)}',
                                              style: TextStyle(fontSize: 10, color: dovizRenk(c), fontWeight: FontWeight.w600),
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                                      final sem = c == 'USD' ? r'$' : c == 'EUR' ? '€' : c == 'GBP' ? '£' : c;
                                      final m = d['miktar'] as double;
                                      return Text(
                                        '$sem${_binAyracSade(m)}',
                                        style: TextStyle(fontSize: 11, color: dovizRenk(c), fontWeight: FontWeight.w600),
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                                            children: nakitDovizListesiGecmis.map((d) {
                                              final c = d['cins'] as String;
                                              final sem = c == 'USD' ? r'$' : c == 'EUR' ? '€' : c == 'GBP' ? '£' : c;
                                              final m = d['miktar'] as double;
                                              return Text(
                                                '$sem${_binAyracSade(m)}',
                                                style: TextStyle(fontSize: 10, color: dovizRenk(c), fontWeight: FontWeight.w600),
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
                          if (anaKasaHarcama > 0)
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                                            final sem = c == 'USD' ? r'$' : c == 'EUR' ? '€' : c == 'GBP' ? '£' : c;
                                            final m = d['miktar'] as double;
                                            return Text(
                                              '$sem${_binAyracSade(m)}',
                                              style: TextStyle(fontSize: 10, color: dovizRenk(c), fontWeight: FontWeight.w600),
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
                      final fark = referansTarih.difference(tarihDt).inDays;
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
                        builder: (_) => OzetEkrani(
                          subeKodu: _aktifSubeKodu,
                          baslangicTarihi: tarihDt,
                          subeler: widget.subeler,
                          gecmisGunHakki: widget.gecmisGunHakki,
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
              colors: [Color(0xFF01579B), Color(0xFF0288D1), Color(0xFF29B6F6)],
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
            _RaporlarWidget(subeler: subeler),
            _SubeOzetTablosu(subeler: subeler),
          ],
        ),
      ),
    );
  }
}

class _RaporlarWidget extends StatefulWidget {
  final List<String> subeler;
  final bool merkziGiderGor;
  const _RaporlarWidget({this.subeler = const [], this.merkziGiderGor = true});

  @override
  State<_RaporlarWidget> createState() => _RaporlarWidgetState();
}

class _RaporlarWidgetState extends State<_RaporlarWidget>
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
  int _karsilastirmaAy = DateTime.now().month == 1
      ? 12
      : DateTime.now().month - 1;
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
    final snapshot = await FirebaseFirestore.instance
        .collection('subeler')
        .get();
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
      final hedefSubeler = _secilenSube != null
          ? [_secilenSube!]
          : _aktifSubeler;
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
    double harcama =
        _topla(kayitlar, 'toplamHarcama') +
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
  ) => Padding(
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
          .map((d) => '${sembol(d['cins'] as String)}${_fmtSade(d['miktar'] as double)}')
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
                                  ...(s['bankaDoviz'] as List<Map<String, dynamic>>).map((d) {
                                    final cn = d['cins'] as String;
                                    final sem = cn == 'USD' ? r'$' : cn == 'EUR' ? '€' : '£';
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
                              items:
                                  List.generate(
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
        final turEslesi =
            _aramaGiderTuru == null ||
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
          final turEslesi =
              _aramaGiderTuru == null ||
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

class OzetEkrani extends StatefulWidget {
  final String subeKodu;
  final DateTime baslangicTarihi;
  final List<String> subeler;
  final int gecmisGunHakki;

  const OzetEkrani({
    super.key,
    required this.subeKodu,
    required this.baslangicTarihi,
    this.subeler = const [],
    this.gecmisGunHakki = 0,
  });

  @override
  State<OzetEkrani> createState() => _OzetEkraniState();
}

class _OzetEkraniState extends State<OzetEkrani> {
  late DateTime _secilenTarih;
  late String _secilenSube;
  Map<String, dynamic>? _kayit;
  bool _yukleniyor = true;
  Map<String, String> _subeAdlari = {};
  List<Map<String, dynamic>> _tutarsizTransferler = [];

  @override
  void initState() {
    super.initState();
    _secilenTarih = widget.baslangicTarihi;
    _secilenSube = widget.subeKodu;
    _subeAdlariniYukle();
    _kayitYukle();
  }

  Future<void> _subeAdlariniYukle() async {
    if (widget.subeler.isEmpty) return;
    try {
      final Map<String, String> adlar = {};
      for (var id in widget.subeler) {
        final doc = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(id)
            .get();
        adlar[id] = doc.data()?['ad'] as String? ?? id;
      }
      if (mounted) setState(() => _subeAdlari = adlar);
    } catch (_) {}
  }

  String _tarihKey(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  String _tarihGoster(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';

  Future<void> _excelAralikSec() async {
    DateTime baslangic = DateTime.now().subtract(const Duration(days: 30));
    DateTime bitis = DateTime.now();

    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Excel için Tarih Aralığı'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.calendar_today),
                title: const Text('Başlangıç'),
                subtitle: Text(_tarihGoster(baslangic)),
                onTap: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: baslangic,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setS(() => baslangic = d);
                },
              ),
              ListTile(
                leading: const Icon(Icons.calendar_today),
                title: const Text('Bitiş'),
                subtitle: Text(_tarihGoster(bitis)),
                onTap: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: bitis,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setS(() => bitis = d);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('İptal'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _excelOlustur(baslangic, bitis);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green[700],
                foregroundColor: Colors.white,
              ),
              child: const Text('Excel Oluştur'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _excelOlustur(DateTime baslangic, DateTime bitis) async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Excel hazırlanıyor...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      final kayitlar = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(_secilenSube)
          .collection('gunluk')
          .orderBy('tarih')
          .get();

      final bas = _tarihKey(baslangic);
      final bit = _tarihKey(bitis);
      final filtreliKayitlar = kayitlar.docs
          .where((d) => d.id.compareTo(bas) >= 0 && d.id.compareTo(bit) <= 0)
          .toList();

      if (filtreliKayitlar.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Seçili tarih aralığında kayıt bulunamadı'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final excel = xl.Excel.createExcel();
      // Varsayılan Sheet1i sil, yenisini ekle
      excel.rename('Sheet1', 'Kasa Takip');
      final sheet = excel['Kasa Takip'];

      // ── Kolon grupları ve renkleri ──────────────────────────────────────
      // Her grup için başlık + renk tanımı
      // [kolon adı, grup rengi hex]
      final List<Map<String, String>> kolonlar = [
        {'ad': 'Tarih', 'renk': '#0288D1'},
        {'ad': 'Devreden Flot', 'renk': '#2E7D32'},
        {'ad': 'Ekranda Görünen Nakit', 'renk': '#F57F17'},
        {'ad': 'Toplam POS', 'renk': '#0288D1'},
        {'ad': 'Günlük Satış Toplamı', 'renk': '#C62828'},
        {'ad': 'Toplam Harcama', 'renk': '#C62828'},
        {'ad': 'Günlük Flot', 'renk': '#2E7D32'},
        {'ad': 'Kasa Farkı', 'renk': '#6A1B9A'},
        // Ana Kasa Kalanı grubu
        {'ad': 'Ana Kasa Kalanı (TL)', 'renk': '#1565C0'},
        {'ad': 'Ana Kasa Kalanı (USD)', 'renk': '#E65100'},
        {'ad': 'Ana Kasa Kalanı (EUR)', 'renk': '#6A1B9A'},
        {'ad': 'Ana Kasa Kalanı (GBP)', 'renk': '#00695C'},
        // Ana Kasa Harcama
        {'ad': 'Ana Kasa Harcama', 'renk': '#BF360C'},
        // Nakit Çıkış
        {'ad': 'Nakit Çıkış', 'renk': '#7B1FA2'},
        // Bankaya Yatan grubu
        {'ad': 'Bankaya Yatan (TL)', 'renk': '#1565C0'},
        {'ad': 'Bankaya Yatan (USD)', 'renk': '#E65100'},
        {'ad': 'Bankaya Yatan (EUR)', 'renk': '#6A1B9A'},
        {'ad': 'Bankaya Yatan (GBP)', 'renk': '#00695C'},
        // Transferler & Diğer
        {'ad': 'Transferler Toplam', 'renk': '#37474F'},
        {'ad': 'Diğer Alımlar Toplam', 'renk': '#37474F'},
      ];

      // Başlık satırı
      for (int i = 0; i < kolonlar.length; i++) {
        final cell = sheet.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
        );
        cell.value = xl.TextCellValue(kolonlar[i]['ad']!);
        cell.cellStyle = xl.CellStyle(
          bold: true,
          backgroundColorHex: xl.ExcelColor.fromHexString(kolonlar[i]['renk']!),
          fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
        );
      }

      // Veri satırları
      for (int r = 0; r < filtreliKayitlar.length; r++) {
        final d = filtreliKayitlar[r].data();

        // Döviz Ana Kasa kalanları
        final dovizKalanlar = d['dovizAnaKasaKalanlari'] as Map? ?? {};

        // Bankaya yatan döviz
        final bankaDovizler = (d['bankaDovizler'] as List?)?.cast<Map>() ?? [];
        double bankaUSD = 0, bankaEUR = 0, bankaGBP = 0;
        for (var bd in bankaDovizler) {
          final cins = bd['cins'] as String? ?? '';
          final miktar = (bd['miktar'] as num? ?? 0).toDouble();
          if (cins == 'USD') bankaUSD += miktar;
          if (cins == 'EUR') bankaEUR += miktar;
          if (cins == 'GBP') bankaGBP += miktar;
        }

        // Transferler net toplam (GİDEN - GELEN)
        final transferler = (d['transferler'] as List?)?.cast<Map>() ?? [];
        double transferGiden = 0, transferGelen = 0;
        for (var t in transferler) {
          final kat = t['kategori'] as String? ?? '';
          final tutar = (t['tutar'] as num? ?? 0).toDouble();
          if (kat == 'GİDEN') transferGiden += tutar;
          if (kat == 'GELEN') transferGelen += tutar;
        }
        final transferNet = transferGelen - transferGiden;

        // Diğer alımlar toplam
        final digerAlimlar = (d['digerAlimlar'] as List?)?.cast<Map>() ?? [];
        final digerToplam = digerAlimlar.fold(
          0.0,
          (s, t) => s + (t['tutar'] as num? ?? 0).toDouble(),
        );

        // tarih alanından güvenilir format (2026-03-22 → 22.03.2026)
        final tarihRaw = d['tarih'] as String? ?? '';
        String tarihFormatli = d['tarihGoster'] ?? tarihRaw;
        if (tarihRaw.length == 10) {
          final tp = tarihRaw.split('-');
          if (tp.length == 3) tarihFormatli = '${tp[2]}.${tp[1]}.${tp[0]}';
        }

        final List<dynamic> satirVeriler = [
          tarihFormatli, // Tarih
          _toDouble(d['devredenFlot']), // Devreden Flot
          _toDouble(d['ekrandaGorunenNakit']), // Ekranda Görünen Nakit
          _toDouble(d['toplamPos']), // Toplam POS
          _toDouble(d['gunlukSatisToplami']), // Günlük Satış Toplamı
          _toDouble(d['toplamHarcama']), // Toplam Harcama
          _toDouble(d['gunlukFlot']), // Günlük Flot
          _toDouble(d['kasaFarki']), // Kasa Farkı
          _toDouble(d['anaKasaKalani']), // Ana Kasa Kalanı TL
          _toDouble(dovizKalanlar['USD']), // Ana Kasa Kalanı USD
          _toDouble(dovizKalanlar['EUR']), // Ana Kasa Kalanı EUR
          _toDouble(dovizKalanlar['GBP']), // Ana Kasa Kalanı GBP
          _toDouble(d['toplamAnaKasaHarcama']), // Ana Kasa Harcama
          _toDouble(d['toplamNakitCikis']), // Nakit Çıkış
          _toDouble(d['bankayaYatirilan']), // Bankaya Yatan TL
          bankaUSD, // Bankaya Yatan USD
          bankaEUR, // Bankaya Yatan EUR
          bankaGBP, // Bankaya Yatan GBP
          transferNet, // Transferler Net
          digerToplam, // Diğer Alımlar
        ];

        for (int c = 0; c < satirVeriler.length; c++) {
          final cell = sheet.cell(
            xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1),
          );
          final val = satirVeriler[c];
          if (val is String) {
            cell.value = xl.TextCellValue(val);
          } else {
            final dVal = (val as double);
            // Sıfır değerleri boş bırak (daha temiz görünüm)
            if (dVal != 0) cell.value = xl.DoubleCellValue(dVal);
          }
        }
      }

      // Sütun genişlikleri
      for (int i = 0; i < kolonlar.length; i++) {
        sheet.setColumnWidth(i, i == 0 ? 14 : 20);
      }

      final bytes = excel.encode();
      if (bytes == null) return;

      final subeAd = _subeAdlari[_secilenSube] ?? _secilenSube;
      final dosyaAdi =
          'Kasa_Takip_${subeAd}_${_tarihGoster(baslangic)}-${_tarihGoster(bitis)}.xlsx'
              .replaceAll('/', '-');

      // Platform farkını excel_download.dart halleder (web/android/ios)
      await excelKaydet(bytes, dosyaAdi);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              kIsWeb
                  ? 'Excel indiriliyor: $dosyaAdi'
                  : 'Excel kaydedildi: $dosyaAdi',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _pdfOlustur(
    Map<String, dynamic> d, {
    double? aylikSatisToplami,
    List<Map<String, dynamic>> tutarsizTransferler = const [],
  }) async {
    final pdf = pw.Document();
    final subeAd = _subeAdlari[_secilenSube] ?? _secilenSube;

    // Türkçe karakter destekli font yükle
    final font = await PdfGoogleFonts.notoSansRegular();
    final fontBold = await PdfGoogleFonts.notoSansBold();

    String fmt(dynamic val) {
      if (val == null) return '0,00';
      final double v = (val as num).toDouble();
      final parts = v.toStringAsFixed(2).split('.');
      final intPart = parts[0];
      final decPart = parts[1];
      final buffer = StringBuffer();
      for (int i = 0; i < intPart.length; i++) {
        if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write('.');
        buffer.write(intPart[i]);
      }
      return '${buffer.toString()},$decPart';
    }

    final harcamalar = (d['harcamalar'] as List?)?.cast<Map>() ?? [];
    final anaHarcamalar = (d['anaKasaHarcamalari'] as List?)?.cast<Map>() ?? [];
    final posListesi = (d['posListesi'] as List?)?.cast<Map>() ?? [];
    final transferListesi =
        (d['transferler'] as List?)
            ?.cast<Map>()
            .where(
              (t) => (t['kategori'] == 'GİDEN' || t['kategori'] == 'GELEN'),
            )
            .toList() ??
        [];
    final digerAlimlarListesi =
        ((d['digerAlimlar'] as List?)?.cast<Map>() ?? []).where((da) {
          final aciklama = (da['aciklama'] ?? '').toString().trim();
          final tutar = (da['tutar'] as num? ?? 0).toDouble();
          return aciklama.isNotEmpty || tutar > 0;
        }).toList();

    // Döviz verileri
    const dovizTurleri = ['USD', 'EUR', 'GBP'];
    const dovizSembolleri = {'USD': '\$', 'EUR': '€', 'GBP': '£'};
    final dovizler = (d['dovizler'] as List?)?.cast<Map>() ?? [];
    final dovizKalanlar = d['dovizAnaKasaKalanlari'] as Map?;
    final oncekiDovizKalanlar = d['oncekiDovizAnaKasaKalanlari'] as Map?;
    final bankaDovizListesi = (d['bankaDovizler'] as List?)?.cast<Map>() ?? [];
    final nakitDovizListesi = (d['nakitDovizler'] as List?)?.cast<Map>() ?? [];
    final toplamNakitCikis = _toDouble(d['toplamNakitCikis']);

    // Döviz miktarları ve TL karşılıkları
    final Map<String, double> dovizMiktarlari = {};
    final Map<String, double> dovizKurlar = {};
    for (var t in dovizTurleri) {
      double topMiktar = 0, topTL = 0;
      for (var dv in dovizler.where((dv) => dv['cins'] == t)) {
        topMiktar += (dv['miktar'] as num? ?? 0).toDouble();
        topTL += (dv['tlKarsiligi'] as num? ?? 0).toDouble();
      }
      dovizMiktarlari[t] = topMiktar;
      dovizKurlar[t] = topMiktar > 0 ? topTL / topMiktar : 0;
    }
    final dovizliTurler = dovizTurleri
        .where((t) => (dovizMiktarlari[t] ?? 0) > 0)
        .toList();

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
    final kirmizi = pw.TextStyle(
      font: fontBold,
      fontFallback: [font],
      color: PdfColors.red700,
      fontSize: 10,
    );
    final mavi = pw.TextStyle(
      font: fontBold,
      fontFallback: [font],
      color: PdfColors.blue900,
      fontSize: 10,
    );
    final yesil = pw.TextStyle(
      font: fontBold,
      fontFallback: [font],
      color: PdfColors.green700,
      fontSize: 10,
    );

    pw.Widget bolumBaslik(String baslikText, PdfColor renk, {String? toplam}) {
      return pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        color: renk,
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              baslikText,
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
    }

    pw.Widget satir(String label, String deger, {pw.TextStyle? style}) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label, style: normal),
            pw.Text(deger, style: style ?? koyu),
          ],
        ),
      );
    }

    // ── Tüm içeriği tek bir widget listesi olarak oluştur ──────────────────
    final icerik = <pw.Widget>[
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
      // Günlük Satış Toplamı — belirgin kırmızı şerit
      if ((d['gunlukSatisToplami'] as num? ?? 0) > 0)
        pw.Container(
          width: double.infinity,
          color: PdfColors.red700,
          child: pw.Column(
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
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
                      fmt(d['gunlukSatisToplami']),
                      style: pw.TextStyle(
                        font: fontBold,
                        color: PdfColors.white,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if ((aylikSatisToplami ?? 0) > 0)
                pw.Container(
                  width: double.infinity,
                  color: PdfColors.red900,
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'AYLIK TOPLAM (1-${_secilenTarih.day})',
                        style: pw.TextStyle(
                          font: font,
                          color: PdfColor.fromHex('#FFCDD2'),
                          fontSize: 10,
                        ),
                      ),
                      pw.Text(
                        fmt(aylikSatisToplami!),
                        style: pw.TextStyle(
                          font: fontBold,
                          color: PdfColor.fromHex('#FFCDD2'),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      pw.SizedBox(height: 8),
      bolumBaslik(
        'POS TOPLAMI',
        PdfColors.blueGrey700,
        toplam: fmt(d['toplamPos']),
      ),
      pw.SizedBox(height: 6),
      bolumBaslik(
        'HARCAMALAR',
        PdfColors.red700,
        toplam: fmt(d['toplamHarcama']),
      ),
      pw.Container(
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300),
        ),
        child: pw.Column(
          children: [
            ...harcamalar
                .where((h) => (h['tutar'] ?? 0) != 0)
                .map((h) => satir(h['aciklama'] ?? 'Harcama', fmt(h['tutar']))),
          ],
        ),
      ),
      pw.SizedBox(height: 6),
      bolumBaslik('KASA DURUMU', PdfColors.green700),
      pw.Container(
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            // Ekranda Görünen Nakit — kalın, koyu mavi
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 2),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Ekranda Görünen Nakit',
                    style: pw.TextStyle(
                      font: fontBold,
                      fontSize: 10,
                      color: PdfColors.blue900,
                    ),
                  ),
                  pw.Text(
                    fmt(d['ekrandaGorunenNakit']),
                    style: pw.TextStyle(
                      font: fontBold,
                      fontSize: 10,
                      color: PdfColors.blue900,
                    ),
                  ),
                ],
              ),
            ),
            satir('Devreden Flot', fmt(d['devredenFlot'])),
            satir('Günün Flotu', fmt(d['gunlukFlot'])),
            satir(
              'Kasa Farkı',
              fmt(d['kasaFarki']),
              style: ((d['kasaFarki'] ?? 0) as num) >= 0 ? yesil : kirmizi,
            ),
            pw.Divider(),
            // Günlük Kasa Kalanı — belirgin, kırmızı
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 2),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Günlük Kasa Kalanı',
                    style: pw.TextStyle(font: fontBold, fontSize: 11),
                  ),
                  pw.Text(
                    fmt(d['gunlukKasaKalani']),
                    style: pw.TextStyle(
                      font: fontBold,
                      fontSize: 11,
                      color: (_toDouble(d['gunlukKasaKalani']) >= 0)
                          ? PdfColors.green700
                          : PdfColors.red700,
                    ),
                  ),
                ],
              ),
            ),
            if (dovizliTurler.isNotEmpty) ...[
              // TL satırı — büyük ve kalın
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 2),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'TL',
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 11,
                        color: PdfColors.green800,
                      ),
                    ),
                    pw.Text(
                      fmt(d['gunlukKasaKalaniTL']),
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 11,
                        color: PdfColors.green800,
                      ),
                    ),
                  ],
                ),
              ),
              // Döviz satırları — her biri farklı renk
              ...dovizliTurler.map((t) {
                // USD turuncu, EUR mor, GBP koyu yeşil
                final renk = t == 'USD'
                    ? PdfColor.fromHex('#E65100')
                    : t == 'EUR'
                    ? PdfColor.fromHex('#6A1B9A')
                    : PdfColor.fromHex('#1B5E20');
                final sembol = dovizSembolleri[t] ?? t;
                final miktar = dovizMiktarlari[t] ?? 0;
                final tlK = miktar * (dovizKurlar[t] ?? 0);
                return pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        t,
                        style: pw.TextStyle(
                          font: fontBold,
                          fontSize: 10,
                          color: renk,
                        ),
                      ),
                      pw.Text(
                        '$sembol ${miktar.toStringAsFixed(2)} (${fmt(tlK)})',
                        style: pw.TextStyle(
                          font: fontBold,
                          fontSize: 10,
                          color: renk,
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
      pw.SizedBox(height: 6),
      // Nakit Çıkış kartı
      if ((d['toplamNakitCikis'] as num? ?? 0) > 0 ||
          ((d['nakitDovizler'] as List?)?.cast<Map>() ?? []).any(
            (nd) => (nd['miktar'] as num? ?? 0) > 0,
          )) ...[
        pw.SizedBox(height: 6),
        bolumBaslik(
          'NAKİT ÇIKIŞ',
          PdfColor.fromHex('#7B1FA2'),
          toplam: (d['toplamNakitCikis'] as num? ?? 0) > 0
              ? fmt(d['toplamNakitCikis'])
              : null,
        ),
        ...((d['nakitCikislar'] as List?)?.cast<Map>() ?? [])
            .where((h) => (h['tutar'] as num? ?? 0) > 0)
            .map(
              (h) => satir(
                h['aciklama']?.toString().isNotEmpty == true
                    ? h['aciklama'].toString()
                    : 'Nakit Çıkış',
                fmt(h['tutar']),
              ),
            ),
        // Döviz nakit çıkışları PDF'te ilgili döviz kartında gösterilir
      ],

      if (anaHarcamalar.isNotEmpty &&
          (d['toplamAnaKasaHarcama'] ?? 0) != 0) ...[
        bolumBaslik(
          'ANA KASA HARCAMALAR',
          PdfColors.orange700,
          toplam: fmt(d['toplamAnaKasaHarcama']),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300),
          ),
          child: pw.Column(
            children: [
              ...anaHarcamalar
                  .where((h) => (h['tutar'] ?? 0) != 0)
                  .map(
                    (h) => satir(h['aciklama'] ?? 'Harcama', fmt(h['tutar'])),
                  ),
            ],
          ),
        ),
        pw.SizedBox(height: 6),
      ],
      bolumBaslik(
        'ANA KASA',
        PdfColors.blue900,
        toplam: fmt(d['anaKasaKalani']),
      ),
      pw.Container(
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300),
        ),
        child: pw.Column(
          children: [
            // TL kutusu
            pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 4),
              padding: const pw.EdgeInsets.all(6),
              decoration: pw.BoxDecoration(
                color: PdfColors.blue50,
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
                  pw.SizedBox(height: 2),
                  satir('Devreden Ana Kasa', fmt(d['oncekiAnaKasaKalani'])),
                  satir(
                    'Günlük Kasa Kalanı (TL)',
                    fmt(d['gunlukKasaKalaniTL']),
                  ),
                  if ((d['toplamAnaKasaHarcama'] ?? 0) != 0)
                    satir('Ana Kasa Harcama', fmt(d['toplamAnaKasaHarcama'])),
                  satir('Bankaya Yatırılan', fmt(d['bankayaYatirilan'])),
                  if ((d['toplamNakitCikis'] ?? 0) != 0)
                    satir('Nakit Çıkış (TL)', fmt(d['toplamNakitCikis'])),
                  ...((d['nakitDovizler'] as List?)?.cast<Map>() ?? [])
                      .where((nd) => (nd['miktar'] as num? ?? 0) > 0)
                      .map((nd) {
                        final cins = nd['cins'] as String? ?? '';
                        final sembol = cins == 'USD'
                            ? r'$'
                            : cins == 'EUR'
                            ? '€'
                            : cins == 'GBP'
                            ? '£'
                            : cins;
                        final miktar = (nd['miktar'] as num).toDouble();
                        return satir(
                          'Nakit Çıkış ($cins)',
                          '$sembol ${miktar.toStringAsFixed(2)}',
                        );
                      }),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(vertical: 2),
                    child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(
                          'Ana Kasa Kalanı',
                          style: pw.TextStyle(font: fontBold, fontSize: 10),
                        ),
                        pw.Text(
                          fmt(d['anaKasaKalani']),
                          style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: ((d['anaKasaKalani'] ?? 0) as num) >= 0
                                ? PdfColors.green700
                                : PdfColors.red700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Döviz kutuları
            ...dovizTurleri
                .where((t) {
                  final kalan = (dovizKalanlar?[t] as num?)?.toDouble() ?? 0;
                  final devreden =
                      (oncekiDovizKalanlar?[t] as num?)?.toDouble() ?? 0;
                  return kalan != 0 ||
                      devreden != 0 ||
                      (dovizMiktarlari[t] ?? 0) > 0;
                })
                .toList()
                .asMap()
                .entries
                .map((entry) {
                  final t = entry.value;
                  final idx = entry.key;
                  // Her döviz farklı renk paleti
                  const bgRenkler = [
                    PdfColors.orange50,
                    PdfColors.purple50,
                    PdfColors.teal50,
                  ];
                  const yaziRenkler = [
                    PdfColors.orange800,
                    PdfColors.purple800,
                    PdfColors.teal800,
                  ];
                  const kalanRenkler = [
                    PdfColors.deepOrange700,
                    PdfColors.purple700,
                    PdfColors.teal700,
                  ];
                  final bgRenk = bgRenkler[idx % bgRenkler.length];
                  final yaziRenk = yaziRenkler[idx % yaziRenkler.length];
                  final kalanRenk = kalanRenkler[idx % kalanRenkler.length];

                  final sembol = dovizSembolleri[t] ?? t;
                  final kalan = (dovizKalanlar?[t] as num?)?.toDouble() ?? 0;
                  final devreden =
                      (oncekiDovizKalanlar?[t] as num?)?.toDouble() ?? 0;
                  double bankaYatan = 0;
                  for (var bd in bankaDovizListesi) {
                    if (bd['cins'] == t)
                      bankaYatan += (bd['miktar'] as num? ?? 0).toDouble();
                  }
                  return pw.Container(
                    margin: const pw.EdgeInsets.only(bottom: 4),
                    padding: const pw.EdgeInsets.all(6),
                    decoration: pw.BoxDecoration(
                      color: bgRenk,
                      borderRadius: const pw.BorderRadius.all(
                        pw.Radius.circular(6),
                      ),
                    ),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          '$sembol $t',
                          style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: yaziRenk,
                          ),
                        ),
                        pw.SizedBox(height: 2),
                        satir(
                          'Devreden Ana Kasa',
                          '$sembol ${devreden.toStringAsFixed(2)}',
                        ),
                        satir(
                          'Günlük Kasa Kalanı',
                          '$sembol ${(dovizMiktarlari[t] ?? 0).toStringAsFixed(2)}',
                        ),
                        if (bankaYatan > 0)
                          satir(
                            'Bankaya Yatırılan',
                            '$sembol ${bankaYatan.toStringAsFixed(2)}',
                          ),
                        ...((d['nakitDovizler'] as List?)?.cast<Map>() ?? [])
                            .where(
                              (nd) =>
                                  nd['cins'] == t &&
                                  (nd['miktar'] as num? ?? 0) > 0,
                            )
                            .map(
                              (nd) => satir(
                                nd['aciklama']?.toString().isNotEmpty == true
                                    ? nd['aciklama'].toString()
                                    : 'Nakit Çıkış',
                                '$sembol ${(nd['miktar'] as num).toStringAsFixed(2)}',
                              ),
                            ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(vertical: 2),
                          child: pw.Row(
                            mainAxisAlignment:
                                pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text(
                                'Ana Kasa Kalanı',
                                style: pw.TextStyle(
                                  font: fontBold,
                                  fontSize: 10,
                                  color: yaziRenk,
                                ),
                              ),
                              pw.Text(
                                '$sembol ${kalan.toStringAsFixed(2)}',
                                style: pw.TextStyle(
                                  font: fontBold,
                                  fontSize: 10,
                                  color: kalan >= 0
                                      ? kalanRenk
                                      : PdfColors.red700,
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
      if (transferListesi.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        () {
          double netT = 0;
          for (final t in transferListesi) {
            final kat = t['kategori'] as String? ?? '';
            final tutar = ((t['tutar'] ?? 0) as num).toDouble();
            if (kat == 'GELEN') netT += tutar;
            if (kat == 'GİDEN') netT -= tutar;
          }
          final netPrefix = netT >= 0 ? '+' : '-';
          return bolumBaslik(
            'TRANSFERLER',
            PdfColors.blueGrey600,
            toplam: '$netPrefix ${fmt(netT.abs())}',
          );
        }(),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300),
          ),
          child: pw.Column(
            children: [
              ...transferListesi.map((t) {
                final kat = t['kategori'] as String? ?? '';
                final isGiden = kat == 'GİDEN';
                final renk = isGiden ? PdfColors.red700 : PdfColors.blue900;
                final prefix = isGiden ? '- ' : '+ ';
                final aciklama = (t['aciklama'] as String?)?.isNotEmpty == true
                    ? t['aciklama'] as String
                    : '';
                final hedefSube =
                    (t['hedefSube'] as String?)?.isNotEmpty == true
                    ? t['hedefSube'] as String
                    : '';
                final hedefSubeAd =
                    (t['hedefSubeAd'] as String?)?.isNotEmpty == true
                    ? t['hedefSubeAd'] as String
                    : hedefSube;
                final kaynakSube =
                    (t['kaynakSube'] as String?)?.isNotEmpty == true
                    ? t['kaynakSube'] as String
                    : '';
                final kaynakSubeAd =
                    (t['kaynakSubeAd'] as String?)?.isNotEmpty == true
                    ? t['kaynakSubeAd'] as String
                    : (kaynakSube.isNotEmpty ? kaynakSube : '');
                final subeLabel = isGiden ? hedefSubeAd : kaynakSubeAd;
                final aciklamaTemiz =
                    aciklama == subeLabel ||
                        aciklama == (isGiden ? hedefSube : kaynakSube)
                    ? ''
                    : aciklama;
                final labelText = [
                  kat,
                  if (subeLabel.isNotEmpty) subeLabel,
                  if (aciklamaTemiz.isNotEmpty) aciklamaTemiz,
                ].join(' - ');
                return pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.RichText(
                        text: pw.TextSpan(
                          children: [
                            pw.TextSpan(
                              text: labelText,
                              style: pw.TextStyle(
                                font: fontBold,
                                fontSize: 10,
                                color: renk,
                              ),
                            ),
                          ],
                        ),
                      ),
                      pw.Text(
                        '$prefix${fmt(t['tutar'])}',
                        style: pw.TextStyle(
                          font: fontBold,
                          fontSize: 10,
                          color: renk,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ],
      if (digerAlimlarListesi.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        () {
          double toplamDiger = digerAlimlarListesi.fold(
            0.0,
            (s, t) => s + ((t['tutar'] as num? ?? 0).toDouble()),
          );
          return bolumBaslik(
            'DİĞER ALIMLAR',
            PdfColors.grey,
            toplam: fmt(toplamDiger),
          );
        }(),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300),
          ),
          child: pw.Column(
            children: [
              ...digerAlimlarListesi
                  .where((t) => (t['tutar'] ?? 0) != 0)
                  .map((t) => satir(t['aciklama'] ?? '', fmt(t['tutar']))),
            ],
          ),
        ),
      ],
      if (tutarsizTransferler.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        bolumBaslik('⚠ TUTARSIZ TRANSFER', PdfColors.red700),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.red300),
            color: PdfColors.red50,
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              ...tutarsizTransferler.map((t) {
                final gonderesSube =
                    t['gonderenSubeAd'] as String? ??
                    t['gonderesSube'] as String? ??
                    '?';
                final alanSube =
                    t['alanSubeAd'] as String? ??
                    t['alanSube'] as String? ??
                    '?';
                final aciklama = t['aciklama'] as String? ?? '';
                final gonderilenTutar =
                    (t['gonderilenTutar'] as num? ?? t['tutar'] as num? ?? 0)
                        .toDouble();
                final onaylananTutar =
                    (t['onaylananTutar'] as num? ?? t['tutar'] as num? ?? 0)
                        .toDouble();
                final nedenMetin =
                    'Gönderilen: ${fmt(gonderilenTutar)} / Onaylanan: ${fmt(onaylananTutar)}';
                return pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 3),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text(
                            '$gonderesSube → $alanSube',
                            style: pw.TextStyle(
                              font: fontBold,
                              fontSize: 10,
                              color: PdfColors.red700,
                            ),
                          ),
                          pw.Text(
                            fmt(gonderilenTutar),
                            style: pw.TextStyle(
                              font: fontBold,
                              fontSize: 10,
                              color: PdfColors.red700,
                            ),
                          ),
                        ],
                      ),
                      if (aciklama.isNotEmpty)
                        pw.Text(
                          '  Açıklama: $aciklama',
                          style: pw.TextStyle(
                            font: font,
                            fontSize: 9,
                            color: PdfColors.grey700,
                          ),
                        ),
                      pw.Text(
                        '  $nedenMetin',
                        style: pw.TextStyle(
                          font: font,
                          fontSize: 9,
                          color: PdfColors.orange700,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    ];

    // ── Tek sayfa: tüm içeriği FittedBox ile ölçeklendir, sayfada ortala ──
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(16),
        build: (context) {
          final pageW = PdfPageFormat.a4.availableWidth - 32;
          final pageH = PdfPageFormat.a4.availableHeight - 32;
          // İçeriği sabit genişlikte oluştur, yüksekliği serbest bırak
          // Sonra FittedBox ile sayfaya sığdır
          return pw.FittedBox(
            fit: pw.BoxFit.contain,
            alignment: pw.Alignment.topCenter,
            child: pw.SizedBox(
              width: pageW,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                mainAxisSize: pw.MainAxisSize.min,
                children: icerik,
              ),
            ),
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (_) => pdf.save());
  }

  double _aylikSatisToplami = 0;

  Future<void> _kayitYukle() async {
    setState(() => _yukleniyor = true);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(_secilenSube)
          .collection('gunluk')
          .doc(_tarihKey(_secilenTarih))
          .get();

      // Aylık toplam satış: ayın 1inden seçilen güne kadar
      double aylikToplam = 0;
      try {
        final ayBas =
            '${_secilenTarih.year}-${_secilenTarih.month.toString().padLeft(2, '0')}-01';
        final gun = _tarihKey(_secilenTarih);
        final ayKayitlar = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(_secilenSube)
            .collection('gunluk')
            .where('tarih', isGreaterThanOrEqualTo: ayBas)
            .where('tarih', isLessThanOrEqualTo: gun)
            .get();
        for (var k in ayKayitlar.docs) {
          aylikToplam += ((k.data()['gunlukSatisToplami'] as num?) ?? 0)
              .toDouble();
        }
      } catch (_) {}

      setState(() {
        _kayit = doc.exists ? doc.data() : null;
        _aylikSatisToplami = aylikToplam;
        _yukleniyor = false;
      });

      // Tutarsız transfer sorgusu
      try {
        final tarihKey = _tarihKey(_secilenTarih);
        final snap1 = await FirebaseFirestore.instance
            .collection('onaylananTransferler')
            .where('tarih', isEqualTo: tarihKey)
            .where('alanSube', isEqualTo: _secilenSube)
            .where('tutarsiz', isEqualTo: true)
            .get();
        final snap2 = await FirebaseFirestore.instance
            .collection('onaylananTransferler')
            .where('tarih', isEqualTo: tarihKey)
            .where('gonderesSube', isEqualTo: _secilenSube)
            .where('tutarsiz', isEqualTo: true)
            .get();
        final liste = [
          ...snap1.docs.map((d) => {...d.data(), 'docId': d.id}),
          ...snap2.docs.map((d) => {...d.data(), 'docId': d.id}),
        ];
        if (mounted) setState(() => _tutarsizTransferler = liste);
      } catch (_) {}
    } catch (_) {
      setState(() {
        _kayit = null;
        _aylikSatisToplami = 0;
        _yukleniyor = false;
      });
    }
  }

  Widget _ozetTarihNavBar() {
    final yonetici = widget.gecmisGunHakki == -1;
    final bugun = DateTime.now();
    final enEskiTarih = yonetici
        ? DateTime(2020)
        : bugun.subtract(Duration(days: widget.gecmisGunHakki));
    final geriAktif =
        widget.gecmisGunHakki != 0 && _secilenTarih.isAfter(enEskiTarih);
    final ileriAktif = _secilenTarih.isBefore(
      DateTime(bugun.year, bugun.month, bugun.day),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 20),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          constraints: const BoxConstraints(minWidth: 28),
          onPressed: geriAktif
              ? () {
                  setState(
                    () => _secilenTarih = _secilenTarih.subtract(
                      const Duration(days: 1),
                    ),
                  );
                  _kayitYukle();
                }
              : null,
          disabledColor: Colors.white30,
        ),
        GestureDetector(
          onTap: _tarihSec,
          child: Text(
            _tarihGoster(_secilenTarih),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right, color: Colors.white, size: 20),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          constraints: const BoxConstraints(minWidth: 28),
          onPressed: ileriAktif
              ? () {
                  setState(
                    () => _secilenTarih = _secilenTarih.add(
                      const Duration(days: 1),
                    ),
                  );
                  _kayitYukle();
                }
              : null,
          disabledColor: Colors.white30,
        ),
      ],
    );
  }

  Future<void> _tarihSec() async {
    final yonetici = widget.gecmisGunHakki == -1;
    if (widget.gecmisGunHakki == 0 && !yonetici) return; // Yetki yok
    final bugun = DateTime.now();
    final firstDate = yonetici
        ? DateTime(2020)
        : bugun.subtract(Duration(days: widget.gecmisGunHakki));
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _secilenTarih,
      firstDate: firstDate,
      lastDate: bugun,
      helpText: 'Tarih Seçin',
      cancelText: 'İptal',
      confirmText: 'Seç',
    );
    if (picked != null && picked != _secilenTarih) {
      setState(() => _secilenTarih = picked);
      _kayitYukle();
    }
  }

  String _fmt(double val) {
    final parts = val.toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final decPart = parts[1];
    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write('.');
      buffer.write(intPart[i]);
    }
    return '${buffer.toString()},$decPart';
  }

  String _sembol(String t) => t == 'USD'
      ? '\$'
      : t == 'EUR'
      ? '€'
      : '£';

  double _toDouble(dynamic val) => val == null ? 0 : (val as num).toDouble();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
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
            ? DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _secilenSube,
                  dropdownColor: const Color(0xFF7B1F2E),
                  icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                  isDense: true,
                  isExpanded: true,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  selectedItemBuilder: (context) => widget.subeler
                      .map(
                        (s) => Text(
                          '${_subeAdlari[s] ?? s} Günlük Özet',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      )
                      .toList(),
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
                  onChanged: (yeniSube) {
                    if (yeniSube != null && yeniSube != _secilenSube) {
                      setState(() => _secilenSube = yeniSube);
                      _kayitYukle();
                    }
                  },
                ),
              )
            : Text('${_subeAdlari[_secilenSube] ?? _secilenSube} Günlük Özet'),
        centerTitle: false,
        backgroundColor: const Color(0xFF7B1F2E),
        foregroundColor: Colors.white,
        actions: [
          if (_kayit != null) ...[
            IconButton(
              icon: const Icon(Icons.edit, size: 18),
              tooltip: 'Düzenle',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => OnHazirlikEkrani(
                    subeKodu: _secilenSube,
                    subeler: widget.subeler,
                    baslangicTarihi: _secilenTarih,
                    gecmisGunHakki: widget.gecmisGunHakki,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.picture_as_pdf, size: 18),
              tooltip: 'PDF',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => _pdfOlustur(
                _kayit!,
                aylikSatisToplami: _aylikSatisToplami,
                tutarsizTransferler: _tutarsizTransferler,
              ),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.table_chart, size: 18),
            tooltip: 'Excel',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => _excelAralikSec(),
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: Container(
            color: const Color(0xFF6B1828),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _ozetTarihNavBar(),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Yükleme sırasında ince progress bar — içerik kaybolmaz (göz kırpma yok)
            if (_yukleniyor)
              const LinearProgressIndicator(
                minHeight: 3,
                backgroundColor: Colors.transparent,
                color: Color(0xFF7B1F2E),
              ),
            if (!_yukleniyor && _kayit == null)
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
                    const SizedBox(height: 12),
                    Text(
                      '${_tarihGoster(_secilenTarih)} tarihinde kayıt bulunamadı.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600], fontSize: 15),
                    ),
                  ],
                ),
              )
            else if (_kayit != null)
              _ozetIcerik(_kayit!),
          ],
        ),
      ),
    );
  }

  Widget _ozetIcerik(Map<String, dynamic> d) {
    final posListesi = (d['posListesi'] as List?)?.cast<Map>() ?? [];
    final harcamalar = (d['harcamalar'] as List?)?.cast<Map>() ?? [];
    final anaHarcamalar = (d['anaKasaHarcamalari'] as List?)?.cast<Map>() ?? [];
    final dovizler = (d['dovizler'] as List?)?.cast<Map>() ?? [];
    final dovizKalanlar = d['dovizAnaKasaKalanlari'] as Map?;
    final oncekiDovizKalanlar = d['oncekiDovizAnaKasaKalanlari'] as Map?;
    final bankaDovizListesi = (d['bankaDovizler'] as List?)?.cast<Map>() ?? [];
    final nakitDovizListesi = (d['nakitDovizler'] as List?)?.cast<Map>() ?? [];
    final toplamNakitCikis = _toDouble(d['toplamNakitCikis']);

    final toplamPos = _toDouble(d['toplamPos']);
    final toplamHarcama = _toDouble(d['toplamHarcama']);
    final gunlukSatisToplami = _toDouble(d['gunlukSatisToplami']);
    final devredenFlot = _toDouble(d['devredenFlot']);
    final flotTutari = _toDouble(d['gunlukFlot']);
    final kasaFarki = _toDouble(d['kasaFarki']);
    final gunlukKasaKalani = _toDouble(d['gunlukKasaKalani']);
    final gunlukKasaKalaniTL = _toDouble(d['gunlukKasaKalaniTL']);
    final toplamAnaKasaHarcama = _toDouble(d['toplamAnaKasaHarcama']);
    final bankayaYatirilan = _toDouble(d['bankayaYatirilan']);
    final anaKasaKalani = _toDouble(d['anaKasaKalani']);
    final oncekiAnaKasaKalani = _toDouble(d['oncekiAnaKasaKalani']);

    final List<String> dovizTurleri = ['USD', 'EUR', 'GBP'];
    final dovizliTurler = dovizTurleri.where((t) {
      return dovizler.any((dv) => dv['cins'] == t && (dv['miktar'] ?? 0) != 0);
    }).toList();

    Map<String, double> dovizMiktarlari = {};
    Map<String, double> dovizKurlar = {};
    for (var t in dovizTurleri) {
      double topMiktar = 0, topTL = 0;
      for (var dv in dovizler.where((dv) => dv['cins'] == t)) {
        topMiktar += _toDouble(dv['miktar']);
        topTL += _toDouble(dv['tlKarsiligi']);
      }
      dovizMiktarlari[t] = topMiktar;
      dovizKurlar[t] = topMiktar > 0 ? topTL / topMiktar : 0;
    }

    return Column(
      children: [
        // Günlük Satış Toplamı — en üstte belirgin şerit
        if (gunlukSatisToplami > 0)
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
            child: Column(
              children: [
                // Günlük satış
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.trending_up,
                            color: Colors.white,
                            size: 20,
                          ),
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
                        _fmt(gunlukSatisToplami),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ),
                // Aylık toplam satış
                if (_aylikSatisToplami > 0)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red[900],
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(14),
                        bottomRight: Radius.circular(14),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'AYLIK TOPLAM (1-${_secilenTarih.day})',
                          style: TextStyle(
                            color: Colors.red[200],
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            letterSpacing: 0.5,
                          ),
                        ),
                        Text(
                          _fmt(_aylikSatisToplami),
                          style: TextStyle(
                            color: Colors.red[100],
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
        // POS Toplamı - sadece toplam
        _bolum(
          renk: const Color(0xFF0288D1),
          ikon: Icons.credit_card,
          baslik: 'POS TOPLAMI',
          toplam: _fmt(toplamPos),
          child: const SizedBox.shrink(),
        ),
        const SizedBox(height: 12),

        // Harcamalar
        _bolum(
          renk: const Color(0xFFE53935),
          ikon: Icons.receipt_long,
          baslik: 'HARCAMALAR',
          toplam: _fmt(toplamHarcama),
          child: Column(
            children: harcamalar
                .where((h) => (h['tutar'] ?? 0) != 0)
                .map(
                  (h) => _kalemSatiri(
                    h['aciklama']?.isEmpty ?? true ? 'Harcama' : h['aciklama'],
                    _fmt(_toDouble(h['tutar'])),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 12),

        // Kasa Durumu
        _bolum(
          renk: const Color(0xFF2E7D32),
          ikon: Icons.account_balance_wallet,
          baslik: 'KASA DURUMU',
          child: Column(
            children: [
              _kalemSatiriBold(
                'Ekranda Görünen Nakit',
                _fmt(_toDouble(d['ekrandaGorunenNakit'])),
                renk: const Color(0xFF0288D1),
              ),
              _kalemSatiri('Devreden Flot', _fmt(devredenFlot)),
              _kalemSatiri('Günün Flotu', _fmt(flotTutari)),
              _kalemSatiriFark('Kasa Farkı', kasaFarki),
              const Divider(height: 16),
              _kalemSatiriBold(
                'Günlük Kasa Kalanı',
                _fmt(gunlukKasaKalani),
                renk: gunlukKasaKalani >= 0 ? Colors.green[700]! : Colors.red[700]!,
              ),
              if (dovizliTurler.isNotEmpty) ...[
                const SizedBox(height: 4),
                _kalemSatiriAlt(
                  '  ↳ TL',
                  _fmt(gunlukKasaKalaniTL),
                  Colors.green[700]!,
                ),
                ...dovizliTurler.map((t) {
                  final sembol = _sembol(t);
                  final miktar = dovizMiktarlari[t] ?? 0;
                  final tlK = miktar * (dovizKurlar[t] ?? 0);
                  return _kalemSatiriAlt(
                    '  ↳ $t',
                    '$sembol ${miktar.toStringAsFixed(2)} (${_fmt(tlK)})',
                    dovizRenk(t),
                  );
                }),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Nakit Çıkış kartı
        if (toplamNakitCikis > 0 ||
            nakitDovizListesi.any((nd) => (nd['miktar'] as num? ?? 0) > 0)) ...[
          _bolum(
            renk: const Color(0xFF7B1FA2),
            ikon: Icons.payments_outlined,
            baslik: 'NAKİT ÇIKIŞ',
            toplam: toplamNakitCikis > 0 ? _fmt(toplamNakitCikis) : null,
            child: Column(
              children: [
                if (toplamNakitCikis > 0)
                  ...((d['nakitCikislar'] as List?)?.cast<Map>() ?? [])
                      .where((h) => (h['tutar'] as num? ?? 0) > 0)
                      .map(
                        (h) => _kalemSatiri(
                          h['aciklama']?.toString().isNotEmpty == true
                              ? h['aciklama'].toString()
                              : 'Nakit Çıkış',
                          _fmt((h['tutar'] as num).toDouble()),
                        ),
                      ),
                ...nakitDovizListesi
                    .where((nd) => (nd['miktar'] as num? ?? 0) > 0)
                    .map((nd) {
                      final cins = nd['cins'] as String? ?? '';
                      final sembol = cins == 'USD'
                          ? r'$'
                          : cins == 'EUR'
                          ? '€'
                          : cins == 'GBP'
                          ? '£'
                          : cins;
                      final miktar = (nd['miktar'] as num).toDouble();
                      return _kalemSatiri(
                        nd['aciklama']?.toString().isNotEmpty == true
                            ? nd['aciklama'].toString()
                            : 'Nakit $cins Çıkış',
                        '$sembol ${miktar.toStringAsFixed(2)}',
                      );
                    }),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Ana Kasa Harcamalar
        if (toplamAnaKasaHarcama > 0) ...[
          _bolum(
            renk: const Color(0xFFE65100),
            ikon: Icons.money_off,
            baslik: 'ANA KASA HARCAMALAR',
            toplam: _fmt(toplamAnaKasaHarcama),
            child: Column(
              children: anaHarcamalar
                  .where((h) => (h['tutar'] ?? 0) != 0)
                  .map(
                    (h) => _kalemSatiri(
                      h['aciklama']?.isEmpty ?? true
                          ? 'Harcama'
                          : h['aciklama'],
                      _fmt(_toDouble(h['tutar'])),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Ana Kasa
        _bolum(
          renk: const Color(0xFF1565C0),
          ikon: Icons.account_balance,
          baslik: 'ANA KASA',
          child: Column(
            children: [
              // TL
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'TL',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1565C0),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _kalemSatiri(
                      'Devreden Ana Kasa',
                      _fmt(oncekiAnaKasaKalani),
                    ),
                    _kalemSatiri(
                      'Günlük Kasa Kalanı (TL)',
                      _fmt(gunlukKasaKalaniTL),
                    ),
                    if (toplamAnaKasaHarcama > 0)
                      _kalemSatiri(
                        'Ana Kasa Harcama',
                        _fmt(toplamAnaKasaHarcama),
                      ),
                    _kalemSatiri('Bankaya Yatırılan', _fmt(bankayaYatirilan)),
                    _kalemSatiriBold(
                      'Ana Kasa Kalanı',
                      _fmt(anaKasaKalani),
                      renk: anaKasaKalani >= 0
                          ? Colors.green[700]!
                          : Colors.red[700]!,
                    ),
                  ],
                ),
              ),
              // Dövizler — PDF ile aynı renk paleti
              ...dovizTurleri
                  .asMap()
                  .entries
                  .where((entry) {
                    final t = entry.value;
                    final kalan = _toDouble(dovizKalanlar?[t]);
                    final devreden = _toDouble(oncekiDovizKalanlar?[t]);
                    final miktar = dovizMiktarlari[t] ?? 0;
                    return kalan != 0 || devreden != 0 || miktar > 0;
                  })
                  .map((entry) {
                    final idx = entry.key;
                    final t = entry.value;
                    final sembol = _sembol(t);
                    final kalan = _toDouble(dovizKalanlar?[t]);
                    final devreden = _toDouble(oncekiDovizKalanlar?[t]);
                    double bankaYatan = 0;
                    for (var bd in bankaDovizListesi) {
                      if (bd['cins'] == t)
                        bankaYatan += _toDouble(bd['miktar']);
                    }

                    // PDF ile aynı renk paleti
                    final bgRenkler = [
                      Colors.orange[50]!,
                      Colors.purple[50]!,
                      Colors.teal[50]!,
                    ];
                    final yaziRenkler = [
                      Colors.orange[800]!,
                      Colors.purple[800]!,
                      Colors.teal[800]!,
                    ];
                    final kalanRenkler = [
                      Colors.deepOrange[700]!,
                      Colors.purple[700]!,
                      Colors.teal[700]!,
                    ];
                    final bgRenk = bgRenkler[idx % bgRenkler.length];
                    final yaziRenk = yaziRenkler[idx % yaziRenkler.length];
                    final kalanRenk = kalanRenkler[idx % kalanRenkler.length];

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: bgRenk,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$sembol $t',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: yaziRenk,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _kalemSatiri(
                            'Devreden Ana Kasa',
                            '$sembol ${devreden.toStringAsFixed(2)}',
                          ),
                          _kalemSatiri(
                            'Günlük Kasa Kalanı',
                            '$sembol ${(dovizMiktarlari[t] ?? 0).toStringAsFixed(2)}',
                          ),
                          if (bankaYatan > 0)
                            _kalemSatiri(
                              'Bankaya Yatırılan',
                              '$sembol ${bankaYatan.toStringAsFixed(2)}',
                            ),
                          ...nakitDovizListesi
                              .where(
                                (nd) =>
                                    nd['cins'] == t &&
                                    (nd['miktar'] as num? ?? 0) > 0,
                              )
                              .map(
                                (nd) => _kalemSatiri(
                                  nd['aciklama']?.toString().isNotEmpty == true
                                      ? nd['aciklama'].toString()
                                      : 'Nakit Çıkış',
                                  '$sembol ${(nd['miktar'] as num).toStringAsFixed(2)}',
                                ),
                              ),
                          _kalemSatiriBold(
                            'Ana Kasa Kalanı',
                            '$sembol ${kalan.toStringAsFixed(2)}',
                            renk: kalanRenk,
                          ),
                        ],
                      ),
                    );
                  }),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Transferler (varsa)
        Builder(
          builder: (context) {
            final transferListesi =
                (d['transferler'] as List?)?.cast<Map>() ?? [];
            final sadeceTrf = transferListesi
                .where(
                  (t) => t['kategori'] == 'GİDEN' || t['kategori'] == 'GELEN',
                )
                .toList();
            if (sadeceTrf.isEmpty) return const SizedBox.shrink();

            final gidenler = sadeceTrf
                .where((t) => t['kategori'] == 'GİDEN')
                .toList();
            final gelenler = sadeceTrf
                .where((t) => t['kategori'] == 'GELEN')
                .toList();
            double toplamGiden = gidenler.fold(
              0.0,
              (s, t) => s + _toDouble(t['tutar']),
            );
            double toplamGelen = gelenler.fold(
              0.0,
              (s, t) => s + _toDouble(t['tutar']),
            );
            double netTransfer = toplamGelen - toplamGiden;

            return _bolum(
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
                      final hedef =
                          (t['hedefSube'] as String?)?.isNotEmpty == true
                          ? t['hedefSube'] as String
                          : '';
                      final hedefAd =
                          (t['hedefSubeAd'] as String?)?.isNotEmpty == true
                          ? t['hedefSubeAd'] as String
                          : hedef;
                      final aciklama = t['aciklama'] as String? ?? '';
                      // Açıklama şube adını içeriyorsa tekrar yazma
                      final aciklamaTemiz =
                          aciklama == hedefAd || aciklama == hedef
                          ? ''
                          : aciklama;
                      final label = [
                        if (hedefAd.isNotEmpty) hedefAd,
                        if (aciklamaTemiz.isNotEmpty) aciklamaTemiz,
                      ].join(' - ');
                      return _kalemSatiriRenk(
                        label.isEmpty ? 'Transfer' : label,
                        '- ${_fmt(_toDouble(t['tutar']))}',
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
                      final kaynak =
                          (t['kaynakSube'] as String?)?.isNotEmpty == true
                          ? t['kaynakSube'] as String
                          : '';
                      // kaynakSubeAd yoksa _subeAdlarindan bak
                      final kaynakAd =
                          (t['kaynakSubeAd'] as String?)?.isNotEmpty == true
                          ? t['kaynakSubeAd'] as String
                          : (_subeAdlari[kaynak]?.isNotEmpty == true
                                ? _subeAdlari[kaynak]!
                                : kaynak);
                      final aciklama = t['aciklama'] as String? ?? '';
                      final aciklamaTemiz =
                          aciklama == kaynakAd || aciklama == kaynak
                          ? ''
                          : aciklama;
                      final label = [
                        if (kaynakAd.isNotEmpty) kaynakAd,
                        if (aciklamaTemiz.isNotEmpty) aciklamaTemiz,
                      ].join(' - ');
                      return _kalemSatiriRenk(
                        label.isEmpty ? 'Transfer' : label,
                        '+ ${_fmt(_toDouble(t['tutar']))}',
                        const Color(0xFF0288D1),
                      );
                    }),
                    const SizedBox(height: 4),
                  ],
                  if (toplamGiden > 0 || toplamGelen > 0) ...[
                    const Divider(),
                    if (toplamGiden > 0)
                      _kalemSatiriRenk(
                        'Toplam Giden',
                        '- ${_fmt(toplamGiden)}',
                        Colors.red[700]!,
                      ),
                    if (toplamGelen > 0)
                      _kalemSatiriRenk(
                        'Toplam Gelen',
                        '+ ${_fmt(toplamGelen)}',
                        const Color(0xFF0288D1),
                      ),
                    if (toplamGiden > 0 && toplamGelen > 0)
                      _kalemSatiriBold(
                        'Net Transfer',
                        '${netTransfer >= 0 ? '+' : '-'} ${_fmt(netTransfer.abs())}',
                        renk: netTransfer >= 0
                            ? const Color(0xFF0288D1)
                            : Colors.red[700]!,
                      ),
                  ],
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 12),

        // ── Tutarsız Transfer Uyarısı ───────────────────────────────────────
        if (_tutarsizTransferler.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.red[50],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red[300]!),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red[700],
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      topRight: Radius.circular(12),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'TUTARSIZ TRANSFER (${_tutarsizTransferler.length})',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                ..._tutarsizTransferler.map((t) {
                  final gonderesSube =
                      t['gonderenSubeAd'] as String? ??
                      t['gonderesSube'] as String? ??
                      '?';
                  final alanSube =
                      t['alanSubeAd'] as String? ??
                      t['alanSube'] as String? ??
                      '?';
                  final aciklama = t['aciklama'] as String? ?? '';
                  final gonderilenTutar =
                      (t['gonderilenTutar'] as num? ?? t['tutar'] as num? ?? 0)
                          .toDouble();
                  final onaylananTutar =
                      (t['onaylananTutar'] as num? ?? t['tutar'] as num? ?? 0)
                          .toDouble();
                  final tutarsiz =
                      (gonderilenTutar - onaylananTutar).abs() > 0.01;
                  final nedenMetin = tutarsiz
                      ? 'Gönderilen: ${_fmt(gonderilenTutar)} / Onaylanan: ${_fmt(onaylananTutar)}'
                      : 'Kayıt uyumsuz';
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: Colors.red[200]!),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.swap_horiz,
                              size: 14,
                              color: Colors.red[700],
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '$gonderesSube → $alanSube',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.red[800],
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Text(
                              _fmt(gonderilenTutar),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.red[700],
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        if (aciklama.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2, left: 20),
                            child: Text(
                              aciklama,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[700],
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2, left: 20),
                          child: Text(
                            nedenMetin,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.orange[800],
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),

        // Diğer Alımlar (varsa)
        Builder(
          builder: (context) {
            final digerListesiRaw =
                (d['digerAlimlar'] as List?)?.cast<Map>() ?? [];
            // Boş kayıtları filtrele (aciklama yok ve tutar 0)
            final digerListesi = digerListesiRaw.where((da) {
              final aciklama = (da['aciklama'] ?? '').toString().trim();
              final tutar = _toDouble(da['tutar']);
              return aciklama.isNotEmpty || tutar > 0;
            }).toList();
            if (digerListesi.isEmpty) return const SizedBox.shrink();
            final toplam = digerListesi.fold(
              0.0,
              (s, t) => s + _toDouble(t['tutar']),
            );
            return _bolum(
              renk: Colors.grey[700]!,
              ikon: Icons.shopping_bag_outlined,
              baslik: 'DİĞER ALIMLAR',
              toplam: _fmt(toplam),
              child: Column(
                children: digerListesi
                    .where((t) => (t['tutar'] ?? 0) != 0)
                    .map(
                      (t) => _kalemSatiri(
                        t['aciklama'] ?? '',
                        _fmt(_toDouble(t['tutar'])),
                      ),
                    )
                    .toList(),
              ),
            );
          },
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _bolum({
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

  Widget _kalemSatiriRenk(String label, String deger, Color renk) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: renk, fontSize: 14)),
          Text(
            deger,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: renk,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _kalemSatiri(String label, String deger) {
    return Padding(
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
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _kalemSatiriBold(String label, String deger, {Color? renk}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          Text(
            deger,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: renk ?? Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _kalemSatiriAlt(String label, String deger, Color renk) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: renk, fontSize: 13)),
          Text(
            deger,
            style: TextStyle(
              color: renk,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _kalemSatiriFark(String label, double fark) {
    Color renk = fark >= 0 ? Colors.green[700]! : Colors.red[700]!;
    String ikon = fark >= 0 ? '▲' : '▼';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.black54, fontSize: 14),
          ),
          Text(
            '$ikon ${fark.abs().toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: renk,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Şube Özet Tablosu ────────────────────────────────────────────────────────

class _SubeOzetTablosu extends StatefulWidget {
  final List<String> subeler;
  const _SubeOzetTablosu({this.subeler = const []});

  @override
  State<_SubeOzetTablosu> createState() => _SubeOzetTablosuState();
}

class _SubeOzetTablosuState extends State<_SubeOzetTablosu>
    with AutomaticKeepAliveClientMixin {
  String _filtreModu = 'ay';
  int _secilenYil = DateTime.now().year;
  int _secilenAy = DateTime.now().month;
  DateTime _baslangic = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _bitis = DateTime.now();

  bool _karsilastirmaAcik = false;
  int _karsilastirmaYil = DateTime.now().year;
  int _karsilastirmaAy = DateTime.now().month == 1
      ? 12
      : DateTime.now().month - 1;
  DateTime _karsilastirmaBaslangic = DateTime(
    DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year,
    DateTime.now().month == 1 ? 12 : DateTime.now().month - 1,
    1,
  );
  DateTime _karsilastirmaBitis = DateTime(
    DateTime.now().year,
    DateTime.now().month == 1 ? DateTime.now().year - 1 : DateTime.now().year,
    DateTime.now().month == 1 ? 12 : DateTime.now().month - 1 + 1,
    0,
  );

  bool _yukleniyor = false;
  Map<String, String> _subeAdlari = {};
  // subeId → {ciro, anaKasaTL, anaKasaUSD, anaKasaEUR, anaKasaGBP}
  List<Map<String, dynamic>> _subeVeriler = [];
  List<Map<String, dynamic>> _karsilastirmaVeriler = [];

  double _kdvOrani = 10.0; // Firestore'dan yüklenir

  final _aylar = [
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
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _subeAdlariniYukle();
    // Sayfa açılınca mevcut ay ile otomatik yükle
    WidgetsBinding.instance.addPostFrameCallback((_) => _yukle());
  }

  Future<void> _subeAdlariniYukle() async {
    final snap = await FirebaseFirestore.instance.collection('subeler').get();
    final adlar = <String, String>{};
    for (var doc in snap.docs) {
      adlar[doc.id] = (doc.data()['ad'] as String?) ?? doc.id;
    }
    if (mounted) setState(() => _subeAdlari = adlar);
  }

  List<String> get _aktifSubeler =>
      widget.subeler.isNotEmpty ? widget.subeler : _subeAdlari.keys.toList();

  String _tarihKey(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  String _baslangicKey() {
    if (_filtreModu == 'ay') {
      return '${_secilenYil.toString().padLeft(4, '0')}-${_secilenAy.toString().padLeft(2, '0')}-01';
    }
    return _tarihKey(_baslangic);
  }

  String _bitisKey() {
    if (_filtreModu == 'ay') {
      final sonGun = DateTime(_secilenYil, _secilenAy + 1, 0).day;
      return '${_secilenYil.toString().padLeft(4, '0')}-${_secilenAy.toString().padLeft(2, '0')}-${sonGun.toString().padLeft(2, '0')}';
    }
    return _tarihKey(_bitis);
  }

  String _karsilastirmaBasKey() {
    if (_filtreModu == 'ay') {
      return '${_karsilastirmaYil.toString().padLeft(4, '0')}-${_karsilastirmaAy.toString().padLeft(2, '0')}-01';
    }
    return _tarihKey(_karsilastirmaBaslangic);
  }

  String _karsilastirmaBitKey() {
    if (_filtreModu == 'ay') {
      final sonGun = DateTime(_karsilastirmaYil, _karsilastirmaAy + 1, 0).day;
      return '${_karsilastirmaYil.toString().padLeft(4, '0')}-${_karsilastirmaAy.toString().padLeft(2, '0')}-${sonGun.toString().padLeft(2, '0')}';
    }
    return _tarihKey(_karsilastirmaBitis);
  }

  Future<List<Map<String, dynamic>>> _veriCek(String bas, String bit) async {
    // Tüm şubeler paralel — sıralı await yerine Future.wait
    final futures = _aktifSubeler.map((subeId) async {
      final snap = await FirebaseFirestore.instance
          .collection('subeler')
          .doc(subeId)
          .collection('gunluk')
          .where('tarih', isGreaterThanOrEqualTo: bas)
          .where('tarih', isLessThanOrEqualTo: bit)
          .get();

      double ciro = 0,
          anaKasaTL = 0,
          anaKasaUSD = 0,
          anaKasaEUR = 0,
          anaKasaGBP = 0;
      for (var doc in snap.docs) {
        final d = doc.data();
        ciro += ((d['gunlukSatisToplami'] as num?) ?? 0).toDouble();
      }
      // Ana Kasa: dönemin son gününün kalanı
      if (snap.docs.isNotEmpty) {
        final son = snap.docs.last.data();
        anaKasaTL = ((son['anaKasaKalani'] as num?) ?? 0).toDouble();
        final dovizKalanlar = son['dovizAnaKasaKalanlari'] as Map?;
        if (dovizKalanlar != null) {
          anaKasaUSD = ((dovizKalanlar['USD'] as num?) ?? 0).toDouble();
          anaKasaEUR = ((dovizKalanlar['EUR'] as num?) ?? 0).toDouble();
          anaKasaGBP = ((dovizKalanlar['GBP'] as num?) ?? 0).toDouble();
        }
      }
      return {
        'subeId': subeId,
        'subeAd': _subeAdlari[subeId] ?? subeId,
        'ciro': ciro,
        'anaKasaTL': anaKasaTL,
        'anaKasaUSD': anaKasaUSD,
        'anaKasaEUR': anaKasaEUR,
        'anaKasaGBP': anaKasaGBP,
      };
    });

    return List<Map<String, dynamic>>.from(await Future.wait(futures));
  }

  Future<void> _yukle() async {
    setState(() => _yukleniyor = true);
    try {
      // KDV oranını Firestore'dan yükle
      final ayarSnap = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('banknotlar')
          .get();
      final kdvOrani =
          (ayarSnap.data()?['kdvOrani'] as num?)?.toDouble() ?? 10.0;

      final veriler = await _veriCek(_baslangicKey(), _bitisKey());
      // Ciro büyükten küçüğe sırala
      veriler.sort(
        (a, b) => (b['ciro'] as double).compareTo(a['ciro'] as double),
      );
      List<Map<String, dynamic>> karsilastirma = [];
      if (_karsilastirmaAcik) {
        karsilastirma = await _veriCek(
          _karsilastirmaBasKey(),
          _karsilastirmaBitKey(),
        );
      }
      if (mounted)
        setState(() {
          _subeVeriler = veriler;
          _karsilastirmaVeriler = karsilastirma;
          _kdvOrani = kdvOrani;
          _yukleniyor = false;
        });
    } catch (e) {
      if (mounted) setState(() => _yukleniyor = false);
    }
  }

  String _fmt(double v) {
    if (v == 0) return '0,00 ₺';
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

  String _fmtDoviz(double v, String sembol) {
    if (v == 0) return '';
    final parts = v.toStringAsFixed(2).split('.');
    final buf = StringBuffer();
    for (int i = 0; i < parts[0].length; i++) {
      if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write('.');
      buf.write(parts[0][i]);
    }
    return '$sembol ${buf.toString()},${parts[1]}';
  }

  String _fmtYuzde(double yeni, double eski) {
    if (eski == 0) return '';
    final pct = ((yeni - eski) / eski * 100);
    final sign = pct >= 0 ? '▲' : '▼';
    return '$sign ${pct.abs().toStringAsFixed(1)}%';
  }

  double _karsilastirmaCiro(String subeId) {
    for (var v in _karsilastirmaVeriler) {
      if (v['subeId'] == subeId) return (v['ciro'] as double);
    }
    return 0;
  }

  Future<void> _excelIndir() async {
    if (_subeVeriler.isEmpty) return;
    try {
      final excel = xl.Excel.createExcel();
      excel.rename('Sheet1', 'Şube Özet');
      final sheet = excel['Şube Özet'];

      // Başlıklar
      final basliklar = ['Şube', 'Ciro', 'Ana Kasa (TL)', 'USD', 'EUR', 'GBP'];
      if (_karsilastirmaAcik) basliklar.addAll(['Önceki Ciro', 'Fark %']);
      for (int i = 0; i < basliklar.length; i++) {
        final cell = sheet.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
        );
        cell.value = xl.TextCellValue(basliklar[i]);
        cell.cellStyle = xl.CellStyle(
          bold: true,
          backgroundColorHex: xl.ExcelColor.fromHexString('#0288D1'),
          fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
        );
      }

      // Toplam satırı
      double toplamCiro = _subeVeriler.fold(
        0.0,
        (s, v) => s + (v['ciro'] as double),
      );
      double toplamTL = _subeVeriler.fold(
        0.0,
        (s, v) => s + (v['anaKasaTL'] as double),
      );
      double toplamUSD = _subeVeriler.fold(
        0.0,
        (s, v) => s + (v['anaKasaUSD'] as double),
      );
      double toplamEUR = _subeVeriler.fold(
        0.0,
        (s, v) => s + (v['anaKasaEUR'] as double),
      );
      double toplamGBP = _subeVeriler.fold(
        0.0,
        (s, v) => s + (v['anaKasaGBP'] as double),
      );

      final toplamRow = [
        xl.TextCellValue('GENEL TOPLAM'),
        xl.DoubleCellValue(toplamCiro),
        xl.DoubleCellValue(toplamTL),
        xl.DoubleCellValue(toplamUSD),
        xl.DoubleCellValue(toplamEUR),
        xl.DoubleCellValue(toplamGBP),
      ];
      for (int i = 0; i < toplamRow.length; i++) {
        final cell = sheet.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 1),
        );
        cell.value = toplamRow[i];
        cell.cellStyle = xl.CellStyle(
          bold: true,
          backgroundColorHex: xl.ExcelColor.fromHexString('#E3F2FD'),
        );
      }

      // Şube satırları
      for (int r = 0; r < _subeVeriler.length; r++) {
        final v = _subeVeriler[r];
        final rowData = [
          xl.TextCellValue(v['subeAd'] as String),
          xl.DoubleCellValue(v['ciro'] as double),
          xl.DoubleCellValue(v['anaKasaTL'] as double),
          xl.DoubleCellValue(v['anaKasaUSD'] as double),
          xl.DoubleCellValue(v['anaKasaEUR'] as double),
          xl.DoubleCellValue(v['anaKasaGBP'] as double),
        ];
        if (_karsilastirmaAcik) {
          final onceki = _karsilastirmaCiro(v['subeId'] as String);
          rowData.add(xl.DoubleCellValue(onceki));
          final pct = onceki > 0
              ? ((v['ciro'] as double) - onceki) / onceki * 100
              : 0.0;
          rowData.add(xl.DoubleCellValue(pct));
        }
        for (int i = 0; i < rowData.length; i++) {
          sheet
                  .cell(
                    xl.CellIndex.indexByColumnRow(
                      columnIndex: i,
                      rowIndex: r + 2,
                    ),
                  )
                  .value =
              rowData[i];
        }
      }

      final bytes = excel.save();
      if (bytes != null) {
        await excelKaydet(
          bytes,
          'sube_ozet_${_baslangicKey()}_${_bitisKey()}.xlsx',
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Excel hatası: $e'),
            backgroundColor: Colors.red,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final maxCiro = _subeVeriler.isEmpty
        ? 1.0
        : _subeVeriler
              .map((v) => v['ciro'] as double)
              .reduce((a, b) => a > b ? a : b)
              .clamp(1.0, double.infinity);

    final toplamCiro = _subeVeriler.fold(
      0.0,
      (s, v) => s + (v['ciro'] as double),
    );
    final toplamTL = _subeVeriler.fold(
      0.0,
      (s, v) => s + (v['anaKasaTL'] as double),
    );
    final toplamUSD = _subeVeriler.fold(
      0.0,
      (s, v) => s + (v['anaKasaUSD'] as double),
    );
    final toplamEUR = _subeVeriler.fold(
      0.0,
      (s, v) => s + (v['anaKasaEUR'] as double),
    );
    final toplamGBP = _subeVeriler.fold(
      0.0,
      (s, v) => s + (v['anaKasaGBP'] as double),
    );

    final oncekiToplamCiro = _karsilastirmaVeriler.fold(
      0.0,
      (s, v) => s + (v['ciro'] as double),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Filtre ───────────────────────────────────────────────────────
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
                          final oncekiAy = simdi.month == 1
                              ? 12
                              : simdi.month - 1;
                          final oncekiYil = simdi.month == 1
                              ? simdi.year - 1
                              : simdi.year;
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
                          // Karşılaştırma modunu ana filtreden bağımsız başlat
                        }
                      });
                    },
                  ),
                  if (_karsilastirmaAcik) ...[
                    const SizedBox(height: 8),
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
                              items:
                                  List.generate(
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
                  Row(
                    children: [
                      Expanded(
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
                      if (_subeVeriler.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _excelIndir,
                          icon: const Icon(Icons.table_chart, size: 18),
                          label: const Text('Excel'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.green[700],
                            side: BorderSide(color: Colors.green[700]!),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),

          if (_subeVeriler.isNotEmpty) ...[
            const SizedBox(height: 16),

            // ── CİRO BÖLÜMÜ ─────────────────────────────────────────────
            const Text(
              'Ciro Sıralaması',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.black54,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            // Ciro kartı — şube adı + bar sabit, sağa scroll ile KDVsiz görünür
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0288D1).withOpacity(0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // ── HEADER ──────────────────────────────────────────────
                    Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFF0288D1),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(14),
                          topRight: Radius.circular(14),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: Text(
                              'Genel Toplam Ciro',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 10,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_karsilastirmaAcik &&
                                        oncekiToplamCiro > 0) ...[
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            'Önceki: ${_fmt(oncekiToplamCiro)}',
                                            style: const TextStyle(
                                              color: Colors.white54,
                                              fontSize: 10,
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 1,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withOpacity(
                                                0.15,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                            child: Text(
                                              _fmtYuzde(
                                                toplamCiro,
                                                oncekiToplamCiro,
                                              ),
                                              style: TextStyle(
                                                fontSize: 10,
                                                color:
                                                    toplamCiro >=
                                                        oncekiToplamCiro
                                                    ? Colors.greenAccent
                                                    : Colors.redAccent,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(width: 10),
                                    ],
                                    Text(
                                      _fmt(toplamCiro),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (toplamCiro > 0) ...[
                                      const SizedBox(width: 10),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: Colors.white.withOpacity(
                                              0.3,
                                            ),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              'KDVsiz (%${_kdvOrani.toStringAsFixed(0)})',
                                              style: TextStyle(
                                                color: Colors.white.withOpacity(
                                                  0.7,
                                                ),
                                                fontSize: 9,
                                              ),
                                            ),
                                            Text(
                                              _fmt(
                                                toplamCiro /
                                                    (1 + _kdvOrani / 100),
                                              ),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                                fontWeight: FontWeight.bold,
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
                          ),
                        ],
                      ),
                    ),
                    // ── ŞUBE SATIRLARI ──────────────────────────────────────
                    ..._subeVeriler.asMap().entries.map((entry) {
                      final i = entry.key;
                      final v = entry.value;
                      final ciro = v['ciro'] as double;
                      final oncekiCiro = _karsilastirmaAcik
                          ? _karsilastirmaCiro(v['subeId'] as String)
                          : 0.0;
                      final barOran = maxCiro > 0 ? ciro / maxCiro : 0.0;
                      final oncekiBarOran = maxCiro > 0
                          ? oncekiCiro / maxCiro
                          : 0.0;
                      final rankColors = [
                        [const Color(0xFFFFF8E1), const Color(0xFFF57F17)],
                        [const Color(0xFFECEFF1), const Color(0xFF455A64)],
                        [const Color(0xFFFBE9E7), const Color(0xFFBF360C)],
                      ];
                      final rankColor = i < 3
                          ? rankColors[i]
                          : [Colors.grey[100]!, Colors.grey[600]!];
                      return Container(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.grey.withOpacity(0.12),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            // SABİT SOL: sıra no + şube adı + bar
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: rankColor[0],
                                        shape: BoxShape.circle,
                                      ),
                                      child: Center(
                                        child: Text(
                                          '${i + 1}',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: rankColor[1],
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            v['subeAd'] as String,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                            child: LinearProgressIndicator(
                                              value: barOran,
                                              backgroundColor: Colors.grey[100],
                                              valueColor:
                                                  const AlwaysStoppedAnimation<
                                                    Color
                                                  >(Color(0xFF0288D1)),
                                              minHeight: 5,
                                            ),
                                          ),
                                          if (_karsilastirmaAcik &&
                                              oncekiCiro > 0) ...[
                                            const SizedBox(height: 2),
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                              child: LinearProgressIndicator(
                                                value: oncekiBarOran,
                                                backgroundColor:
                                                    Colors.grey[100],
                                                valueColor:
                                                    const AlwaysStoppedAnimation<
                                                      Color
                                                    >(Color(0xFF90A4AE)),
                                                minHeight: 3,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // SCROLL SAĞ: ciro + KDVsiz
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          _fmt(ciro),
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (_karsilastirmaAcik &&
                                            oncekiCiro > 0) ...[
                                          const SizedBox(height: 2),
                                          Builder(
                                            builder: (_) {
                                              final yuzde = _fmtYuzde(
                                                ciro,
                                                oncekiCiro,
                                              );
                                              final artis = ciro >= oncekiCiro;
                                              return Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 4,
                                                          vertical: 1,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: artis
                                                          ? Colors.green[50]
                                                          : Colors.red[50],
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            3,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      yuzde,
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        color: artis
                                                            ? Colors.green[700]
                                                            : Colors.red[700],
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    _fmt(oncekiCiro),
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color:
                                                          Colors.blueGrey[600],
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (ciro > 0) ...[
                                      const SizedBox(width: 10),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFF0288D1,
                                          ).withOpacity(0.07),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: const Color(
                                              0xFF0288D1,
                                            ).withOpacity(0.18),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              'KDVsiz',
                                              style: TextStyle(
                                                color: Colors.grey[600],
                                                fontSize: 9,
                                              ),
                                            ),
                                            Text(
                                              _fmt(
                                                ciro / (1 + _kdvOrani / 100),
                                              ),
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF0288D1),
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
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── ANA KASA BÖLÜMÜ ──────────────────────────────────────────
            const Text(
              'Ana Kasa Kalanları',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.black54,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1565C0).withOpacity(0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Toplam şerit
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1565C0),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(14),
                        topRight: Radius.circular(14),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Flexible(
                          child: Text(
                            'Genel Toplam Ana Kasa',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              if (toplamUSD != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF8E1),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    '\$ ${toplamUSD.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                      color: Color(0xFFE65100),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (toplamEUR != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3E5F5),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    '€ ${toplamEUR.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                      color: Color(0xFF6A1B9A),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (toplamGBP != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE8F5E9),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    '£ ${toplamGBP.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                      color: Color(0xFF1B5E20),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              Text(
                                _fmt(toplamTL),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Şube satırları
                  ..._subeVeriler.map((v) {
                    final tl = v['anaKasaTL'] as double;
                    final usd = v['anaKasaUSD'] as double;
                    final eur = v['anaKasaEUR'] as double;
                    final gbp = v['anaKasaGBP'] as double;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: Colors.grey.withOpacity(0.12),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              v['subeAd'] as String,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Wrap(
                            spacing: 6,
                            alignment: WrapAlignment.end,
                            children: [
                              if (usd != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF8E1),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    _fmtDoviz(usd, '\$'),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFFE65100),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (eur != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3E5F5),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    _fmtDoviz(eur, '€'),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF6A1B9A),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (gbp != 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE8F5E9),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    _fmtDoviz(gbp, '£'),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF1B5E20),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              Text(
                                _fmt(tl),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: tl >= 0
                                      ? const Color(0xFF0C447C)
                                      : Colors.red[700]!,
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
            const SizedBox(height: 32),
          ],
        ],
      ),
    );
  }
}
