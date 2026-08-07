import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// De ENIGE plek waar de focus-highlight (rand + gloed + vergroting)
// getekend wordt - zowel TvFocusable (die zelf de tik/focus afhandelt) als
// knoppen die hun focus al ergens anders beheren (Material-knoppen met een
// eigen FocusNode, zoals de hero-knoppen en de navigatietabs) gaan hier
// doorheen. Vroeger had elk van die plekken zijn eigen kopie van dezelfde
// decoratie, en een fix op de ene plek loste de andere kopieën niet mee op.
class TvHighlightBox extends StatelessWidget {
  final bool focused;
  final Widget child;
  final BorderRadius borderRadius;
  // Kleine, tekst-gevulde knoppen (navigatietabs, hero-knoppen) krijgen
  // bewust een lichtere highlight zonder vergroting - dezelfde zware gloed
  // als op een poster maakte tekst daar onleesbaar i.p.v. duidelijker.
  final bool muted;
  const TvHighlightBox({
    super.key,
    required this.focused,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: focused && !muted ? 1.25 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        // De gloed/schaduw blijft in "decoration" (achter het kind, zoals
        // een schaduw hoort te renderen - in foregroundDecoration tekent een
        // boxShadow een vólledig gevulde, wazige vorm BOVENOP het kind, geen
        // rand eromheen). Enkel de rand staat in foregroundDecoration, want
        // een border in "decoration" telt in Flutter impliciet mee als extra
        // padding rond het kind - dat liet het kind bij focus buiten zijn
        // toegewezen ruimte groeien en gaf een echte RenderFlex-overflow.
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: !focused
            ? const []
            : (muted
                ? [BoxShadow(color: const Color(0xFF00b4d8).withOpacity(0.55), blurRadius: 10, spreadRadius: 0.5)]
                : [
                    BoxShadow(color: const Color(0xFF00e5ff).withOpacity(0.95), blurRadius: 10, spreadRadius: 1),
                    BoxShadow(color: const Color(0xFF00e5ff).withOpacity(0.6), blurRadius: 26, spreadRadius: 3),
                  ]),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            color: !focused ? Colors.transparent : (muted ? const Color(0xFF00b4d8) : const Color(0xFF00e5ff)),
            width: muted ? 2 : 4,
          ),
        ),
        child: child,
      ),
    );
  }
}

// Maakt een willekeurige tegel/kaart bedienbaar met een afstandsbediening
// (D-pad + "OK"/Enter/Space activeert de tap), met de highlight hierboven.
// Gewone GestureDetectors hebben geen toetsenbord-/D-pad-ondersteuning, dus
// zonder dit heeft een afstandsbediening niets om naartoe te bewegen in
// rijen zoals de posterlijsten.
//
// Niet-gemute (dus vergrote) tegels tekenen hun highlight via de Overlay
// i.p.v. gewoon inline in de rij/raster zelf. Reden: in een ListView/GridView
// tekenen latere items ALTIJD bovenop eerdere items, ongeacht welk item
// focus heeft - een vergrote, gefocuste tegel die in de ruimte van zijn
// buurman groeit, kon dus voor een stuk verborgen raken áchter die buurman
// (als die later in de lijst staat), wat leek alsof "een stuk van de
// highlight wegviel". Genoeg permanente marge geven om dat te vermijden
// maakte de hele rij gelijkmatig ruimer (ook de niet-gefocuste tegels),
// wat het contrast van "deze ene tegel is groter" juist wegneemt. Via de
// Overlay tekent de gefocuste tegel altijd op de allerbovenste laag, boven
// alle rij-/rasterinhoud, dus kan hij vrij groeien zonder ooit door een
// buur verborgen te raken én zonder dat de rest van de rij extra ruimte
// nodig heeft.
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
  final bool muted;
  // Optioneel: gebruik een extern beheerde FocusNode i.p.v. er zelf een aan
  // te maken - nodig zodra ander code (zoals "omhoog"-navigatie vanuit een
  // andere rij) expliciet naar déze specifieke knop moet kunnen springen.
  final FocusNode? focusNode;
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
    this.muted = false,
    this.focusNode,
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

  // LayerLink + CompositedTransformFollower is Flutter's eigen mechanisme
  // voor "een zwevende laag die een widget blijft volgen, ook terwijl die
  // beweegt" (hetzelfde dat tooltips/dropdowns gebruiken) - nodig omdat
  // Scrollable.ensureVisible de rij laat scrollen zodra dit item focus
  // krijgt: een eenmalig berekende positie zou dan meteen weer verouderd
  // zijn.
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _overlayEntry;

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _showOverlay() {
    if (widget.muted) return;
    final box = _anchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final overlayState = Overlay.maybeOf(context);
    if (overlayState == null) return;
    final size = box.size;
    _removeOverlay();
    _overlayEntry = OverlayEntry(builder: (_) {
      return CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: GestureDetector(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: TvHighlightBox(
              focused: true,
              borderRadius: widget.borderRadius,
              child: widget.child,
            ),
          ),
        ),
      );
    });
    overlayState.insert(_overlayEntry!);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (has) {
        // Vóór setState, zodat de highlight al klaarstaat in dezelfde frame
        // waarin de originele (dan onzichtbare) tegel verdwijnt - anders
        // een korte flikkering (leeg gat) voor de highlight verschijnt.
        if (has) {
          _showOverlay();
        } else {
          _removeOverlay();
        }
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
        child: CompositedTransformTarget(
          link: _layerLink,
          child: KeyedSubtree(
            key: _anchorKey,
            // Terwijl de vergrote highlight via de Overlay boven alles
            // getekend wordt, blijft dit de "echte" plek in de rij/raster -
            // nodig voor lay-out, scroll-naar-focus en D-pad-navigatie, maar
            // onzichtbaar zodat hij niet dubbel getekend wordt. Gemute
            // knoppen (die niet vergroten) tekenen gewoon hier, geen Overlay
            // nodig.
            child: Opacity(
              opacity: (_focused && !widget.muted) ? 0.0 : 1.0,
              child: TvHighlightBox(
                focused: _focused && widget.muted,
                muted: widget.muted,
                borderRadius: widget.borderRadius,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
