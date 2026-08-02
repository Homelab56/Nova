import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Maakt een willekeurige tegel/kaart bedienbaar met een afstandsbediening
// (D-pad + "OK"/Enter/Space activeert de tap) met een subtiele focus-gloed
// + lichte vergroting, en scrollt zichzelf in beeld zodra hij focus krijgt.
// Gewone GestureDetectors hebben geen toetsenbord-/D-pad-ondersteuning, dus
// zonder dit heeft een afstandsbediening niets om naartoe te bewegen in
// rijen zoals de posterlijsten.
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final bool autofocus;
  // Sommige schermdelen overlappen elkaar visueel (bv. de doorschijnende
  // koptekst bovenop de hero-banner), waardoor Flutter's automatische
  // "dichtstbijzijnde focusbare widget in deze richting"-logica soms niet
  // betrouwbaar de koptekst terugvindt vanuit het bovenste rij-item. Geef
  // hier een FocusNode op om "omhoog" vanaf dit item altijd expliciet naar
  // over te springen i.p.v. te vertrouwen op die automatische zoektocht.
  final FocusNode? escapeUp;
  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
    this.autofocus = false,
    this.escapeUp,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (has) {
        setState(() => _focused = has);
        if (has) {
          Scrollable.ensureVisible(context,
            duration: const Duration(milliseconds: 200), alignment: 0.5, curve: Curves.easeOut);
        }
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (widget.escapeUp != null && event.logicalKey == LogicalKeyboardKey.arrowUp) {
            widget.escapeUp!.requestFocus();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter ||
              event.logicalKey == LogicalKeyboardKey.space ||
              event.logicalKey == LogicalKeyboardKey.gameButtonA) {
            widget.onTap?.call();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _focused ? 1.035 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              // Zachte gekleurde gloed i.p.v. een hard wit kader - leest als
              // een subtiele markering, niet als een opvallende doos errond.
              boxShadow: _focused
                ? [BoxShadow(color: const Color(0xFF00b4d8).withOpacity(0.65), blurRadius: 12, spreadRadius: 0.5)]
                : const [],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
