import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiService {
  static const _storage = FlutterSecureStorage();

  // Verander dit naar het IP van je Debian server
  static const String _defaultBase = 'http://192.168.1.100:8005';

  static Future<String> get baseUrl async {
    final saved = await _storage.read(key: 'server_url');
    return saved ?? _defaultBase;
  }

  static Future<Map<String, String>> get _headers async => {
    'Content-Type': 'application/json',
  };

  static Future<dynamic> get(String path) async {
    final base = await baseUrl;
    final r = await http.get(Uri.parse('$base$path'), headers: await _headers);
    if (r.statusCode == 200) return jsonDecode(r.body);
    throw Exception('GET $path failed: ${r.statusCode}');
  }

  static Future<dynamic> post(String path, Map<String, dynamic> body) async {
    final base = await baseUrl;
    final r = await http.post(
      Uri.parse('$base$path'),
      headers: await _headers,
      body: jsonEncode(body),
    );
    if (r.statusCode == 200) return jsonDecode(r.body);
    throw Exception('POST $path failed: ${r.statusCode}');
  }

  static Future<dynamic> delete(String path) async {
    final base = await baseUrl;
    final r = await http.delete(Uri.parse('$base$path'), headers: await _headers);
    if (r.statusCode == 200) return jsonDecode(r.body);
    throw Exception('DELETE $path failed: ${r.statusCode}');
  }

  // --- TMDB ---
  static Future<List> getTrending() async => await get('/search/trending') as List;
  static Future<List> getPopularMovies() async => await get('/search/popular/movies') as List;
  static Future<List> getPopularTv() async => await get('/search/popular/tv') as List;
  static Future<List> searchMovies(String q, {int page = 1}) async {
    final data = await get('/search/movie?q=${Uri.encodeComponent(q)}&page=$page');
    return data['items'] as List;
  }
  static Future<List> searchTv(String q, {int page = 1}) async {
    final data = await get('/search/tv?q=${Uri.encodeComponent(q)}&page=$page');
    return data['items'] as List;
  }
  static Future<Map> getMovieDetail(int id) async => await get('/search/movie/$id') as Map;
  static Future<Map> getTvDetail(int id) async => await get('/search/tv/$id') as Map;
  static Future<List> getMovieCredits(int id) async => await get('/search/movie/$id/credits') as List;
  static Future<List> getTvCredits(int id) async => await get('/search/tv/$id/credits') as List;
  static Future<List> getSimilarMovies(int id) async => await get('/search/movie/$id/similar') as List;
  static Future<List> getSimilarTv(int id) async => await get('/search/tv/$id/similar') as List;
  static Future<Map> getSeason(int id, int season) async => await get('/search/tv/$id/season/$season') as Map;
  static Future<List> getGenre(int genreId, String type, {int page = 1}) async {
    final data = await get('/search/genre/$genreId?type=$type&page=$page');
    return data['items'] as List;
  }

  // --- Debrid ---
  static Future<String?> getStreamUrl(String query) async {
    try {
      final data = await get('/debrid/search?q=${Uri.encodeComponent(query)}');
      return data['stream_url'] as String?;
    } catch (_) { return null; }
  }

  // --- Watchlist ---
  static Future<List> getWatchlist() async => await get('/user/watchlist') as List;
  static Future<void> addToWatchlist(Map<String, dynamic> item) async => await post('/user/watchlist', item);
  static Future<void> removeFromWatchlist(int id) async => await delete('/user/watchlist/$id');

  // --- Progress ---
  static Future<List> getProgress() async => await get('/user/progress') as List;
  static Future<void> saveProgress(Map<String, dynamic> item) async => await post('/user/progress', item);

  // --- Settings ---
  static Future<Map> getSettings() async => await get('/settings/') as Map;
  static Future<void> saveSettings(Map<String, dynamic> s) async => await post('/settings/', s);
  static Future<Map> testTmdb() async => await get('/settings/test/tmdb') as Map;
  static Future<Map> testRd() async => await get('/settings/test/rd') as Map;
}
