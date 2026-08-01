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

const _avatarColors = [
  Color(0xFF00b4d8), Color(0xFFe63946), Color(0xFFf4a261),
  Color(0xFF2a9d8f), Color(0xFF9b5de5), Color(0xFFffb703),
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
    int colorIndex = existing?.colorIndex ?? (_profiles.length % _avatarColors.length);

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
              Wrap(spacing: 10, children: [
                for (var i = 0; i < _avatarColors.length; i++)
                  GestureDetector(
                    onTap: () => setDialogState(() => colorIndex = i),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: _avatarColors[i],
                      child: colorIndex == i ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                    ),
                  ),
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
          : Center(
              // Bij het grote logo past de inhoud niet altijd op kleinere
              // vensters - scrollbaar i.p.v. te laten overlopen.
              child: SingleChildScrollView(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                // Het bestand heeft best wat doorzichtige ruimte rond het
                // eigenlijke beeldmerk, dus een royale hoogte om het logo zelf
                // écht groot te doen ogen.
                Image.asset('assets/logo.png', height: 680),
                const SizedBox(height: 4),
                const Text('Wie kijkt er?', style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800)),
                const SizedBox(height: 48),
                Wrap(
                  spacing: 24, runSpacing: 24, alignment: WrapAlignment.center,
                  children: [
                    for (final profile in _profiles) _profileTile(profile),
                    _addTile(),
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

  Widget _profileTile(Profile profile) {
    final color = _avatarColors[profile.colorIndex % _avatarColors.length];
    return GestureDetector(
      onTap: () => _editing ? _createOrEditProfile(existing: profile) : _selectProfile(profile),
      child: SizedBox(
        width: 110,
        child: Column(children: [
          Stack(children: [
            Container(
              width: 90, height: 90,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
              child: Center(child: Text(profile.name.isNotEmpty ? profile.name[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w700))),
            ),
            if (profile.pin != null)
              const Positioned(bottom: 4, right: 4, child: Icon(Icons.lock, color: Colors.white70, size: 16)),
            if (_editing)
              Positioned.fill(child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(16)),
                child: const Center(child: Icon(Icons.edit, color: Colors.white, size: 28)),
              )),
          ]),
          const SizedBox(height: 8),
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
            width: 90, height: 90,
            decoration: BoxDecoration(
              color: const Color(0xFF0f1520),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white24),
            ),
            child: const Icon(Icons.add, color: Colors.grey, size: 36),
          ),
          const SizedBox(height: 8),
          const Text('Nieuw profiel', style: TextStyle(color: Colors.grey, fontSize: 14)),
        ]),
      ),
    );
  }
}
