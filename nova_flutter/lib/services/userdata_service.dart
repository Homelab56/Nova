import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'profile_service.dart';

class UserDataService {
  static Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  // Alle sleutels hieronder worden per actief profiel apart bijgehouden,
  // zodat elk profiel zijn eigen watchlist/kijkgeschiedenis/rangschikking heeft.
  static String get _ns {
    final id = ProfileService.activeProfileId;
    return id != null ? 'profile_${id}_' : '';
  }

  // --- Watchlist ---
  static Future<List<Map>> getWatchlist() async {
    final p = await _prefs;
    final raw = p.getString('${_ns}watchlist') ?? '[]';
    return (jsonDecode(raw) as List).cast<Map>();
  }

  static Future<void> addToWatchlist(Map item) async {
    final list = await getWatchlist();
    if (!list.any((w) => w['id'] == item['id'])) {
      list.insert(0, item);
      final p = await _prefs;
      await p.setString('${_ns}watchlist', jsonEncode(list));
    }
  }

  static Future<void> removeFromWatchlist(int id) async {
    final list = await getWatchlist();
    list.removeWhere((w) => w['id'] == id);
    final p = await _prefs;
    await p.setString('${_ns}watchlist', jsonEncode(list));
  }

  static Future<bool> isInWatchlist(int id) async {
    final list = await getWatchlist();
    return list.any((w) => w['id'] == id);
  }

  // --- Progress ---
  static Future<List<Map>> getProgress() async {
    final p = await _prefs;
    final raw = p.getString('${_ns}progress') ?? '{}';
    final map = jsonDecode(raw) as Map;
    return map.values.cast<Map>().toList();
  }

  static Future<void> saveProgress(Map item, double currentTime, double duration) async {
    final p = await _prefs;
    final raw = p.getString('${_ns}progress') ?? '{}';
    final map = jsonDecode(raw) as Map;
    map[item['id'].toString()] = {...item, 'current_time': currentTime, 'duration': duration};
    await p.setString('${_ns}progress', jsonEncode(map));
  }

  static Future<Map?> getItemProgress(Object id) async {
    final p = await _prefs;
    final raw = p.getString('${_ns}progress') ?? '{}';
    final map = jsonDecode(raw) as Map;
    return map[id.toString()] as Map?;
  }

  static Future<void> removeProgress(Object id) async {
    final p = await _prefs;
    final raw = p.getString('${_ns}progress') ?? '{}';
    final map = jsonDecode(raw) as Map;
    map.remove(id.toString());
    await p.setString('${_ns}progress', jsonEncode(map));
  }

  // --- Persoonlijke rangschikking (1-3 sterren) ---
  // 1 ster: niet voor mij, sluit dit uit toekomstige ontdek-rijen.
  // 2 sterren: prima, maar niet bijzonder.
  // 3 sterren: top - voedt een "Omdat je hield van ..." aanbevelingsrij.
  static Future<Map<String, dynamic>> getRatings() async {
    final p = await _prefs;
    final raw = p.getString('${_ns}ratings') ?? '{}';
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  static Future<void> setRating(Map item, int stars, {required String mediaType}) async {
    final p = await _prefs;
    final ratings = await getRatings();
    final id = item['id'];
    ratings[id.toString()] = {
      'id': id,
      'stars': stars,
      'media_type': mediaType,
      'title': item['title'] ?? item['name'],
      'poster_path': item['poster_path'],
      'backdrop_path': item['backdrop_path'],
      'rated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await p.setString('${_ns}ratings', jsonEncode(ratings));
  }

  static Future<void> clearRating(Object id) async {
    final p = await _prefs;
    final ratings = await getRatings();
    ratings.remove(id.toString());
    await p.setString('${_ns}ratings', jsonEncode(ratings));
  }

  static Future<int?> getRating(Object id) async {
    final ratings = await getRatings();
    final r = ratings[id.toString()];
    if (r == null) return null;
    return (r['stars'] as num?)?.toInt();
  }
}
