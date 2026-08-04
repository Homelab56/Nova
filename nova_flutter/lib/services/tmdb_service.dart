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
    
    // We proberen het pad met en zonder /api prefix
    final paths = path.startsWith('/api') ? [path, path.replaceFirst('/api', '')] : [path, '/api$path'];
    
    String? lastError;
    for (final p in paths) {
      try {
        final uri = Uri.parse('$base$p').replace(
          queryParameters: query.map((k, v) => MapEntry(k, v.toString())),
        );
        final r = await http.get(uri).timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) return jsonDecode(r.body);
        lastError = 'Backend $p failed: ${r.statusCode}';
      } catch (e) {
        lastError = 'Connection to $p failed: $e';
        continue;
      }
    }
    throw Exception(lastError ?? 'Backend $path failed');
  }

  static Future<List> getTrending() async {
    final d = await _backendGet('/api/search/trending');
    return _extractItems(d);
  }

  // Generieke, gepagineerde variant voor "Meer bekijken"-schermen - alle
  // /api/search categorie-endpoints (trending/popular/toprated/kids) geven
  // dezelfde {items, page, total_pages, total_results}-vorm terug.
  static Future<Map<String, dynamic>> getPaged(String path, {int page = 1}) async {
    final d = await _backendGet(path, {'page': page});
    return {
      'items': _extractItems(d),
      'total_pages': (d is Map ? (d['total_pages'] as num?)?.toInt() : null) ?? 1,
      'total_results': (d is Map ? (d['total_results'] as num?)?.toInt() : null) ?? 0,
    };
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
    if (type == 'all') {
      final movies = await _backendGet('/api/search/genre/$genreId', {'type': 'movie', 'page': page});
      final tv = await _backendGet('/api/search/genre/$genreId', {'type': 'tv', 'page': page});
      
      final items = [..._extractItems(movies), ..._extractItems(tv)];
      // Sorteer op populariteit aangezien we twee lijsten mergen
      items.sort((a, b) => ((b['popularity'] ?? 0) as num).compareTo((a['popularity'] ?? 0) as num));
      
      return {
        'items': items,
        'total_pages': (movies['total_pages'] as int? ?? 1),
        'total_results': (movies['total_results'] as int? ?? 0) + (tv['total_results'] as int? ?? 0),
      };
    }
    
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
    // De backend geeft de cast-lijst al direct terug (niet gewrapt in
    // {"cast": [...]}) - eerder werd hier altijd stilzwijgend een lege
    // lijst teruggegeven omdat dit als Map i.p.v. List werd uitgepakt.
    final d = await _backendGet('/api/search/$type/$id/credits');
    return _extractItems(d).take(12).toList();
  }

  static Future<List> getSimilar(int id, String type) async {
    final d = await _backendGet('/api/search/$type/$id/similar');
    final items = _extractItems(d);
    return items.take(20).toList();
  }

  static Future<Map> getSeason(int id, int season) async {
    return await _backendGet('/api/search/tv/$id/season/$season') as Map;
  }

  static Future<List> getKidsMovies() async {
    final d = await _backendGet('/api/search/kids/movies');
    return _extractItems(d);
  }

  static Future<List> getKidsTv() async {
    final d = await _backendGet('/api/search/kids/tv');
    return _extractItems(d);
  }

  static Future<List> getKidsMoviesTopRated() async => _extractItems(await _backendGet('/api/search/kids/movies/toprated'));
  static Future<List> getKidsMoviesNewest() async => _extractItems(await _backendGet('/api/search/kids/movies/newest'));
  static Future<List> getKidsTvTopRated() async => _extractItems(await _backendGet('/api/search/kids/tv/toprated'));
  static Future<List> getKidsTvNewest() async => _extractItems(await _backendGet('/api/search/kids/tv/newest'));

  // Voor extra ontdek-rijen (genres) op Home/Films/Series - geeft enkel de
  // itemlijst terug, geen paginering nodig zoals bij het volledige genre-scherm.
  static Future<List> getGenreItems(int genreId, String type) async {
    final data = await discoverGenre(genreId, type);
    return data['items'] as List;
  }

  static Future<List> searchPeople(String q, {int page = 1}) async {
    final d = await _backendGet('/api/search/person', {'q': q, 'page': page});
    return _extractItems(d);
  }

  static Future<Map> getPerson(int id) async => await _backendGet('/api/search/person/$id') as Map;

  static Future<List> getPersonCredits(int id) async {
    final d = await _backendGet('/api/search/person/$id/credits');
    return _extractItems(d);
  }

  static Future<bool> testKey(String key) async {
    if (key.trim().isEmpty) return false;
    final uri = Uri.parse('https://api.themoviedb.org/3/configuration')
        .replace(queryParameters: {'api_key': key.trim()});
    final r = await http.get(uri).timeout(const Duration(seconds: 8));
    return r.statusCode == 200;
  }
}
