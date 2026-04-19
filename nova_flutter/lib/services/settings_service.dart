import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const _kTmdb = 'tmdb_key';
  static const _kRd = 'rd_token';
  static const _kBackend = 'backend_url';

  static Future<SharedPreferences> get _prefs async => SharedPreferences.getInstance();

  static Future<String> getTmdbKey() async {
    final p = await _prefs;
    return p.getString(_kTmdb) ?? '';
  }

  static Future<String> getRdToken() async {
    final p = await _prefs;
    return p.getString(_kRd) ?? '';
  }

  static Future<String> getBackendUrl() async {
    final p = await _prefs;
    return p.getString(_kBackend) ?? 'http://localhost:8000';
  }

  static Future<void> setTmdbKey(String v) async {
    final p = await _prefs;
    await p.setString(_kTmdb, v);
  }

  static Future<void> setRdToken(String v) async {
    final p = await _prefs;
    await p.setString(_kRd, v);
  }

  static Future<void> setBackendUrl(String v) async {
    final p = await _prefs;
    await p.setString(_kBackend, v);
  }

  static Future<bool> isConfigured() async {
    final t = await getTmdbKey();
    final r = await getRdToken();
    return t.isNotEmpty && r.isNotEmpty;
  }
}
