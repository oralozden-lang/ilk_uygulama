import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AktiviteTab extends StatefulWidget {
  const AktiviteTab({super.key});
  @override
  State<AktiviteTab> createState() => _AktiviteTabState();
}

class _AktiviteTabState extends State<AktiviteTab> {
  // Future bir kez oluşturulur — rebuild'de yeniden sorgu atmaz
  late Future<List<Map<String, dynamic>>> _gelecek;

  @override
  void initState() {
    super.initState();
    _gelecek = _aktiviteYukle();
  }

  void _yenile() {
    setState(() {
      _gelecek = _aktiviteYukle();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _gelecek, // sabit referans — rebuild'de tekrar çağrılmaz
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        final kayitlar = snap.data ?? [];
        if (kayitlar.isEmpty)
          return RefreshIndicator(
            onRefresh: () async => _yenile(),
            child: ListView(
              children: const [
                Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text('Son 7 günde kayıt yok.',
                        style: TextStyle(color: Colors.grey)),
                  ),
                ),
              ],
            ),
          );
        return RefreshIndicator(
          onRefresh: () async => _yenile(),
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
              final tamamlandi =
                  d['tamamlandi'] == true || d['tamamlandi'] == 1;
              final gosterimAd = kaydeden.isNotEmpty
                  ? kaydeden
                  : kilitKullanici.isNotEmpty
                      ? kilitKullanici
                      : '—';

              Color badgeRenk;
              String badgeMetin;
              if (tamamlandi) {
                badgeRenk = Colors.green[700]!;
                badgeMetin = 'Kapatıldı';
              } else if (kaydeden.isNotEmpty) {
                badgeRenk = Colors.orange[700]!;
                badgeMetin = 'Açık Gün';
              } else {
                badgeRenk = Colors.blue[700]!;
                badgeMetin = 'Otomatik';
              }

              final log = (d['aktiviteLog'] as List?)?.cast<Map>() ?? [];

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
                          fontSize: 13),
                    ),
                  ),
                  title: Row(children: [
                    Flexible(
                      child: Text(gosterimAd,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: badgeRenk.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: badgeRenk.withOpacity(0.5)),
                      ),
                      child: Text(badgeMetin,
                          style: TextStyle(
                              fontSize: 10,
                              color: badgeRenk,
                              fontWeight: FontWeight.w600)),
                    ),
                  ]),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$subeKodu  •  $tarih',
                          style: const TextStyle(fontSize: 12)),
                      if (versiyon.isNotEmpty)
                        Text(versiyon,
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey[400])),
                      if (kilitKullanici.isNotEmpty &&
                          kilitKullanici != kaydeden)
                        Text('Kilitleyen: $kilitKullanici',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey[600])),
                      ...log.map((e) {
                        final islem = e['islem'] as String? ?? '';
                        final kul = e['kullanici'] as String? ?? '';
                        final zam = (e['zaman'] as Timestamp?)?.toDate();
                        final zamStr = zam != null
                            ? '${zam.day.toString().padLeft(2, '0')}.${zam.month.toString().padLeft(2, '0')} '
                                '${zam.hour.toString().padLeft(2, '0')}:${zam.minute.toString().padLeft(2, '0')}'
                            : '';
                        final islemRenk = islem == 'Günü Kapat'
                            ? Colors.green[700]!
                            : Colors.orange[700]!;
                        return Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Row(children: [
                            Icon(
                              islem == 'Günü Kapat'
                                  ? Icons.lock
                                  : Icons.lock_open,
                              size: 11,
                              color: islemRenk,
                            ),
                            const SizedBox(width: 4),
                            Text('$islem — $kul',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: islemRenk,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(width: 6),
                            Text(zamStr,
                                style: TextStyle(
                                    fontSize: 10, color: Colors.grey[500])),
                          ]),
                        );
                      }),
                    ],
                  ),
                  trailing: Text(zamanStr,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  isThreeLine: true,
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
      final sinir = DateTime.now().subtract(const Duration(days: 7));
      final sinirTs = Timestamp.fromDate(sinir);

      // Şubeler + tüm gunluk sorgular paralel
      final subelerSnap =
          await FirebaseFirestore.instance.collection('subeler').get();

      final futures = subelerSnap.docs.map((subeDoc) async {
        final snap = await FirebaseFirestore.instance
            .collection('subeler')
            .doc(subeDoc.id)
            .collection('gunluk')
            .where('kayitZamani', isGreaterThan: sinirTs)
            .orderBy('kayitZamani', descending: true)
            .limit(50) // şube başına max 50 kayıt — sınırsız çekmez
            .get();
        return snap.docs.map((doc) {
          final d = doc.data();
          return {
            ...d,
            '_subeId': subeDoc.id,
            '_kilitKullanici': d['kullanici'] as String? ?? '',
            '_versiyon': d['versiyon'] as String? ?? '',
          };
        }).toList();
      });

      // Hepsi paralel — şube sayısı kadar roundtrip değil, tek turda
      final results = await Future.wait(futures);
      final sonuclar = <Map<String, dynamic>>[];
      for (final liste in results) sonuclar.addAll(liste);

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
}
