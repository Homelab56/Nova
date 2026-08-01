import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

class Profile {
  final String id;
  final String name;
  final String? pin; // 4-cijferige code, null = geen pincode
  final int colorIndex;
  final String? icon; // sleutel in _avatarIcons, null = toon letter i.p.v. icoon

  Profile({required this.id, required this.name, this.pin, this.colorIndex = 0, this.icon});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'pin': pin, 'colorIndex': colorIndex, 'icon': icon};

  factory Profile.fromJson(Map j) => Profile(
    id: j['id'].toString(),
    name: j['name'] as String,
    pin: j['pin'] as String?,
    colorIndex: (j['colorIndex'] as num?)?.toInt() ?? 0,
    icon: j['icon'] as String?,
  );

  Profile copyWith({String? name, String? pin, bool clearPin = false, int? colorIndex, String? icon, bool clearIcon = false}) => Profile(
    id: id,
    name: name ?? this.name,
    pin: clearPin ? null : (pin ?? this.pin),
    colorIndex: colorIndex ?? this.colorIndex,
    icon: clearIcon ? null : (icon ?? this.icon),
  );
}

class ProfileService {
  // Actief profiel voor deze sessie - bewust NIET tussen opstarten bewaard,
  // zodat je (zoals bij Netflix) elke keer dat de app start eerst een
  // profiel moet kiezen.
  static String? activeProfileId;
  static String? activeProfileName;

  // Profielen (en hun watchlist/kijkgeschiedenis/rangschikking) leven nu op
  // de server, niet meer lokaal op het toestel - zo delen PC, TV en elk
  // ander toestel dezelfde profielen i.p.v. dat elk toestel zijn eigen lege
  // set heeft.
  static Future<List<Profile>> getProfiles() async {
    final raw = await ApiService.get('/profiles/') as List;
    return raw.map((j) => Profile.fromJson(j as Map)).toList();
  }

  static Future<Profile> createProfile(String name, {String? pin, int colorIndex = 0, String? icon, String? id}) async {
    final j = await ApiService.post('/profiles/', {
      if (id != null) 'id': id,
      'name': name,
      'pin': (pin != null && pin.isNotEmpty) ? pin : null,
      'colorIndex': colorIndex,
      'icon': icon,
    }) as Map;
    return Profile.fromJson(j);
  }

  static Future<void> updateProfile(Profile profile) async {
    await ApiService.put('/profiles/${profile.id}', {
      'name': profile.name, 'pin': profile.pin, 'colorIndex': profile.colorIndex, 'icon': profile.icon,
    });
  }

  static Future<void> deleteProfile(String id) async {
    await ApiService.delete('/profiles/$id');
  }

  // Eenmalige overzet: dit toestel (typisch de PC waar profielen voor het
  // eerst gemaakt zijn) had voorheen alles lokaal opgeslagen. Als de server
  // nog leeg is maar dit toestel wel lokale profielen heeft, zetten we die
  // eenmalig over zodat niemand zijn profielen/watchlist/geschiedenis kwijt-
  // raakt door deze overstap naar gedeelde server-opslag.
  static Future<void> migrateLocalDataToServerIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('migrated_profiles_to_server') == true) return;

    try {
      final serverProfiles = await getProfiles();
      if (serverProfiles.isNotEmpty) {
        await prefs.setBool('migrated_profiles_to_server', true);
        return;
      }

      final raw = prefs.getString('profiles');
      if (raw == null) {
        await prefs.setBool('migrated_profiles_to_server', true);
        return;
      }

      final localProfiles = (jsonDecode(raw) as List).map((j) => Profile.fromJson(j as Map)).toList();
      for (final p in localProfiles) {
        await createProfile(p.name, pin: p.pin, colorIndex: p.colorIndex, icon: p.icon, id: p.id);

        final wlRaw = prefs.getString('profile_${p.id}_watchlist');
        if (wlRaw != null) {
          final list = (jsonDecode(wlRaw) as List).cast<Map>().toList().reversed;
          for (final item in list) {
            await ApiService.post('/profiles/${p.id}/watchlist', Map<String, dynamic>.from(item));
          }
        }

        final progRaw = prefs.getString('profile_${p.id}_progress');
        if (progRaw != null) {
          final map = jsonDecode(progRaw) as Map;
          for (final v in map.values) {
            await ApiService.post('/profiles/${p.id}/progress', Map<String, dynamic>.from(v as Map));
          }
        }

        final ratRaw = prefs.getString('profile_${p.id}_ratings');
        if (ratRaw != null) {
          final map = jsonDecode(ratRaw) as Map;
          for (final v in map.values) {
            await ApiService.post('/profiles/${p.id}/ratings', Map<String, dynamic>.from(v as Map));
          }
        }
      }
      await prefs.setBool('migrated_profiles_to_server', true);
    } catch (e) {
      // Geen server bereikbaar bij opstarten: gewoon niets doen, we proberen
      // het opnieuw bij de volgende keer dat het profielscherm opent.
    }
  }
}
