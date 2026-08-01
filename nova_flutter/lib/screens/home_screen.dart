import 'dart:async';
import 'package:flutter/material.dart';
import '../services/tmdb_service.dart';
import '../services/debrid_service.dart';
import '../services/userdata_service.dart';
import '../widgets/nova_image.dart';
import '../widgets/media_row.dart';
import 'watch_screen.dart';
import 'settings_screen.dart';
import 'watchlist_screen.dart';
import 'search_screen.dart';
import 'category_screen.dart';
import 'profile_screen.dart';
import '../services/profile_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

// Extra genres om te doorbladeren op Home/Films/Series, naast de
// hoofdrijen (Top 10/Populair/Best beoordeeld) - zodat er een echte
// bibliotheek is om doorheen te scrollen i.p.v. maar een handvol rijen.
// TV-genre-ID's verschillen deels van film-ID's in TMDB (bv. Sci-Fi
// "878" voor film vs "10765" "Sci-Fi & Fantasy" voor tv).
const _movieGenreRows = [
  {'title': 'Actie films', 'id': 28},
  {'title': 'Komedie films', 'id': 35},
  {'title': 'Horror', 'id': 27},
  {'title': 'Sci-Fi films', 'id': 878},
  {'title': 'Animatiefilms', 'id': 16},
  {'title': 'Thrillers', 'id': 53},
];
const _tvGenreRows = [
  {'title': 'Actie & Avontuur series', 'id': 10759},
  {'title': 'Komedie series', 'id': 35},
  {'title': 'Drama series', 'id': 18},
  {'title': 'Sci-Fi & Fantasy series', 'id': 10765},
  {'title': 'Mystery series', 'id': 9648},
  {'title': 'Misdaad series', 'id': 80},
];

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  List _trending = [], _popularMovies = [], _popularTv = [];
  List _trendMovies = [], _trendTv = [], _topMovies = [], _topTv = [];
  List _kidsMovies = [], _kidsTv = [];
  List _kidsMoviesTop = [], _kidsMoviesNew = [], _kidsTvTop = [], _kidsTvNew = [];
  List _rdLibrary = [], _progress = [];
  final Map<int, List> _movieGenreItems = {};
  final Map<int, List> _tvGenreItems = {};
  // 1-ster-rangschikkingen ("niet voor mij") sluiten we overal uit; 3-sterren
  // ("top!") voedt de "Omdat je hield van ..."-rijen hieronder.
  final Set<int> _excludedIds = {};
  List<Map<String, dynamic>> _recommendationRows = [];
  bool _loading = true;
  int _heroIndex = 0;
  Timer? _heroTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _heroTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted) return;
      final count = _heroItems.length < 5 ? _heroItems.length : 5;
      if (count <= 1) return;
      setState(() => _heroIndex = (_heroIndex + 1) % count);
    });
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    super.dispose();
  }

  Future<List> _safeList(Future<List> f) async {
    try {
      return await f.timeout(const Duration(seconds: 12));
    } catch (_) {
      return const [];
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // Alle Future.wait-blokken hieronder worden meteen (dus parallel)
    // gestart - enkel het await'en gebeurt na elkaar.
    final mainFuture = Future.wait([
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
    final kidsExtraFuture = Future.wait([
      _safeList(TmdbService.getKidsMoviesTopRated()),
      _safeList(TmdbService.getKidsMoviesNewest()),
      _safeList(TmdbService.getKidsTvTopRated()),
      _safeList(TmdbService.getKidsTvNewest()),
    ]);
    final movieGenreFuture = Future.wait(
      _movieGenreRows.map((g) => _safeList(TmdbService.getGenreItems(g['id'] as int, 'movie'))));
    final tvGenreFuture = Future.wait(
      _tvGenreRows.map((g) => _safeList(TmdbService.getGenreItems(g['id'] as int, 'tv'))));

    // 1-ster-uitsluitingen en de "Omdat je hield van ..."-zaadjes (de 3
    // meest recente 3-sterren-rangschikkingen) uit de lokale rangschikkingen
    // van dit profiel - dit is puur lokaal, geen netwerkverzoek nodig.
    final ratings = await UserDataService.getRatings();
    final excluded = <int>{};
    final topRated = <Map<String, dynamic>>[];
    for (final v in ratings.values) {
      final r = v as Map;
      final stars = (r['stars'] as num?)?.toInt() ?? 0;
      final id = (r['id'] as num?)?.toInt();
      if (id == null) continue;
      if (stars == 1) excluded.add(id);
      if (stars == 3) {
        topRated.add({
          'id': id,
          'media_type': r['media_type'] ?? 'movie',
          'title': r['title'] ?? '',
          'rated_at': (r['rated_at'] as num?) ?? 0,
        });
      }
    }
    topRated.sort((a, b) => (b['rated_at'] as num).compareTo(a['rated_at'] as num));
    final seeds = topRated.take(3).toList();
    final recsFuture = Future.wait(
      seeds.map((s) => _safeList(TmdbService.getSimilar(s['id'] as int, s['media_type'] as String))));

    final results = await mainFuture;
    final kidsExtra = await kidsExtraFuture;
    final movieGenreResults = await movieGenreFuture;
    final tvGenreResults = await tvGenreFuture;
    final recLists = await recsFuture;
    if (!mounted) return;
    setState(() {
      _excludedIds
        ..clear()
        ..addAll(excluded);
      _recommendationRows = [
        for (var i = 0; i < seeds.length; i++)
          if (recLists[i].isNotEmpty)
            {'title': 'Omdat je hield van ${seeds[i]['title']}', 'items': recLists[i]},
      ];
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
      _kidsMoviesTop = kidsExtra[0];
      _kidsMoviesNew = kidsExtra[1];
      _kidsTvTop = kidsExtra[2];
      _kidsTvNew = kidsExtra[3];
      for (var i = 0; i < _movieGenreRows.length; i++) {
        _movieGenreItems[_movieGenreRows[i]['id'] as int] = movieGenreResults[i];
      }
      for (var i = 0; i < _tvGenreRows.length; i++) {
        _tvGenreItems[_tvGenreRows[i]['id'] as int] = tvGenreResults[i];
      }
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
        {'title': 'Top 10 films deze week', 'items': _trendMovies, 'is_ranked': true, 'path': '/api/search/trending/movies'},
        {'title': 'Populaire films', 'items': _popularMovies, 'path': '/api/search/popular/movies'},
        {'title': 'Best beoordeeld', 'items': _topMovies, 'path': '/api/search/toprated/movies'},
        for (final g in _movieGenreRows)
          {'title': g['title'], 'items': _movieGenreItems[g['id']] ?? const []},
      ]); break;
      case 2: baseRows.addAll([
        {'title': 'Top 10 series deze week', 'items': _trendTv, 'is_ranked': true, 'path': '/api/search/trending/tv'},
        {'title': 'Populaire series', 'items': _popularTv, 'path': '/api/search/popular/tv'},
        {'title': 'Best beoordeeld', 'items': _topTv, 'path': '/api/search/toprated/tv'},
        for (final g in _tvGenreRows)
          {'title': g['title'], 'items': _tvGenreItems[g['id']] ?? const []},
      ]); break;
      case 3: baseRows.addAll([
        {'title': 'Top 10 kinderfilms', 'items': _kidsMovies, 'is_ranked': true, 'path': '/api/search/kids/movies'},
        {'title': 'Best beoordeelde kinderfilms', 'items': _kidsMoviesTop, 'path': '/api/search/kids/movies/toprated'},
        {'title': 'Nieuwste kinderfilms', 'items': _kidsMoviesNew, 'path': '/api/search/kids/movies/newest'},
      ]); break;
      case 4: baseRows.addAll([
        {'title': 'Top 10 kinderseries', 'items': _kidsTv, 'is_ranked': true, 'path': '/api/search/kids/tv'},
        {'title': 'Best beoordeelde kinderseries', 'items': _kidsTvTop, 'path': '/api/search/kids/tv/toprated'},
        {'title': 'Nieuwste kinderseries', 'items': _kidsTvNew, 'path': '/api/search/kids/tv/newest'},
      ]); break;
      default: baseRows.addAll([
        {'title': 'Top 10 films deze week', 'items': _trendMovies, 'is_ranked': true},
        {'title': 'Top 10 series deze week', 'items': _trendTv, 'is_ranked': true},
        ..._recommendationRows,
        {'title': 'Populaire films', 'items': _popularMovies, 'path': '/api/search/popular/movies'},
        {'title': 'Populaire series', 'items': _popularTv, 'path': '/api/search/popular/tv'},
        {'title': 'Best beoordeelde films', 'items': _topMovies, 'path': '/api/search/toprated/movies'},
        {'title': 'Best beoordeelde series', 'items': _topTv, 'path': '/api/search/toprated/tv'},
        // Een representatieve greep genres i.p.v. alle 12 - anders wordt Home
        // extreem lang; de volledige lijst staat al op de Films/Series-tabs.
        {'title': 'Actie films', 'items': _movieGenreItems[28] ?? const []},
        {'title': 'Komedie series', 'items': _tvGenreItems[35] ?? const []},
        {'title': 'Horror', 'items': _movieGenreItems[27] ?? const []},
        {'title': 'Sci-Fi & Fantasy series', 'items': _tvGenreItems[10765] ?? const []},
      ]);
    }

    if (_rdLibrary.isNotEmpty) {
      baseRows.add({'title': 'Mijn Real-Debrid Bibliotheek', 'items': _rdLibrary, 'is_rd': true});
    }
    return _dedupeRows(baseRows);
  }

  // Voorkomt dat dezelfde film/serie in meerdere rijen op dezelfde pagina
  // opduikt (bv. de populairste actiefilm staat vaak toch al bovenaan
  // "Populair" én "Actie") - elke volgende rij toont enkel wat nog niet
  // in een eerdere rij op deze pagina stond. "Verder kijken" en de eigen
  // RD-bibliotheek blijven ongemoeid, dat zijn geen ontdek-rijen.
  // Alles met een 1-ster-rangschikking ("niet voor mij") wordt hier ook
  // meteen overal uitgesloten.
  List<Map<String, dynamic>> _dedupeRows(List<Map<String, dynamic>> rows) {
    final seen = <dynamic>{};
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r['is_progress'] == true || r['is_rd'] == true) {
        out.add(r);
        continue;
      }
      final items = (r['items'] as List?) ?? const [];
      final filtered = [];
      for (final it in items) {
        final id = (it is Map) ? it['id'] : null;
        if (id != null) {
          if (_excludedIds.contains(id)) continue;
          if (seen.contains(id)) continue;
          seen.add(id);
        }
        filtered.add(it);
      }
      out.add({...r, 'items': filtered});
    }
    return out;
  }

  List get _heroItems => _tab == 1 ? _popularMovies
    : _tab == 2 ? _popularTv
    : _tab == 3 ? _kidsMovies
    : _tab == 4 ? _kidsTv
    : _trending;

  Widget _buildHeroCarousel() {
    final items = _heroItems;
    if (items.isEmpty) return const SizedBox.shrink();
    final idx = _heroIndex < items.length ? _heroIndex : 0;
    final item = items[idx];
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 600),
      child: KeyedSubtree(key: ValueKey(item['id']), child: _buildHero(item)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080c14),
      body: Stack(children: [
        _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8)))
          : RefreshIndicator(
              onRefresh: _load,
              color: const Color(0xFF00b4d8),
              child: CustomScrollView(
                slivers: [
                  if (_heroItems.isNotEmpty) SliverToBoxAdapter(child: _buildHeroCarousel()),
                  ..._rows.map((r) => SliverToBoxAdapter(
                    child: _buildRow(r['title'] as String, r['items'] as List,
                      isRd: r['is_rd'] == true,
                      isProgress: r['is_progress'] == true,
                      isRanked: r['is_ranked'] == true,
                      path: r['path'] as String?))),
                  const SliverToBoxAdapter(child: SizedBox(height: 50)),
                ],
              ),
            ),
        Positioned(top: 0, left: 0, right: 0, child: SafeArea(bottom: false, child: _buildAppBar())),
      ]),
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
        _buildNavBtn('Kids Films', 3),
        _buildNavBtn('Kids Series', 4),
        _buildNavBtn('Watchlist', 5),
        
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
        Tooltip(
          message: 'Profiel wisselen (${ProfileService.activeProfileName ?? ""})',
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen())),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: CircleAvatar(
                radius: 14,
                backgroundColor: const Color(0xFF00b4d8),
                child: Text(
                  (ProfileService.activeProfileName?.isNotEmpty == true) ? ProfileService.activeProfileName![0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
        ),
        IconButton(icon: const Icon(Icons.settings_outlined, color: Colors.grey, size: 22),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
      ]),
    );
  }

  Widget _buildNavBtn(String label, int index) {
    final bool active = _tab == index;
    return InkWell(
      onTap: () {
        if (index == 5) {
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
            _heroIndex = 0;
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
    final overview = (item['overview'] as String?) ?? '';

    return GestureDetector(
      onTap: () => _openWatch(item),
      child: SizedBox(
        height: 640,
        child: Stack(fit: StackFit.expand, children: [
          // Brede/lage banner vs. een ~16:9 bronbeeld betekent dat cover
          // sowieso stevig moet bijsnijden - een hogere banner (was 520) en
          // een naar boven verschoven uitsnede (i.p.v. gecentreerd, wat zowel
          // boven als onder wegsnijdt) houden meer van de originele artwork
          // zichtbaar i.p.v. een sterk ingezoomde middenstrook.
          NovaImage(path: backdrop, width: double.infinity, height: 640,
            baseUrl: 'https://image.tmdb.org/t/p/original', fit: BoxFit.cover,
            alignment: const Alignment(0, -0.55)),
          // Verticale gradient (leesbaarheid onderaan) + horizontale gradient
          // (leesbaarheid links, waar de tekst staat) - zoals Netflix' hero.
          Container(decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.transparent, Color(0xFF080c14)],
              stops: [0.0, 0.55, 1.0]))),
          Container(decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight,
              colors: [Color(0xF2080c14), Colors.transparent],
              stops: [0.0, 0.65]))),
          Positioned(bottom: 40, left: 40, right: 40,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: Colors.white,
                    height: 1.1, shadows: [Shadow(blurRadius: 12, color: Colors.black)])),
              ),
              if (rating != null) ...[
                const SizedBox(height: 10),
                Text('★ $rating', style: const TextStyle(color: Colors.amber, fontSize: 15)),
              ],
              if (overview.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Text(overview, maxLines: 3, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, color: Colors.white70, height: 1.4)),
                ),
              ],
              const SizedBox(height: 20),
              Row(children: [
                ElevatedButton.icon(
                  onPressed: () => _openWatch(item),
                  icon: const Icon(Icons.play_arrow, size: 20),
                  label: const Text('Afspelen'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white, foregroundColor: Colors.black,
                    textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14)),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => UserDataService.addToWatchlist(Map<String, dynamic>.from(item)),
                  icon: const Icon(Icons.add, size: 18, color: Colors.white),
                  label: const Text('Watchlist', style: TextStyle(color: Colors.white, fontSize: 15)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white54),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
                ),
              ]),
            ])),
        ]),
      ),
    );
  }

  Widget _buildRow(String title, List items, {bool isRd = false, bool isProgress = false, bool isRanked = false, String? path}) {
    if (items.isEmpty) return const SizedBox.shrink();
    return MediaRow(
      title: title,
      titleColor: isRd ? const Color(0xFF00b4d8) : Colors.white,
      height: isProgress ? 185 : (isRanked ? 320 : 300),
      itemCount: isRanked ? (items.length < 10 ? items.length : 10) : items.length,
      path: path,
      onSeeAll: path == null ? null : () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => CategoryScreen(title: title, path: path))),
      itemBuilder: (_, i) => isRanked
        ? _buildRankedCard(items[i], i + 1)
        : _buildCard(items[i], isRd: isRd, isProgress: isProgress),
    );
  }

  // Netflix-achtige "Top 10" kaart. Rang "10" krijgt een bredere cijfer-zone
  // dan 1-9 (2 tekens i.p.v. 1) zodat beide cijfers altijd volledig leesbaar
  // blijven i.p.v. dat de poster het merendeel van "10" wegneemt.
  Widget _buildRankedCard(Map item, int rank) {
    final poster = item['poster_path'] as String?;
    final title = item['title'] ?? item['name'] ?? '';
    const posterWidth = 165.0;
    const posterHeight = 250.0;
    // Zichtbaar deel van het cijfer vóór de poster begint overlappen, en de
    // volledige breedte die aan FittedBox gegeven wordt (iets ruimer, zodat
    // een klein stukje bewust achter de poster verdwijnt voor het bleed-
    // effect, zonder de leesbaarheid van het cijfer zelf te verliezen).
    final double numVisible = rank >= 10 ? 170 : 100;
    // Ruim genoeg dat de hoogte (niet de breedte) altijd de beperkende
    // factor is voor FittedBox, zodat elk cijfer - "1" of "10" - even hoog
    // wordt als de poster zelf.
    final double numBoxWidth = rank >= 10 ? 250 : 170;
    final double cardWidth = numVisible + posterWidth;
    return GestureDetector(
      onTap: () => _openWatch(item),
      child: Container(
        width: cardWidth,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: posterHeight,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned(
                left: 0, top: 0, bottom: 0, width: numBoxWidth,
                child: FittedBox(
                  fit: BoxFit.contain,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '$rank',
                    // fontSize is enkel de basis-maat vóór FittedBox schaalt -
                    // zonder expliciete fontSize viel dit terug op de kleine
                    // standaard tekstgrootte, waardoor strokeWidth verhoudingsgewijs
                    // enorm werd na het opschalen (vulde de cijfers helemaal dicht).
                    style: TextStyle(
                      fontSize: 100,
                      fontWeight: FontWeight.w900,
                      fontStyle: FontStyle.italic,
                      foreground: Paint()
                        ..style = PaintingStyle.stroke
                        ..strokeWidth = 2.5
                        ..color = Colors.grey.shade300,
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 0, bottom: 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(children: [
                    NovaImage(path: poster, width: posterWidth, height: posterHeight),
                    _cornerIcon(Icons.add, () => _addToWatchlistWithFeedback(item)),
                  ]),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.only(left: numVisible),
            child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }

  Widget _cornerIcon(IconData icon, VoidCallback onTap) {
    return Positioned(
      top: 6, right: 6,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 15),
        ),
      ),
    );
  }

  void _addToWatchlistWithFeedback(Map item) async {
    await UserDataService.addToWatchlist(Map<String, dynamic>.from(item));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Toegevoegd aan watchlist'), backgroundColor: Color(0xFF00b4d8), duration: Duration(seconds: 2)));
  }

  void _removeFromProgress(Map item) async {
    await UserDataService.removeProgress(item['id']);
    if (!mounted) return;
    setState(() => _progress.removeWhere((p) => p['id'] == item['id']));
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
        onTap: () => _openWatch(item, autoResume: true),
        child: Container(
          width: 230, margin: const EdgeInsets.symmetric(horizontal: 5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: NovaImage(path: backdrop, width: 230, height: 130, baseUrl: 'https://image.tmdb.org/t/p/w300'),
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
              const Positioned.fill(child: Center(child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 34))),
              _cornerIcon(Icons.close, () => _removeFromProgress(item)),
            ]),
            const SizedBox(height: 8),
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
    }

    return GestureDetector(
      onTap: () => _openWatch(item),
      child: Container(
        width: 168, margin: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 4))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(children: [
                isRd
                  ? Container(width: 168, height: 235, color: const Color(0xFF0f1520),
                      child: const Icon(Icons.folder_open, color: Color(0xFF00b4d8), size: 36))
                  : NovaImage(path: poster, width: 168, height: 235),
                if (!isRd) _cornerIcon(Icons.add, () => _addToWatchlistWithFeedback(item)),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
          if (!isRd && yearStr.isNotEmpty)
            Text(yearStr, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      ),
    );
  }

  void _openWatch(Map item, {bool autoResume = false}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WatchScreen(media: Map<String, dynamic>.from(item), autoResume: autoResume)),
    ).then((_) => _load()); // Herlaad progress bij terugkomst
  }
}
