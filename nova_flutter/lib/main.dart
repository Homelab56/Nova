import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/settings_screen.dart';
import 'screens/profile_screen.dart';
import 'services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  // Tijdelijke diagnose voor de TV-afstandsbediening: logt elke ontvangen
  // toets + wie op dat moment focus heeft, zodat navigatieproblemen via
  // logcat te herleiden zijn i.p.v. te moeten gokken wat er precies gebeurt.
  HardwareKeyboard.instance.addHandler((event) {
    debugPrint('[Nova][key] ${event.runtimeType} ${event.logicalKey.debugName} '
      '| focus=${FocusManager.instance.primaryFocus?.debugLabel}');
    return false;
  });
  final configured = await SettingsService.isConfigured();
  runApp(NovaApp(startOnSettings: !configured));
}

class NovaApp extends StatelessWidget {
  final bool startOnSettings;
  const NovaApp({super.key, this.startOnSettings = false});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nova',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF080c14),
        colorScheme: const ColorScheme.dark(primary: Color(0xFF00b4d8), surface: Color(0xFF0f1520)),
        fontFamily: 'Roboto',
      ),
      // Bij elke opstart eerst een profiel laten kiezen (zoals Netflix) -
      // er wordt bewust geen laatst-gekozen profiel onthouden.
      home: startOnSettings ? const SettingsScreen(isFirstRun: true) : const ProfileScreen(),
    );
  }
}
