import 'package:flutter/material.dart';
import '../widgets/nova_image.dart';
import '../widgets/tv_focusable.dart';
import '../services/tmdb_service.dart';
import 'watch_screen.dart';
import 'person_screen.dart';

const tmdbProfile = 'https://image.tmdb.org/t/p/w185';

const tmdbPoster = 'https://image.tmdb.org/t/p/w342';

class SearchScreen extends StatefulWidget {
  final int? genreId;
  final String? genreName;
  const SearchScreen({super.key, this.genreId, this.genreName});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  List _results = [];
  List _people = [];
  bool _loading = false;
  int _page = 1, _totalPages = 1, _total = 0;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    if (widget.genreId != null) {
      _loadGenre(widget.genreId!);
    }
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  // Automatisch de volgende pagina laden zodra je bijna onderaan bent,
  // i.p.v. steeds zelf op "Meer laden" te moeten klikken.
  void _onScroll() {
    if (_loading || _page >= _totalPages) return;
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.pixels < _scrollCtrl.position.maxScrollExtent - 600) return;
    if (widget.genreId != null && _ctrl.text.isEmpty) {
      _loadGenre(widget.genreId!, append: true);
    } else if (_lastQuery.isNotEmpty) {
      _search(_lastQuery, append: true);
    }
  }

  Future<void> _loadGenre(int id, {bool append = false}) async {
    setState(() => _loading = true);
    try {
      // Voor genre zoeken we zowel films als series zoals in de browser
      final data = await TmdbService.discoverGenre(id, 'all', page: append ? _page + 1 : 1);
      setState(() {
        _results = append ? [..._results, ...(data['items'] as List)] : data['items'] as List;
        _page = append ? _page + 1 : 1;
        _totalPages = data['total_pages'] as int;
        _total = data['total_results'] as int;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _results = append ? _results : [];
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fout bij laden van genre: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _search(String q, {bool append = false}) async {
    if (q.isEmpty) return;
    setState(() => _loading = true);
    try {
      final data = await TmdbService.searchAll(q, page: append ? _page + 1 : 1);
      // Personen enkel bij een nieuwe zoekopdracht ophalen (niet bij elke
      // pagina bijladen) - er is geen paginering voor nodig, gewoon de
      // beste treffers tonen.
      if (!append) TmdbService.searchPeople(q).then((p) { if (mounted) setState(() => _people = p); });
      setState(() {
        _lastQuery = q;
        _results = append ? [..._results, ...(data['items'] as List)] : data['items'] as List;
        _page = append ? _page + 1 : 1;
        _totalPages = data['total_pages'] as int;
        _total = data['total_results'] as int;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Zoekfout: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080c14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f1520),
        foregroundColor: Colors.white,
        title: widget.genreId != null && _ctrl.text.isEmpty
          ? Text('Genre: ${widget.genreName}')
          : TextField(
              controller: _ctrl,
              autofocus: widget.genreId == null,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Zoek films of series...',
                hintStyle: TextStyle(color: Colors.grey),
                border: InputBorder.none,
              ),
              onSubmitted: (v) => _search(v),
              onChanged: (v) { if (v.length > 2) _search(v); },
            ),
      ),
      body: Column(
        children: [
          if (_people.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Acteurs & actrices', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                  const SizedBox(height: 10),
                  // Kopruimte boven + horizontale padding op de ListView -
                  // anders snijdt de standaard clip van ListView de focus-
                  // groei van de avatar af (boven) of van de eerste/laatste
                  // avatar specifiek (opzij, kan niet verder scrollen om
                  // daar ruimte voor te maken).
                  SizedBox(height: 132 + 90, child: Padding(
                    padding: const EdgeInsets.only(top: 90),
                    child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 50),
                    itemCount: _people.length,
                    itemBuilder: (_, i) {
                      final p = _people[i];
                      final profile = p['profile_path'] as String?;
                      final personId = p['id'] as int?;
                      return Container(width: 88, margin: const EdgeInsets.only(right: 20),
                        child: Column(children: [
                          TvFocusable(
                            borderRadius: BorderRadius.circular(40),
                            onTap: personId == null ? null : () => Navigator.push(context, MaterialPageRoute(
                              builder: (_) => PersonScreen(personId: personId, name: p['name'] as String?, profilePath: profile))),
                            child: CircleAvatar(radius: 40, backgroundColor: const Color(0xFF0f1520),
                              backgroundImage: profile != null ? NetworkImage('$tmdbProfile$profile') : null,
                              child: profile == null ? const Icon(Icons.person, color: Colors.grey, size: 28) : null),
                          ),
                          const SizedBox(height: 6),
                          Text(p['name'] ?? '', maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: Colors.white70)),
                        ]),
                      );
                    },
                  ))),
                ],
              ),
            ),
          if (_total > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Text('${_results.length} van $_total resultaten',
                    style: const TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            ),
          Expanded(
            child: _loading && _results.isEmpty
              ? const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8)))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // Bereken aantal kolommen op basis van breedte - grotere
                    // tegels (net als op het startscherm) i.p.v. veel kleine.
                    int crossAxisCount = (constraints.maxWidth / 210).floor();
                    if (crossAxisCount < 2) crossAxisCount = 2;

                    return GridView.builder(
                      controller: _scrollCtrl,
                      // Extra ruimte bovenaan - anders sneed de standaard
                      // clip van GridView de focus-vergroting/gloed van de
                      // bovenste rij tegels af (net als bij MediaRow).
                      // Links/rechts/onder ruimer dan 12 - anders snijdt de
                      // GridView's eigen rand de focus-groei van de eerste/
                      // laatste kolom en de onderste rij af (kunnen niet
                      // verder scrollen om daar ruimte voor te maken).
                      padding: const EdgeInsets.fromLTRB(60, 90, 60, 60),
                      cacheExtent: 2000,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        childAspectRatio: 0.62,
                        // Was 14/18 - te weinig voor de focus-vergroting
                        // (schaal 1.25), zie category_screen.dart voor de
                        // volledige toelichting.
                        crossAxisSpacing: 32,
                        mainAxisSpacing: 52,
                      ),
                      // Volgende pagina laadt automatisch via _onScroll; deze
                      // laatste tegel is enkel nog een laad-indicator, geen
                      // knop die je zelf moet aantikken.
                      itemCount: _results.length + (_page < _totalPages ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i == _results.length) {
                          return const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8), strokeWidth: 2));
                        }
                        final item = _results[i];
                        final poster = item['poster_path'];
                        final title = item['title'] ?? item['name'] ?? '';
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: TvFocusable(
                                onTap: () => Navigator.push(context, MaterialPageRoute(
                                  builder: (_) => WatchScreen(media: Map<String, dynamic>.from(item)))),
                                borderRadius: BorderRadius.circular(10),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: poster != null
                                    ? NovaImage(path: '$tmdbPoster$poster', fit: BoxFit.cover, width: double.infinity)
                                    : Container(color: const Color(0xFF0f1520), child: const Icon(Icons.movie, color: Colors.grey)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: Colors.white70)),
                          ],
                        );
                      },
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }
}
