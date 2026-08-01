import 'package:flutter/material.dart';
import '../widgets/nova_image.dart';
import '../widgets/tv_focusable.dart';
import '../services/userdata_service.dart';
import 'watch_screen.dart';

const tmdbBackdrop = 'https://image.tmdb.org/t/p/w780';
const tmdbPoster = 'https://image.tmdb.org/t/p/w342';

class WatchlistScreen extends StatefulWidget {
  const WatchlistScreen({super.key});
  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  List<Map> _list = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final data = await UserDataService.getWatchlist();
    setState(() => _list = data);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080c14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f1520), foregroundColor: Colors.white,
        title: Text('Mijn Watchlist${_list.isNotEmpty ? " (${_list.length})" : ""}'),
      ),
      body: _list.isEmpty
        ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.bookmark_outline, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('Je watchlist is leeg', style: TextStyle(color: Colors.grey, fontSize: 16)),
            SizedBox(height: 8),
            Text('Druk op + bij een film of serie', style: TextStyle(color: Colors.grey, fontSize: 13)),
          ]))
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (_, i) => _buildRow(_list[i]),
          ),
    );
  }

  Widget _buildRow(Map item) {
    final backdrop = item['backdrop_path'] as String?;
    final poster = item['poster_path'] as String?;
    final title = item['title'] ?? item['name'] ?? '';
    final overview = (item['overview'] as String?) ?? '';
    final rating = (item['vote_average'] as num?)?.toStringAsFixed(1);
    final date = ((item['release_date'] ?? item['first_air_date'] ?? '') as String);
    final year = date.length >= 4 ? date.substring(0, 4) : '';
    final isMovie = item['title'] != null;

    return TvFocusable(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => WatchScreen(media: Map<String, dynamic>.from(item)))).then((_) => _load()),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0f1520),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
            child: backdrop != null
              ? NovaImage(path: backdrop, width: 220, height: 140, baseUrl: tmdbBackdrop, fit: BoxFit.cover)
              : (poster != null
                ? NovaImage(path: poster, width: 220, height: 140, baseUrl: tmdbPoster, fit: BoxFit.cover)
                : Container(width: 220, height: 140, color: const Color(0xFF080c14),
                    child: const Icon(Icons.movie_outlined, color: Colors.grey, size: 32))),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white)),
                  ),
                  GestureDetector(
                    onTap: () async {
                      await UserDataService.removeFromWatchlist(item['id'] as int);
                      _load();
                    },
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
                      child: const Icon(Icons.close, size: 16, color: Colors.white70),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Icon(isMovie ? Icons.movie_outlined : Icons.tv_outlined, size: 14, color: const Color(0xFF00b4d8)),
                  const SizedBox(width: 5),
                  Text(isMovie ? 'Film' : 'Serie', style: const TextStyle(color: Color(0xFF00b4d8), fontSize: 12, fontWeight: FontWeight.w600)),
                  if (year.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Text(year, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                  if (rating != null) ...[
                    const SizedBox(width: 10),
                    const Icon(Icons.star, size: 13, color: Colors.amber),
                    const SizedBox(width: 3),
                    Text(rating, style: const TextStyle(color: Colors.amber, fontSize: 12)),
                  ],
                ]),
                if (overview.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(overview, maxLines: 3, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.grey, fontSize: 13, height: 1.4)),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
