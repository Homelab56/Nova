import 'dart:convert';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

class DebridService {
  static const _base = 'https://api.real-debrid.com/rest/1.0';

  static Future<Map<String, String>> get _headers async => {
    'Authorization': 'Bearer ${await SettingsService.getRdToken()}',
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  static Future<Map?> getUser() async {
    final r = await http.get(Uri.parse('$_base/user'), headers: await _headers);
    if (r.statusCode == 200) return jsonDecode(r.body) as Map;
    return null;
  }

  static Future<bool> testToken(String token) async {
    final r = await http.get(Uri.parse('$_base/user'),
      headers: {'Authorization': 'Bearer $token'});
    return r.statusCode == 200;
  }

  /// Haalt de RD bibliotheek op
  static Future<List> getLibrary() async {
    try {
      final headers = await _headers;
      final r = await http.get(
        Uri.parse('$_base/torrents?limit=100'),
        headers: headers,
      ).timeout(const Duration(seconds: 10));
      
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as List;
        return data.where((t) => t['status'] == 'downloaded').toList();
      }
    } catch (_) {}
    return [];
  }

  /// Checkt of een titel beschikbaar is in de RD bibliotheek
  static Future<bool> checkAvailability(String query) async {
    try {
      final headers = await _headers;
      final r = await http.get(
        Uri.parse('$_base/torrents?limit=100'),
        headers: headers,
      ).timeout(const Duration(seconds: 10));
      
      if (r.statusCode != 200) return false;

      final torrents = jsonDecode(r.body) as List;
      final qLower = query.toLowerCase().replaceAll(':', '').replaceAll('-', '');
      final words = qLower.split(' ').where((w) => w.length >= 2).toList();

      if (words.isEmpty) return false;

      for (final t in torrents) {
        final name = (t['filename'] as String? ?? '').toLowerCase();
        final score = words.where((w) => name.contains(w)).length;
        final minScore = words.length >= 2 ? 2 : 1;
        
        if (score >= minScore && t['status'] == 'downloaded' && (t['links'] as List?)?.isNotEmpty == true) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Zoekt in je RD bibliotheek naar een match op titel
  static Future<String?> findStream(String query) async {
    try {
      final headers = await _headers;

      // Haal bestaande torrents op
      final r = await http.get(
        Uri.parse('$_base/torrents?limit=100'),
        headers: headers,
      ).timeout(const Duration(seconds: 10));
      
      if (r.statusCode != 200) return null;

      final torrents = jsonDecode(r.body) as List;
      final qLower = query.toLowerCase().replaceAll(':', '').replaceAll('-', '');
      final words = qLower.split(' ').where((w) => w.length >= 2).toList();

      if (words.isEmpty) return null;

      // Zoek beste match
      Map? best;
      int bestScore = 0;
      for (final t in torrents) {
        final name = (t['filename'] as String? ?? '').toLowerCase();
        final score = words.where((w) => name.contains(w)).length;
        if (score > bestScore && t['status'] == 'downloaded' && (t['links'] as List?)?.isNotEmpty == true) {
          bestScore = score;
          best = t;
        }
      }

      // Voor kortere queries is score 1 ook prima, zolang het maar de beste is
      final minScore = words.length >= 2 ? 2 : 1;
      if (best == null || bestScore < minScore) return null;

      // Unrestrict de link
      final links = best['links'] as List;
      final unr = await http.post(
        Uri.parse('$_base/unrestrict/link'),
        headers: headers,
        body: {'link': links[0].toString()},
      ).timeout(const Duration(seconds: 10));
      
      if (unr.statusCode == 200) {
        final data = jsonDecode(unr.body);
        return data['download'] as String?;
      }
    } catch (e) {
      print('DebridService error: $e');
    }
    return null;
  }

  /// Voeg een magnet toe en unrestrict direct
  static Future<String?> addMagnetAndStream(String magnet) async {
    final headers = await _headers;

    // Stap 1: magnet toevoegen
    final add = await http.post(Uri.parse('$_base/torrents/addMagnet'), headers: headers, body: {'magnet': magnet});
    if (add.statusCode != 201 && add.statusCode != 200) return null;
    final torrentId = jsonDecode(add.body)['id'] as String;

    // Stap 2: bestanden selecteren
    await http.post(Uri.parse('$_base/torrents/selectFiles/$torrentId'), headers: headers, body: {'files': 'all'});

    // Stap 3: wacht op links
    await Future.delayed(const Duration(seconds: 3));
    final info = await http.get(Uri.parse('$_base/torrents/info/$torrentId'), headers: headers);
    if (info.statusCode != 200) return null;
    final infoData = jsonDecode(info.body);
    final links = infoData['links'] as List?;
    if (links == null || links.isEmpty) return null;

    // Stap 4: unrestrict
    final unr = await http.post(Uri.parse('$_base/unrestrict/link'), headers: headers, body: {'link': links[0].toString()});
    if (unr.statusCode == 200) return jsonDecode(unr.body)['download'] as String?;
    return null;
  }
}
