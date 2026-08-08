import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// De ENIGE plek waar de focus-highlight (rand + gloed + optionele lift)
// getekend wordt - zowel TvFocusable (die zelf de tik/focus afhandelt) als
// knoppen die hun focus al ergens anders beheren (Material-knoppen met een
// eigen FocusNode, zoals de hero-knoppen en de navigatietabs) gaan hier
// doorheen. Vroeger had elk van die plekken zijn eigen kopie van dezelfde
// decoratie, en een fix op de ene plek (bv. de RenderFlex-overflow door een
// border in "decoration", of een boxShadow die per ongeluk een effen vlak
// tekende in foregroundDecoration) loste de andere kopieën niet mee op.
class TvHighlightBox extends StatelessWidget {
  final bool focused;
  final Widget child;
  final BorderRadius borderRadius;
  // Kleine, tekst-gevulde knoppen (navigatietabs, hero-knoppen) krijgen
  // bewust een lichtere highlight zonder vergroting - dezelfde zware gloed
  // als op een poster maakte tekst daar onleesbaar i.p.v. duidelijker.
  final bool muted;
  // Voor tegels in krappe rijen/rasters waar geen enkele hoeveelheid marge
  // rond de tegel betrouwbaar bleek: geen vergroting bij focus, enkel de
  // rand + gloed. Een tegel die nooit buiten zijn eigen vak groeit kan ook
  // nooit een halve/afgesneden rand geven, ongeacht buren of scherm-/
  // scroll-randen - simpelweg omdat er dan niets is om af te snijden.
  final bool noGrow;
  const TvHighlightBox({
    super.key,
    required this.focused,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
    this.muted = false,
    this.noGrow = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: focused && !muted && !noGrow ? 1.3 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        // De gloed/schaduw blijft in "decoration" (achter het kind, zoals
        // een schaduw hoort te renderen - in foregroundDecoration tekent een
        // boxShadow een vólledig gevulde, wazige vorm BOVENOP het kind, geen
        // rand eromheen: leek dan een effen gekleurd vlak i.p.v. de poster
        // erachter). Enkel de rand staat in foregroundDecoration, want een
        // border in "decoration" telt in Flutter impliciet mee als extra
        // padding rond het kind (zodat de rand niet over de inhoud heen
        // valt) - dat liet het kind bij focus buiten zijn toegewezen ruimte
        // groeien en gaf een echte RenderFlex-overflow/crash in rijen met
        // een krap vastgezette hoogte. Een boxShadow telt daar niet in mee,
        // dus die blijft veilig in "decoration".
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: !focused
            ? const []
            : (muted
                // Was blurRadius:18, spreadRadius:2, opacity:0.75 - nog
                // steeds te subtiel op een effen witte knop ("Afspelen").
                // Fel/lichtblauw (0xFF00b4d8) heeft van nature weinig
                // contrast tegen wit, ongeacht hoe groot de gloed is -
                // fors groter gemaakt om dat te compenseren.
                ? [BoxShadow(color: const Color(0xFF00b4d8).withOpacity(0.9), blurRadius: 28, spreadRadius: 5)]
                : [
                    BoxShadow(color: const Color(0xFF00e5ff).withOpacity(0.95), blurRadius: 10, spreadRadius: 1),
                    BoxShadow(color: const Color(0xFF00e5ff).withOpacity(0.6), blurRadius: 26, spreadRadius: 3),
                  ]),
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            // Donkerder, verzadigder blauw voor gemute knoppen (i.p.v. het
            // lichtere 0xFF00b4d8) - een lichte kleur rand heeft weinig
            // contrast tegen een effen witte knop zoals "Afspelen",
            // ongeacht de dikte; donkerder leest daar wél duidelijk, en
            // blijft ook tegen de donkere pagina-achtergrond goed zichtbaar.
            color: !focused ? Colors.transparent : (muted ? const Color(0xFF0891b2) : const Color(0xFF00e5ff)),
            // Was 2, toen 3 - nog dikker leest ondubbelzinniger.
            width: muted ? 5 : 4,
          ),
        ),
        child: child,
      ),
    );
  }
}

// Maakt een willekeurige tegel/kaart bedienbaar met een afstandsbediening
// (D-pad + "OK"/Enter/Space activeert de tap) met de highlight hierboven,
// en scrollt zichzelf in beeld zodra hij focus krijgt. Gewone
// GestureDetectors hebben geen toetsenbord-/D-pad-ondersteuning, dus zonder
// dit heeft een afstandsbediening niets om naartoe te bewegen in rijen
// zoals de posterlijsten.
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
  final bool noGrow;
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
    this.noGrow = false,
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
  // Was gebaseerd op Android's eigen "herhaal"-toets-gebeurtenis
  // (KeyRepeatEvent), maar de timing daarvan bleek onvoorspelbaar genoeg
  // (verschilt per toestel/afstandsbediening) dat een bedoelde lange druk
  // soms nog als gewone tik telde - de tegel opende dan gewoon i.p.v. het
  // verwijder-/watchlist-menu te tonen. Een eigen Timer geeft een vaste,
  // voorspelbare duur, los van toestel-specifieke herhaal-timing.
  Timer? _longPressTimer;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (has) {
        setState(() => _focused = has);
        final skipScroll = widget.autofocus && !_hadFocusChange;
        _hadFocusChange = true;
        if (has && !skipScroll) {
          Scrollable.ensureVisible(context,
            duration: const Duration(milliseconds: 200), alignment: 0.5, curve: Curves.easeOut);
        }
        // Zonder dit kon een lopende long-press-timer nog afgaan nadat de
        // focus (bv. door snel verder te navigeren) al naar een andere
        // tegel was verhuisd, zonder dat er ooit een KeyUp voor déze tegel
        // binnenkwam - het verwijder-/watchlist-menu voor de verkeerde
        // (niet meer gefocuste) tegel zou dan alsnog kunnen opengaan.
        if (!has) {
          _longPressTimer?.cancel();
          _longPressTimer = null;
          _longPressFired = false;
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
        // ingedrukt blijft om als long-press te tellen. Een vaste Timer
        // i.p.v. Android's herhaal-toets-gebeurtenis (zie toelichting bij
        // _longPressTimer hierboven).
        if (event is KeyDownEvent) {
          // Herhaalde KeyDown-events tijdens het ingedrukt houden mogen de
          // timer niet telkens herstarten - enkel bij de allereerste indruk.
          if (_longPressTimer == null) {
            _longPressFired = false;
            _longPressTimer = Timer(const Duration(milliseconds: 500), () {
              _longPressFired = true;
              widget.onLongPress!();
            });
          }
          return KeyEventResult.handled;
        }
        if (event is KeyUpEvent) {
          _longPressTimer?.cancel();
          _longPressTimer = null;
          if (!_longPressFired) widget.onTap?.call();
          _longPressFired = false;
          return KeyEventResult.handled;
        }
        // Android blijft KeyRepeatEvents sturen zolang de toets ingedrukt
        // blijft (los van onze eigen Timer hierboven) - gewoon opslokken
        // i.p.v. laten doorborrelen naar een voorouder-widget, anders kon
        // die tijdens een lange druk ongewenst herhaaldelijk reageren.
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: TvHighlightBox(
          focused: _focused,
          muted: widget.muted,
          noGrow: widget.noGrow,
          borderRadius: widget.borderRadius,
          child: widget.child,
        ),
      ),
    );
  }
}
