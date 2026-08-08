import 'package:flutter/material.dart';

// Horizontale rij met titel, optionele "Meer bekijken"-link en (bij hover,
// desktop-only) pijltjes om verder te scrollen - de standaard muiswiel-scroll
// op een horizontale ListView is op Windows niet betrouwbaar/intuïtief.
class MediaRow extends StatefulWidget {
  final String title;
  final Color titleColor;
  final double height;
  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final String? path;
  final VoidCallback? onSeeAll;
  const MediaRow({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.titleColor = Colors.white,
    this.height = 290,
    this.path,
    this.onSeeAll,
  });
  @override
  State<MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<MediaRow> {
  final _scrollCtrl = ScrollController();
  bool _hovering = false;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollBy(double delta) {
    if (!_scrollCtrl.hasClients) return;
    final max = _scrollCtrl.position.maxScrollExtent;
    final current = _scrollCtrl.offset;
    // Eindeloos scrollen: bij de rand nog eens op hetzelfde pijltje klikken
    // springt door naar het andere uiteinde i.p.v. daar simpelweg te
    // blijven staan - zoals Netflix' rijen werken.
    if (delta > 0 && current >= max - 5) {
      _scrollCtrl.animateTo(0, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
      return;
    }
    if (delta < 0 && current <= 5) {
      _scrollCtrl.animateTo(max, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
      return;
    }
    final target = (current + delta).clamp(0.0, max);
    _scrollCtrl.animateTo(target, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
  }

  Widget _arrow(IconData icon, VoidCallback onTap, {required Alignment alignment}) {
    return Positioned(
      left: alignment == Alignment.centerLeft ? 0 : null,
      right: alignment == Alignment.centerRight ? 0 : null,
      top: 0, bottom: 30,
      child: AnimatedOpacity(
        opacity: _hovering ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: IgnorePointer(
          ignoring: !_hovering,
          child: Container(
            width: 44,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: alignment == Alignment.centerLeft ? Alignment.centerLeft : Alignment.centerRight,
                end: alignment == Alignment.centerLeft ? Alignment.centerRight : Alignment.centerLeft,
                colors: [const Color(0xFF080c14).withOpacity(0.9), Colors.transparent],
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                child: Icon(icon, color: Colors.white, size: 28),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
        child: Row(children: [
          Text(widget.title, style: TextStyle(
            fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 0.2,
            color: widget.titleColor)),
          if (widget.onSeeAll != null) ...[
            const SizedBox(width: 14),
            InkWell(
              onTap: widget.onSeeAll,
              child: const Text('Meer bekijken >',
                style: TextStyle(fontSize: 13, color: Color(0xFF00b4d8), fontWeight: FontWeight.w600)),
            ),
          ],
        ]),
      ),
      SizedBox(
        // Rij-tegels vergroten niet meer bij focus (noGrow op TvFocusable) -
        // enkel rand+gloed binnen de tegel se eigen grootte, dus geen extra
        // ruimte hier meer nodig om iets te laten overlopen.
        height: widget.height,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: Stack(children: [
            ListView.builder(
              controller: _scrollCtrl,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              // Een stuk groter dan de standaard (~250px) zodat een D-pad
              // meerdere kaarten voorbij het scherm al kan focussen i.p.v.
              // vast te lopen zodra hij een nog niet opgebouwde kaart nadert.
              cacheExtent: 2000,
              itemCount: widget.itemCount,
              itemBuilder: widget.itemBuilder,
            ),
            _arrow(Icons.chevron_left, () => _scrollBy(-800), alignment: Alignment.centerLeft),
            _arrow(Icons.chevron_right, () => _scrollBy(800), alignment: Alignment.centerRight),
          ]),
        ),
      ),
    ]);
  }
}
