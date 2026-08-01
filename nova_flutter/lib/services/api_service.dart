import 'dart:convert';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

// Dunne client voor de eigen backend (momenteel enkel gebruikt voor de
// profielen-API) - gebruikt bewust dezelfde adresresolutie en met/zonder
// "/api"-prefix-aanpak als TmdbService, zodat dit werkt ongeacht hoe de
// server precies voor je opgezet is.
class ApiService {
  static Future<String> _base() async {
    final raw = (await SettingsService.getBackendUrl()).trim();
    return raw.isEmpty ? 'http://localhost:8000' : raw.replaceAll(RegExp(r'/$'), '');
  }

  static List<String> _candidatePaths(String path) =>
      path.startsWith('/api') ? [path, path.replaceFirst('/api', '')] : [path, '/api$path'];

  static Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final base = await _base();
    String? lastError;
    for (final p in _candidatePaths(path)) {
      try {
        final uri = Uri.parse('$base$p');
        final headers = {'Content-Type': 'application/json'};
        final http.Response r;
        switch (method) {
          case 'GET':
            r = await http.get(uri, headers: headers).timeout(const Duration(seconds: 12));
            break;
          case 'POST':
            r = await http.post(uri, headers: headers, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 12));
            break;
          case 'PUT':
            r = await http.put(uri, headers: headers, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 12));
            break;
          case 'DELETE':
            r = await http.delete(uri, headers: headers).timeout(const Duration(seconds: 12));
            break;
          default:
            throw ArgumentError('Onbekende methode: $method');
        }
        if (r.statusCode == 200) return r.body.isEmpty ? null : jsonDecode(r.body);
        lastError = '$method $p failed: ${r.statusCode}';
      } catch (e) {
        lastError = '$method $p failed: $e';
        continue;
      }
    }
    throw Exception(lastError ?? '$method $path failed');
  }

  static Future<dynamic> get(String path) => _request('GET', path);
  static Future<dynamic> post(String path, Map<String, dynamic> body) => _request('POST', path, body: body);
  static Future<dynamic> put(String path, Map<String, dynamic> body) => _request('PUT', path, body: body);
  static Future<dynamic> delete(String path) => _request('DELETE', path);
}
