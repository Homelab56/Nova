import 'dart:convert';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

class TmdbService {
  static List _extractItems(dynamic data) {
    if (data is List) return data;
    if (data is Map && data['items'] is List) return data['items'] as List;
    if (data is Map && data['results'] is List) return data['results'] as List;
    return const [];
  }

  static Future<String> _backendBase() async {
    final raw = (await SettingsService.getBackendUrl()).trim();
    return raw.isEmpty ? 'http://localhost:8000' : raw.replaceAll(RegExp(r'/$'), '');
  }

  static Future<dynamic> _backendGet(String path, [Map<String, dynamic> query = const {}]) async {
    final base = await _backendBase();
    final uri = Uri.parse('$base$path').replace(
      queryParameters: query.map((k, v) => MapEntry(k, v.toString())),
    );
    final r = await http.get(uri).timeout(const Duration(seconds: 12));
    if (r.statusCode == 200) return jsonDecode(r.body);
    throw Exception('Backend $path failed: ${r.statusCode}');
  }

  static Future<List> getTrending() async {
    final d = await _backendGet('/api/search/trending');
    return _extractItems(d);
  }

  static Future<List> getPopularMovies({int page = 1}) async {
    final d = await _backendGet('/api/search/popular/movies', {'page': page});
    return _extractItems(d);
  }

  static Future<List> getPopularTv({int page = 1}) async {
    final d = await _backendGet('/api/search/popular/tv', {'page': page});
    return _extractItems(d);
  }

  static Future<List> getTrendingMovies() async {
    final d = await _backendGet('/api/search/trending/movies');
    return _extractItems(d);
  }

  static Future<List> getTrendingTv() async {
    final d = await _backendGet('/api/search/trending/tv');
    return _extractItems(d);
  }

  static Future<List> getTopRatedMovies() async {
    final d = await _backendGet('/api/search/toprated/movies');
    return _extractItems(d);
  }

  static Future<List> getTopRatedTv() async {
    final d = await _backendGet('/api/search/toprated/tv');
    return _extractItems(d);
  }

  static Future<Map<String, dynamic>> searchAll(String q, {int page = 1}) async {
    final movies = await _backendGet('/api/search/movie', {'q': q, 'page': page});
    final tv = await _backendGet('/api/search/tv', {'q': q, 'page': page});
    final items = [..._extractItems(movies), ..._extractItems(tv)];
    final totalPages = ((movies is Map ? (movies['total_pages'] as num?) : null) ?? 1);
    final totalResults =
        ((movies is Map ? (movies['total_results'] as num?) : null) ?? 0) +
        ((tv is Map ? (tv['total_results'] as num?) : null) ?? 0);
    return {'items': items, 'total_pages': totalPages, 'total_results': totalResults};
  }

  static Future<Map<String, dynamic>> discoverGenre(int genreId, String type, {int page = 1}) async {
    final d = await _backendGet('/api/search/genre/$genreId', {'type': type, 'page': page});
    return {
      'items': _extractItems(d),
      'total_pages': (d is Map ? d['total_pages'] : 1),
      'total_results': (d is Map ? d['total_results'] : 0),
    };
  }

  static Future<Map> getMovieDetail(int id) async => await _backendGet('/api/search/movie/$id') as Map;
  static Future<Map> getTvDetail(int id) async => await _backendGet('/api/search/tv/$id') as Map;

  static Future<List> getCredits(int id, String type) async {
    final d = await _backendGet('/api/search/$type/$id/credits');
    final cast = (d is Map ? (d['cast'] as List?) : null) ?? const [];
    return cast.take(12).toList();
  }

  static Future<List> getSimilar(int id, String type) async {
    final d = await _backendGet('/api/search/$type/$id/similar');
    final items = _extractItems(d);
    return items.take(20).toList();
  }

  static Future<Map> getSeason(int id, int season) async {
    return await _backendGet('/api/search/tv/$id/season/$season') as Map;
  }

  static Future<bool> testKey(String key) async {
    if (key.trim().isEmpty) return false;
    final uri = Uri.parse('https://api.themoviedb.org/3/configuration')
        .replace(queryParameters: {'api_key': key.trim()});
    final r = await http.get(uri).timeout(const Duration(seconds: 8));
    return r.statusCode == 200;
  }
}
