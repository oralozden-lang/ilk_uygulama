import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../raporlar_ekrani.dart';
import '../../widgets/sube_ozet_tablosu.dart';

class RaporlarTab extends StatefulWidget {
  final bool merkziGiderGor;
  const RaporlarTab({super.key, this.merkziGiderGor = true});

  @override
  State<RaporlarTab> createState() => _RaporlarTabState();
}

class _RaporlarTabState extends State<RaporlarTab> {
  late Future<List<String>> _subelerGelecek;

  @override
  void initState() {
    super.initState();
    _subelerGelecek = FirebaseFirestore.instance
        .collection('subeler')
        .get()
        .then((snap) => snap.docs.map((d) => d.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _subelerGelecek,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        final subeler = snap.data ?? [];
        return DefaultTabController(
          length: 3,
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
                        text: 'Dönem Raporu'),
                    Tab(icon: Icon(Icons.store, size: 18), text: 'Şube Özet'),
                    Tab(
                        icon: Icon(Icons.payment, size: 18),
                        text: 'Ödeme Kanalları'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    RaporlarWidget(
                      subeler: subeler,
                      merkziGiderGor: widget.merkziGiderGor,
                    ),
                    SubeOzetTablosu(subeler: subeler),
                    OdemeKanallariWidget(subeler: subeler),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
