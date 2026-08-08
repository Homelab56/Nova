import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/settings_service.dart';
import '../widgets/tv_focusable.dart';
import 'profile_screen.dart';

class SettingsScreen extends StatefulWidget {
  final bool isFirstRun;
  const SettingsScreen({super.key, this.isFirstRun = false});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

const Map<String, String> kLangOptions = {'nl': 'Nederlands', 'en': 'Engels'};

class _SettingsScreenState extends State<SettingsScreen> {
  final _backendCtrl = TextEditingController();
  Map<String, dynamic>? _status;
  bool _loadingStatus = false;
  bool _saving = false;

  String _audioLang = 'en';
  String _subLang1 = 'nl';
  String? _subLang2 = 'nl';
  bool _subsEnabled = true;
  bool _savingPrefs = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _backendCtrl.text = await SettingsService.getBackendUrl();
    if (_backendCtrl.text.isNotEmpty) {
      _fetchStatus();
      _loadPrefs();
    }
    setState(() {});
  }

  // Normaliseert eender welke taalcode (bv. "nl-be", "nld", "eng") naar een
  // waarde die exact overeenkomt met een sleutel in kLangOptions, zodat de
  // dropdown nooit crasht op een waarde die niet in zijn itemslijst zit.
  String _clampLang(String? v, String fallback) {
    final norm = (v ?? '').toLowerCase().trim();
    if (norm.startsWith('nl') || norm.startsWith('dut') || norm.startsWith('vla')) return 'nl';
    if (norm.startsWith('en')) return 'en';
    return kLangOptions.containsKey(fallback) ? fallback : 'en';
  }

  Future<void> _loadPrefs() async {
    final url = _backendCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
    for (final path in ['/user/prefs', '/api/user/prefs']) {
      try {
        final r = await http.get(Uri.parse('$url$path')).timeout(const Duration(seconds: 5));
        if (r.statusCode == 200) {
          final data = jsonDecode(r.body) as Map<String, dynamic>;
          if (data.isEmpty) return;
          setState(() {
            _audioLang = _clampLang(data['default_audio_lang'] as String?, 'en');
            _subLang1 = _clampLang(data['default_sub_lang_1'] as String?, 'nl');
            final s2 = data['default_sub_lang_2'] as String?;
            _subLang2 = (s2 == null || s2.isEmpty) ? null : _clampLang(s2, 'nl');
            _subsEnabled = data['subtitles_enabled'] as bool? ?? true;
          });
          return;
        }
      } catch (e) {
        debugPrint('Prefs fetch error ($path): $e');
      }
    }
  }

  Future<void> _savePrefs() async {
    setState(() => _savingPrefs = true);
    final url = _backendCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
    final body = jsonEncode({
      'default_audio_lang': _audioLang,
      'default_sub_lang_1': _subLang1,
      'default_sub_lang_2': _subLang2 ?? '',
      'subtitles_enabled': _subsEnabled,
    });
    for (final path in ['/user/prefs', '/api/user/prefs']) {
      try {
        final r = await http.post(Uri.parse('$url$path'),
          headers: {'Content-Type': 'application/json'}, body: body).timeout(const Duration(seconds: 5));
        if (r.statusCode == 200) break;
      } catch (e) {
        debugPrint('Prefs save error ($path): $e');
      }
    }
    setState(() => _savingPrefs = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Voorkeuren opgeslagen'), backgroundColor: Color(0xFF00b4d8)));
    }
  }

  Future<void> _fetchStatus() async {
    if (_backendCtrl.text.isEmpty) return;
    setState(() => _loadingStatus = true);
    final url = _backendCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
    for (final path in ['/settings/status', '/api/settings/status']) {
      try {
        final r = await http.get(Uri.parse('$url$path')).timeout(const Duration(seconds: 5));
        if (r.statusCode == 200) {
          setState(() => _status = jsonDecode(r.body));
          break;
        }
      } catch (e) {
        debugPrint('Status fetch error ($path): $e');
      }
    }
    setState(() => _loadingStatus = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await SettingsService.setBackendUrl(_backendCtrl.text.trim());
    await _fetchStatus();
    setState(() => _saving = false);

    if (widget.isFirstRun && mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Opgeslagen'), backgroundColor: Color(0xFF00b4d8)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080c14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0f1520),
        elevation: 0,
        title: Row(children: [
          Image.asset('assets/logo.png', height: 28),
          const SizedBox(width: 10),
          Text(widget.isFirstRun ? 'Welkom bij Nova' : 'Instellingen',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ]),
        automaticallyImplyLeading: false,
        // Zie category_screen.dart - standaard terugknop van AppBar is
        // amper zichtbaar bij focus op de TV. Bij de allereerste opstart
        // (isFirstRun) is er bewust geen terugknop - je kan daar nog niet
        // vandaan (nog geen server ingesteld).
        leading: widget.isFirstRun ? null : Center(
          child: TvFocusable(
            muted: true,
            borderRadius: BorderRadius.circular(20),
            onTap: () => Navigator.pop(context),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.arrow_back),
            ),
          ),
        ),
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Server Verbinding', 
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Voer het adres van je Nova server in om te verbinden.',
            style: TextStyle(color: Colors.grey, fontSize: 14)),
          const SizedBox(height: 16),
          
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0f1520),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.withOpacity(0.1)),
            ),
            child: Column(
              children: [
                TextField(
                  controller: _backendCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    hintText: 'http://192.168.1.75:8002',
                    hintStyle: const TextStyle(color: Colors.grey),
                    filled: true, fillColor: const Color(0xFF080c14),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF00b4d8))),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00b4d8),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(_saving ? 'Verbinden...' : 'Verbinding Opslaan',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),
          const Text('Afspeel voorkeuren',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Standaard audio- en ondertiteltaal bij het starten van een video.',
            style: TextStyle(color: Colors.grey, fontSize: 14)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0f1520),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.withOpacity(0.1)),
            ),
            child: Column(
              children: [
                _buildLangRow('Standaard audio', _audioLang, kLangOptions,
                  (v) => setState(() => _audioLang = v ?? _audioLang)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: Text('Ondertitels', style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 14))),
                  Switch(
                    value: _subsEnabled,
                    activeColor: const Color(0xFF00b4d8),
                    onChanged: (v) => setState(() => _subsEnabled = v),
                  ),
                ]),
                if (_subsEnabled) ...[
                  const SizedBox(height: 4),
                  _buildLangRow('Ondertiteltaal', _subLang1, kLangOptions,
                    (v) => setState(() => _subLang1 = v ?? _subLang1)),
                  const SizedBox(height: 12),
                  _buildLangRow('2e taal (indien 1e niet beschikbaar)', _subLang2, {
                    ...kLangOptions,
                  }, (v) => setState(() => _subLang2 = v), allowNone: true),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _savingPrefs ? null : _savePrefs,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00b4d8),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(_savingPrefs ? 'Opslaan...' : 'Voorkeuren Opslaan',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),
          const Text('Systeem Status',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Geconfigureerd via .env op de server.',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 16),

          if (_loadingStatus)
            const Center(child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(color: Color(0xFF00b4d8)),
            ))
          else if (_status == null)
            const Center(child: Padding(
              padding: EdgeInsets.all(20),
              child: Text('Geen verbinding met server.', style: TextStyle(color: Colors.redAccent)),
            ))
          else ...[
            _buildStatusCard('TMDB Metadata', _status!['tmdb']),
            _buildStatusCard('Real-Debrid', _status!['rd']),
            _buildStatusCard('AIOStreams', (_status!['aiostreams'] as Map<String, dynamic>?) ?? {'ok': false, 'message': 'Niet geconfigureerd (zet AIOSTREAMS_URL op de server).'}),
            _buildStatusCard('Prowlarr / Jackett', _status!['jackett']),
            _buildStatusCard('Media-mount', _status!['media']),
          ],
        ],
      ),
    );
  }

  Widget _buildLangRow(String label, String? value, Map<String, String> options, ValueChanged<String?> onChanged, {bool allowNone = false}) {
    return Row(children: [
      Expanded(child: Text(label, style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 14))),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF080c14),
          borderRadius: BorderRadius.circular(10),
        ),
        child: DropdownButton<String?>(
          value: value,
          underline: const SizedBox.shrink(),
          dropdownColor: const Color(0xFF0f1520),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          items: [
            if (allowNone) const DropdownMenuItem(value: null, child: Text('Geen')),
            ...options.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))),
          ],
          onChanged: onChanged,
        ),
      ),
    ]);
  }

  Widget _buildStatusCard(String title, Map<String, dynamic> data) {
    final bool ok = data['ok'] ?? false;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0f1520),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ok ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.error, color: ok ? Colors.green : Colors.redAccent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 2),
                Text(data['message'] ?? (ok ? 'Verbonden' : 'Fout'), 
                  style: TextStyle(color: ok ? Colors.green.shade300 : Colors.red.shade300, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
