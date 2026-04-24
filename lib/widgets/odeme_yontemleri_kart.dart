import '../core/formatters.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
// ─── Ödeme Yöntemleri Kartı ─────────────────────────────────────────────────────

class OdemeYontemleriKart extends StatefulWidget {
  const OdemeYontemleriKart();

  @override
  State<OdemeYontemleriKart> createState() => OdemeYontemleriKartState();
}

class OdemeYontemleriKartState extends State<OdemeYontemleriKart> {
  static const _koleksiyon = 'odemeyontemleri';

  List<Map<String, dynamic>> _liste = [];
  bool _yukleniyor = true;

  @override
  void initState() {
    super.initState();
    _yukle();
  }

  Future<void> _yukle() async {
    setState(() => _yukleniyor = true);
    try {
      final snap = await FirebaseFirestore.instance
          .collection(_koleksiyon)
          .orderBy('sira')
          .get();
      if (mounted) {
        setState(() {
          _liste = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
          _yukleniyor = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _yukleniyor = false);
    }
  }

  Future<void> _ekleDialog({Map<String, dynamic>? mevcut}) async {
    final adCtrl = TextEditingController(text: mevcut?['ad'] ?? '');
    final pulseCtrl = TextEditingController(text: mevcut?['pulseAdi'] ?? '');
    final digerCtrl =
        TextEditingController(text: mevcut?['digerEkranAdi'] ?? '');
    final pulseSiraCtrl = TextEditingController(
        text: mevcut?['pulseSira'] != null
            ? mevcut!['pulseSira'].toString()
            : '');
    String tip = mevcut?['tip'] ?? 'yemekKarti';
    bool aktif = mevcut?['aktif'] ?? true;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(mevcut == null ? 'Yeni Ödeme Yöntemi' : 'Düzenle'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: adCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Ad *', isDense: true),
                  inputFormatters: [IlkHarfBuyukFormatter()],
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: pulseCtrl,
                  decoration: const InputDecoration(
                      labelText: "Pulse'daki adı", isDense: true),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: digerCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Diğer ekrandaki adı', isDense: true),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: pulseSiraCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Pulse sıra no (örn: 1, 2, 8...)',
                      isDense: true),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                const Text('Tip',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: RadioListTile<String>(
                        title: const Text('Yemek Kartı',
                            style: TextStyle(fontSize: 13)),
                        value: 'yemekKarti',
                        groupValue: tip,
                        dense: true,
                        onChanged: (v) => setDlg(() => tip = v!),
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<String>(
                        title: const Text('Online',
                            style: TextStyle(fontSize: 13)),
                        value: 'online',
                        groupValue: tip,
                        dense: true,
                        onChanged: (v) => setDlg(() => tip = v!),
                      ),
                    ),
                  ],
                ),
                RadioListTile<String>(
                  title: const Text('Pulse Kalemi',
                      style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Sadece Pulse özet tablosunda görünür',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                  value: 'pulseKalemi',
                  groupValue: tip,
                  dense: true,
                  onChanged: (v) => setDlg(() => tip = v!),
                ),
                SwitchListTile(
                  title: const Text('Aktif', style: TextStyle(fontSize: 13)),
                  value: aktif,
                  dense: true,
                  onChanged: (v) => setDlg(() => aktif = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('İptal', style: TextStyle(color: Colors.red)),
            ),
            FilledButton(
              onPressed: () async {
                final ad = adCtrl.text.trim();
                if (ad.isEmpty) return;
                final veri = {
                  'ad': ad,
                  'pulseAdi': pulseCtrl.text.trim(),
                  'digerEkranAdi': digerCtrl.text.trim(),
                  'pulseSira': int.tryParse(pulseSiraCtrl.text.trim()) ?? 99,
                  'tip': tip,
                  'aktif': aktif,
                  'sira': mevcut?['sira'] ?? _liste.length,
                };
                if (mevcut != null) {
                  await FirebaseFirestore.instance
                      .collection(_koleksiyon)
                      .doc(mevcut['id'] as String)
                      .update(veri);
                } else {
                  await FirebaseFirestore.instance
                      .collection(_koleksiyon)
                      .add(veri);
                }
                if (ctx.mounted) Navigator.pop(ctx);
                await _yukle();
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
    adCtrl.dispose();
    pulseCtrl.dispose();
    digerCtrl.dispose();
    pulseSiraCtrl.dispose();
  }

  Future<void> _sil(String id) async {
    final onay = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sil'),
        content: const Text('Bu ödeme yöntemi silinecek. Emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (onay == true) {
      await FirebaseFirestore.instance.collection(_koleksiyon).doc(id).delete();
      await _yukle();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ödeme Yöntemleri',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Yemek kartları ve online ödeme kanalları.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _ekleDialog(),
                  icon: const Icon(Icons.add_circle_outline,
                      color: Color(0xFF0288D1)),
                  tooltip: 'Yeni ekle',
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_yukleniyor)
              const Center(child: CircularProgressIndicator())
            else if (_liste.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Henüz ödeme yöntemi eklenmemiş.',
                    style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                  ),
                ),
              )
            else
              ..._liste.map((item) {
                final ad = item['ad'] as String? ?? '';
                final tip = item['tip'] as String? ?? 'yemekKarti';
                final aktif = item['aktif'] as bool? ?? true;
                final pulseAdi = item['pulseAdi'] as String? ?? '';
                final digerAdi = item['digerEkranAdi'] as String? ?? '';
                final tipRenk = tip == 'online'
                    ? const Color(0xFF0288D1)
                    : tip == 'pulseKalemi'
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFF6A1B9A);
                final tipYazi = tip == 'online'
                    ? 'Online'
                    : tip == 'pulseKalemi'
                        ? 'Pulse Kalemi'
                        : 'Yemek Kartı';
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: aktif
                        ? Colors.grey.withOpacity(0.06)
                        : Colors.grey.withOpacity(0.03),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  ad,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: aktif ? null : Colors.grey,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: tipRenk.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    tipYazi,
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: tipRenk,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                if (!aktif) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'Pasif',
                                      style: TextStyle(
                                          fontSize: 10, color: Colors.grey),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (pulseAdi.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  'Pulse: $pulseAdi',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.grey[500]),
                                ),
                              ),
                            if (digerAdi.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Text(
                                  'Diğer: $digerAdi',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.grey[500]),
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined,
                            size: 18, color: Color(0xFF0288D1)),
                        onPressed: () => _ekleDialog(mevcut: item),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            size: 18, color: Colors.redAccent),
                        onPressed: () => _sil(item['id'] as String),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
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
}
