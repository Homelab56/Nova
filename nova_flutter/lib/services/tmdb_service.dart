import 'dart:convert';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

class TmdbService {
  static const _base = 'https://api.themoviedb.org/3';
  static const _lang = 'nl-NL';

  static Future<Map<String, String>> get _params async => {
    'api_key': await SettingsService.getTmdbKey(),
    'language': _lang,
  };

  static Uri _uri(String path, [Map<String, String> extra = const {}]) {
    return Uri.parse('$_base$path');
  }

  static Future<dynamic> _get(String path, [Map<String, dynamic> extra = const {}]) async {
    final key = await SettingsService.getTmdbKey();
    final params = {'api_key': key, 'language': _lang, ...extra.map((k, v) => MapEntry(k, v.toString()))};
    final uri = Uri.parse('$_base$path').replace(queryParameters: params);
    final r = await http.get(uri);
    if (r.statusCode == 200) return jsonDecode(r.body);
    throw Exception('TMDB $path failed: ${r.statusCode}');
  }

  static Future<List> getTrending() async {
    final d = await _get('/trending/all/week');
    return d['results'] as List;
  }

  static Future<List> getPopularMovies({int page = 1}) async {
    final d = await _get('/movie/popular', {'page': page});
    return d['results'] as List;
  }

  static Future<List> getPopularTv({int page = 1}) async {
    final d = await _get('/tv/popular', {'page': page});
    return d['results'] as List;
  }

  static Future<List> getTrendingMovies() async {
    final d = await _get('/trending/movie/week');
    return d['results'] as List;
  }

  static Future<List> getTrendingTv() async {
    final d = await _get('/trending/tv/week');
    return d['results'] as List;
  }

  static Future<List> getTopRatedMovies() async {
    final d = await _get('/movie/top_rated');
    return d['results'] as List;
  }

  static Future<List> getTopRatedTv() async {
    final d = await _get('/tv/top_rated');
    return d['results'] as List;
  }

  static Future<Map<String, dynamic>> searchAll(String q, {int page = 1}) async {
    final d = await _get('/search/multi', {'query': q, 'page': page});
    return {'items': d['results'] as List, 'total_pages': d['total_pages'], 'total_results': d['total_results']};
  }

  static Future<Map<String, dynamic>> discoverGenre(int genreId, String type, {int page = 1}) async {
    final d = await _get('/discover/$type', {'with_genres': genreId, 'sort_by': 'popularity.desc', 'page': page});
    return {'items': d['results'] as List, 'total_pages': d['total_pages'], 'total_results': d['total_results']};
  }

  static Future<Map> getMovieDetail(int id) async => await _get('/movie/$id') as Map;
  static Future<Map> getTvDetail(int id) async => await _get('/tv/$id') as Map;

  static Future<List> getCredits(int id, String type) async {
    final d = await _get('/$type/$id/credits');
    final cast = d['cast'] as List;
    return cast.take(12).toList();
  }

  static Future<List> getSimilar(int id, String type) async {
    final d = await _get('/$type/$id/similar');
    return (d['results'] as List).take(20).toList();
  }

  static Future<Map> getSeason(int id, int season) async {
    return await _get('/tv/$id/season/$season') as Map;
  }

  static Future<bool> testKey(String key) async {
    final uri = Uri.parse('$_base/configuration').replace(queryParameters: {'api_key': key});
    final r = await http.get(uri);
    return r.statusCode == 200;
  }
}
