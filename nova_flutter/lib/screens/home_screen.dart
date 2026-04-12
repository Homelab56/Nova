import 'package:flutter/material.dart';
import '../services/tmdb_service.dart';
import '../services/debrid_service.dart';
import '../services/userdata_service.dart';
import '../widgets/nova_image.dart';
import 'watch_screen.dart';
import 'settings_screen.dart';
import 'watchlist_screen.dart';
import 'search_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  List _trending = [], _popularMovies = [], _popularTv = [];
  List _trendMovies = [], _trendTv = [], _topMovies = [], _topTv = [];
  List _rdLibrary = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await Future.wait([
      TmdbService.getTrending(),
      TmdbService.getPopularMovies(),
      TmdbService.getPopularTv(),
      TmdbService.getTrendingMovies(),
      TmdbService.getTrendingTv(),
      TmdbService.getTopRatedMovies(),
      TmdbService.getTopRatedTv(),
      DebridService.getLibrary(),
    ]);
    setState(() {
      _trending = r[0]; _popularMovies = r[1]; _popularTv = r[2];
      _trendMovies = r[3]; _trendTv = r[4]; _topMovies = r[5]; _topTv = r[6];
      _rdLibrary = r[7];
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _rows {
    final List<Map<String, dynamic>> baseRows;
    switch (_tab) {
      case 1: baseRows = [
        {'title': 'Populaire films', 'items': _popularMovies},
        {'title': 'Trending films', 'items': _trendMovies},
        {'title': 'Best beoordeeld', 'items': _topMovies},
      ]; break;
      case 2: baseRows = [
        {'title': 'Populaire series', 'items': _popularTv},
        {'title': 'Trending series', 'items': _trendTv},
        {'title': 'Best beoordeeld', 'items': _topTv},
      ]; break;
      default: baseRows = [
        {'title': 'Trending deze week', 'items': _trending},
        {'title': 'Populaire films', 'items': _popularMovies},
        {'title': 'Populaire series', 'items': _popularTv},
        {'title': 'Trending films', 'items': _trendMovies},
        {'title': 'Trending series', 'items': _trendTv},
        {'title': 'Best beoordeelde films', 'items': _topMovies},
        {'title': 'Best beoordeelde series', 'items': _topTv},
      ];
    }

    if (_rdLibrary.isNotEmpty) {
      // Voeg bibliotheek toe na de eerste rij
      baseRows.insert(1, {'title': 'Mijn Real-Debrid Bibliotheek', 'items': _rdLibrary, 'is_rd': true});
    }
    return baseRows;
  }

  List get _heroItems => _tab == 1 ? _popularMovies : _tab == 2 ? _popularTv : _trending;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080c14),
      body: SafeArea(
        child: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8)))
          : RefreshIndicator(
              onRefresh: _load,
              color: const Color(0xFF00b4d8),
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: _buildAppBar()),
                  if (_heroItems.isNotEmpty) SliverToBoxAdapter(child: _buildHero(_heroItems[0])),
                  ..._rows.map((r) => SliverToBoxAdapter(
                    child: _buildRow(r['title'] as String, r['items'] as List, isRd: r['is_rd'] == true))),
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                ],
              ),
            ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Image.asset('assets/logo.png', height: 36),
        const Spacer(),
        IconButton(icon: const Icon(Icons.search, color: Colors.white),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen()))),
        IconButton(icon: const Icon(Icons.settings_outlined, color: Colors.grey),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
      ]),
    );
  }

  Widget _buildHero(Map item) {
    final title = item['title'] ?? item['name'] ?? '';
    final backdrop = item['backdrop_path'] as String?;
    final rating = (item['vote_average'] as num?)?.toStringAsFixed(1);

    return GestureDetector(
      onTap: () => _openWatch(item),
      child: Stack(children: [
        NovaImage(path: backdrop, width: double.infinity, height: 260,
          baseUrl: 'https://image.tmdb.org/t/p/w780'),
        Container(height: 260, decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0xFF080c14)]))),
        Positioned(bottom: 16, left: 16, right: 16,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white,
              shadows: [Shadow(blurRadius: 8, color: Colors.black)])),
            if (rating != null) ...[
              const SizedBox(height: 4),
              Text('★ $rating', style: const TextStyle(color: Colors.amber, fontSize: 13)),
            ],
            const SizedBox(height: 10),
            Row(children: [
              ElevatedButton.icon(
                onPressed: () => _openWatch(item),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Afspelen'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white, foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10)),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () => UserDataService.addToWatchlist(Map<String, dynamic>.from(item)),
                icon: const Icon(Icons.add, size: 16, color: Colors.white),
                label: const Text('Watchlist', style: TextStyle(color: Colors.white)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white54),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
              ),
            ]),
          ])),
      ]),
    );
  }

  Widget _buildRow(String title, List items, {bool isRd = false}) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
        child: Text(title, style: TextStyle(
          fontSize: 17, fontWeight: FontWeight.bold, 
          color: isRd ? const Color(0xFF00b4d8) : Colors.white)),
      ),
      SizedBox(
        height: 185,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: items.length,
          itemBuilder: (_, i) => _buildCard(items[i], isRd: isRd),
        ),
      ),
    ]);
  }

  Widget _buildCard(Map item, {bool isRd = false}) {
    final poster = item['poster_path'] as String?;
    final title = item['title'] ?? item['name'] ?? item['filename'] ?? '';
    final year = ((item['release_date'] ?? item['first_air_date'] ?? '') as String);
    final yearStr = year.length >= 4 ? year.substring(0, 4) : '';

    return GestureDetector(
      onTap: () => _openWatch(item),
      child: Container(
        width: 115, margin: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: isRd 
              ? Container(width: 115, height: 150, color: const Color(0xFF0f1520), 
                  child: const Icon(Icons.folder_open, color: Color(0xFF00b4d8), size: 30))
              : NovaImage(path: poster, width: 115, height: 150),
          ),
          const SizedBox(height: 5),
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w500)),
          if (!isRd && yearStr.isNotEmpty)
            Text(yearStr, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ]),
      ),
    );
  }

  void _openWatch(Map item) => Navigator.push(context,
    MaterialPageRoute(builder: (_) => WatchScreen(media: Map<String, dynamic>.from(item))));

  Widget _buildBottomNav() {
    return BottomNavigationBar(
      currentIndex: _tab,
      onTap: (i) {
        if (i == 3) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const WatchlistScreen()));
        } else {
          setState(() => _tab = i);
        }
      },
      backgroundColor: const Color(0xFF0f1520),
      selectedItemColor: const Color(0xFF00b4d8),
      unselectedItemColor: Colors.grey,
      type: BottomNavigationBarType.fixed,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: 'Home'),
        BottomNavigationBarItem(icon: Icon(Icons.movie_outlined), activeIcon: Icon(Icons.movie), label: 'Films'),
        BottomNavigationBarItem(icon: Icon(Icons.tv_outlined), activeIcon: Icon(Icons.tv), label: 'Series'),
        BottomNavigationBarItem(icon: Icon(Icons.bookmark_outline), activeIcon: Icon(Icons.bookmark), label: 'Watchlist'),
      ],
    );
  }
}
