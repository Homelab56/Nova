import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/settings_service.dart';
import 'home_screen.dart';

class SettingsScreen extends StatefulWidget {
  final bool isFirstRun;
  const SettingsScreen({super.key, this.isFirstRun = false});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _backendCtrl = TextEditingController();
  Map<String, dynamic>? _status;
  bool _loadingStatus = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _backendCtrl.text = await SettingsService.getBackendUrl();
    if (_backendCtrl.text.isNotEmpty) {
      _fetchStatus();
    }
    setState(() {});
  }

  Future<void> _fetchStatus() async {
    if (_backendCtrl.text.isEmpty) return;
    setState(() => _loadingStatus = true);
    try {
      final url = _backendCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
      final r = await http.get(Uri.parse('$url/api/settings/status')).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        setState(() => _status = jsonDecode(r.body));
      }
    } catch (e) {
      debugPrint('Status fetch error: $e');
    } finally {
      setState(() => _loadingStatus = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await SettingsService.setBackendUrl(_backendCtrl.text.trim());
    await _fetchStatus();
    setState(() => _saving = false);

    if (widget.isFirstRun && mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
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
        automaticallyImplyLeading: !widget.isFirstRun,
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
            _buildStatusCard('Prowlarr / Jackett', _status!['jackett']),
            _buildStatusCard('Dumbarr Mount', _status!['media']),
          ],
        ],
      ),
    );
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
