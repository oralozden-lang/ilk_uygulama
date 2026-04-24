import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'giris_ekrani.dart';
import 'on_hazirlik_ekrani.dart';

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
