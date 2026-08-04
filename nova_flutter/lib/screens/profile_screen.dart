import 'dart:math';
import 'package:flutter/material.dart';
import '../services/profile_service.dart';
import '../widgets/tv_focusable.dart';
import 'home_screen.dart';

// Vaste seed zodat het sterrenveld niet bij elke rebuild/hot-reload
// verspringt - het moet een rustige, stabiele achtergrond zijn.
class _StarfieldPainter extends CustomPainter {
  final int starCount;
  const _StarfieldPainter({this.starCount = 140});

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = Random(42);
    for (var i = 0; i < starCount; i++) {
      final dx = rnd.nextDouble() * size.width;
      final dy = rnd.nextDouble() * size.height;
      final radius = rnd.nextDouble() * 1.4 + 0.3;
      final opacity = rnd.nextDouble() * 0.5 + 0.15;
      final paint = Paint()..color = Colors.white.withOpacity(opacity);
      canvas.drawCircle(Offset(dx, dy), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StarfieldPainter oldDelegate) => false;
}

// Basiskleuren bewust breed gespreid over de kleurenwaaier (niet allemaal
// blauw/teal) zodat elk profiel in één oogopslag te onderscheiden is - een
// nauwe familie oogde bij vergelijking "te veel op elkaar". Elke kleur krijgt
// er zelf (via _gradientFor) een subtiel donkerder gradient-randje bij voor
// de medaillon-look, zonder de herkenbaarheid van de kleur te verliezen.
const _avatarBaseColors = <Color>[
  Color(0xFF00b4d8), Color(0xFFe63946), Color(0xFFf4a261), Color(0xFF2a9d8f),
  Color(0xFF9b5de5), Color(0xFFffb703), Color(0xFFef476f), Color(0xFF06d6a0),
  Color(0xFF118ab2), Color(0xFFffd166), Color(0xFFc9184a), Color(0xFF80ffdb),
  Color(0xFF7209b7), Color(0xFFf72585), Color(0xFF4cc9f0), Color(0xFF43aa8b),
  Color(0xFFf94144), Color(0xFFf3722c), Color(0xFF90be6d), Color(0xFF577590),
];

List<Color> _gradientFor(int index) {
  final base = _avatarBaseColors[index % _avatarBaseColors.length];
  return [base, Color.lerp(base, Colors.black, 0.35)!];
}

// Optionele iconen als alternatief voor de letter-avatar - een profiel kan
// zowel een kleur als (optioneel) een icoon kiezen dat past bij wat diegene
// leuk vindt, i.p.v. verplicht een letter te tonen.
const _avatarIcons = <String, IconData>{
  'star': Icons.star_rounded,
  'movie': Icons.movie_rounded,
  'rocket': Icons.rocket_launch_rounded,
  'game': Icons.sports_esports_rounded,
  'music': Icons.music_note_rounded,
  'heart': Icons.favorite_rounded,
  'football': Icons.sports_soccer_rounded,
  'book': Icons.menu_book_rounded,
  'camera': Icons.camera_alt_rounded,
  'headphones': Icons.headphones_rounded,
  'moon': Icons.nightlight_round,
  'crown': Icons.emoji_events_rounded,
  'pizza': Icons.local_pizza_rounded,
  'cat': Icons.pets_rounded,
  'theater': Icons.theater_comedy_rounded,
  'fire': Icons.local_fire_department_rounded,
};

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<Profile> _profiles = [];
  bool _loading = true;
  bool _editing = false;
  String? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final profiles = await ProfileService.getProfiles();
      if (!mounted) return;
      setState(() { _profiles = profiles; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Kan geen verbinding maken met de server.'; _loading = false; });
    }
  }

  Future<void> _selectProfile(Profile profile) async {
    if (profile.pin != null && profile.pin!.isNotEmpty) {
      final ok = await _askPin(profile.pin!);
      if (ok != true) return;
    }
    ProfileService.activeProfileId = profile.id;
    ProfileService.activeProfileName = profile.name;
    if (!mounted) return;
    // Volledig verse Home-stack i.p.v. pushReplacement: dit scherm is soms de
    // allereerste route (koude start) en soms erbovenop gepusht (wisselen
    // vanuit de app) - in beide gevallen willen we geen oude schermen van
    // het vorige profiel laten rondslingeren.
    Navigator.pushAndRemoveUntil(
      context, MaterialPageRoute(builder: (_) => const HomeScreen()), (route) => false);
  }

  Future<bool?> _askPin(String correctPin) async {
    final ctrl = TextEditingController();
    String? error;
    return showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0f1520),
          title: const Text('Pincode', style: TextStyle(color: Colors.white)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: true,
              maxLength: 4,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                counterText: '',
                errorText: error,
                enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              ),
              onSubmitted: (v) {
                if (v == correctPin) {
                  Navigator.pop(context, true);
                } else {
                  setDialogState(() => error = 'Onjuiste pincode');
                }
              },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuleren')),
            TextButton(
              onPressed: () {
                if (ctrl.text == correctPin) {
                  Navigator.pop(context, true);
                } else {
                  setDialogState(() => error = 'Onjuiste pincode');
                }
              },
              child: const Text('Bevestigen', style: TextStyle(color: Color(0xFF00b4d8))),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _createOrEditProfile({Profile? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final pinCtrl = TextEditingController(text: existing?.pin ?? '');
    // Kleuren mogen niet dubbel voorkomen - elke andere profiel se kleur is
    // hier uitgesloten (het eigen huidige kleurtje bij bewerken telt niet mee
    // als "bezet", anders zou je het niet kunnen behouden).
    final usedIndices = _profiles
      .where((p) => p.id != existing?.id)
      .map((p) => p.colorIndex % _avatarBaseColors.length)
      .toSet();
    int colorIndex = existing?.colorIndex ??
      List.generate(_avatarBaseColors.length, (i) => i).firstWhere(
        (i) => !usedIndices.contains(i),
        orElse: () => _profiles.length % _avatarBaseColors.length,
      );
    String? selectedIcon = existing?.icon;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0f1520),
          title: Text(existing == null ? 'Nieuw profiel' : 'Profiel bewerken', style: const TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Naam', labelStyle: TextStyle(color: Colors.grey)),
              ),
              const SizedBox(height: 16),
              const Text('Kleur', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (var i = 0; i < _avatarBaseColors.length; i++)
                  Builder(builder: (context) {
                    final taken = usedIndices.contains(i);
                    return TvFocusable(
                      borderRadius: BorderRadius.circular(17),
                      onTap: taken ? null : () => setDialogState(() => colorIndex = i),
                      child: Opacity(
                        opacity: taken ? 0.25 : 1,
                        child: Container(
                          width: 34, height: 34,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft, end: Alignment.bottomRight,
                              colors: _gradientFor(i),
                            ),
                            border: Border.all(
                              color: colorIndex == i ? Colors.white : Colors.white24,
                              width: colorIndex == i ? 2.5 : 1,
                            ),
                          ),
                          child: colorIndex == i
                            ? const Icon(Icons.check, color: Colors.white, size: 16)
                            : (taken ? const Icon(Icons.block, color: Colors.white70, size: 14) : null),
                        ),
                      ),
                    );
                  }),
              ]),
              const SizedBox(height: 16),
              const Text('Icoon (optioneel)', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(spacing: 10, runSpacing: 10, children: [
                Builder(builder: (context) {
                  final selected = selectedIcon == null;
                  return TvFocusable(
                    borderRadius: BorderRadius.circular(17),
                    onTap: () => setDialogState(() => selectedIcon = null),
                    child: Container(
                      width: 34, height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF1a2230),
                        border: Border.all(color: selected ? Colors.white : Colors.white24, width: selected ? 2.5 : 1),
                      ),
                      child: const Center(child: Text('Aa', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700))),
                    ),
                  );
                }),
                for (final entry in _avatarIcons.entries)
                  Builder(builder: (context) {
                    final selected = selectedIcon == entry.key;
                    return TvFocusable(
                      borderRadius: BorderRadius.circular(17),
                      onTap: () => setDialogState(() => selectedIcon = entry.key),
                      child: Container(
                        width: 34, height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF1a2230),
                          border: Border.all(color: selected ? Colors.white : Colors.white24, width: selected ? 2.5 : 1),
                        ),
                        child: Icon(entry.value, color: Colors.white70, size: 17),
                      ),
                    );
                  }),
              ]),
              const SizedBox(height: 16),
              TextField(
                controller: pinCtrl,
                obscureText: true,
                maxLength: 4,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Pincode (optioneel)', labelStyle: TextStyle(color: Colors.grey), counterText: '',
                ),
              ),
            ]),
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: const Color(0xFF0f1520),
                      title: const Text('Profiel verwijderen?', style: TextStyle(color: Colors.white)),
                      content: Text('"${existing.name}" en zijn watchlist/kijkgeschiedenis/rangschikking worden verwijderd.',
                        style: const TextStyle(color: Colors.grey)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuleren')),
                        TextButton(onPressed: () => Navigator.pop(context, true),
                          child: const Text('Verwijderen', style: TextStyle(color: Colors.redAccent))),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await ProfileService.deleteProfile(existing.id);
                    if (context.mounted) Navigator.pop(context, false);
                    _load();
                  }
                },
                child: const Text('Verwijderen', style: TextStyle(color: Colors.redAccent)),
              ),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuleren')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Opslaan', style: TextStyle(color: Color(0xFF00b4d8))),
            ),
          ],
        );
      }),
    );

    if (result != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    final pin = pinCtrl.text.trim();
    if (existing == null) {
      await ProfileService.createProfile(name, pin: pin, colorIndex: colorIndex, icon: selectedIcon);
    } else {
      await ProfileService.updateProfile(existing.copyWith(
        name: name, pin: pin.isEmpty ? null : pin, clearPin: pin.isEmpty,
        colorIndex: colorIndex, icon: selectedIcon, clearIcon: selectedIcon == null));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080c14),
      body: SafeArea(
        child: Stack(children: [
          // Zachte gloed + een subtiel sterrenveld i.p.v. een kaal vlak -
          // dit is het allereerste scherm dat je ziet en past bij "Nova".
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.5),
                  radius: 1.3,
                  colors: [Color(0xFF122438), Color(0xFF080c14)],
                ),
              ),
            ),
          ),
          const Positioned.fill(child: CustomPaint(painter: _StarfieldPainter())),
          _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8)))
          : _error != null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.cloud_off, color: Colors.white38, size: 48),
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                const SizedBox(height: 20),
                TextButton(onPressed: _load, child: const Text('Opnieuw proberen')),
              ]),
            )
          // LayoutBuilder + minHeight i.p.v. gewoon Center: een Column
          // binnenin een SingleChildScrollView krijgt onbegrensde hoogte,
          // waardoor mainAxisAlignment/Center genegeerd wordt en alles naar
          // boven schuift zodra het scrollbaar is - dit dwingt "centreer
          // wanneer het past, scroll wanneer het niet past" af.
          : LayoutBuilder(builder: (context, constraints) {
              // Het logo krijgt zoveel ruimte als na aftrek van wat de rest
              // van de inhoud (titel, profielen, knop) sowieso nodig heeft
              // nog overblijft, geschaald tussen een minimum en het volledige
              // formaat - zo past alles altijd in één beeld, zonder te
              // moeten scrollen, ongeacht of dit een groot PC-venster of een
              // kortere TV-viewport is. Vaste pixelwaarden pasten wel op een
              // groot venster maar duwden op een kleiner scherm de profielen
              // (het belangrijkste, interactieve deel) voorbij de rand.
              const restBudget = 380.0;
              const logoBudgetFull = 500.0; // mark(300) + gap(16) + text(184)
              final logoBudget = (constraints.maxHeight - restBudget).clamp(160.0, logoBudgetFull);
              final logoScale = logoBudget / logoBudgetFull;
              final markH = 300 * logoScale;
              final gapH = 16 * logoScale;
              final textH = 184 * logoScale;

              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      // Twee losse afbeeldingen i.p.v. één grote gecombineerde
                      // logo.png - op een TV bleek enkel de onderste helft
                      // (de "NOVA"-tekst) te renderen en het bovenste
                      // N-beeldmerk gewoon te ontbreken, ook al was het
                      // bestand zelf perfect in orde. Apart tonen is minder
                      // gevoelig voor wat daar ook de oorzaak van was.
                      Image.asset('assets/logo_mark.png', height: markH),
                      SizedBox(height: gapH),
                      Image.asset('assets/logo_text.png', height: textH),
                      const SizedBox(height: 4),
                      const Text('Wie kijkt er?', style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 48),
                      Wrap(
                        spacing: 24, runSpacing: 24, alignment: WrapAlignment.center,
                        children: [
                          for (var i = 0; i < _profiles.length; i++)
                            _profileTile(_profiles[i], autofocus: i == 0),
                          // Ook tonen als er nog geen enkel profiel is, anders
                          // is er op een verse installatie geen zichtbare
                          // manier om het allereerste profiel aan te maken.
                          if (_editing || _profiles.isEmpty) _addTile(autofocus: _profiles.isEmpty),
                        ],
                      ),
                      const SizedBox(height: 40),
                      TextButton(
                        onPressed: () => setState(() => _editing = !_editing),
                        child: Text(_editing ? 'Klaar' : 'Profielen beheren',
                          style: TextStyle(color: _editing ? const Color(0xFF00b4d8) : Colors.grey, fontSize: 14)),
                      ),
                    ]),
                  ),
                ),
              );
            }),
          if (Navigator.canPop(context))
            Positioned(
              top: 8, left: 8,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
        ]),
      ),
    );
  }

  // Cirkelvormige medaillon-look (gradient vulling + gloed + lichte rand +
  // sparkle-accent) i.p.v. platte gekleurde vierkantjes met één letter erin -
  // sluit beter aan bij het metallic logo en het sterrenveld erachter.
  Widget _avatarBadge(Profile profile) {
    final grad = _gradientFor(profile.colorIndex);
    final iconData = profile.icon != null ? _avatarIcons[profile.icon] : null;
    return Stack(clipBehavior: Clip.none, children: [
      Container(
        width: 92, height: 92,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(-0.3, -0.4),
            radius: 1.0,
            colors: [grad[0], grad[1], const Color(0xFF080c14)],
            stops: const [0.0, 0.55, 1.0],
          ),
          border: Border.all(color: Colors.white.withOpacity(0.55), width: 1.6),
          boxShadow: [
            BoxShadow(color: grad[0].withOpacity(0.55), blurRadius: 20, spreadRadius: 1),
          ],
        ),
        child: Center(
          child: iconData != null
            ? Icon(iconData, color: Colors.white, size: 38,
                shadows: [Shadow(blurRadius: 8, color: Colors.black.withOpacity(0.6))])
            : Text(
                profile.name.isNotEmpty ? profile.name[0].toUpperCase() : '?',
                style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black.withOpacity(0.6))]),
              ),
        ),
      ),
      Positioned(top: -2, right: 4,
        child: Icon(Icons.auto_awesome, color: Colors.white.withOpacity(0.85), size: 14)),
    ]);
  }

  Widget _profileTile(Profile profile, {bool autofocus = false}) {
    return TvFocusable(
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(60),
      onTap: () => _editing ? _createOrEditProfile(existing: profile) : _selectProfile(profile),
      child: SizedBox(
        width: 110,
        child: Column(children: [
          Stack(children: [
            _avatarBadge(profile),
            if (profile.pin != null)
              Positioned(bottom: 2, right: 6,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.lock, color: Colors.white70, size: 13),
                )),
            if (_editing)
              Positioned.fill(child: DecoratedBox(
                decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                child: const Center(child: Icon(Icons.edit, color: Colors.white, size: 28)),
              )),
          ]),
          const SizedBox(height: 10),
          Text(profile.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _addTile({bool autofocus = false}) {
    return TvFocusable(
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(60),
      onTap: () => _createOrEditProfile(),
      child: SizedBox(
        width: 110,
        child: Column(children: [
          Container(
            width: 92, height: 92,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0f1520),
              border: Border.all(color: Colors.white24, width: 1.6),
            ),
            child: const Icon(Icons.add, color: Colors.grey, size: 36),
          ),
          const SizedBox(height: 10),
          const Text('Nieuw profiel', style: TextStyle(color: Colors.grey, fontSize: 14)),
        ]),
      ),
    );
  }
}
