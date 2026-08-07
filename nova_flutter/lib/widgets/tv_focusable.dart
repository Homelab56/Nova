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
  // Optioneel: wordt long-press ondersteund (muis/aanraking via
  // GestureDetector, D-pad via de "herhaal"-toets-gebeurtenis die Android
  // al zelf stuurt zodra een toets lang genoeg ingedrukt blijft). Zonder dit
  // blijft het bestaande gedrag exact ongewijzigd (tikt meteen op KeyDown).
  final VoidCallback? onLongPress;
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
    this.onLongPress,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
    this.autofocus = false,
    this.escapeUp,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;
  // De állereerste focus-gebeurtenis (autofocus bij het openen van het
  // scherm) mag niet scrollen: dat duwde op het profielscherm het logo
  // erboven zomaar uit beeld om de eerste focusbare tegel te centreren -
  // onopgemerkt op een groot venster (alles paste toch al), wel zichtbaar
  // stuk op een kleiner TV-scherm. Latere, echte D-pad-navigatie scrollt
  // gewoon normaal mee.
  bool _hadFocusChange = false;
  // Enkel relevant als onLongPress is opgegeven: voorkomt dat de KeyUp na
  // een lange druk ook nog eens als gewone tik telt.
  bool _longPressFired = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (has) {
        setState(() => _focused = has);
        final skipScroll = widget.autofocus && !_hadFocusChange;
        _hadFocusChange = true;
        if (has && !skipScroll) {
          Scrollable.ensureVisible(context,
            duration: const Duration(milliseconds: 200), alignment: 0.5, curve: Curves.easeOut);
        }
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            widget.escapeUp != null && event.logicalKey == LogicalKeyboardKey.arrowUp) {
          widget.escapeUp!.requestFocus();
          return KeyEventResult.handled;
        }
        final isSelectKey = event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter ||
            event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA;
        if (!isSelectKey) return KeyEventResult.ignored;

        if (widget.onLongPress == null) {
          if (event is KeyDownEvent) {
            widget.onTap?.call();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        // Met long-press: pas op KeyUp een gewone tik doen (niet meteen op
        // KeyDown), zodat we eerst kunnen zien of de toets lang genoeg
        // ingedrukt blijft om als long-press te tellen.
        if (event is KeyDownEvent) {
          _longPressFired = false;
          return KeyEventResult.handled;
        }
        if (event is KeyRepeatEvent) {
          if (!_longPressFired) {
            _longPressFired = true;
            widget.onLongPress!();
          }
          return KeyEventResult.handled;
        }
        if (event is KeyUpEvent) {
          if (!_longPressFired) widget.onTap?.call();
          _longPressFired = false;
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _focused ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              // Een dunne, scherpe rand leest ondubbelzinnig als "dit is
              // geselecteerd" - ook van op de bank en ook voor wie de vorige,
              // zachtere gloed-only versie niet duidelijk genoeg vond. De
              // gloed blijft erbij voor wat diepte, maar is niet meer de
              // enige aanwijzing. Twee gestapelde schaduwen (een strakke
              // dichtbij, een ruimere errond) lezen van op afstand feller
              // dan één enkele - dat bleek zelfs met de eerste (sterkere)
              // versie nog te subtiel.
              border: Border.all(
                color: _focused ? const Color(0xFF00e5ff) : Colors.transparent,
                width: 4,
              ),
              boxShadow: _focused
                ? [
                    BoxShadow(color: const Color(0xFF00e5ff).withOpacity(0.9), blurRadius: 10, spreadRadius: 1),
                    BoxShadow(color: const Color(0xFF00e5ff).withOpacity(0.55), blurRadius: 28, spreadRadius: 4),
                  ]
                : const [],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
