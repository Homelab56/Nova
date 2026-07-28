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
  List _kidsMovies = [], _kidsTv = [];
  List _rdLibrary = [], _progress = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<List> _safeList(Future<List> f) async {
    try {
      return await f.timeout(const Duration(seconds: 12));
    } catch (_) {
      return const [];
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      _safeList(TmdbService.getTrending()),
      _safeList(TmdbService.getPopularMovies()),
      _safeList(TmdbService.getPopularTv()),
      _safeList(TmdbService.getTrendingMovies()),
      _safeList(TmdbService.getTrendingTv()),
      _safeList(TmdbService.getTopRatedMovies()),
      _safeList(TmdbService.getTopRatedTv()),
      _safeList(DebridService.getLibrary()),
      UserDataService.getProgress(),
      _safeList(TmdbService.getKidsMovies()),
      _safeList(TmdbService.getKidsTv()),
    ]);
    if (!mounted) return;
    setState(() {
      _trending = results[0];
      _popularMovies = results[1];
      _popularTv = results[2];
      _trendMovies = results[3];
      _trendTv = results[4];
      _topMovies = results[5];
      _topTv = results[6];
      _rdLibrary = results[7];
      _progress = (results[8] as List).reversed.toList();
      _kidsMovies = results[9];
      _kidsTv = results[10];
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _rows {
    final List<Map<String, dynamic>> baseRows = [];
    
    // Voeg Verder kijken altijd als eerste rij toe
    if (_progress.isNotEmpty) {
      baseRows.add({'title': 'Verder kijken', 'items': _progress, 'is_progress': true});
    }

    switch (_tab) {
      case 1: baseRows.addAll([
        {'title': 'Populaire films', 'items': _popularMovies},
        {'title': 'Trending films', 'items': _trendMovies},
        {'title': 'Best beoordeeld', 'items': _topMovies},
      ]); break;
      case 2: baseRows.addAll([
        {'title': 'Populaire series', 'items': _popularTv},
        {'title': 'Trending series', 'items': _trendTv},
        {'title': 'Best beoordeeld', 'items': _topTv},
      ]); break;
      case 4: baseRows.addAll([
        {'title': 'Kinderfilms', 'items': _kidsMovies},
        {'title': 'Kinderseries', 'items': _kidsTv},
      ]); break;
      default: baseRows.addAll([
        {'title': 'Trending deze week', 'items': _trending},
        {'title': 'Populaire films', 'items': _popularMovies},
        {'title': 'Populaire series', 'items': _popularTv},
        {'title': 'Trending films', 'items': _trendMovies},
        {'title': 'Trending series', 'items': _trendTv},
        {'title': 'Best beoordeelde films', 'items': _topMovies},
        {'title': 'Best beoordeelde series', 'items': _topTv},
      ]);
    }

    if (_rdLibrary.isNotEmpty) {
      baseRows.add({'title': 'Mijn Real-Debrid Bibliotheek', 'items': _rdLibrary, 'is_rd': true});
    }
    return baseRows;
  }

  List get _heroItems => _tab == 1 ? _popularMovies : _tab == 2 ? _popularTv : _tab == 4 ? _kidsMovies : _trending;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080c14),
      body: SafeArea(
        child: Column(
          children: [
            _buildAppBar(),
            Expanded(
              child: _loading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8)))
                : RefreshIndicator(
                    onRefresh: _load,
                    color: const Color(0xFF00b4d8),
                    child: CustomScrollView(
                      slivers: [
                        if (_heroItems.isNotEmpty) SliverToBoxAdapter(child: _buildHero(_heroItems[0])),
                        ..._rows.map((r) => SliverToBoxAdapter(
                          child: _buildRow(r['title'] as String, r['items'] as List,
                            isRd: r['is_rd'] == true,
                            isProgress: r['is_progress'] == true))),
                        const SliverToBoxAdapter(child: SizedBox(height: 50)),
                      ],
                    ),
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Container(
      color: const Color(0xFF080c14).withOpacity(0.9),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Image.asset('assets/logo.png', height: 32),
        const SizedBox(width: 24),
        _buildNavBtn('Home', 0),
        _buildNavBtn('Films', 1),
        _buildNavBtn('Series', 2),
        _buildNavBtn('Kids', 4),
        _buildNavBtn('Watchlist', 3),
        
        const SizedBox(width: 12),
        // Genres knop
        PopupMenuButton<int>(
          offset: const Offset(0, 40),
          color: const Color(0xFF0f1520),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.white12)),
          onSelected: (id) async {
            final names = {
              28: 'Actie', 12: 'Avontuur', 16: 'Animatie', 35: 'Komedie', 80: 'Misdaad',
              99: 'Documentaire', 18: 'Drama', 10751: 'Familie', 14: 'Fantasy',
              27: 'Horror', 9648: 'Mystery', 10749: 'Romantiek', 878: 'Sci-Fi',
              53: 'Thriller', 10752: 'Oorlog'
            };
            final name = names[id] ?? 'Genre';
            // Open search screen met genre filter
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => SearchScreen(genreId: id, genreName: name)
            ));
          },
          itemBuilder: (context) => [
            28, 12, 16, 35, 80, 99, 18, 10751, 14, 27, 9648, 10749, 878, 53, 10752
          ].map((id) {
            final names = {
              28: 'Actie', 12: 'Avontuur', 16: 'Animatie', 35: 'Komedie', 80: 'Misdaad',
              99: 'Documentaire', 18: 'Drama', 10751: 'Familie', 14: 'Fantasy',
              27: 'Horror', 9648: 'Mystery', 10749: 'Romantiek', 878: 'Sci-Fi',
              53: 'Thriller', 10752: 'Oorlog'
            };
            return PopupMenuItem(
              value: id,
              child: Text(names[id] ?? '', style: const TextStyle(color: Colors.white, fontSize: 13)),
            );
          }).toList(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.menu, size: 16, color: Colors.grey),
                SizedBox(width: 8),
                Text('Genres', style: TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            ),
          ),
        ),
        
        const Spacer(),
        IconButton(icon: const Icon(Icons.search, color: Colors.white, size: 22),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen()))),
        IconButton(icon: const Icon(Icons.settings_outlined, color: Colors.grey, size: 22),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
      ]),
    );
  }

  Widget _buildNavBtn(String label, int index) {
    final bool active = _tab == index;
    return InkWell(
      onTap: () {
        if (index == 3) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const WatchlistScreen(),
              settings: const RouteSettings(name: 'watchlist'),
            ),
          ).then((_) => _load());
        } else {
          setState(() {
            _tab = index;
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: active ? const Color(0xFF00b4d8) : Colors.grey,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 2,
              width: active ? 20 : 0,
              color: const Color(0xFF00b4d8),
            ),
          ],
        ),
      ),
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

  Widget _buildRow(String title, List items, {bool isRd = false, bool isProgress = false}) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
        child: Text(title, style: TextStyle(
          fontSize: 17, fontWeight: FontWeight.bold, 
          color: isRd ? const Color(0xFF00b4d8) : Colors.white)),
      ),
      SizedBox(
        height: isProgress ? 160 : 205,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: items.length,
          itemBuilder: (_, i) => _buildCard(items[i], isRd: isRd, isProgress: isProgress),
        ),
      ),
    ]);
  }

  Widget _buildCard(Map item, {bool isRd = false, bool isProgress = false}) {
    final poster = item['poster_path'] as String?;
    final backdrop = item['backdrop_path'] as String?;
    final title = item['title'] ?? item['name'] ?? item['filename'] ?? '';
    final year = ((item['release_date'] ?? item['first_air_date'] ?? '') as String);
    final yearStr = year.length >= 4 ? year.substring(0, 4) : '';
    
    // Voor progress tonen we een horizontale kaart (backdrop) zoals in de browser
    if (isProgress) {
      final double progress = (item['current_time'] ?? 0) / (item['duration'] ?? 1);
      
      return GestureDetector(
        onTap: () => _openWatch(item),
        child: Container(
          width: 200, margin: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: NovaImage(path: backdrop, width: 200, height: 112, baseUrl: 'https://image.tmdb.org/t/p/w300'),
              ),
              Positioned(bottom: 0, left: 0, right: 0,
                child: Container(
                  height: 3, color: Colors.white24,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: Container(color: const Color(0xFF00b4d8)),
                  ),
                ),
              ),
              const Positioned.fill(child: Center(child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 30))),
            ]),
            const SizedBox(height: 6),
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w500)),
          ]),
        ),
      );
    }

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

  void _openWatch(Map item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WatchScreen(media: Map<String, dynamic>.from(item))),
    ).then((_) => _load()); // Herlaad progress bij terugkomst
  }
}
