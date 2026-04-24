import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/kullanici_yetki.dart';
import '../core/utils.dart';
import '../widgets/kasa_logo.dart';
import 'sube_secim_ekrani.dart';
import 'yonetici_paneli_ekrani.dart';
import 'on_hazirlik_ekrani.dart';

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
    _gunKapanisSaatiniYukle();
  }

  Future<void> _gunKapanisSaatiniYukle() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('ayarlar')
          .doc('banknotlar')
          .get();
      final saat = (doc.data()?['gunKapanisSaati'] as num?)?.toInt();
      if (saat != null) gunKapanisSaati = saat;
    } catch (_) {}
  }

  Future<void> _versiyonKontrol() async {
    try {
      final resp = await http
          .get(Uri.parse(
            'https://raw.githubusercontent.com/oralozden-lang/ilk_uygulama/main/lib/main.dart',
          ))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final match =
            RegExp(r"appVersiyon = '(v[\d.]+)'").firstMatch(resp.body);
        if (match != null) {
          final uzak = match.group(1)!;
          if (uzak != appVersiyon && mounted) {
            final prefs = await SharedPreferences.getInstance();
            final gosterildi = prefs.getString('uyariGosterildi') ?? '';
            if (gosterildi == uzak) return;
            await prefs.setString('uyariGosterildi', uzak);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      'Güncelleme: $appVersiyon → $uzak  •  Sayfayı yenileyin.'),
                  backgroundColor: Colors.orange[700],
                  duration: const Duration(seconds: 8),
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
      }
    } catch (_) {}
  }

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

      if (data['aktif'] == false) {
        setState(() => _hata = 'Bu hesap devre dışı bırakılmıştır');
        return;
      }

      if (data['parola'] != parola.trim()) {
        setState(() => _hata = 'Hatalı parola');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('kullanici', kullanici.trim().toLowerCase());
      await prefs.setString('parola', parola.trim());

      if (!mounted) return;

      final yonetici = data['yonetici'] == true;
      final subeler = List<String>.from(data['subeler'] ?? []);
      final rolId = data['rolId'] as String?;

      KullaniciYetki yetki;
      if (yonetici) {
        yetki = KullaniciYetki.yonetici;
      } else if (rolId != null) {
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
        yetki = KullaniciYetki(
          raporGoruntuleme: data['raporGoruntuleme'] == true,
          gecmisGunHakki: (data['gecmisGunHakki'] as int?) ?? 3,
        );
      }

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
                const KasaLogo(),
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
                  appVersiyon,
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
