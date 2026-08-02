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
  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
    this.autofocus = false,
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
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
             event.logicalKey == LogicalKeyboardKey.enter ||
             event.logicalKey == LogicalKeyboardKey.numpadEnter ||
             event.logicalKey == LogicalKeyboardKey.space ||
             event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _focused ? 1.04 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              border: Border.all(color: _focused ? Colors.white70 : Colors.transparent, width: 2),
              boxShadow: _focused
                ? [BoxShadow(color: Colors.white.withOpacity(0.25), blurRadius: 8)]
                : const [],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
