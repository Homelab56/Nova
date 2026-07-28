import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
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
  late final Player _player;
  late final VideoController _controller;
  bool _showPlayer = false;
  Tracks _tracks = const Tracks();
  Track _currentTrack = const Track();
  Map? _currentEpisode;
  Map<String, dynamic> _prefs = {
    'default_audio_lang': 'en',
    'default_sub_lang_1': 'nl',
    'default_sub_lang_2': '',
    'subtitles_enabled': true,
  };
  bool _autoAppliedAudio = false;
  bool _autoAppliedSubs = false;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    // Ruimere netwerkbuffer zodat streamen van een externe (Real-Debrid) URL
    // niet steeds hapert bij kleine snelheidsschommelingen.
    final native = _player.platform;
    if (native is NativePlayer) {
      native.setProperty('cache', 'yes');
      native.setProperty('cache-secs', '120');
      native.setProperty('demuxer-max-bytes', '512MiB');
      native.setProperty('demuxer-max-back-bytes', '64MiB');
      native.setProperty('demuxer-readahead-secs', '60');
      native.setProperty('network-timeout', '30');
      // Hardware-decodering: zonder dit decodeert mpv HEVC/4K+ bronnen op de
      // CPU, wat op hoge resolutie tot haperend beeld leidt ondanks vlotte audio.
      native.setProperty('hwdec', 'auto-safe');
    }
    _loadDetails();
    _checkWatchlist();
    _loadPrefs();
    if (isMovie) _checkAvailability();

    // Luister naar player updates voor progress
    int lastSave = -1;
    _player.stream.position.listen((pos) {
      final dur = _player.state.duration;
      final sec = pos.inSeconds;
      if (dur.inSeconds > 0 && sec > 0 && sec % 10 == 0 && sec != lastSave) {
        lastSave = sec;
        final item = _progressItem();
        debugPrint('[Nova] saveProgress: id=${item['id']} sec=$sec dur=${dur.inSeconds}');
        UserDataService.saveProgress(
          item,
          sec.toDouble(),
          dur.inSeconds.toDouble()
        );
      }
    });

    // Luister naar beschikbare/geselecteerde audio- en ondertitelsporen
    _player.stream.tracks.listen((t) {
      if (mounted) setState(() => _tracks = t);
      _autoApplyTrackPrefs();
    });
    _player.stream.track.listen((t) {
      if (mounted) setState(() => _currentTrack = t);
    });
  }

  Future<void> _loadPrefs() async {
    final baseUrl = (await SettingsService.getBackendUrl()).trim().replaceAll(RegExp(r'/$'), '');
    for (final path in ['/user/prefs', '/api/user/prefs']) {
      try {
        final r = await http.get(Uri.parse('$baseUrl$path')).timeout(const Duration(seconds: 5));
        if (r.statusCode == 200) {
          final data = jsonDecode(r.body) as Map<String, dynamic>;
          if (data.isNotEmpty && mounted) {
            setState(() => _prefs = {..._prefs, ...data});
          }
          return;
        }
      } catch (_) {
        continue;
      }
    }
  }

  String _normLang(String s) => s.toLowerCase().trim().replaceAll('_', '-');

  bool _isForcedTrack(dynamic t) => (t.title as String? ?? '').toLowerCase().contains('forced');

  // [avoidForced] zorgt dat we een "Forced"-ondertitelspoor pas als allerlaatste
  // redmiddel kiezen: die tonen doorgaans maar een handvol regels (bv. bij een
  // vreemde taal in beeld), niet de volledige ondertiteling - zonder deze
  // check leek het net of er geen ondertitels beschikbaar waren.
  dynamic _matchTrack(List tracks, List<String> preferredLangs, {bool avoidForced = false}) {
    final prefer = preferredLangs.where((e) => e.isNotEmpty).map(_normLang).toList();
    for (final p in prefer) {
      for (final t in tracks) {
        if (avoidForced && _isForcedTrack(t)) continue;
        final lang = _normLang(t.language as String? ?? '');
        if (lang.isNotEmpty && (lang.startsWith(p) || p.startsWith(lang))) return t;
      }
    }
    for (final p in prefer) {
      for (final t in tracks) {
        if (avoidForced && _isForcedTrack(t)) continue;
        final title = (t.title as String? ?? '').toLowerCase();
        if (title.contains(p)) return t;
      }
    }
    if (avoidForced) return _matchTrack(tracks, preferredLangs);
    return null;
  }

  // Past de opgeslagen standaard audio-/ondertiteltaal toe zodra mpv de
  // beschikbare sporen van de zojuist geopende bron heeft gedetecteerd.
  // Audio en ondertitels worden onafhankelijk toegepast: mpv rapporteert ze
  // vaak in aparte updates (bv. audio eerder dan ondertitels), dus een enkele
  // gedeelde "klaar"-vlag zou de latere selectie overslaan.
  void _autoApplyTrackPrefs() {
    final hasRealAudio = _tracks.audio.any((t) => t.id != 'auto' && t.id != 'no');
    final hasRealSubs = _tracks.subtitle.any((t) => t.id != 'auto' && t.id != 'no');

    if (!_autoAppliedAudio && hasRealAudio) {
      _autoAppliedAudio = true;
      final audioLang = (_prefs['default_audio_lang'] as String? ?? '').trim();
      final audioMatch = _matchTrack(_tracks.audio, [audioLang, 'en', 'eng']);
      debugPrint('[Nova] auto audio match: ${audioMatch != null ? "${audioMatch.id}:${audioMatch.language}" : "geen match"}');
      if (audioMatch != null) _player.setAudioTrack(audioMatch);
    }

    if (!_autoAppliedSubs && hasRealSubs) {
      _autoAppliedSubs = true;
      if (_prefs['subtitles_enabled'] == true) {
        final sub1 = (_prefs['default_sub_lang_1'] as String? ?? '').trim();
        final sub2 = (_prefs['default_sub_lang_2'] as String? ?? '').trim();
        // NL heeft voorrang; als er geen Nederlandse ondertitels in de bron
        // zitten, valt dit terug op Engels i.p.v. helemaal geen ondertiteling.
        final subMatch = _matchTrack(_tracks.subtitle, [sub1, sub2, 'nl', 'nld', 'dut', 'en', 'eng'], avoidForced: true);
        debugPrint('[Nova] auto subtitle match: ${subMatch != null ? "${subMatch.id}:${subMatch.language}" : "geen match"}');
        if (subMatch != null) _player.setSubtitleTrack(subMatch);
      }
    }
  }

  // Vertaalt een taalcode naar een leesbare naam. mpv's "title" veld is vaak
  // maar een vlag (Forced/Regular/SDH) i.p.v. de taal, dus die tonen we enkel
  // als aanvulling, niet als hoofdlabel.
  String _langName(String? lang) {
    final l = _normLang(lang ?? '');
    if (l.isEmpty) return '';
    if (l.startsWith('nl') || l.startsWith('dut') || l.startsWith('vla')) return 'Nederlands';
    if (l.startsWith('en')) return 'Engels';
    return lang!;
  }

  String _trackLabel(dynamic track) {
    final id = track.id as String;
    if (id == 'no') return 'Uit';
    if (id == 'auto') return 'Automatisch';
    final lang = track.language as String?;
    final title = track.title as String?;
    final langName = _langName(lang);
    if (langName.isNotEmpty) {
      if (title != null && title.isNotEmpty && title.toLowerCase() != langName.toLowerCase()) {
        return '$langName ($title)';
      }
      return langName;
    }
    return title ?? lang ?? 'Spoor $id';
  }

  static const _allowedLangPrefixes = [
    'nl', 'nld', 'dut', 'vla', 'vlaams', 'dutch', 'flemish', 'nederlands',
    'en', 'eng', 'english',
  ];

  bool _isAllowedLang(dynamic track) {
    final id = track.id as String;
    if (id == 'auto' || id == 'no') return true;
    final lang = (track.language as String? ?? '').toLowerCase();
    final title = (track.title as String? ?? '').toLowerCase();
    if (lang.isEmpty && title.isEmpty) return true;
    return _allowedLangPrefixes.any((p) => lang.startsWith(p) || title.contains(p));
  }

  bool _hasSelectableTracks(List tracks) =>
      tracks.where((t) => _isAllowedLang(t) && t.id != 'auto' && t.id != 'no').isNotEmpty;

  void _pickAudioTrack() {
    final options = _tracks.audio.where(_isAllowedLang).toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0f1520),
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Audio', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            for (final t in options)
              ListTile(
                title: Text(_trackLabel(t), style: const TextStyle(color: Colors.white)),
                trailing: t == _currentTrack.audio ? const Icon(Icons.check, color: Color(0xFF00b4d8)) : null,
                onTap: () {
                  _player.setAudioTrack(t);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _pickSubtitleTrack() {
    final options = _tracks.subtitle.where(_isAllowedLang).toList();
    final hasEmbeddedNl = options.any((t) {
      final lang = _normLang(t.language ?? '');
      return lang.startsWith('nl') || lang.startsWith('dut');
    });
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0f1520),
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Ondertitels', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            for (final t in options)
              ListTile(
                title: Text(_trackLabel(t), style: const TextStyle(color: Colors.white)),
                trailing: t == _currentTrack.subtitle ? const Icon(Icons.check, color: Color(0xFF00b4d8)) : null,
                onTap: () {
                  _player.setSubtitleTrack(t);
                  Navigator.pop(context);
                },
              ),
            if (!hasEmbeddedNl) ...[
              const Divider(color: Colors.white12, height: 1),
              ListTile(
                leading: const Icon(Icons.cloud_download_outlined, color: Color(0xFF00b4d8)),
                title: const Text('Extern NL zoeken (auto-sync)', style: TextStyle(color: Color(0xFF00b4d8))),
                subtitle: const Text('Zoekt op OpenSubtitles en lijnt automatisch uit op de audio. Kan tot ~1-2 min duren.',
                  style: TextStyle(color: Colors.grey, fontSize: 11)),
                onTap: () {
                  Navigator.pop(context);
                  _loadExternalSubtitle();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _loadExternalSubtitle() async {
    final url = _streamUrl;
    final tmdbId = widget.media['id'];
    if (url == null || tmdbId is! int) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nederlandse ondertitels zoeken en synchroniseren...'), duration: Duration(seconds: 6)));
    try {
      final baseUrl = (await SettingsService.getBackendUrl()).trim().replaceAll(RegExp(r'/$'), '');
      final params = {
        'url': url,
        'tmdb_id': '$tmdbId',
        'media_type': isMovie ? 'movie' : 'tv',
        'lang': 'nl',
        if (_currentEpisode != null) 'season': '$_selectedSeason',
        if (_currentEpisode != null) 'episode': '${_currentEpisode!['episode_number']}',
      };
      for (final path in ['/stream/subtitle-external.vtt', '/api/stream/subtitle-external.vtt']) {
        final vttUrl = Uri.parse('$baseUrl$path').replace(queryParameters: params);
        final check = await http.get(vttUrl).timeout(const Duration(seconds: 150));
        if (check.statusCode == 200) {
          final track = SubtitleTrack.uri(vttUrl.toString(), title: 'Nederlands (extern)', language: 'nl');
          await _player.setSubtitleTrack(track);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Nederlandse ondertitels geladen.'), backgroundColor: Color(0xFF00b4d8)));
          }
          return;
        }
        if (check.statusCode != 404) continue;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Geen Nederlandse ondertitels gevonden op OpenSubtitles.'), backgroundColor: Colors.redAccent));
        }
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kon geen verbinding maken met de server.'), backgroundColor: Colors.redAccent));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fout bij ophalen ondertitels: $e'), backgroundColor: Colors.redAccent));
      }
    }
  }

  Future<bool> _tryStartProcess(String exe, List<String> args) async {
    try {
      final p = await Process.start(exe, args, runInShell: true);
      unawaited(p.exitCode);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryStartExePath(String exePath, List<String> args) async {
    try {
      final f = File(exePath);
      if (!await f.exists()) return false;
      final p = await Process.start(exePath, args, runInShell: true);
      unawaited(p.exitCode);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openExternalPlayer(String url) async {
    final okMpv = await _tryStartProcess('mpv', [url]);
    if (okMpv) return;
    final okMpvPath = await _tryStartExePath(r'C:\Program Files\mpv\mpv.exe', [url]) ||
        await _tryStartExePath(r'C:\Program Files (x86)\mpv\mpv.exe', [url]);
    if (okMpvPath) return;

    final okVlc = await _tryStartProcess('vlc', [url]);
    if (okVlc) return;
    final okVlcPath = await _tryStartExePath(r'C:\Program Files\VideoLAN\VLC\vlc.exe', [url]) ||
        await _tryStartExePath(r'C:\Program Files (x86)\VideoLAN\VLC\vlc.exe', [url]);
    if (okVlcPath) return;

    final okExplorer = await _tryStartProcess('explorer.exe', [url]);
    if (okExplorer) return;

    await _tryStartProcess('cmd', ['/c', 'start', '', '"$url"']);
  }

  bool get isMovie => widget.media['title'] != null && widget.media['first_air_date'] == null;
  String get title => widget.media['title'] ?? widget.media['name'] ?? '';
  String get year {
    final d = (widget.media['release_date'] ?? widget.media['first_air_date'] ?? '') as String;
    return d.length >= 4 ? d.substring(0, 4) : '';
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

  // Voortgang wordt opgeslagen onder de show/film-id; bij een serie voegen we
  // seizoen/aflevering toe zodat hervatten niet de voortgang van een andere
  // aflevering pakt.
  Map<String, dynamic> _progressItem() {
    final item = Map<String, dynamic>.from(widget.media);
    if (_currentEpisode != null) {
      item['season_number'] = _selectedSeason;
      item['episode_number'] = _currentEpisode!['episode_number'];
    }
    return item;
  }

  Future<double> _resumeSeconds({Map? episode}) async {
    final id = widget.media['id'];
    final saved = await UserDataService.getItemProgress(id);
    debugPrint('[Nova] _resumeSeconds: id=$id (${id.runtimeType}) episode=${episode?['episode_number']} saved=$saved');
    if (saved == null) return 0;
    if (episode != null) {
      if (saved['season_number'] != _selectedSeason || saved['episode_number'] != episode['episode_number']) {
        debugPrint('[Nova] _resumeSeconds: andere aflevering (saved S${saved['season_number']}E${saved['episode_number']} vs huidige S${_selectedSeason}E${episode['episode_number']})');
        return 0; // opgeslagen voortgang hoort bij een andere aflevering
      }
    } else if (saved['season_number'] != null) {
      return 0; // film, maar het opgeslagen record is van een aflevering
    }
    final t = (saved['current_time'] as num?)?.toDouble() ?? 0;
    final d = (saved['duration'] as num?)?.toDouble() ?? 0;
    if (t <= 10) return 0;
    if (d > 0 && t > d - 20) return 0; // vrijwel afgelopen, gewoon opnieuw beginnen
    return t;
  }

  Future<void> _play({Map? episode}) async {
    _currentEpisode = episode;
    setState(() {
      _loadingStream = true;
      _status = 'Zoeken naar streams...';
      _showPlayer = false;
    });
    
    final q = episode != null
      ? '$title S${_selectedSeason.toString().padLeft(2,'0')}E${(episode['episode_number'] as int).toString().padLeft(2,'0')}'
      : '$title $year';

    try {
      final baseUrl = (await SettingsService.getBackendUrl()).trim().replaceAll(RegExp(r'/$'), '');
      
      final apiPaths = ['/api/debrid/search', '/debrid/search'];
      String? url;
      String? source;
      String? errorMessage;
      
      for (final path in apiPaths) {
        try {
          final apiUrl = '$baseUrl$path?q=${Uri.encodeComponent(q)}&tmdb_id=${widget.media['id']}&media_type=${isMovie ? "movie" : "tv"}&client=windows';
          final response = await http.get(Uri.parse(apiUrl)).timeout(const Duration(seconds: 25));
          
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            final direct = data['direct_url'] as String?;
            final stream = data['stream_url'] as String?;
            url = (direct != null && direct.isNotEmpty) ? direct : stream;
            source = data['source'] ?? 'unknown';
            if (url != null) break;
            errorMessage = data['message'];
          } else {
            errorMessage = 'Server fout: ${response.statusCode}';
          }
        } catch (e) {
          errorMessage = 'Verbindingsfout: $e';
          continue;
        }
      }

      if (url == null) {
        setState(() {
          _status = errorMessage ?? 'Geen stream gevonden voor deze titel.';
          _loadingStream = false;
        });
        return;
      }

      final statusLabel = source == 'scraper' ? 'Gevonden op internet. Laden...' : 'Gevonden in bibliotheek. Laden...';
      final resume = await _resumeSeconds(episode: episode);
      await _playUrl(url, statusLabel: statusLabel, resumeSeconds: resume);
    } catch (e) {
      setState(() {
        _status = 'Fout bij afspelen: $e';
        _loadingStream = false;
      });
    }
  }

  Future<void> _playUrl(String url, {String statusLabel = 'Laden...', double resumeSeconds = 0}) async {
    final baseUrl = (await SettingsService.getBackendUrl()).trim().replaceAll(RegExp(r'/$'), '');
    if (url.startsWith('/')) {
      url = baseUrl + url;
    }

    _autoAppliedAudio = false;
    _autoAppliedSubs = false;
    setState(() {
      _status = statusLabel;
      _loadingStream = true;
      _tracks = const Tracks();
      _currentTrack = const Track();
    });

    debugPrint('[Nova] _playUrl: resumeSeconds=$resumeSeconds url=$url');

    // Player configureren voor betere compatibiliteit. We openen gepauzeerd,
    // wachten tot mpv de duur kent (bron is dan echt geladen), seeken pas
    // daarna en starten dan het afspelen - direct seeken vlak na open() kan
    // stil genegeerd worden omdat mpv de seek nog niet kan verwerken.
    await _player.open(Media(url, httpHeaders: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    }), play: false);

    if (resumeSeconds > 0) {
      try {
        await _player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 15));
      } catch (_) {}
      await _player.seek(Duration(seconds: resumeSeconds.round()));
      debugPrint('[Nova] seeked to ${resumeSeconds.round()}s, position now: ${_player.state.position}');
    }
    await _player.play();

    final native = _player.platform;
    if (native is NativePlayer) {
      Future.delayed(const Duration(seconds: 2), () async {
        try {
          final hwdec = await native.getProperty('hwdec-current');
          final vcodec = await native.getProperty('video-codec');
          final subs = _tracks.subtitle.map((t) => '${t.id}:${t.language}:${t.title}').join(', ');
          final auds = _tracks.audio.map((t) => '${t.id}:${t.language}:${t.title}').join(', ');
          debugPrint('[Nova] hwdec-current=$hwdec video-codec=$vcodec');
          debugPrint('[Nova] subtitle tracks: $subs');
          debugPrint('[Nova] audio tracks: $auds');
          debugPrint('[Nova] position 2s na start: ${_player.state.position}');
        } catch (_) {}
      });
    }

    _player.stream.error.listen((err) {
      if (mounted) {
        setState(() {
          _status = 'Video fout: $err';
          _showPlayer = false;
          _loadingStream = false;
        });
      }
    });

    UserDataService.saveProgress(_progressItem(), resumeSeconds, resumeSeconds > 0 ? resumeSeconds + 100 : 100);

    if (mounted) {
      setState(() {
        _streamUrl = url;
        _loadingStream = false;
        _status = '';
        _showPlayer = true;
      });
    }
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} MB';
  }

  Future<void> _pickSource({Map? episode}) async {
    _currentEpisode = episode;
    final q = episode != null
      ? '$title S${_selectedSeason.toString().padLeft(2,'0')}E${(episode['episode_number'] as int).toString().padLeft(2,'0')}'
      : '$title $year';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0f1520),
      isScrollControlled: true,
      builder: (sheetContext) => FutureBuilder<List>(
        future: _fetchSources(q),
        builder: (context, snapshot) {
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
              child: ListView(
                shrinkWrap: true,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Kies een bron', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8))),
                    )
                  else if ((snapshot.data ?? []).isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Geen bronnen gevonden.', style: TextStyle(color: Colors.grey)),
                    )
                  else
                    for (final s in snapshot.data!)
                      ListTile(
                        title: Text(s['title'] as String, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 13)),
                        subtitle: Text(
                          [
                            if ((s['resolution'] as String).isNotEmpty) s['resolution'],
                            if (s['cached'] == true) 'Direct beschikbaar',
                            _formatSize(s['size_bytes'] as int),
                            if (s['has_nl_subs'] == true) '✓ NL ondertitels'
                            else if (s['has_en_subs'] == true) '✓ EN ondertitels',
                          ].where((e) => (e as String).isNotEmpty).join(' · '),
                          style: TextStyle(
                            color: s['has_nl_subs'] == true ? const Color(0xFF00b4d8) : Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                        onTap: () async {
                          Navigator.pop(sheetContext);
                          final direct = s['direct_url'] as String?;
                          final stream = s['stream_url'] as String?;
                          final chosen = (direct != null && direct.isNotEmpty) ? direct : stream;
                          if (chosen != null) {
                            final resume = await _resumeSeconds(episode: episode);
                            _playUrl(chosen, statusLabel: 'Bron laden...', resumeSeconds: resume);
                          }
                        },
                      ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<List> _fetchSources(String q) async {
    try {
      final baseUrl = (await SettingsService.getBackendUrl()).trim().replaceAll(RegExp(r'/$'), '');
      for (final path in ['/api/debrid/sources', '/debrid/sources']) {
        try {
          final apiUrl = '$baseUrl$path?q=${Uri.encodeComponent(q)}&tmdb_id=${widget.media['id']}&media_type=${isMovie ? "movie" : "tv"}';
          final response = await http.get(Uri.parse(apiUrl)).timeout(const Duration(seconds: 25));
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            final sources = data['sources'] as List?;
            if (sources != null) return sources;
          }
        } catch (_) {
          continue;
        }
      }
    } catch (_) {}
    return const [];
  }

  Widget _trackButton(IconData icon, VoidCallback onTap, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _player.dispose();
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
              if (_showPlayer)
                AspectRatio(
                  aspectRatio: 16/9,
                  child: Stack(children: [
                    Video(controller: _controller),
                    Positioned(
                      top: 8, right: 8,
                      child: Row(children: [
                        _trackButton(Icons.dns_outlined, () => _pickSource(episode: _currentEpisode), 'Andere bron'),
                        if (_hasSelectableTracks(_tracks.audio)) ...[
                          const SizedBox(width: 8),
                          _trackButton(Icons.multitrack_audio, _pickAudioTrack, 'Audio'),
                        ],
                        if (_hasSelectableTracks(_tracks.subtitle)) ...[
                          const SizedBox(width: 8),
                          _trackButton(Icons.subtitles, _pickSubtitleTrack, 'Ondertitels'),
                        ],
                      ]),
                    ),
                  ]),
                )
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
                          if (isMovie) ...[
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _loadingStream ? null : () => _pickSource(),
                              icon: const Icon(Icons.dns_outlined, size: 16, color: Colors.white),
                              label: const Text('Bronnen', style: TextStyle(color: Colors.white, fontSize: 13)),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Colors.white38),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              ),
                            ),
                          ],
                          const SizedBox(width: 8),
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
          GestureDetector(
            onTap: () => _pickSource(episode: ep),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.dns_outlined, color: Colors.grey, size: 18),
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.play_arrow, color: Color(0xFF00b4d8), size: 20),
        ]),
      ),
    );
  }
}

