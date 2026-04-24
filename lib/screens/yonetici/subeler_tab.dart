import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../on_hazirlik_ekrani.dart';

class SubelerTab extends StatefulWidget {
  const SubelerTab({super.key});
  @override
  State<SubelerTab> createState() => _SubelerTabState();
}

class _SubelerTabState extends State<SubelerTab> {
  @override
  Widget build(BuildContext context) {
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
                    backgroundColor:
                        aktif ? const Color(0xFF0288D1) : Colors.grey,
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
                    final subeIdleri =
                        tumSubeler.docs.map((d) => d.id).toList();
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
                            Icon(Icons.edit,
                                color: Color(0xFF0288D1), size: 18),
                            SizedBox(width: 8),
                            Text('Düzenle'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'sil',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline,
                                color: Colors.red, size: 18),
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
    final uyeNoCtrl = TextEditingController();
    // Mevcut Üye İşyeri No'yu Firestore'dan çek
    FirebaseFirestore.instance.collection('subeler').doc(id).get().then((doc) {
      if (doc.exists) {
        uyeNoCtrl.text = (doc.data()?['uyeIsyeriNo'] as String?) ?? '';
      }
    });
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Şube Düzenle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: adCtrl,
              decoration: const InputDecoration(labelText: 'Şube Adı'),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: uyeNoCtrl,
              decoration: const InputDecoration(
                labelText: 'Üye İşyeri No',
                hintText: 'Banka POS kodu (opsiyonel)',
              ),
              keyboardType: TextInputType.number,
            ),
          ],
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
              final Map<String, dynamic> guncelleme = {'ad': yeniAd};
              final uyeNo = uyeNoCtrl.text.trim();
              if (uyeNo.isNotEmpty) guncelleme['uyeIsyeriNo'] = uyeNo;
              await FirebaseFirestore.instance
                  .collection('subeler')
                  .doc(id)
                  .update(guncelleme);
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
}
