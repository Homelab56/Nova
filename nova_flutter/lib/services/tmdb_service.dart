import 'api_service.dart';

class TmdbService {
  static Future<List> getTrending() async {
    return await ApiService.get('/search/trending') as List;
  }

  static Future<List> getPopularMovies({int page = 1}) async {
    return await ApiService.get('/search/popular/movies') as List;
  }

  static Future<List> getPopularTv({int page = 1}) async {
    return await ApiService.get('/search/popular/tv') as List;
  }

  static Future<List> getTrendingMovies() async {
    return await ApiService.get('/search/trending/movies') as List;
  }

  static Future<List> getTrendingTv() async {
    return await ApiService.get('/search/trending/tv') as List;
  }

  static Future<List> getTopRatedMovies() async {
    return await ApiService.get('/search/toprated/movies') as List;
  }

  static Future<List> getTopRatedTv() async {
    return await ApiService.get('/search/toprated/tv') as List;
  }

  static Future<Map<String, dynamic>> searchAll(String q, {int page = 1}) async {
    final movie = await ApiService.get('/search/movie?q=${Uri.encodeComponent(q)}&page=$page') as Map;
    final tv = await ApiService.get('/search/tv?q=${Uri.encodeComponent(q)}&page=$page') as Map;
    final items = <dynamic>[
      ...((movie['items'] as List?) ?? const []),
      ...((tv['items'] as List?) ?? const []),
    ];
    items.sort((a, b) {
      final ap = (a is Map ? (a['popularity'] as num?) : null) ?? 0;
      final bp = (b is Map ? (b['popularity'] as num?) : null) ?? 0;
      return bp.compareTo(ap);
    });
    final totalPagesMovie = (movie['total_pages'] as int?) ?? 1;
    final totalPagesTv = (tv['total_pages'] as int?) ?? 1;
    final totalResultsMovie = (movie['total_results'] as int?) ?? 0;
    final totalResultsTv = (tv['total_results'] as int?) ?? 0;
    return {
      'items': items,
      'total_pages': totalPagesMovie > totalPagesTv ? totalPagesMovie : totalPagesTv,
      'total_results': totalResultsMovie + totalResultsTv,
    };
  }

  static Future<Map<String, dynamic>> discoverGenre(int genreId, String type, {int page = 1}) async {
    final d = await ApiService.get('/search/genre/$genreId?type=$type&page=$page') as Map;
    return {
      'items': (d['items'] as List?) ?? const [],
      'total_pages': (d['total_pages'] as int?) ?? 1,
      'total_results': (d['total_results'] as int?) ?? 0,
    };
  }

  static Future<Map> getMovieDetail(int id) async => await ApiService.get('/search/movie/$id') as Map;
  static Future<Map> getTvDetail(int id) async => await ApiService.get('/search/tv/$id') as Map;

  static Future<List> getCredits(int id, String type) async {
    return await ApiService.get('/search/$type/$id/credits') as List;
  }

  static Future<List> getSimilar(int id, String type) async {
    return await ApiService.get('/search/$type/$id/similar') as List;
  }

  static Future<Map> getSeason(int id, int season) async {
    return await ApiService.get('/search/tv/$id/season/$season') as Map;
  }

  static Future<bool> testKey(String key) async {
    return true;
  }
}
