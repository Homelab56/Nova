import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SettingsService {
  static const _storage = FlutterSecureStorage();

  static Future<String> getTmdbKey() async => await _storage.read(key: 'tmdb_key') ?? '';
  static Future<String> getRdToken() async => await _storage.read(key: 'rd_token') ?? '';
  static Future<String> getBackendUrl() async {
    final backend = await _storage.read(key: 'backend_url');
    if (backend != null && backend.trim().isNotEmpty) return backend.trim();
    final legacy = await _storage.read(key: 'server_url');
    if (legacy != null && legacy.trim().isNotEmpty) return legacy.trim();
    return '';
  }

  static Future<void> setTmdbKey(String v) => _storage.write(key: 'tmdb_key', value: v);
  static Future<void> setRdToken(String v) => _storage.write(key: 'rd_token', value: v);
  static Future<void> setBackendUrl(String v) async {
    final cleaned = v.trim();
    await _storage.write(key: 'backend_url', value: cleaned);
    await _storage.write(key: 'server_url', value: cleaned);
  }

  static Future<bool> isConfigured() async {
    final url = await getBackendUrl();
    return url.trim().isNotEmpty;
  }
}
