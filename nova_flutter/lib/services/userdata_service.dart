import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class UserDataService {
  static Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  // --- Watchlist ---
  static Future<List<Map>> getWatchlist() async {
    final p = await _prefs;
    final raw = p.getString('watchlist') ?? '[]';
    return (jsonDecode(raw) as List).cast<Map>();
  }

  static Future<void> addToWatchlist(Map item) async {
    final list = await getWatchlist();
    if (!list.any((w) => w['id'] == item['id'])) {
      list.insert(0, item);
      final p = await _prefs;
      await p.setString('watchlist', jsonEncode(list));
    }
  }

  static Future<void> removeFromWatchlist(int id) async {
    final list = await getWatchlist();
    list.removeWhere((w) => w['id'] == id);
    final p = await _prefs;
    await p.setString('watchlist', jsonEncode(list));
  }

  static Future<bool> isInWatchlist(int id) async {
    final list = await getWatchlist();
    return list.any((w) => w['id'] == id);
  }

  // --- Progress ---
  static Future<List<Map>> getProgress() async {
    final p = await _prefs;
    final raw = p.getString('progress') ?? '{}';
    final map = jsonDecode(raw) as Map;
    return map.values.cast<Map>().toList();
  }

  static Future<void> saveProgress(Map item, double currentTime, double duration) async {
    final p = await _prefs;
    final raw = p.getString('progress') ?? '{}';
    final map = jsonDecode(raw) as Map;
    map[item['id'].toString()] = {...item, 'current_time': currentTime, 'duration': duration};
    await p.setString('progress', jsonEncode(map));
  }

  static Future<Map?> getItemProgress(int id) async {
    final p = await _prefs;
    final raw = p.getString('progress') ?? '{}';
    final map = jsonDecode(raw) as Map;
    return map[id.toString()] as Map?;
  }
}
