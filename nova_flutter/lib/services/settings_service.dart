import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SettingsService {
  static const _storage = FlutterSecureStorage();

  static Future<String> getTmdbKey() async => await _storage.read(key: 'tmdb_key') ?? '';
  static Future<String> getRdToken() async => await _storage.read(key: 'rd_token') ?? '';
  static Future<String> getBackendUrl() async => await _storage.read(key: 'backend_url') ?? 'http://localhost:8000';

  static Future<void> setTmdbKey(String v) => _storage.write(key: 'tmdb_key', value: v);
  static Future<void> setRdToken(String v) => _storage.write(key: 'rd_token', value: v);
  static Future<void> setBackendUrl(String v) => _storage.write(key: 'backend_url', value: v);

  static Future<bool> isConfigured() async {
    final t = await getTmdbKey();
    final r = await getRdToken();
    return t.isNotEmpty && r.isNotEmpty;
  }
}
