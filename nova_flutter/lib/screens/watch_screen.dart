import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../widgets/nova_image.dart';
import '../widgets/media_row.dart';
import '../widgets/tv_focusable.dart';
import '../services/tmdb_service.dart';
import '../services/debrid_service.dart';
import '../services/userdata_service.dart';
import '../services/settings_service.dart';
import '../services/device_capability_service.dart';
import 'person_screen.dart';

const tmdbPoster = 'https://image.tmdb.org/t/p/w342';
const tmdbProfile = 'https://image.tmdb.org/t/p/w185';
const tmdbStill = 'https://image.tmdb.org/t/p/w300';
const tmdbBackdrop = 'https://image.tmdb.org/t/p/original';

class WatchScreen extends StatefulWidget {
  final Map<String, dynamic> media;
  final bool autoResume;
  const WatchScreen({super.key, required this.media, this.autoResume = false});
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
  String? _currentSourceUrl;
  Map<String, dynamic> _prefs = {
    'default_audio_lang': 'en',
    'default_sub_lang_1': 'nl',
    'default_sub_lang_2': '',
    'subtitles_enabled': true,
  };
  bool _autoAppliedAudio = false;
  bool _autoAppliedSubs = false;
  bool _autoFetchedExternalSubs = false;
  Map? _savedProgress;
  int? _rating;
  final _scrollCtrl = ScrollController();
  final FocusNode _playFocus = FocusNode();
  final FocusNode _sourcesFocus = FocusNode();
  final FocusNode _watchlistFocus = FocusNode();
  // Losstaand van de knoppen in het infoblok hierboven - dit zijn de kleine
  // pictogram-knoppen die enkel bovenop de speler zelf verschijnen zodra
  // die effectief speelt.
  final FocusNode _playerAreaFocus = FocusNode();
  final FocusNode _playerSourceFocus = FocusNode();
  final FocusNode _playerAudioFocus = FocusNode();
  final FocusNode _playerSubtitleFocus = FocusNode();
  final FocusNode _playerFullscreenFocus = FocusNode();
  final FocusNode _playerPlayPauseFocus = FocusNode();
  final FocusNode _skipSuggestionFocus = FocusNode();
  bool _isFullScreen = false;
  bool get _isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  final List<FocusNode> _starFocusNodes = List.generate(3, (_) => FocusNode());
  bool _endRatingPromptShown = false;
  // Terug-knop en bron/audio/ondertitels-rij verdwijnen na een paar seconden
  // inactiviteit i.p.v. constant over de video te blijven staan - net als
  // bij elke andere videospeler, en verschijnen weer bij de minste interactie.
  bool _controlsVisible = true;
  Timer? _controlsHideTimer;

  void _showControlsBriefly() {
    setState(() => _controlsVisible = true);
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
      // Focus terug naar de video zelf zodra de knoppenbalk vervaagt -
      // anders bleef select soms het laatst-gefocuste (nu onzichtbare)
      // knopje activeren i.p.v. gewoon te pauzeren/hervatten, zoals bij
      // elke andere videospeler waar "OK" altijd gewoon pauzeert.
      if (_showPlayer) _playerAreaFocus.requestFocus();
    });
  }
  String? _seekIndicator;
  Timer? _seekIndicatorTimer;
  Duration _position = Duration.zero;
  bool _isPlaying = true;
  Duration? _dragPosition; // niet-null zolang de balk met muis/aanraking gesleept wordt

  @override
  void initState() {
    super.initState();
    _player = Player();
    // mediacodec_embed (rechtstreeks op de Android Surface tekenen, geen
    // kopie) leek een logische snelheidswinst, maar bleek op deze TV-chip
    // de Codec2-bufferqueue helemaal vast te laten lopen (duizenden
    // opeenvolgende dequeue-fouts in de log, stream laadt dan nooit) - erger
    // dan de kopie die we probeerden te vermijden. Terug naar de standaard
    // vo=gpu + hwdec=auto-safe, die wél werkt (zij het met een kopie per
    // beeld).
    _controller = VideoController(_player);
    // Ruimere netwerkbuffer zodat streamen van een externe (Real-Debrid) URL
    // niet steeds hapert bij kleine snelheidsschommelingen. Op Android is dit
    // veel te zwaar: logcat op een Shield toonde de systeem-lowmemorykiller
    // Nova (én de TV-launcher én de Chromecast-service) tegelijk afschieten
    // vlak na het starten van een 4K-bron, met tot 512+64MiB aan buffers
    // bovenop decodeerbuffers en de rest van het toestel se geheugengebruik.
    // Op de zwakkere Philips (minder geheugen, geen harde kill maar wel
    // constante druk) verklaart dat vermoedelijk ook de aanhoudende traagheid.
    final native = _player.platform;
    if (native is NativePlayer) {
      native.setProperty('cache', 'yes');
      native.setProperty('cache-secs', Platform.isAndroid ? '30' : '120');
      native.setProperty('demuxer-max-bytes', Platform.isAndroid ? '96MiB' : '512MiB');
      native.setProperty('demuxer-max-back-bytes', Platform.isAndroid ? '16MiB' : '64MiB');
      native.setProperty('demuxer-readahead-secs', Platform.isAndroid ? '20' : '60');
      native.setProperty('network-timeout', '30');
      // Hardware-decodering: zonder dit decodeert mpv HEVC/4K+ bronnen op de
      // CPU, wat op hoge resolutie tot haperend beeld leidt ondanks vlotte audio.
      native.setProperty('hwdec', 'auto-safe');
    }
    _loadDetails();
    _checkWatchlist();
    _loadPrefs();
    _loadSavedProgress();
    _loadRating();
    if (isMovie) _checkAvailability();

    // Vanuit "Verder kijken" meteen doorspelen i.p.v. eerst het detailscherm
    // te tonen waar nog eens op Afspelen geklikt moet worden.
    if (widget.autoResume) {
      final savedSeason = widget.media['season_number'];
      final savedEpisode = widget.media['episode_number'];
      if (savedSeason is int) _selectedSeason = savedSeason;
      final episode = savedEpisode is int ? {'episode_number': savedEpisode} : null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _play(episode: episode));
    }

    // Luister naar player updates voor progress
    int lastSave = -1;
    _player.stream.position.listen((pos) {
      if (mounted) setState(() => _position = pos);
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
        // Houd de "bekeken"-markeringen in de afleveringenlijst live bij,
        // zonder het hele scherm opnieuw te moeten laden.
        if (mounted) {
          setState(() => _savedProgress = {
            ...item,
            'current_time': sec.toDouble(),
            'duration': dur.inSeconds.toDouble(),
          });
        }
      }
    });
    // Zichtbare pauze-status: zonder dit was er geen enkel visueel verschil
    // tussen afspelen en pauze buiten het stilvallen van het beeld zelf.
    _player.stream.playing.listen((p) {
      if (mounted) setState(() => _isPlaying = p);
    });

    // Bij het einde van een film (niet per aflevering, dat zou te opdringerig
    // zijn) meteen om een rangschikking vragen - anders scrol je zelf niet
    // meer naar het sterren-rijtje onderaan eens de aftiteling loopt.
    _player.stream.completed.listen((completed) {
      if (completed && isMovie && !_endRatingPromptShown && _rating == null) {
        _endRatingPromptShown = true;
        _showEndRatingPrompt();
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

    // Eén keer geregistreerd i.p.v. bij elke _playUrl() (elke keer opnieuw
    // afspelen/aflevering wisselen) - dat stapelde anders bij elke wissel
    // een extra listener op, die dan allemaal tegelijk op hetzelfde
    // foutmoment vuurden.
    _player.stream.error.listen((err) {
      if (mounted) {
        setState(() {
          _status = 'Video fout: $err';
          _showPlayer = false;
          _loadingStream = false;
        });
      }
    });
  }

  Future<void> _loadSavedProgress() async {
    final saved = await UserDataService.getItemProgress(widget.media['id']);
    if (mounted) setState(() => _savedProgress = saved);
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
  // Verschillende ISO-taalcodes voor dezelfde taal (bv. "nl" vs "dut"/"nld")
  // matchen elkaar niet via startsWith - dus expliciet alle varianten geven,
  // zodat een taal pas als "geen match" telt als écht geen enkele variant
  // gevonden is (i.p.v. per ongeluk een andere taal te raken omdat die eerder
  // in de lijst staat).
  List<String> _langSynonyms(String lang) {
    final l = _normLang(lang);
    if (l.isEmpty) return const [];
    if (l.startsWith('nl') || l.startsWith('dut') || l.startsWith('vla')) {
      return const ['nl', 'nld', 'dut', 'vla'];
    }
    if (l.startsWith('en')) return const ['en', 'eng'];
    return [l];
  }

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
      // Eerst alle varianten van de voorkeurstaal volledig uitputten, dan pas
      // Engels als redmiddel - anders kan een latere taal in een platte lijst
      // per ongeluk eerder matchen dan een synoniem van de voorkeurstaal.
      var audioMatch = _matchTrack(_tracks.audio, _langSynonyms(audioLang.isNotEmpty ? audioLang : 'en'));
      audioMatch ??= _matchTrack(_tracks.audio, ['en', 'eng']);
      debugPrint('[Nova] auto audio match: ${audioMatch != null ? "${audioMatch.id}:${audioMatch.language}" : "geen match"}');
      if (audioMatch != null) _player.setAudioTrack(audioMatch);
    }

    if (!_autoAppliedSubs && hasRealSubs) {
      _autoAppliedSubs = true;
      if (_prefs['subtitles_enabled'] == true) {
        final sub1 = (_prefs['default_sub_lang_1'] as String? ?? 'nl').trim();
        // Eerst enkel een ingebouwd NL-spoor proberen (geen EN-fallback hier),
        // zodat we weten of we automatisch een externe NL-ondertitel moeten
        // ophalen wanneer de bron zelf geen Nederlandse subs heeft. Belangrijk:
        // alle NL-taalcode-varianten (nl/nld/dut/vla) eerst volledig proberen
        // vóór ook maar te kijken naar de ingestelde 2e taal (vaak Engels) -
        // anders wint die 2e taal het van een Nederlands spoor met een andere
        // ISO-code dan waar "nl" letterlijk op matcht.
        final nlMatch = _matchTrack(_tracks.subtitle, _langSynonyms(sub1), avoidForced: true);
        debugPrint('[Nova] auto subtitle match (NL): ${nlMatch != null ? "${nlMatch.id}:${nlMatch.language}" : "geen match"}');
        if (nlMatch != null) {
          _player.setSubtitleTrack(nlMatch);
        } else {
          // Engels als tijdelijke ondertiteling terwijl we op de achtergrond
          // automatisch een gesynchroniseerde NL-versie ophalen.
          final enMatch = _matchTrack(_tracks.subtitle, ['en', 'eng'], avoidForced: true);
          if (enMatch != null) _player.setSubtitleTrack(enMatch);
          if (!_autoFetchedExternalSubs) {
            _autoFetchedExternalSubs = true;
            _loadExternalSubtitle();
          }
        }
      }
    }
  }

  static const _nlTitlePrefixes = ['nl', 'nld', 'dut', 'vla', 'vlaams', 'dutch', 'flemish', 'nederlands'];
  static const _enTitlePrefixes = ['en', 'eng', 'english'];
  static final RegExp _nlTitleRe =
      RegExp(r'\b(nl|nld|dut|vla|vlaams|dutch|flemish|nederlands)\b', caseSensitive: false);
  static final RegExp _enTitleRe = RegExp(r'\b(en|eng|english)\b', caseSensitive: false);

  // Herleidt taal uit de taalcode, en indien die ontbreekt/onbekend is uit de
  // titel (mkv-titels bevatten soms wel "English"/"Nederlands" maar geen
  // taalcode-metadata). \b zodat "Bengali" niet als "en" matcht.
  String? _resolveLangName(String? lang, String? title) {
    final l = _normLang(lang ?? '');
    if (l.startsWith('nl') || l.startsWith('dut') || l.startsWith('vla')) return 'Nederlands';
    if (l.startsWith('en')) return 'Engels';
    final t = title ?? '';
    if (t.isNotEmpty) {
      if (_nlTitleRe.hasMatch(t)) return 'Nederlands';
      if (_enTitleRe.hasMatch(t)) return 'Engels';
    }
    return null;
  }

  String _trackLabel(dynamic track) {
    final id = track.id as String;
    if (id == 'no') return 'Uit';
    if (id == 'auto') return 'Automatisch';
    final lang = track.language as String?;
    final title = track.title as String?;
    final langName = _resolveLangName(lang, title) ?? '';
    if (langName.isNotEmpty) {
      if (title != null && title.isNotEmpty && title.toLowerCase() != langName.toLowerCase()) {
        return '$langName ($title)';
      }
      return langName;
    }
    return title ?? lang ?? 'Spoor $id';
  }

  static const _allowedLangPrefixes = [..._nlTitlePrefixes, ..._enTitlePrefixes];

  bool _isAllowedLang(dynamic track) {
    final id = track.id as String;
    if (id == 'auto' || id == 'no') return true;
    final lang = (track.language as String? ?? '').toLowerCase();
    final title = (track.title as String? ?? '').toLowerCase();
    if (lang.isEmpty && title.isEmpty) return true;
    return _allowedLangPrefixes.any((p) => lang.startsWith(p) || title.contains(p));
  }

  // Strenger dan _isAllowedLang: enkel sporen met een BEVESTIGDE NL/EN-taal
  // (code of titel) worden getoond. Gebruikt voor de ondertitel-lijst, want
  // die bevat vaak veel niet-getagde sporen in andere talen (FR/DE/ES/...)
  // die de gebruiker daar niet wil zien.
  bool _isConfirmedNlOrEn(dynamic track) {
    final id = track.id as String;
    if (id == 'auto' || id == 'no') return true;
    return _resolveLangName(track.language as String?, track.title as String?) != null;
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
            for (var i = 0; i < options.length; i++)
              ListTile(
                autofocus: i == 0,
                title: Text(_trackLabel(options[i]), style: const TextStyle(color: Colors.white)),
                trailing: options[i] == _currentTrack.audio ? const Icon(Icons.check, color: Color(0xFF00b4d8)) : null,
                onTap: () {
                  _player.setAudioTrack(options[i]);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _pickSubtitleTrack() {
    final options = _tracks.subtitle.where(_isConfirmedNlOrEn).toList();
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
            for (var i = 0; i < options.length; i++)
              ListTile(
                autofocus: i == 0,
                title: Text(_trackLabel(options[i]), style: const TextStyle(color: Colors.white)),
                trailing: options[i] == _currentTrack.subtitle ? const Icon(Icons.check, color: Color(0xFF00b4d8)) : null,
                onTap: () {
                  _player.setSubtitleTrack(options[i]);
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

  // Checkt (via ffprobe op de backend, zonder de video te hoeven openen) of
  // de bron zelf al een Nederlandse ondertitel bevat.
  Future<bool> _hasEmbeddedDutchSubtitle(String streamUrl) async {
    try {
      final baseUrl = (await SettingsService.getBackendUrl()).trim().replaceAll(RegExp(r'/$'), '');
      for (final path in ['/stream/subtitles', '/api/stream/subtitles']) {
        final uri = Uri.parse('$baseUrl$path').replace(queryParameters: {'url': streamUrl});
        final r = await http.get(uri).timeout(const Duration(seconds: 20));
        if (r.statusCode == 200) {
          final data = jsonDecode(r.body);
          final tracks = (data['tracks'] as List?) ?? [];
          return tracks.any((t) {
            final lang = _normLang((t['language'] as String?) ?? '');
            final title = ((t['title'] as String?) ?? '').toLowerCase();
            return lang.startsWith('nl') || lang.startsWith('dut') || title.contains('dutch') || title.contains('nederlands');
          });
        }
      }
    } catch (e) {
      debugPrint('[Nova] embedded-ondertitel check mislukt: $e');
    }
    return false;
  }

  // Zoekt op OpenSubtitles en synchroniseert via de backend; geeft enkel de
  // VTT-url terug (of null bij falen), zonder zelf de player aan te raken -
  // zo is dit zowel bruikbaar vóór het afspelen start als achteraf handmatig.
  Future<String?> _fetchExternalSubtitleUri(String streamUrl, {Map? episode}) async {
    final tmdbId = widget.media['id'];
    if (tmdbId is! int) return null;
    try {
      final baseUrl = (await SettingsService.getBackendUrl()).trim().replaceAll(RegExp(r'/$'), '');
      final params = {
        'url': streamUrl,
        'tmdb_id': '$tmdbId',
        'media_type': isMovie ? 'movie' : 'tv',
        'lang': 'nl',
        if (episode != null) 'season': '$_selectedSeason',
        if (episode != null) 'episode': '${episode['episode_number']}',
      };
      for (final path in ['/stream/subtitle-external.vtt', '/api/stream/subtitle-external.vtt']) {
        final vttUrl = Uri.parse('$baseUrl$path').replace(queryParameters: params);
        // Ruim: bij meerdere kandidaten kan de backend meerdere audio-
        // extracties + ffsubsync-runs na elkaar proberen voor er 1 lukt.
        final check = await http.get(vttUrl).timeout(const Duration(seconds: 600));
        if (check.statusCode == 200) return vttUrl.toString();
        if (check.statusCode != 404) continue;
        return null;
      }
    } catch (e) {
      debugPrint('[Nova] externe ondertitels ophalen mislukt: $e');
    }
    return null;
  }

  Future<void> _loadExternalSubtitle() async {
    final url = _streamUrl;
    if (url == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nederlandse ondertitels zoeken en synchroniseren...'), duration: Duration(seconds: 6)));
    final vttUrl = await _fetchExternalSubtitleUri(url, episode: _currentEpisode);
    if (!mounted) return;
    if (vttUrl != null) {
      await _player.setSubtitleTrack(SubtitleTrack.uri(vttUrl, title: 'Nederlands (extern)', language: 'nl'));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nederlandse ondertitels geladen.'), backgroundColor: Color(0xFF00b4d8)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Geen Nederlandse ondertitels gevonden.'), backgroundColor: Colors.redAccent));
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

  // Sommige meegegeven media-data (bv. een oude rangschikking die ooit met
  // het foute media_type werd opgeslagen) kan zeggen "film" terwijl TMDB het
  // als serie kent of omgekeerd - _loadDetails() zet dit recht zodra de TMDB-
  // aanroep met het aangenomen type mislukt, zodat de Afspelen-knop niet
  // stilletjes verdwijnt.
  bool? _mediaTypeOverride;
  // TMDB-responses (vooral /recommendations en /similar) laten soms zowel
  // "title" als "first_air_date" in het item zitten, met de niet-van-
  // toepassing-zijnde velden als lege string "" i.p.v. helemaal afwezig
  // (null) - een strikte "== null"-check trapte daar dus in en gokte
  // stelselmatig het verkeerde type voor films die via zo'n rij geopend
  // werden, wat Afspelen elke keer eerst nodeloos als serie liet zoeken.
  bool get isMovie => _mediaTypeOverride ??
    (widget.media['title'] != null &&
     (widget.media['first_air_date'] as String? ?? '').isEmpty);
  String get title => widget.media['title'] ?? widget.media['name'] ?? '';
  String get year {
    final d = (widget.media['release_date'] ?? widget.media['first_air_date'] ?? '') as String;
    return d.length >= 4 ? d.substring(0, 4) : '';
  }

  // Genres/duur/makers komen uit de volledige detail-fetch (_detail), niet
  // uit widget.media (het zoekresultaat) - die heeft enkel genre_ids
  // (nummers, geen namen) en geen runtime.
  String? get _genresLabel {
    final genres = (_detail?['genres'] as List?)?.cast<Map>() ?? const [];
    if (genres.isEmpty) return null;
    return genres.map((g) => g['name']).whereType<String>().join(' • ');
  }

  String? get _runtimeLabel {
    if (isMovie) {
      final rt = (_detail?['runtime'] as num?)?.toInt();
      if (rt == null || rt <= 0) return null;
      final h = rt ~/ 60, m = rt % 60;
      return h > 0 ? '${h}u ${m}m' : '${m}m';
    }
    final list = (_detail?['episode_run_time'] as List?) ?? const [];
    if (list.isEmpty) return null;
    final rt = (list.first as num).toInt();
    return '~${rt}m per aflevering';
  }

  String? get _creatorsLabel {
    if (isMovie) return null;
    final creators = (_detail?['created_by'] as List?)?.cast<Map>() ?? const [];
    if (creators.isEmpty) return null;
    return creators.map((c) => c['name']).whereType<String>().join(', ');
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

  Future<void> _loadRating() async {
    final stars = await UserDataService.getRating(widget.media['id']);
    if (mounted) setState(() => _rating = stars);
  }

  // Tikken op dezelfde ster die al gekozen was, wist de rangschikking weer -
  // zo kan je een fout tikje herstellen zonder een apart "wis"-knopje nodig
  // te hebben.
  Future<void> _setRating(int stars) async {
    if (_rating == stars) {
      await UserDataService.clearRating(widget.media['id']);
      setState(() => _rating = null);
    } else {
      await UserDataService.setRating(widget.media, stars, mediaType: isMovie ? 'movie' : 'tv');
      setState(() => _rating = stars);
    }
  }

  Future<void> _showEndRatingPrompt() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0f1520),
          title: const Text('Wat vond je ervan?', style: TextStyle(color: Colors.white)),
          content: Row(mainAxisSize: MainAxisSize.min, children: [
            for (int i = 1; i <= 3; i++)
              IconButton(
                autofocus: i == 1,
                onPressed: () async {
                  await _setRating(i);
                  setDialogState(() {});
                  if (context.mounted) Navigator.pop(context);
                },
                icon: Icon(
                  (_rating != null && _rating! >= i) ? Icons.star : Icons.star_border,
                  color: (_rating != null && _rating! >= i) ? Colors.amber : Colors.white54,
                  size: 32,
                ),
                tooltip: i == 1 ? 'Niet voor mij' : i == 2 ? 'Oké' : 'Top!',
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Overslaan')),
          ],
        );
      }),
    );
  }

  // Titel/metadata/omschrijving/knoppen/sterren - herbruikt zowel overlayed
  // op de hero-achtergrond (vóór het afspelen) als plat onder de speler/het
  // laadscherm (tijdens/na het afspelen), zodat je altijd nog kan
  // rangschikken en de titel/omschrijving blijft zien i.p.v. dat die
  // volledig verdwijnt zodra de video start.
  Widget _buildInfoBlock(List seasons, {bool overlay = true}) {
    final rating = (widget.media['vote_average'] as num?)?.toStringAsFixed(1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: overlay ? 640 : double.infinity),
        child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: overlay ? 34 : 26, fontWeight: FontWeight.w900, color: Colors.white,
            height: 1.1, shadows: overlay ? const [Shadow(blurRadius: 12, color: Colors.black)] : null)),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 10, children: [
        if (year.isNotEmpty) Text(year, style: const TextStyle(color: Colors.grey, fontSize: 14)),
        if (rating != null) Text('★ $rating', style: const TextStyle(color: Colors.amber, fontSize: 14)),
        if (_runtimeLabel != null) Text(_runtimeLabel!, style: const TextStyle(color: Colors.grey, fontSize: 14)),
        if (seasons.isNotEmpty) Text('${seasons.length} seizoen${seasons.length > 1 ? "en" : ""}',
          style: const TextStyle(color: Colors.grey, fontSize: 14)),
      ]),
      if (_genresLabel != null) ...[
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: overlay ? 560 : double.infinity),
          child: Text(_genresLabel!, style: const TextStyle(color: Colors.white54, fontSize: 13)),
        ),
      ],
      if (_creatorsLabel != null) ...[
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: overlay ? 560 : double.infinity),
          child: Text('Van ${_creatorsLabel!}', style: const TextStyle(color: Colors.white54, fontSize: 13)),
        ),
      ],
      const SizedBox(height: 14),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: overlay ? 560 : double.infinity),
        child: Text(widget.media['overview'] ?? '', maxLines: 3, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5)),
      ),
      const SizedBox(height: 18),
      Row(children: [
        if (isMovie)
          _focusRing(
            focusNode: _playFocus,
            child: ElevatedButton.icon(
              focusNode: _playFocus,
              onPressed: _loadingStream ? null : () => _play(),
              icon: _loadingStream
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Icon(Icons.play_arrow, size: 20),
              label: Text(_loadingStream ? 'Laden...' : 'Afspelen'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isAvailable == true ? const Color(0xFF00b4d8) : Colors.white,
                foregroundColor: _isAvailable == true ? Colors.white : Colors.black,
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              ),
            ),
          ),
        if (isMovie) ...[
          const SizedBox(width: 12),
          _focusRing(
            focusNode: _sourcesFocus,
            child: OutlinedButton.icon(
              focusNode: _sourcesFocus,
              onPressed: _loadingStream ? null : () => _pickSource(),
              icon: const Icon(Icons.dns_outlined, size: 18, color: Colors.white),
              label: const Text('Bronnen', style: TextStyle(color: Colors.white, fontSize: 15)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white54),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              ),
            ),
          ),
        ],
        const SizedBox(width: 12),
        _focusRing(
          focusNode: _watchlistFocus,
          child: OutlinedButton.icon(
            focusNode: _watchlistFocus,
            onPressed: _toggleWatchlist,
            icon: Icon(_inWatchlist ? Icons.bookmark : Icons.bookmark_outline, size: 18,
              color: _inWatchlist ? const Color(0xFF00b4d8) : Colors.white),
            label: Text(_inWatchlist ? 'In watchlist' : '+ Watchlist',
              style: TextStyle(color: _inWatchlist ? const Color(0xFF00b4d8) : Colors.white, fontSize: 15)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: _inWatchlist ? const Color(0xFF00b4d8) : Colors.white54),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        for (int i = 1; i <= 3; i++)
          _focusRing(
            focusNode: _starFocusNodes[i - 1],
            child: IconButton(
              focusNode: _starFocusNodes[i - 1],
              onPressed: () => _setRating(i),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                (_rating != null && _rating! >= i) ? Icons.star : Icons.star_border,
                color: (_rating != null && _rating! >= i) ? Colors.amber : Colors.white54,
                size: 24,
              ),
              tooltip: i == 1 ? 'Niet voor mij' : i == 2 ? 'Oké' : 'Top!',
            ),
          ),
        if (_rating != null) ...[
          const SizedBox(width: 4),
          Text(
            _rating == 1 ? 'Niet voor mij' : _rating == 2 ? 'Oké' : 'Top!',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ],
      ]),
      if (_status.isNotEmpty) Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(_status, style: const TextStyle(color: Color(0xFF00b4d8), fontSize: 13)),
      ),
    ]);
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

    final assumedIsMovie = isMovie;
    List results;
    try {
      results = await Future.wait([
        assumedIsMovie ? TmdbService.getMovieDetail(id) : TmdbService.getTvDetail(id),
        TmdbService.getCredits(id, assumedIsMovie ? 'movie' : 'tv'),
        TmdbService.getRecommendations(id, assumedIsMovie ? 'movie' : 'tv'),
      ]);
    } catch (_) {
      // Aangenomen type klopte niet - probeer het andere type i.p.v. hier
      // stil vast te lopen (en daardoor bv. de Afspelen-knop nooit te tonen
      // als dit eigenlijk wél een film bleek).
      final correctedIsMovie = !assumedIsMovie;
      results = await Future.wait([
        correctedIsMovie ? TmdbService.getMovieDetail(id) : TmdbService.getTvDetail(id),
        TmdbService.getCredits(id, correctedIsMovie ? 'movie' : 'tv'),
        TmdbService.getRecommendations(id, correctedIsMovie ? 'movie' : 'tv'),
      ]);
      if (mounted) setState(() => _mediaTypeOverride = correctedIsMovie);
      // Liep initState() al mis met het foute type, dan is de beschikbaar-
      // heidscheck voor een film toen overgeslagen - alsnog inhalen.
      if (correctedIsMovie) _checkAvailability();
    }
    if (!mounted) return;
    setState(() {
      _detail = results[0] as Map;
      _cast = results[1] as List;
      _similar = results[2] as List;
    });
    // _selectedSeason kan al gezet zijn (bv. door "Verder kijken" dat direct
    // naar de juiste aflevering doorspeelt) - dat mag hier niet overschreven
    // worden terug naar seizoen 1.
    if (!isMovie) _loadSeason(_selectedSeason);
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

  // D-pad-vriendelijk vooruit-/terugspoelen: er is geen aanraakbare
  // voortgangsbalk (die vereist slepen, wat een afstandsbediening niet kan),
  // dus links/rechts op de speler zelf springt in vaste stappen.
  void _seek(int deltaSeconds) {
    final pos = _player.state.position;
    final dur = _player.state.duration;
    var target = pos + Duration(seconds: deltaSeconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    _player.seek(target);
    setState(() => _seekIndicator = deltaSeconds > 0 ? '+${deltaSeconds}s' : '${deltaSeconds}s');
    _seekIndicatorTimer?.cancel();
    _seekIndicatorTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekIndicator = null);
    });
  }

  // "Terug" tijdens het afspelen sluit enkel de speler en toont opnieuw het
  // scherm met titel/omschrijving/rangschikking - niet de hele detailpagina
  // verlaten, dat voelde niet als "terug" maar als "weg".
  void _handleBack() {
    if (_showPlayer) {
      _player.pause();
      setState(() => _showPlayer = false);
    } else {
      Navigator.pop(context);
    }
  }

  // Zonder echte audio-detectie (vergelijking met een andere aflevering)
  // is er geen betrouwbare manier om precies te weten waar de aftiteling
  // begint - een vast tijdvenster zit er ofwel te vroeg ofwel te laat naast
  // per episode. 100s resterend is een redelijk gemiddelde tussen wat te
  // laat (45s) en te vroeg (180s) bleek in de praktijk.
  static const _nextEpisodeWindow = Duration(seconds: 100);

  // Enkel binnen het al geladen seizoen - een aflevering uit het volgende
  // seizoen zou een aparte season-fetch vergen enkel voor deze knop.
  Map? get _nextEpisodeInSeason {
    if (isMovie || _currentEpisode == null) return null;
    final episodes = (_seasonData?['episodes'] as List?) ?? [];
    final nextNum = (_currentEpisode!['episode_number'] as int) + 1;
    for (final e in episodes) {
      if (e is Map && e['episode_number'] == nextNum) return e;
    }
    return null;
  }

  bool get _showNextEpisodeButton {
    final dur = _player.state.duration;
    if (dur <= Duration.zero || isMovie || _currentEpisode == null || _nextEpisodeInSeason == null) return false;
    final remaining = dur - _position;
    return remaining > Duration.zero && remaining < _nextEpisodeWindow;
  }

  Widget _buildSkipSuggestionButton({required IconData icon, required String label, required VoidCallback onTap}) {
    return Focus(
      // GEEN autofocus: dit knopje verschijnt automatisch tijdens het kijken
      // (laatste ~100s van een aflevering) - met autofocus zou het de
      // afstandsbediening-focus stiekem wegkapen van waar de kijker net mee
      // bezig was, zonder dat die zelf iets deed. Gewoon bereikbaar via
      // omhoog vanaf de video (zie _playerAreaFocus), niet vanzelf gepakt.
      focusNode: _skipSuggestionFocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        _showControlsBriefly();
        if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _playerAreaFocus.requestFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter ||
            event.logicalKey == LogicalKeyboardKey.space) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(builder: (context) {
        final focused = Focus.of(context).hasFocus;
        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          // Dezelfde gedeelde TvHighlightBox als de rest van de app i.p.v.
          // een eigen kopie van de rand/gloed-decoratie.
          child: TvHighlightBox(
            focused: focused,
            muted: true,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
              ]),
            ),
          ),
        );
      }),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  Widget _buildPlaybackProgressBar() {
    final dur = _player.state.duration;
    final totalMs = dur.inMilliseconds > 0 ? dur.inMilliseconds : 1;
    final shown = _dragPosition ?? _position;
    final valueMs = shown.inMilliseconds.clamp(0, totalMs).toDouble();
    return Row(children: [
      Text(_formatDuration(shown),
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(width: 8),
      Expanded(
        // ExcludeFocus: een Slider doet standaard mee in toetsenbord-/D-pad-
        // focustraversal, wat zou botsen met onze eigen links/rechts-spoel-
        // afhandeling op de video zelf. Met muis/aanraking blijft slepen/
        // klikken gewoon werken - enkel focus wordt uitgesloten.
        child: ExcludeFocus(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: const Color(0xFF00b4d8),
              inactiveTrackColor: Colors.white24,
              thumbColor: const Color(0xFF00b4d8),
              overlayColor: const Color(0xFF00b4d8).withOpacity(0.2),
            ),
            child: Slider(
              value: valueMs,
              min: 0,
              max: totalMs.toDouble(),
              onChangeStart: (v) => setState(() => _dragPosition = Duration(milliseconds: v.round())),
              onChanged: (v) => setState(() => _dragPosition = Duration(milliseconds: v.round())),
              onChangeEnd: (v) {
                final target = Duration(milliseconds: v.round());
                _player.seek(target);
                setState(() {
                  _position = target;
                  _dragPosition = null;
                });
                _showControlsBriefly();
              },
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Text(_formatDuration(dur),
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
    ]);
  }

  Future<void> _toggleFullScreen() async {
    if (!_isDesktop) return;
    final next = !_isFullScreen;
    await windowManager.setFullScreen(next);
    if (mounted) setState(() => _isFullScreen = next);
  }

  void _togglePlayPause() {
    if (_player.state.playing) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  // Voorkomt dat twee _play()-aanroepen tegelijk lopen (bv. dubbel tikken op
  // "Volgende aflevering", of een verdwaalde herhaalde toets-event) - zonder
  // dit konden twee _player.open()-aanroepen door elkaar racen, wat als
  // overlappende audio/beeld en "verspringende" staat naar buiten kwam.
  bool _playInFlight = false;

  Future<void> _play({Map? episode}) async {
    if (_playInFlight) return;
    _playInFlight = true;
    try {
      await _playInternal(episode: episode);
    } finally {
      _playInFlight = false;
    }
  }

  Future<void> _playInternal({Map? episode}) async {
    _currentEpisode = episode;
    if (Platform.isAndroid) {
      // Op een TV-toestel met maar ~2GB RAM (logcat op een Shield bevestigde
      // dit) kan alles wat Flutter's afbeeldingscache nog vasthoudt van het
      // doorbladeren van posterrijen samen met de decodeerbuffers van de
      // speler genoeg zijn om het systeem geheugen te laten leegdraaien - de
      // systeem-lowmemorykiller schiet dan zowel Nova als andere apps af.
      // Ruim dat op vlak vóór de zware decodeerbelasting begint.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    }
    setState(() {
      _loadingStream = true;
      _status = 'Zoeken naar streams...';
      _showPlayer = false;
    });
    // Als dit vanuit een afleveringenrij verderop de pagina komt, spring
    // naar boven zodat je het laadscherm/de player ook echt ziet i.p.v.
    // zelf te moeten scrollen.
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(0, duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
    }

    final q = episode != null
      ? '$title S${_selectedSeason.toString().padLeft(2,'0')}E${(episode['episode_number'] as int).toString().padLeft(2,'0')}'
      : '$title $year';

    try {
      final baseUrl = (await SettingsService.getBackendUrl()).trim().replaceAll(RegExp(r'/$'), '');
      // Op geheugenarme TV-toestellen laat de server automatisch geen 4K-
      // bronnen kiezen (crasht anders soms door de systeem-lowmemorykiller) -
      // via "Bronnen" kan je alsnog zelf bewust een hogere resolutie kiezen.
      final maxRes = await DeviceCapabilityService.maxAutoResolution;

      String? url;
      String? source;
      String? errorMessage;

      // "Verder kijken" kan meteen bij het openen automatisch afspelen, nog
      // vóór _loadDetails() een verkeerd aangenomen film/serie-type heeft
      // kunnen rechtzetten (dat vergt zelf al een mislukte + een geslaagde
      // netwerk-aanroep). Dus hier niet vertrouwen op timing, maar gewoon
      // zelf het andere type proberen als het eerste niets oplevert.
      Future<void> attempt(String mediaType) async {
        for (final path in ['/api/debrid/search', '/debrid/search']) {
          try {
            final apiUrl = '$baseUrl$path?q=${Uri.encodeComponent(q)}&tmdb_id=${widget.media['id']}&media_type=$mediaType&client=windows'
              '${maxRes != null ? '&max_resolution=$maxRes' : ''}';
            // 25s was te krap: een koude zoekopdracht (server probeert tot 30
            // kandidaat-bronnen) haalt dat soms niet, waardoor je "geen
            // streams gevonden" te zien kreeg terwijl de server gewoon nog
            // bezig was - een 2de druk op Afspelen werkte dan wél, want de
            // server had het resultaat intussen al gecachet.
            final response = await http.get(Uri.parse(apiUrl)).timeout(const Duration(seconds: 75));

            if (response.statusCode == 200) {
              final data = jsonDecode(response.body);
              final direct = data['direct_url'] as String?;
              final stream = data['stream_url'] as String?;
              url = (direct != null && direct.isNotEmpty) ? direct : stream;
              source = data['source'] ?? 'unknown';
              if (url != null) return;
              errorMessage = data['message'];
            } else {
              errorMessage = 'Server fout: ${response.statusCode}';
            }
          } catch (e) {
            errorMessage = 'Verbindingsfout: $e';
            continue;
          }
        }
      }

      await attempt(isMovie ? 'movie' : 'tv');
      if (url == null) await attempt(isMovie ? 'tv' : 'movie');

      // Soms faalt de zoekopdracht tijdelijk (een kortstondig RD/AIOStreams-
      // hikje) terwijl een volgende identieke poging wél lukt - automatisch
      // één keer herproberen i.p.v. de gebruiker zelf meermaals op Afspelen
      // te laten drukken voor hetzelfde resultaat.
      if (url == null && mounted) {
        setState(() => _status = 'Nog eens proberen...');
        await Future.delayed(const Duration(seconds: 2));
        await attempt(isMovie ? 'movie' : 'tv');
        if (url == null) await attempt(isMovie ? 'tv' : 'movie');
      }

      if (url == null) {
        setState(() {
          _status = errorMessage ?? 'Geen stream gevonden voor deze titel.';
          _loadingStream = false;
        });
        return;
      }
      // Losse non-nullable kopie: `url` zelf blijft String? voor de analyzer
      // omdat het binnen de attempt()-closure hierboven muteert, waardoor
      // type-promotie na de null-check hierboven niet standhoudt.
      final resolvedUrl = url!;
      setState(() => _currentSourceUrl = resolvedUrl);

      final statusLabel = source == 'scraper' ? 'Gevonden op internet. Laden...' : 'Gevonden in bibliotheek. Laden...';
      final resume = await _resumeSeconds(episode: episode);

      // Vóór het afspelen starten al voor Nederlandse ondertitels zorgen, zodat
      // de film pas begint als ze al klaarstaan - i.p.v. ze er halverwege pas
      // bij te laden. OpenSubtitles+ffsubsync eerst proberen: dat garandeert
      // sync op de audio van déze release. Een ingebouwd spoor in het
      // bestand zelf is niet gegarandeerd getimed op exact deze encode (bleek
      // in de praktijk soms flink uit sync), dus dat is enkel het redmiddel
      // als er geen externe ondertitel gevonden wordt.
      String? externalSubUri;
      if (_prefs['subtitles_enabled'] == true) {
        setState(() => _status = 'Nederlandse ondertitels zoeken en synchroniseren (kan ~1 min duren)...');
        externalSubUri = await _fetchExternalSubtitleUri(resolvedUrl, episode: episode);
        if (externalSubUri == null && mounted) {
          setState(() => _status = 'Ondertitels controleren...');
          final hasEmbeddedNl = await _hasEmbeddedDutchSubtitle(resolvedUrl);
          debugPrint('[Nova] geen externe NL-ondertitel gevonden, ingebouwd spoor aanwezig: $hasEmbeddedNl');
        }
      }
      if (!mounted) return;

      await _playUrl(resolvedUrl, statusLabel: statusLabel, resumeSeconds: resume, externalSubtitleUri: externalSubUri);
    } catch (e) {
      setState(() {
        _status = 'Fout bij afspelen: $e';
        _loadingStream = false;
      });
    }
  }

  Future<void> _playUrl(String url, {String statusLabel = 'Laden...', double resumeSeconds = 0, String? externalSubtitleUri}) async {
    final baseUrl = (await SettingsService.getBackendUrl()).trim().replaceAll(RegExp(r'/$'), '');
    if (url.startsWith('/')) {
      url = baseUrl + url;
    }

    _autoAppliedAudio = false;
    // Als we al een extern gesynchroniseerde NL-ondertitel hebben (vóór het
    // afspelen opgehaald), hoeft de auto-apply logica niet nog eens een
    // (Engels) ingebouwd spoor te kiezen zodra de tracks binnenkomen.
    _autoAppliedSubs = externalSubtitleUri != null;
    _autoFetchedExternalSubs = externalSubtitleUri != null;
    _streamUrl = url; // vroeg gezet: tracks kunnen al gedetecteerd worden voor open() hieronder klaar is
    setState(() {
      _status = statusLabel;
      _loadingStream = true;
      _tracks = const Tracks();
      _currentTrack = const Track();
    });

    debugPrint('[Nova] _playUrl: resumeSeconds=$resumeSeconds url=$url externalSub=$externalSubtitleUri');

    // Player configureren voor betere compatibiliteit. We openen gepauzeerd,
    // wachten tot mpv de duur kent (bron is dan echt geladen), seeken pas
    // daarna en starten dan het afspelen - direct seeken vlak na open() kan
    // stil genegeerd worden omdat mpv de seek nog niet kan verwerken.
    await _player.open(Media(url, httpHeaders: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    }), play: false);

    if (externalSubtitleUri != null) {
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(externalSubtitleUri, title: 'Nederlands (extern)', language: 'nl'));
    }

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

    UserDataService.saveProgress(_progressItem(), resumeSeconds, resumeSeconds > 0 ? resumeSeconds + 100 : 100);

    if (mounted) {
      setState(() {
        _loadingStream = false;
        _status = '';
        _showPlayer = true;
      });
      _showControlsBriefly();
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
                  else ...(() {
                    final list = List<Map>.from(snapshot.data!);
                    final currentIdx = _currentSourceUrl == null
                        ? -1
                        : list.indexWhere((s) => s['direct_url'] == _currentSourceUrl);
                    final current = currentIdx == -1 ? null : list.removeAt(currentIdx);
                    return [
                      if (current != null) ...[
                        _sourceTile(current, episode: episode, sheetContext: sheetContext, isCurrent: true, autofocus: true),
                        const Divider(color: Colors.white12, height: 1),
                      ],
                      for (var i = 0; i < list.length; i++)
                        _sourceTile(list[i], episode: episode, sheetContext: sheetContext, autofocus: current == null && i == 0),
                    ];
                  })(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _sourceTile(Map s, {Map? episode, required BuildContext sheetContext, bool isCurrent = false, bool autofocus = false}) {
    return ListTile(
      autofocus: autofocus,
      leading: isCurrent ? const Icon(Icons.play_circle_fill, color: Color(0xFF00b4d8)) : null,
      title: Text(s['title'] as String, maxLines: 2, overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal)),
      subtitle: Text(
        [
          if (isCurrent) 'Huidige bron',
          if ((s['resolution'] as String).isNotEmpty) s['resolution'],
          if (s['cached'] == true) 'Direct beschikbaar',
          _formatSize(s['size_bytes'] as int),
          if (s['has_nl_subs'] == true) '✓ NL ondertitels'
          else if (s['has_en_subs'] == true) '✓ EN ondertitels',
        ].where((e) => (e as String).isNotEmpty).join(' · '),
        style: TextStyle(
          color: isCurrent ? const Color(0xFF00b4d8) : (s['has_nl_subs'] == true ? const Color(0xFF00b4d8) : Colors.grey),
          fontSize: 11,
        ),
      ),
      onTap: () async {
        Navigator.pop(sheetContext);
        final direct = s['direct_url'] as String?;
        final stream = s['stream_url'] as String?;
        final chosen = (direct != null && direct.isNotEmpty) ? direct : stream;
        if (chosen != null) {
          setState(() => _currentSourceUrl = direct);
          final resume = await _resumeSeconds(episode: episode);
          _playUrl(chosen, statusLabel: 'Bron laden...', resumeSeconds: resume);
        }
      },
    );
  }

  Future<List> _fetchSources(String q) async {
    try {
      final baseUrl = (await SettingsService.getBackendUrl()).trim().replaceAll(RegExp(r'/$'), '');
      for (final path in ['/api/debrid/sources', '/debrid/sources']) {
        try {
          final apiUrl = '$baseUrl$path?q=${Uri.encodeComponent(q)}&tmdb_id=${widget.media['id']}&media_type=${isMovie ? "movie" : "tv"}';
          final response = await http.get(Uri.parse(apiUrl)).timeout(const Duration(seconds: 75));
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

  // Zichtbare focus-ring rond de Afspelen/Bronnen/Watchlist-knoppen -
  // Material's ingebouwde focus-highlight bleek op de TV amper zichtbaar.
  Widget _focusRing({required FocusNode focusNode, required Widget child}) {
    return AnimatedBuilder(
      animation: focusNode,
      builder: (context, c) {
        final focused = focusNode.hasFocus;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: focused ? const Color(0xFF00b4d8) : Colors.transparent, width: 3),
          ),
          child: c,
        );
      },
      child: child,
    );
  }

  Widget _trackButton(IconData icon, VoidCallback onTap, String tooltip, {bool autofocus = false, FocusNode? focusNode}) {
    final node = focusNode ?? FocusNode();
    final button = InkWell(
      autofocus: autofocus,
      focusNode: node,
      focusColor: Colors.white24,
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
    );
    return Tooltip(
      message: tooltip,
      child: _focusRing(focusNode: node, child: button),
    );
  }

  @override
  void dispose() {
    _player.dispose();
    _scrollCtrl.dispose();
    _playFocus.dispose();
    _sourcesFocus.dispose();
    _watchlistFocus.dispose();
    _playerAreaFocus.dispose();
    _playerSourceFocus.dispose();
    _playerAudioFocus.dispose();
    _playerSubtitleFocus.dispose();
    _playerFullscreenFocus.dispose();
    _playerPlayPauseFocus.dispose();
    _skipSuggestionFocus.dispose();
    for (final n in _starFocusNodes) { n.dispose(); }
    _seekIndicatorTimer?.cancel();
    _controlsHideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backdrop = widget.media['backdrop_path'];
    final poster = widget.media['poster_path'];
    final seasons = (_detail?['seasons'] as List?)?.where((s) => (s['season_number'] as int) > 0).toList() ?? [];

    return PopScope<void>(
      // Tijdens het afspelen vangt dit ook de fysieke/afstandsbediening-
      // terugknop op (niet enkel het pijltje in beeld) - anders verlaat die
      // meteen de hele pagina i.p.v. eerst gewoon de speler te sluiten.
      canPop: !_showPlayer,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
      backgroundColor: const Color(0xFF080c14),
      body: SafeArea(
        child: SingleChildScrollView(
          controller: _scrollCtrl,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Player of backdrop
              if (_showPlayer)
                Container(
                  width: double.infinity,
                  color: Colors.black,
                  // Muisbeweging telt ook als interactie voor de auto-
                  // verberg-timer van de knoppen - zonder dit verdwijnen ze
                  // na 4s en komen ze nooit meer terug voor een muisgebruiker
                  // (toetsenbord-navigatie ververst de timer al apart).
                  child: MouseRegion(
                    onHover: (_) => _showControlsBriefly(),
                    child: Stack(alignment: Alignment.center, children: [
                    // Wazige, gedimde achtergrond op basis van de eigen
                    // backdrop i.p.v. kale zwarte leegte rond de (met opzet
                    // smallere) speler.
                    if (backdrop != null)
                      Positioned.fill(
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 45, sigmaY: 45),
                          child: Opacity(
                            opacity: 0.35,
                            child: NovaImage(path: '$tmdbBackdrop$backdrop',
                              width: double.infinity, height: double.infinity, fit: BoxFit.cover),
                          ),
                        ),
                      ),
                    Center(
                      child: ConstrainedBox(
                        // In volledig scherm mag de video het hele venster
                        // vullen - de max-breedte is er enkel om 'm in een
                        // gewoon (niet-fullscreen) venster niet absurd breed
                        // te laten worden op een ultrawide scherm.
                        constraints: BoxConstraints(maxWidth: _isFullScreen ? double.infinity : 1100),
                        child: AspectRatio(
                          aspectRatio: 16/9,
                          child: Stack(children: [
                            // Autofocus: zodra de speler start heeft niets
                            // meer focus (het vorige focusbare element - bv.
                            // een episoderij - verdween uit de boom), dus
                            // een afstandsbediening had zonder dit nergens
                            // naartoe te gaan. Links/rechts spoelt, omlaag
                            // springt naar de bron/audio/ondertitels-rij
                            // (die nu onderaan bij de voortgangsbalk staat),
                            // vandaar verder omlaag naar de rest van de
                            // pagina (rangschikking, seizoenen...).
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              // Klikken op het beeld zelf pauzeert/hervat -
                              // zoals bij zowat elke andere videospeler.
                              onTap: () {
                                _togglePlayPause();
                                _showControlsBriefly();
                              },
                              child: Focus(
                                autofocus: true,
                                focusNode: _playerAreaFocus,
                                onKeyEvent: (node, event) {
                                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                                  _showControlsBriefly();
                                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                                    _seek(-30);
                                    return KeyEventResult.handled;
                                  }
                                  if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                                    _seek(30);
                                    return KeyEventResult.handled;
                                  }
                                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                                    _playerPlayPauseFocus.requestFocus();
                                    return KeyEventResult.handled;
                                  }
                                  if (event.logicalKey == LogicalKeyboardKey.arrowUp && _showNextEpisodeButton) {
                                    _skipSuggestionFocus.requestFocus();
                                    return KeyEventResult.handled;
                                  }
                                  if (event.logicalKey == LogicalKeyboardKey.select ||
                                      event.logicalKey == LogicalKeyboardKey.enter ||
                                      event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                                      event.logicalKey == LogicalKeyboardKey.space) {
                                    _togglePlayPause();
                                    return KeyEventResult.handled;
                                  }
                                  return KeyEventResult.ignored;
                                },
                                // NoVideoControls: we hebben al een volledig
                                // eigen bedieningsbalk - media_kit's eigen
                                // standaardbalk gaf anders een dubbele,
                                // overlappende set knoppen.
                                child: Video(
                                  controller: _controller,
                                  controls: NoVideoControls,
                                  // Standaardgrootte was aan de kleine kant om
                                  // vanaf de zetel comfortabel te lezen.
                                  subtitleViewConfiguration: const SubtitleViewConfiguration(
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 44,
                                      fontWeight: FontWeight.w600,
                                      height: 1.2,
                                      shadows: [
                                        Shadow(color: Colors.black, blurRadius: 6, offset: Offset(0, 0)),
                                        Shadow(color: Colors.black, blurRadius: 2, offset: Offset(1, 1)),
                                      ],
                                    ),
                                    padding: EdgeInsets.only(bottom: 24, left: 24, right: 24),
                                  ),
                                ),
                              ),
                            ),
                            // Suggestie, geen automatische actie: blijft gewoon
                            // staan zolang van toepassing, onafhankelijk van de
                            // andere bedieningselementen (die na inactiviteit
                            // vervagen) - je beslist zelf of en wanneer je klikt.
                            if (_showNextEpisodeButton)
                              Positioned(
                                right: 16, bottom: 80,
                                child: _buildSkipSuggestionButton(
                                  icon: Icons.skip_next,
                                  label: 'Volgende aflevering',
                                  onTap: () => _play(episode: _nextEpisodeInSeason),
                                ),
                              ),
                            // Korte visuele bevestiging dat spoelen effectief
                            // iets deed - zonder aanraakbare voortgangsbalk is
                            // dit anders onzichtbaar feedback-loos.
                            if (_seekIndicator != null)
                              Center(
                                child: IgnorePointer(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                    child: Text(_seekIndicator!,
                                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                                  ),
                                ),
                              ),
                            // Zonder dit was pauze visueel niet te onderscheiden
                            // van gewoon afspelen buiten het stilvallen van het
                            // beeld - blijft staan zolang gepauzeerd, geen timer.
                            if (!_isPlaying)
                              Center(
                                child: IgnorePointer(
                                  child: Container(
                                    padding: const EdgeInsets.all(18),
                                    decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                                    child: const Icon(Icons.play_arrow, color: Colors.white, size: 52),
                                  ),
                                ),
                              ),
                            // Onderaan balk: voortgang + bron/audio/onder-
                            // titels samen, net als bij de meeste spelers -
                            // stond eerder apart bovenaan rechts.
                            Positioned(
                              left: 12, right: 12, bottom: 10,
                              child: AnimatedOpacity(
                                opacity: _controlsVisible ? 1 : 0,
                                duration: const Duration(milliseconds: 250),
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  // Met muis/aanraking sleepbaar/klikbaar om
                                  // te spoelen (een afstandsbediening kan
                                  // niet slepen, maar D-pad links/rechts op
                                  // de video zelf blijft daarvoor werken).
                                  // Alleen klikbaar terwijl zichtbaar - anders
                                  // blijft hij onzichtbaar maar aanklikbaar.
                                  IgnorePointer(
                                    ignoring: !_controlsVisible,
                                    child: _buildPlaybackProgressBar(),
                                  ),
                                  const SizedBox(height: 8),
                                  IgnorePointer(
                                    ignoring: !_controlsVisible,
                                    child: Builder(builder: (context) {
                                      // Expliciete links/rechts-koppeling i.p.v. te
                                      // vertrouwen op Flutter's automatische
                                      // "dichtstbijzijnde widget"-navigatie tussen
                                      // deze kleine, dicht opeengepakte knopjes -
                                      // die bleek op deze TV's niet altijd
                                      // betrouwbaar.
                                      final order = <FocusNode>[
                                        _playerPlayPauseFocus,
                                        _playerSourceFocus,
                                        if (_hasSelectableTracks(_tracks.audio)) _playerAudioFocus,
                                        if (_hasSelectableTracks(_tracks.subtitle)) _playerSubtitleFocus,
                                        if (_isDesktop) _playerFullscreenFocus,
                                      ];
                                      return Focus(
                                        canRequestFocus: false,
                                        skipTraversal: true,
                                        onKeyEvent: (node, event) {
                                          if (event is! KeyDownEvent) return KeyEventResult.ignored;
                                          _showControlsBriefly();
                                          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                                            _playerAreaFocus.requestFocus();
                                            return KeyEventResult.handled;
                                          }
                                          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                                            // Bewust een muur: tijdens het afspelen mag D-pad-omlaag
                                            // niet de speler uit naar de pagina eronder - enkel de
                                            // terugknop (fysiek of het pijltje linksboven) verlaat de
                                            // speler, zoals bij een echte fullscreen videospeler.
                                            return KeyEventResult.handled;
                                          }
                                          if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                                              event.logicalKey == LogicalKeyboardKey.arrowRight) {
                                            final current = order.indexWhere((n) => n.hasFocus);
                                            if (current == -1) return KeyEventResult.ignored;
                                            final delta = event.logicalKey == LogicalKeyboardKey.arrowRight ? 1 : -1;
                                            final next = current + delta;
                                            if (next >= 0 && next < order.length) {
                                              order[next].requestFocus();
                                              return KeyEventResult.handled;
                                            }
                                            return KeyEventResult.handled;
                                          }
                                          return KeyEventResult.ignored;
                                        },
                                        // Pauze/play weer terug links (zoals in de meeste
                                        // spelers), bron/audio/ondertitels/fullscreen rechts.
                                        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                          _trackButton(
                                            _isPlaying ? Icons.pause : Icons.play_arrow,
                                            _togglePlayPause,
                                            _isPlaying ? 'Pauzeren' : 'Afspelen',
                                            focusNode: _playerPlayPauseFocus,
                                          ),
                                          Row(mainAxisSize: MainAxisSize.min, children: [
                                            _trackButton(Icons.dns_outlined, () => _pickSource(episode: _currentEpisode), 'Andere bron', focusNode: _playerSourceFocus),
                                            if (_hasSelectableTracks(_tracks.audio)) ...[
                                              const SizedBox(width: 8),
                                              _trackButton(Icons.multitrack_audio, _pickAudioTrack, 'Audio', focusNode: _playerAudioFocus),
                                            ],
                                            if (_hasSelectableTracks(_tracks.subtitle)) ...[
                                              const SizedBox(width: 8),
                                              _trackButton(Icons.subtitles, _pickSubtitleTrack, 'Ondertitels', focusNode: _playerSubtitleFocus),
                                            ],
                                            if (_isDesktop) ...[
                                              const SizedBox(width: 8),
                                              _trackButton(
                                                _isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                                                _toggleFullScreen,
                                                _isFullScreen ? 'Volledig scherm afsluiten' : 'Volledig scherm',
                                                focusNode: _playerFullscreenFocus,
                                              ),
                                            ],
                                          ]),
                                        ]),
                                      );
                                    }),
                                  ),
                                ]),
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ),
                    // Terugknop moet hier ook beschikbaar zijn - eerder was
                    // die enkel zichtbaar vóór het afspelen start (hero/
                    // laadscherm), maar verdween zodra de video echt speelt.
                    // Zelfde auto-verberg-gedrag als de bron/audio/
                    // ondertitels-knoppen hierboven.
                    Positioned(
                      top: 16, left: 16,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: IgnorePointer(
                          ignoring: !_controlsVisible,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: _handleBack,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                              child: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ]),
                  ),
                )
              else if (_loadingStream)
                // Duidelijk laadscherm i.p.v. enkel een klein statuszinnetje
                // onderaan de hero - vooral voor wie de app voor het eerst
                // gebruikt moet meteen zichtbaar zijn dat er iets gebeurt
                // (stream zoeken, ondertitels ophalen, ...).
                Container(
                  width: double.infinity,
                  height: 500,
                  color: Colors.black,
                  child: Stack(alignment: Alignment.center, children: [
                    if (backdrop != null)
                      Positioned.fill(
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 45, sigmaY: 45),
                          child: Opacity(
                            opacity: 0.3,
                            child: NovaImage(path: '$tmdbBackdrop$backdrop',
                              width: double.infinity, height: double.infinity, fit: BoxFit.cover),
                          ),
                        ),
                      ),
                    Positioned.fill(child: Container(color: Colors.black.withOpacity(0.35))),
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      const CircularProgressIndicator(color: Color(0xFF00b4d8)),
                      const SizedBox(height: 20),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Text(_status, textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ]),
                    Positioned(
                      top: 16, left: 16,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                          child: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
                        ),
                      ),
                    ),
                  ]),
                )
              else
                SizedBox(
                  height: 500,
                  child: Stack(fit: StackFit.expand, children: [
                    if (backdrop != null)
                      NovaImage(path: '$tmdbBackdrop$backdrop', width: double.infinity, height: 500,
                        fit: BoxFit.cover, alignment: const Alignment(0, -0.4))
                    else if (poster != null)
                      NovaImage(path: '$tmdbPoster$poster', width: double.infinity, height: 500, fit: BoxFit.cover)
                    else
                      Container(color: const Color(0xFF0f1520)),
                    Container(decoration: const BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.transparent, Color(0xFF080c14)],
                        stops: [0.0, 0.45, 1.0]))),
                    Container(decoration: const BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight,
                        colors: [Color(0xF2080c14), Colors.transparent],
                        stops: [0.0, 0.6]))),
                    Positioned(
                      top: 16, left: 16,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                          child: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
                        ),
                      ),
                    ),
                    Positioned(bottom: 32, left: 32, right: 32, child: _buildInfoBlock(seasons)),
                  ]),
                ),

              // Titel/omschrijving/knoppen/sterren staan hier ook nog eens
              // (plat, niet overlayed op de video) zolang er afgespeeld of
              // geladen wordt - anders verdwijnt alle info (en de kans om te
              // rangschikken) volledig van het scherm zodra je op Afspelen drukt.
              if (_showPlayer || _loadingStream)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                  child: _buildInfoBlock(seasons, overlay: false),
                ),

              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Seizoenen
                    if (!isMovie && seasons.isNotEmpty) ...[
                      const Text('Afleveringen', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white)),
                      const SizedBox(height: 14),
                      // Duidelijk klikbare seizoen-pillen i.p.v. een kleine,
                      // makkelijk over het hoofd geziene dropdown - je ziet in
                      // één oogopslag hoeveel seizoenen er zijn en welke actief is.
                      SizedBox(
                        height: 44,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: seasons.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 10),
                          itemBuilder: (_, i) {
                            final s = seasons[i];
                            final sn = s['season_number'] as int;
                            final active = sn == _selectedSeason;
                            return TvFocusable(
                              borderRadius: BorderRadius.circular(22),
                              onTap: () => _loadSeason(sn),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                padding: const EdgeInsets.symmetric(horizontal: 18),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: active ? const Color(0xFF00b4d8) : const Color(0xFF0f1520),
                                  borderRadius: BorderRadius.circular(22),
                                  border: Border.all(color: active ? Colors.transparent : Colors.white24),
                                ),
                                child: Text(
                                  'Seizoen $sn',
                                  style: TextStyle(
                                    color: active ? Colors.white : Colors.grey.shade300,
                                    fontSize: 14,
                                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 6),
                      Builder(builder: (context) {
                        final current = seasons.firstWhere(
                          (s) => s['season_number'] == _selectedSeason,
                          orElse: () => seasons.first,
                        );
                        return Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4),
                          child: Text('${current['episode_count']} afleveringen',
                            style: const TextStyle(color: Colors.grey, fontSize: 13)),
                        );
                      }),
                      const SizedBox(height: 6),
                      if (_loadingSeason)
                        const Center(child: CircularProgressIndicator(color: Color(0xFF00b4d8)))
                      else
                        ...(_seasonData?['episodes'] as List? ?? []).map((ep) => _buildEpisode(ep)),
                    ],

                    // Cast
                    if (_cast.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      const Text('Cast', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white)),
                      const SizedBox(height: 14),
                      SizedBox(height: 172, child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _cast.length,
                        itemBuilder: (_, i) {
                          final p = _cast[i];
                          final profile = p['profile_path'] as String?;
                          final character = p['character'] as String?;
                          final personId = p['id'] as int?;
                          return Container(width: 96, margin: const EdgeInsets.only(right: 14),
                            child: Column(children: [
                              TvFocusable(
                                borderRadius: BorderRadius.circular(44),
                                onTap: personId == null ? null : () => Navigator.push(context, MaterialPageRoute(
                                  builder: (_) => PersonScreen(personId: personId, name: p['name'] as String?, profilePath: profile))),
                                child: CircleAvatar(radius: 44, backgroundColor: const Color(0xFF0f1520),
                                  backgroundImage: profile != null ? NetworkImage('$tmdbProfile$profile') : null,
                                  child: profile == null ? const Icon(Icons.person, color: Colors.grey, size: 32) : null),
                              ),
                              const SizedBox(height: 8),
                              Text(p['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                              if (character != null && character.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(character, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ]),
                          );
                        },
                      )),
                    ],

                  ],
                ),
              ),

              // Meer zoals dit - buiten de padding hierboven, want MediaRow
              // regelt zijn eigen horizontale marge (net als op het home-scherm).
              if (_similar.isNotEmpty)
                MediaRow(
                  title: 'Meer zoals dit',
                  height: 260,
                  itemCount: _similar.length,
                  itemBuilder: (_, i) {
                    final item = _similar[i];
                    final p = item['poster_path'];
                    return Container(width: 150, margin: const EdgeInsets.symmetric(horizontal: 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        TvFocusable(
                          onTap: () => Navigator.pushReplacement(context, MaterialPageRoute(
                            builder: (_) => WatchScreen(media: Map<String, dynamic>.from(item)))),
                          borderRadius: BorderRadius.circular(10),
                          child: ClipRRect(borderRadius: BorderRadius.circular(10),
                            child: p != null
                              ? NovaImage(path: '$tmdbPoster$p', height: 210, width: 150, fit: BoxFit.cover)
                              : Container(height: 210, width: 150, color: const Color(0xFF0f1520))),
                        ),
                        const SizedBox(height: 6),
                        Text(item['title'] ?? item['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: Colors.white70)),
                      ]));
                  },
                ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
      ),
    );
  }

  // Vergelijkt deze aflevering met de éne opgeslagen kijk-positie van deze
  // serie (er is geen per-aflevering geschiedenis) om af te leiden of ze
  // "voor deze" liggen (bekeken), "erop" (met voortgangsbalk) of erna
  // (nog niet bekeken) - een redelijke aanname bij lineair kijken.
  ({bool watched, double? progress}) _episodeWatchState(int epNum) {
    final sp = _savedProgress;
    if (sp == null || sp['season_number'] == null) return (watched: false, progress: null);
    final savedSeason = sp['season_number'] as int;
    final savedEp = sp['episode_number'] as int;
    if (_selectedSeason < savedSeason || (_selectedSeason == savedSeason && epNum < savedEp)) {
      return (watched: true, progress: null);
    }
    if (_selectedSeason == savedSeason && epNum == savedEp) {
      final t = (sp['current_time'] as num?)?.toDouble() ?? 0;
      final d = (sp['duration'] as num?)?.toDouble() ?? 0;
      if (d > 0) {
        final f = (t / d).clamp(0.0, 1.0);
        if (f > 0.92) return (watched: true, progress: null);
        if (t > 10) return (watched: false, progress: f);
      }
    }
    return (watched: false, progress: null);
  }

  Widget _buildEpisode(Map ep) {
    final still = ep['still_path'];
    final epNum = ep['episode_number'] as int;
    final runtime = ep['runtime'];
    final state = _episodeWatchState(epNum);
    return TvFocusable(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _play(episode: ep),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF0f1520),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.withOpacity(0.12)),
        ),
        child: Row(children: [
          SizedBox(
            width: 34,
            child: state.watched
              ? const Icon(Icons.check_circle, color: Color(0xFF00b4d8), size: 20)
              : Text('$epNum',
                  style: const TextStyle(color: Colors.grey, fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          ),
          const SizedBox(width: 12),
          Stack(children: [
            ClipRRect(borderRadius: BorderRadius.circular(8),
              child: still != null
                ? NovaImage(path: '$tmdbStill$still', width: 140, height: 82, fit: BoxFit.cover)
                : Container(width: 140, height: 82, color: const Color(0xFF080c14),
                    child: const Icon(Icons.play_circle_outline, color: Colors.grey))),
            if (state.watched)
              Positioned.fill(
                child: DecoratedBox(decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4), borderRadius: BorderRadius.circular(8))),
              ),
            if (state.watched)
              const Positioned.fill(child: Center(child: Icon(Icons.check_circle, color: Colors.white, size: 22))),
            if (state.progress != null)
              Positioned(bottom: 0, left: 0, right: 0,
                child: Container(
                  height: 3, color: Colors.white24,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: state.progress,
                    child: Container(color: const Color(0xFF00b4d8)),
                  ),
                ),
              ),
          ]),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Expanded(child: Text(ep['name'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (runtime != null) Text('${runtime}m', style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
            const SizedBox(height: 4),
            Text(ep['overview'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.grey, fontSize: 12, height: 1.4)),
          ])),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _pickSource(episode: ep),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.dns_outlined, color: Colors.grey, size: 20),
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.play_arrow, color: Color(0xFF00b4d8), size: 24),
        ]),
      ),
    );
  }
}

