import 'dart:math';
import 'package:flutter/material.dart';
import '../services/profile_service.dart';
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

// Gradient-paren blijven bewust binnen dezelfde familie als het logo en de
// rest van de app (blauw/teal/cyaan, met goud en zilver als accent) i.p.v.
// een regenboog van losse hues (paars/roze/rood/groen) die niet aansluiten
// bij het metallic blauw-goud kleurenschema.
const _avatarGradients = <List<Color>>[
  [Color(0xFF00b4d8), Color(0xFF0077b6)],
  [Color(0xFF48cae4), Color(0xFF0096c7)],
  [Color(0xFF3a86ff), Color(0xFF023e8a)],
  [Color(0xFF90e0ef), Color(0xFF00b4d8)],
  [Color(0xFF457b9d), Color(0xFF1d3557)],
  [Color(0xFF2a9d8f), Color(0xFF264653)],
  [Color(0xFFffd166), Color(0xFFe09f3e)],
  [Color(0xFFf4a261), Color(0xFFe76f51)],
  [Color(0xFFadb5bd), Color(0xFF495057)],
  [Color(0xFF8ecae6), Color(0xFF219ebc)],
];

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<Profile> _profiles = [];
  bool _loading = true;
  bool _editing = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final profiles = await ProfileService.getProfiles();
    if (!mounted) return;
    setState(() { _profiles = profiles; _loading = false; });
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
      .map((p) => p.colorIndex % _avatarGradients.length)
      .toSet();
    int colorIndex = existing?.colorIndex ??
      List.generate(_avatarGradients.length, (i) => i).firstWhere(
        (i) => !usedIndices.contains(i),
        orElse: () => _profiles.length % _avatarGradients.length,
      );

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
                for (var i = 0; i < _avatarGradients.length; i++)
                  Builder(builder: (context) {
                    final taken = usedIndices.contains(i);
                    return GestureDetector(
                      onTap: taken ? null : () => setDialogState(() => colorIndex = i),
                      child: Opacity(
                        opacity: taken ? 0.25 : 1,
                        child: Container(
                          width: 34, height: 34,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft, end: Alignment.bottomRight,
                              colors: _avatarGradients[i],
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
      final wasFirstProfile = _profiles.isEmpty;
      final profile = await ProfileService.createProfile(name, pin: pin, colorIndex: colorIndex);
      if (wasFirstProfile) {
        await ProfileService.migrateLegacyDataTo(profile.id);
      }
    } else {
      await ProfileService.updateProfile(existing.copyWith(
        name: name, pin: pin.isEmpty ? null : pin, clearPin: pin.isEmpty, colorIndex: colorIndex));
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
          // LayoutBuilder + minHeight i.p.v. gewoon Center: een Column
          // binnenin een SingleChildScrollView krijgt onbegrensde hoogte,
          // waardoor mainAxisAlignment/Center genegeerd wordt en alles naar
          // boven schuift zodra het scrollbaar is - dit dwingt "centreer
          // wanneer het past, scroll wanneer het niet past" af.
          : LayoutBuilder(builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      // Het bestand heeft best wat doorzichtige ruimte rond het
                      // eigenlijke beeldmerk, dus een royale hoogte om het logo
                      // zelf écht groot te doen ogen.
                      Image.asset('assets/logo.png', height: 600),
                      const SizedBox(height: 4),
                      const Text('Wie kijkt er?', style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 48),
                      Wrap(
                        spacing: 24, runSpacing: 24, alignment: WrapAlignment.center,
                        children: [
                          for (final profile in _profiles) _profileTile(profile),
                          // Ook tonen als er nog geen enkel profiel is, anders
                          // is er op een verse installatie geen zichtbare
                          // manier om het allereerste profiel aan te maken.
                          if (_editing || _profiles.isEmpty) _addTile(),
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
    final grad = _avatarGradients[profile.colorIndex % _avatarGradients.length];
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
          child: Text(
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

  Widget _profileTile(Profile profile) {
    return GestureDetector(
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

  Widget _addTile() {
    return GestureDetector(
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
