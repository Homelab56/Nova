import 'package:flutter/material.dart';
import '../widgets/nova_image.dart';
import '../services/userdata_service.dart';
import 'watch_screen.dart';

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
        title: const Text('Mijn Watchlist'),
      ),
      body: _list.isEmpty
        ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.bookmark_outline, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('Je watchlist is leeg', style: TextStyle(color: Colors.grey, fontSize: 16)),
            SizedBox(height: 8),
            Text('Druk op + bij een film of serie', style: TextStyle(color: Colors.grey, fontSize: 13)),
          ]))
        : GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, childAspectRatio: 0.62, crossAxisSpacing: 8, mainAxisSpacing: 8),
            itemCount: _list.length,
            itemBuilder: (_, i) {
              final item = _list[i];
              final poster = item['poster_path'];
              return GestureDetector(
                onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => WatchScreen(media: Map<String, dynamic>.from(item)))).then((_) => _load()),
                child: Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: poster != null
                      ? NovaImage(path: '$tmdbPoster$poster', fit: BoxFit.cover, width: double.infinity, height: double.infinity)
                      : Container(color: const Color(0xFF0f1520), child: const Icon(Icons.movie, color: Colors.grey)),
                  ),
                  Positioned(top: 4, right: 4,
                    child: GestureDetector(
                      onTap: () async {
                        await UserDataService.removeFromWatchlist(item['id'] as int);
                        _load();
                      },
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                        child: const Icon(Icons.close, size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ]),
              );
            },
          ),
    );
  }
}

