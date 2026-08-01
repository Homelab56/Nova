import 'package:flutter/material.dart';
import '../widgets/nova_image.dart';
import '../widgets/tv_focusable.dart';
import '../services/tmdb_service.dart';
import 'watch_screen.dart';

const _tmdbPoster = 'https://image.tmdb.org/t/p/w342';

// Volledig, doorbladerbaar grid-overzicht van een home-rij ("Meer bekijken"),
// i.p.v. enkel de eerste ~20 items die in de horizontale rij passen.
class CategoryScreen extends StatefulWidget {
  final String title;
  final String path;
  const CategoryScreen({super.key, required this.title, required this.path});
  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  final _scrollCtrl = ScrollController();
  List _results = [];
  bool _loading = true;
  int _page = 1, _totalPages = 1, _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loading || _page >= _totalPages) return;
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.pixels < _scrollCtrl.position.maxScrollExtent - 600) return;
    _load(append: true);
  }

  Future<void> _load({bool append = false}) async {
    setState(() => _loading = true);
    try {
      final data = await TmdbService.getPaged(widget.path, page: append ? _page + 1 : 1);
      setState(() {
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
          SnackBar(content: Text('Fout bij laden: $e'), backgroundColor: Colors.red),
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
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          if (_total > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(children: [
                Text('${_results.length} van $_total resultaten',
                  style: const TextStyle(color: Colors.grey, fontSize: 13)),
              ]),
            ),
          Expanded(
            child: _loading && _results.isEmpty
              ? const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8)))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    int crossAxisCount = (constraints.maxWidth / 210).floor();
                    if (crossAxisCount < 2) crossAxisCount = 2;
                    return GridView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.all(12),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        childAspectRatio: 0.62,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 18,
                      ),
                      itemCount: _results.length + (_page < _totalPages ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i == _results.length) {
                          return Container(
                            decoration: BoxDecoration(color: const Color(0xFF0f1520), borderRadius: BorderRadius.circular(10)),
                            child: const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8), strokeWidth: 2)),
                          );
                        }
                        final item = _results[i];
                        final poster = item['poster_path'];
                        final title = item['title'] ?? item['name'] ?? '';
                        return TvFocusable(
                          onTap: () => Navigator.push(context, MaterialPageRoute(
                            builder: (_) => WatchScreen(media: Map<String, dynamic>.from(item)))),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: poster != null
                                    ? NovaImage(path: '$_tmdbPoster$poster', fit: BoxFit.cover, width: double.infinity)
                                    : Container(color: const Color(0xFF0f1520), child: const Icon(Icons.movie, color: Colors.grey)),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, color: Colors.white70)),
                            ],
                          ),
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
