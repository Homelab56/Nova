import 'package:flutter/material.dart';
import '../widgets/nova_image.dart';
import '../services/tmdb_service.dart';
import 'watch_screen.dart';

const tmdbPoster = 'https://image.tmdb.org/t/p/w342';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  List _results = [];
  bool _loading = false;
  int _page = 1, _totalPages = 1, _total = 0;
  String _lastQuery = '';

  Future<void> _search(String q, {bool append = false}) async {
    if (q.isEmpty) return;
    setState(() => _loading = true);
    final data = await TmdbService.searchAll(q, page: append ? _page + 1 : 1);
    setState(() {
      _lastQuery = q;
      _results = append ? [..._results, ...(data['items'] as List)] : data['items'] as List;
      _page = append ? _page + 1 : 1;
      _totalPages = data['total_pages'] as int;
      _total = data['total_results'] as int;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080c14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f1520),
        foregroundColor: Colors.white,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
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
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, childAspectRatio: 0.58, crossAxisSpacing: 8, mainAxisSpacing: 8),
                  itemCount: _results.length + (_page < _totalPages ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i == _results.length) {
                      return GestureDetector(
                        onTap: () => _search(_lastQuery, append: true),
                        child: Container(
                          decoration: BoxDecoration(color: const Color(0xFF0f1520), borderRadius: BorderRadius.circular(10)),
                          child: _loading
                            ? const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8), strokeWidth: 2))
                            : const Center(child: Text('Meer laden', style: TextStyle(color: Color(0xFF00b4d8), fontSize: 12))),
                        ),
                      );
                    }
                    final item = _results[i];
                    final poster = item['poster_path'];
                    final title = item['title'] ?? item['name'] ?? '';
                    return GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => WatchScreen(media: Map<String, dynamic>.from(item)))),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: poster != null
                                ? NovaImage(path: '$tmdbPoster$poster', fit: BoxFit.cover, width: double.infinity)
                                : Container(color: const Color(0xFF0f1520), child: const Icon(Icons.movie, color: Colors.grey)),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: Colors.white70)),
                        ],
                      ),
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }
}

