import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import '../widgets/nova_image.dart';
import '../services/tmdb_service.dart';
import '../services/debrid_service.dart';
import '../services/userdata_service.dart';
import '../services/settings_service.dart';

const tmdbPoster = 'https://image.tmdb.org/t/p/w342';
const tmdbProfile = 'https://image.tmdb.org/t/p/w185';
const tmdbStill = 'https://image.tmdb.org/t/p/w300';
const tmdbBackdrop = 'https://image.tmdb.org/t/p/w780';

class WatchScreen extends StatefulWidget {
  final Map<String, dynamic> media;
  const WatchScreen({super.key, required this.media});
  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  Map? _detail;
  List _cast = [], _similar = [];
  Map? _seasonData;
  int _selectedSeason = 1;
  bool _loadingSeason = false;
  String? _streamUrl;
  bool _loadingStream = false;
  String _status = '';
  bool _inWatchlist = false;
  bool? _isAvailable; // null = nog niet gecheckt
  VideoPlayerController? _vpCtrl;
  ChewieController? _chewieCtrl;
  mk.Player? _mkPlayer;
  VideoController? _mkVideoCtrl;

  bool get isMovie => widget.media['title'] != null && widget.media['first_air_date'] == null;
  String get title => widget.media['title'] ?? widget.media['name'] ?? '';
  String get year {
    final d = (widget.media['release_date'] ?? widget.media['first_air_date'] ?? '') as String;
    return d.length >= 4 ? d.substring(0, 4) : '';
  }

  @override
  void initState() {
    super.initState();
    _loadDetails();
    _checkWatchlist();
    if (isMovie) _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    final q = '$title $year';
    final available = await DebridService.checkAvailability(q);
    if (mounted) setState(() => _isAvailable = available);
  }

  Future<void> _checkWatchlist() async {
    final inList = await UserDataService.isInWatchlist(widget.media['id'] as int);
    setState(() => _inWatchlist = inList);
  }

  Future<void> _toggleWatchlist() async {
    if (_inWatchlist) {
      await UserDataService.removeFromWatchlist(widget.media['id'] as int);
    } else {
      await UserDataService.addToWatchlist(widget.media);
    }
    setState(() => _inWatchlist = !_inWatchlist);
  }

  Future<void> _loadDetails() async {
    final id = widget.media['id'];
    if (id is! int) {
      // Mogelijk een RD item zonder TMDB ID, probeer te zoeken op filename
      final name = widget.media['filename'] ?? widget.media['title'] ?? widget.media['name'];
      if (name != null) {
        final search = await TmdbService.searchAll(name as String);
        if (search['items'].isNotEmpty) {
          final firstMatch = search['items'][0];
          Navigator.pushReplacement(context, MaterialPageRoute(
            builder: (_) => WatchScreen(media: Map<String, dynamic>.from(firstMatch))));
          return;
        }
      }
      setState(() { _status = 'Geen metadata gevonden voor dit item.'; });
      return;
    }

    final type = isMovie ? 'movie' : 'tv';
    final results = await Future.wait([
      isMovie ? TmdbService.getMovieDetail(id) : TmdbService.getTvDetail(id),
      TmdbService.getCredits(id, type),
      TmdbService.getSimilar(id, type),
    ]);
    setState(() {
      _detail = results[0] as Map;
      _cast = results[1] as List;
      _similar = results[2] as List;
    });
    if (!isMovie) _loadSeason(1);
  }

  Future<void> _loadSeason(int s) async {
    setState(() { _loadingSeason = true; _selectedSeason = s; });
    final data = await TmdbService.getSeason(widget.media['id'] as int, s);
    setState(() { _seasonData = data; _loadingSeason = false; });
  }

  Future<void> _play({Map? episode}) async {
    setState(() { _loadingStream = true; _status = 'Zoeken naar streams...'; });
    final q = episode != null
      ? '$title S${_selectedSeason.toString().padLeft(2,'0')}E${(episode['episode_number'] as int).toString().padLeft(2,'0')}'
      : '$title $year';

    try {
      // De backend API doet nu het zware werk (library + scraper + cache check)
      final baseUrl = await SettingsService.getBackendUrl();
      final response = await http.get(Uri.parse('$baseUrl/api/debrid/search?q=${Uri.encodeComponent(q)}&tmdb_id=${widget.media['id']}&media_type=${isMovie ? "movie" : "tv"}&client=windows'));
      
      if (response.statusCode != 200) {
        throw 'Server gaf een foutmelding: ${response.statusCode}';
      }

      final data = jsonDecode(response.body);
      final direct = data['direct_url'] as String?;
      final stream = data['stream_url'] as String?;
      String? url = (Platform.isWindows ? direct : null) ?? stream;

      if (url == null) {
        setState(() {
          _status = data['message'] ?? 'Geen stream gevonden.';
          _loadingStream = false;
        });
        return;
      }

      // Fix relative URLs (bijv. van de lokale mount)
      if (url.startsWith('/')) {
        url = baseUrl.replaceAll(RegExp(r'/$'), '') + url;
      }

      final source = data['source'] ?? 'unknown';
      setState(() { 
        _status = source == 'scraper' ? 'Gevonden op internet. Laden...' : 'Gevonden in bibliotheek. Laden...'; 
      });

      if (Platform.isWindows) {
        _mkPlayer?.dispose();
        _mkPlayer = mk.Player();
        _mkVideoCtrl = VideoController(_mkPlayer!);

        Future<void> openUrl(String u) async {
          await _mkPlayer!.open(mk.Media(u), play: true).timeout(const Duration(seconds: 20));
        }

        try {
          await openUrl(url);
          setState(() { _streamUrl = url; _loadingStream = false; _status = ''; });
          return;
        } catch (_) {
          if (stream != null) {
            var fallback = stream;
            if (fallback.startsWith('/')) {
              fallback = baseUrl.replaceAll(RegExp(r'/$'), '') + fallback;
            }
            setState(() { _status = 'Direct play faalde. Fallback laden...'; });
            await openUrl(fallback);
            setState(() { _streamUrl = fallback; _loadingStream = false; _status = ''; });
            return;
          }
          rethrow;
        }
      }

      _vpCtrl?.dispose();
      _chewieCtrl?.dispose();
      _vpCtrl = VideoPlayerController.networkUrl(Uri.parse(url));
      await _vpCtrl!.initialize().timeout(const Duration(seconds: 15), onTimeout: () {
        throw 'Time-out bij het laden van de video. Probeer het opnieuw.';
      });
      _chewieCtrl = ChewieController(
        videoPlayerController: _vpCtrl!,
        autoPlay: true,
        allowFullScreen: true,
        allowMuting: true,
        showControlsOnInitialize: false,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Text(
              'Fout bij het afspelen: $errorMessage',
              style: const TextStyle(color: Colors.white),
            ),
          );
        },
      );
      setState(() { _streamUrl = url; _loadingStream = false; _status = ''; });
    } catch (e) {
      setState(() {
        _status = 'Fout: $e';
        _loadingStream = false;
      });
    }
  }

  @override
  void dispose() {
    _vpCtrl?.dispose();
    _chewieCtrl?.dispose();
    _mkPlayer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backdrop = widget.media['backdrop_path'];
    final poster = widget.media['poster_path'];
    final rating = (widget.media['vote_average'] as num?)?.toStringAsFixed(1);
    final seasons = (_detail?['seasons'] as List?)?.where((s) => (s['season_number'] as int) > 0).toList() ?? [];

    return Scaffold(
      backgroundColor: const Color(0xFF080c14),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Player of backdrop
              if (_streamUrl != null && Platform.isWindows && _mkVideoCtrl != null)
                AspectRatio(aspectRatio: 16/9, child: Video(controller: _mkVideoCtrl!))
              else if (_streamUrl != null && _chewieCtrl != null)
                AspectRatio(aspectRatio: 16/9, child: Chewie(controller: _chewieCtrl!))
              else if (backdrop != null)
                Stack(children: [
                  NovaImage(path: '$tmdbBackdrop$backdrop',
                    height: 220, width: double.infinity, fit: BoxFit.cover),
                  Container(height: 220, decoration: const BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xFF080c14)]))),
                ]),

              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Terug
                    TextButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back, size: 16),
                      label: const Text('Terug'),
                      style: TextButton.styleFrom(foregroundColor: Colors.grey, padding: EdgeInsets.zero),
                    ),
                    const SizedBox(height: 8),

                    // Info
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (poster != null)
                        ClipRRect(borderRadius: BorderRadius.circular(10),
                          child: NovaImage(path: '$tmdbPoster$poster', width: 90, height: 135, fit: BoxFit.cover)),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white)),
                        const SizedBox(height: 6),
                        Wrap(spacing: 8, children: [
                          if (year.isNotEmpty) Text(year, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                          if (rating != null) Text('★ $rating', style: const TextStyle(color: Colors.amber, fontSize: 13)),
                          if (seasons.isNotEmpty) Text('${seasons.length} seizoen${seasons.length > 1 ? "en" : ""}',
                            style: const TextStyle(color: Colors.grey, fontSize: 13)),
                        ]),
                        const SizedBox(height: 8),
                        Text(widget.media['overview'] ?? '', maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.grey, fontSize: 13, height: 1.5)),
                        const SizedBox(height: 12),
                        Row(children: [
                          if (isMovie)
                            ElevatedButton.icon(
                              onPressed: _loadingStream ? null : () => _play(),
                              icon: _loadingStream
                                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                                : const Icon(Icons.play_arrow, size: 18),
                              label: Text(_loadingStream ? 'Laden...' : 'Afspelen'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _isAvailable == true ? const Color(0xFF00b4d8) : Colors.white, 
                                foregroundColor: _isAvailable == true ? Colors.white : Colors.black,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              ),
                            ),
                          if (isMovie) const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _toggleWatchlist,
                            icon: Icon(_inWatchlist ? Icons.bookmark : Icons.bookmark_outline, size: 16,
                              color: _inWatchlist ? const Color(0xFF00b4d8) : Colors.white),
                            label: Text(_inWatchlist ? 'In watchlist' : '+ Watchlist',
                              style: TextStyle(color: _inWatchlist ? const Color(0xFF00b4d8) : Colors.white, fontSize: 13)),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: _inWatchlist ? const Color(0xFF00b4d8) : Colors.white38),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                          ),
                        ]),
                        if (isMovie && _isAvailable != null) Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(children: [
                            Icon(_isAvailable! ? Icons.check_circle : Icons.info_outline, 
                              size: 14, color: _isAvailable! ? const Color(0xFF00b4d8) : Colors.orange),
                            const SizedBox(width: 4),
                            Text(_isAvailable! ? 'Beschikbaar in je RD bibliotheek' : 'Niet in je bibliotheek', 
                              style: TextStyle(color: _isAvailable! ? const Color(0xFF00b4d8) : Colors.orange, fontSize: 12)),
                          ]),
                        ),
                        if (_status.isNotEmpty) Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(_status, style: const TextStyle(color: Color(0xFF00b4d8), fontSize: 12)),
                        ),
                      ])),
                    ]),

                    // Seizoenen
                    if (!isMovie && seasons.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Row(children: [
                        const Text('Afleveringen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                        const SizedBox(width: 12),
                        DropdownButton<int>(
                          value: _selectedSeason,
                          dropdownColor: const Color(0xFF0f1520),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          underline: const SizedBox.shrink(),
                          items: seasons.map<DropdownMenuItem<int>>((s) => DropdownMenuItem(
                            value: s['season_number'] as int,
                            child: Text('Seizoen ${s['season_number']} (${s['episode_count']} afl.)'),
                          )).toList(),
                          onChanged: (v) { if (v != null) _loadSeason(v); },
                        ),
                      ]),
                      const SizedBox(height: 12),
                      if (_loadingSeason)
                        const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8)))
                      else
                        ...(_seasonData?['episodes'] as List? ?? []).map((ep) => _buildEpisode(ep)),
                    ],

                    // Cast
                    if (_cast.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      const Text('Cast', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                      const SizedBox(height: 12),
                      SizedBox(height: 110, child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _cast.length,
                        itemBuilder: (_, i) {
                          final p = _cast[i];
                          final profile = p['profile_path'];
                          return Container(width: 70, margin: const EdgeInsets.only(right: 10),
                            child: Column(children: [
                              CircleAvatar(radius: 30, backgroundColor: const Color(0xFF0f1520),
                                backgroundImage: profile != null ? NetworkImage('$tmdbProfile$profile') : null,
                                child: profile == null ? const Icon(Icons.person, color: Colors.grey) : null),
                              const SizedBox(height: 4),
                              Text(p['name'] ?? '', maxLines: 2, textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 10, color: Colors.white70)),
                            ]));
                        },
                      )),
                    ],

                    // Meer zoals dit
                    if (_similar.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      const Text('Meer zoals dit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                      const SizedBox(height: 12),
                      SizedBox(height: 185, child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _similar.length,
                        itemBuilder: (_, i) {
                          final item = _similar[i];
                          final p = item['poster_path'];
                          return GestureDetector(
                            onTap: () => Navigator.pushReplacement(context, MaterialPageRoute(
                              builder: (_) => WatchScreen(media: Map<String, dynamic>.from(item)))),
                            child: Container(width: 115, margin: const EdgeInsets.only(right: 8),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                ClipRRect(borderRadius: BorderRadius.circular(10),
                                  child: p != null
                                    ? NovaImage(path: '$tmdbPoster$p', height: 150, width: 115, fit: BoxFit.cover)
                                    : Container(height: 150, width: 115, color: const Color(0xFF0f1520))),
                                const SizedBox(height: 4),
                                Text(item['title'] ?? item['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11, color: Colors.white70)),
                              ])),
                          );
                        },
                      )),
                    ],
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEpisode(Map ep) {
    final still = ep['still_path'];
    final epNum = ep['episode_number'] as int;
    final runtime = ep['runtime'];
    return GestureDetector(
      onTap: () => _play(episode: ep),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0f1520),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.withOpacity(0.12)),
        ),
        child: Row(children: [
          SizedBox(width: 28, child: Text('$epNum',
            style: const TextStyle(color: Colors.grey, fontSize: 15, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
          const SizedBox(width: 8),
          ClipRRect(borderRadius: BorderRadius.circular(8),
            child: still != null
              ? NovaImage(path: '$tmdbStill$still', width: 96, height: 58, fit: BoxFit.cover)
              : Container(width: 96, height: 58, color: const Color(0xFF080c14),
                  child: const Icon(Icons.play_circle_outline, color: Colors.grey))),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Expanded(child: Text(ep['name'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (runtime != null) Text('${runtime}m', style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ]),
            const SizedBox(height: 3),
            Text(ep['overview'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.grey, fontSize: 11, height: 1.4)),
          ])),
          const SizedBox(width: 6),
          const Icon(Icons.play_arrow, color: Color(0xFF00b4d8), size: 20),
        ]),
      ),
    );
  }
}

