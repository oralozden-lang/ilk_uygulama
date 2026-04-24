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
