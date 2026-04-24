import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class RollerTab extends StatefulWidget {
  const RollerTab({super.key});
  @override
  State<RollerTab> createState() => _RollerTabState();
}

class _RollerTabState extends State<RollerTab> {
  // ── Roller Sekmesi ────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
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
          style:
              TextStyle(fontSize: 10, color: renk, fontWeight: FontWeight.w600),
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
                ] as List<(String, String, IconData)>)
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
}
