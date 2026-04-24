import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class KullanicilarTab extends StatefulWidget {
  const KullanicilarTab({super.key});
  @override
  State<KullanicilarTab> createState() => _KullanicilarTabState();
}

class _KullanicilarTabState extends State<KullanicilarTab> {
  final TextEditingController _kullaniciAramaCtrl = TextEditingController();
  String _kullaniciArama = '';
  String? _filtreSube;
  String _filtreAktif = 'tumu';

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('kullanicilar').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final tumKullanicilar = snapshot.data!.docs;

        final kullanicilar = tumKullanicilar.where((k) {
          final data = k.data() as Map<String, dynamic>;
          final aktif = data['aktif'] != false;
          final subeler = List<String>.from(data['subeler'] ?? []);
          final yonetici = data['yonetici'] == true;

          if (_kullaniciArama.isNotEmpty &&
              !k.id.toLowerCase().contains(_kullaniciArama.toLowerCase()))
            return false;
          if (_filtreSube != null &&
              !yonetici &&
              !subeler.contains(_filtreSube)) return false;
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
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                                value: 'tumu', child: Text('Tümü')),
                            DropdownMenuItem(
                                value: 'aktif', child: Text('Aktif')),
                            DropdownMenuItem(
                                value: 'pasif', child: Text('Pasif')),
                          ],
                          onChanged: (v) => setState(() => _filtreAktif = v!),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${kullanicilar.length} kullanıcı'
                          '${kullanicilar.length != tumKullanicilar.length ? ' (toplam ${tumKullanicilar.length})' : ''}',
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
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
                        backgroundColor:
                            aktif ? const Color(0xFF0288D1) : Colors.grey,
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
                          Text(k.id,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          if (yonetici) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.amber,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('YÖNETİCİ',
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                          if (!yonetici && data['rolId'] != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color:
                                    const Color(0xFF0288D1).withOpacity(0.15),
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
                                Icon(Icons.delete, color: Colors.red, size: 18),
                                SizedBox(width: 8),
                                Text('Sil',
                                    style: TextStyle(color: Colors.red)),
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
                if (!yonetici) ...[
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Şubeler:',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 4),
                  FutureBuilder<QuerySnapshot>(
                    future:
                        FirebaseFirestore.instance.collection('subeler').get(),
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
                if (!yonetici) ...[
                  const SizedBox(height: 8),
                  FutureBuilder<QuerySnapshot>(
                    future:
                        FirebaseFirestore.instance.collection('roller').get(),
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
                              value: null, child: Text('Rol Yok (standart)')),
                          ...roller.map((r) {
                            final ad = (r.data() as Map<String, dynamic>)['ad']
                                    as String? ??
                                r.id;
                            return DropdownMenuItem(
                                value: r.id, child: Text(ad));
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
                Container(
                  decoration: BoxDecoration(
                    color: Colors.orange[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange[200]!),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Geçmiş Gün Erişim Hakkı',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                          'Kullanıcı kaç gün geriye gidebilir: $gecmisGunHakki gün',
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[700])),
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
                Container(
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue[200]!),
                  ),
                  child: SwitchListTile(
                    dense: true,
                    title: const Text('Rapor Görüntüleme Yetkisi',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('Raporlar ekranına erişim'),
                    value: raporYetkisi,
                    activeColor: const Color(0xFF0288D1),
                    onChanged: (v) => setS(() => raporYetkisi = v),
                  ),
                ),
                const SizedBox(height: 12),
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
                                value: null, child: Text('Rol Yok (standart)')),
                            ...roller.map((r) {
                              final ad =
                                  (r.data() as Map<String, dynamic>)['ad']
                                          as String? ??
                                      r.id;
                              return DropdownMenuItem(
                                  value: r.id, child: Text(ad));
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
                  child: Text('Şubeler:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 4),
                FutureBuilder<QuerySnapshot>(
                  future:
                      FirebaseFirestore.instance.collection('subeler').get(),
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
