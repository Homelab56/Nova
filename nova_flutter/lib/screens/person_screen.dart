import 'package:flutter/material.dart';
import '../widgets/nova_image.dart';
import '../widgets/tv_focusable.dart';
import '../services/tmdb_service.dart';
import 'watch_screen.dart';

const tmdbPersonProfile = 'https://image.tmdb.org/t/p/h632';
const tmdbPersonPoster = 'https://image.tmdb.org/t/p/w342';

class PersonScreen extends StatefulWidget {
  final int personId;
  final String? name;
  final String? profilePath;
  const PersonScreen({super.key, required this.personId, this.name, this.profilePath});

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<PersonScreen> {
  Map? _person;
  List _credits = [];
  bool _loading = true;
  bool _bioExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        TmdbService.getPerson(widget.personId),
        TmdbService.getPersonCredits(widget.personId),
      ]);
      if (!mounted) return;
      setState(() {
        _person = results[0] as Map;
        _credits = results[1] as List;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = (_person?['name'] as String?) ?? widget.name ?? '';
    final profile = (_person?['profile_path'] as String?) ?? widget.profilePath;
    final bio = (_person?['biography'] as String?)?.trim() ?? '';
    final birthday = _person?['birthday'] as String?;
    final placeOfBirth = _person?['place_of_birth'] as String?;

    return Scaffold(
      backgroundColor: const Color(0xFF080c14),
      body: SafeArea(
        child: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8)))
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Row(
                      children: [
                        TvFocusable(
                          autofocus: true,
                          borderRadius: BorderRadius.circular(24),
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: const BoxDecoration(color: Color(0xFF0f1520), shape: BoxShape.circle),
                            child: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: NovaImage(
                            path: profile, baseUrl: tmdbPersonProfile,
                            width: 140, height: 210, fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Colors.white)),
                              if (birthday != null || placeOfBirth != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  [
                                    if (birthday != null) 'Geboren $birthday',
                                    if (placeOfBirth != null) placeOfBirth,
                                  ].join(' • '),
                                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                                ),
                              ],
                              if (bio.isNotEmpty) ...[
                                const SizedBox(height: 14),
                                Text(bio,
                                  maxLines: _bioExpanded ? null : 6,
                                  overflow: _bioExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5)),
                                if (bio.length > 300)
                                  TvFocusable(
                                    onTap: () => setState(() => _bioExpanded = !_bioExpanded),
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(_bioExpanded ? 'Minder' : 'Meer',
                                        style: const TextStyle(color: Color(0xFF00b4d8), fontSize: 13, fontWeight: FontWeight.w600)),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_credits.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text('Films & series (${_credits.length})',
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white)),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) {
                        int crossAxisCount = (constraints.crossAxisExtent / 150).floor();
                        if (crossAxisCount < 2) crossAxisCount = 2;
                        return SliverGrid(
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            childAspectRatio: 0.6,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 16,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              final item = _credits[i];
                              final poster = item['poster_path'];
                              final title = item['title'] ?? item['name'] ?? '';
                              final character = item['character'] as String?;
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
                                          ? NovaImage(path: poster, baseUrl: tmdbPersonPoster, fit: BoxFit.cover, width: double.infinity)
                                          : Container(color: const Color(0xFF0f1520), child: const Icon(Icons.movie, color: Colors.grey)),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13, color: Colors.white)),
                                    if (character != null && character.isNotEmpty)
                                      Text(character, maxLines: 1, overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                  ],
                                ),
                              );
                            },
                            childCount: _credits.length,
                          ),
                        );
                      },
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ] else
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Geen films of series gevonden.', style: TextStyle(color: Colors.grey)),
                    ),
                  ),
              ],
            ),
      ),
    );
  }
}
