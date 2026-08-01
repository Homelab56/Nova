import 'api_service.dart';
import 'profile_service.dart';

class UserDataService {
  // Watchlist/kijkgeschiedenis/rangschikking leven nu op de server, per
  // profiel-id - zo delen PC, TV en elk ander toestel dezelfde gegevens
  // i.p.v. dat elk toestel zijn eigen lokale kopie bijhoudt.
  static String get _profileId => ProfileService.activeProfileId ?? '';

  // --- Watchlist ---
  static Future<List<Map>> getWatchlist() async {
    if (_profileId.isEmpty) return [];
    final raw = await ApiService.get('/profiles/$_profileId/watchlist') as List;
    return raw.cast<Map>();
  }

  static Future<void> addToWatchlist(Map item) async {
    if (_profileId.isEmpty) return;
    await ApiService.post('/profiles/$_profileId/watchlist', Map<String, dynamic>.from(item));
  }

  static Future<void> removeFromWatchlist(int id) async {
    if (_profileId.isEmpty) return;
    await ApiService.delete('/profiles/$_profileId/watchlist/$id');
  }

  static Future<bool> isInWatchlist(int id) async {
    final list = await getWatchlist();
    return list.any((w) => w['id'] == id);
  }

  // --- Progress ---
  static Future<List<Map>> getProgress() async {
    if (_profileId.isEmpty) return [];
    final raw = await ApiService.get('/profiles/$_profileId/progress') as List;
    return raw.cast<Map>();
  }

  static Future<void> saveProgress(Map item, double currentTime, double duration) async {
    if (_profileId.isEmpty) return;
    await ApiService.post('/profiles/$_profileId/progress', {
      ...Map<String, dynamic>.from(item),
      'current_time': currentTime,
      'duration': duration,
    });
  }

  static Future<Map?> getItemProgress(Object id) async {
    final list = await getProgress();
    for (final m in list) {
      if (m['id'].toString() == id.toString()) return m;
    }
    return null;
  }

  static Future<void> removeProgress(Object id) async {
    if (_profileId.isEmpty) return;
    await ApiService.delete('/profiles/$_profileId/progress/$id');
  }

  // --- Persoonlijke rangschikking (1-3 sterren) ---
  // 1 ster: niet voor mij, sluit dit uit toekomstige ontdek-rijen.
  // 2 sterren: prima, maar niet bijzonder.
  // 3 sterren: top - voedt een "Omdat je hield van ..." aanbevelingsrij.
  static Future<Map<String, dynamic>> getRatings() async {
    if (_profileId.isEmpty) return {};
    final raw = await ApiService.get('/profiles/$_profileId/ratings') as Map;
    return Map<String, dynamic>.from(raw);
  }

  static Future<void> setRating(Map item, int stars, {required String mediaType}) async {
    if (_profileId.isEmpty) return;
    final id = item['id'];
    await ApiService.post('/profiles/$_profileId/ratings', {
      'id': id,
      'stars': stars,
      'media_type': mediaType,
      'title': item['title'] ?? item['name'],
      'poster_path': item['poster_path'],
      'backdrop_path': item['backdrop_path'],
      'rated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<void> clearRating(Object id) async {
    if (_profileId.isEmpty) return;
    await ApiService.delete('/profiles/$_profileId/ratings/$id');
  }

  static Future<int?> getRating(Object id) async {
    final ratings = await getRatings();
    final r = ratings[id.toString()];
    if (r == null) return null;
    return (r['stars'] as num?)?.toInt();
  }
}
