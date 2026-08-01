import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class Profile {
  final String id;
  final String name;
  final String? pin; // 4-cijferige code, null = geen pincode
  final int colorIndex;

  Profile({required this.id, required this.name, this.pin, this.colorIndex = 0});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'pin': pin, 'colorIndex': colorIndex};

  factory Profile.fromJson(Map j) => Profile(
    id: j['id'] as String,
    name: j['name'] as String,
    pin: j['pin'] as String?,
    colorIndex: (j['colorIndex'] as num?)?.toInt() ?? 0,
  );

  Profile copyWith({String? name, String? pin, bool clearPin = false, int? colorIndex}) => Profile(
    id: id,
    name: name ?? this.name,
    pin: clearPin ? null : (pin ?? this.pin),
    colorIndex: colorIndex ?? this.colorIndex,
  );
}

class ProfileService {
  static Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  // Actief profiel voor deze sessie - bewust NIET tussen opstarten bewaard,
  // zodat je (zoals bij Netflix) elke keer dat de app start eerst een
  // profiel moet kiezen.
  static String? activeProfileId;
  static String? activeProfileName;

  static Future<List<Profile>> getProfiles() async {
    final p = await _prefs;
    final raw = p.getString('profiles') ?? '[]';
    return (jsonDecode(raw) as List).map((j) => Profile.fromJson(j as Map)).toList();
  }

  static Future<void> _saveProfiles(List<Profile> profiles) async {
    final p = await _prefs;
    await p.setString('profiles', jsonEncode(profiles.map((e) => e.toJson()).toList()));
  }

  static Future<Profile> createProfile(String name, {String? pin, int colorIndex = 0}) async {
    final profiles = await getProfiles();
    final profile = Profile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      pin: (pin != null && pin.isNotEmpty) ? pin : null,
      colorIndex: colorIndex,
    );
    profiles.add(profile);
    await _saveProfiles(profiles);
    return profile;
  }

  static Future<void> updateProfile(Profile profile) async {
    final profiles = await getProfiles();
    final idx = profiles.indexWhere((p) => p.id == profile.id);
    if (idx != -1) {
      profiles[idx] = profile;
      await _saveProfiles(profiles);
    }
  }

  static Future<void> deleteProfile(String id) async {
    final profiles = await getProfiles();
    profiles.removeWhere((p) => p.id == id);
    await _saveProfiles(profiles);
    final p = await _prefs;
    for (final key in ['watchlist', 'progress', 'ratings']) {
      await p.remove('profile_${id}_$key');
    }
  }

  // Bestaande watchlist/kijkgeschiedenis van vóór profielen bestonden wordt
  // bij het aanmaken van het allereerste profiel overgezet, zodat niemand
  // zijn geschiedenis kwijtraakt door deze update.
  static Future<void> migrateLegacyDataTo(String profileId) async {
    final p = await _prefs;
    for (final key in ['watchlist', 'progress']) {
      final legacy = p.getString(key);
      if (legacy != null) {
        await p.setString('profile_${profileId}_$key', legacy);
        await p.remove(key);
      }
    }
  }
}
