import '../core/formatters.dart';
import 'package:flutter/material.dart';

class GiderAdiAlani extends StatefulWidget {
  final TextEditingController ctrl;
  final List<String> secenekler;
  final String labelText;
  final VoidCallback? onChanged;
  final bool readOnly;

  const GiderAdiAlani({
    required this.ctrl,
    required this.secenekler,
    this.labelText = 'Gider Adı',
    this.onChanged,
    this.readOnly = false,
  });

  @override
  State<GiderAdiAlani> createState() => GiderAdiAlaniState();
}

class GiderAdiAlaniState extends State<GiderAdiAlani> {
  @override
  void dispose() {
    super.dispose();
  }

  void _secimYap() {
    if (widget.readOnly || widget.secenekler.isEmpty) return;
    final ctrl = TextEditingController(text: widget.ctrl.text);

    // FIX: Navigator.pop ÖNCE, onChanged SONRA (addPostFrameCallback ile)
    // Eski sıra: onChanged → setState → rebuild → bottom sheet açık → bordo ekran
    void kaydetVeKapat(BuildContext ctx, String deger) {
      final temiz = deger.trim();
      widget.ctrl.text = temiz;
      widget.ctrl.selection = TextSelection.collapsed(offset: temiz.length);
      Navigator.pop(ctx); // ← Önce bottom sheet'i kapat
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onChanged?.call(); // ← Sonra callback — parent rebuild güvenli
      });
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
                      onTap: () {},
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
                            color:
                                secili ? const Color(0xFF0288D1) : Colors.grey,
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
      onChanged:
          widget.secenekler.isEmpty ? (_) => widget.onChanged?.call() : null,
    );
  }
}

// DigerAlimAciklamaAlani — GiderAdiAlani'nin ince sarmalayıcısı
class DigerAlimAciklamaAlani extends StatelessWidget {
  final TextEditingController ctrl;
  final List<String> secenekler;
  final VoidCallback onChanged;

  const DigerAlimAciklamaAlani({
    required this.ctrl,
    required this.secenekler,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GiderAdiAlani(
      ctrl: ctrl,
      secenekler: secenekler,
      labelText: 'Açıklama',
      onChanged: onChanged,
    );
  }
}
