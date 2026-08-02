import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/settings_screen.dart';
import 'screens/profile_screen.dart';
import 'services/settings_service.dart';

String _keyName(LogicalKeyboardKey k) {
  final known = {
    LogicalKeyboardKey.arrowUp: 'arrowUp',
    LogicalKeyboardKey.arrowDown: 'arrowDown',
    LogicalKeyboardKey.arrowLeft: 'arrowLeft',
    LogicalKeyboardKey.arrowRight: 'arrowRight',
    LogicalKeyboardKey.select: 'select',
    LogicalKeyboardKey.enter: 'enter',
    LogicalKeyboardKey.numpadEnter: 'numpadEnter',
    LogicalKeyboardKey.space: 'space',
    LogicalKeyboardKey.goBack: 'goBack',
    LogicalKeyboardKey.escape: 'escape',
    LogicalKeyboardKey.gameButtonA: 'gameButtonA',
  };
  return known[k] ?? 'keyId=0x${k.keyId.toRadixString(16)}';
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  // Tijdelijke diagnose voor de TV-afstandsbediening: logt elke ontvangen
  // toets + wie op dat moment focus heeft, zodat navigatieproblemen via
  // logcat te herleiden zijn i.p.v. te moeten gokken wat er precies gebeurt.
  // debugName/debugLabel geven altijd null terug in een release-build (met
  // opzet weggelaten door Flutter om de apk klein te houden), dus hier
  // bewust build-mode-onafhankelijke velden gebruikt.
  HardwareKeyboard.instance.addHandler((event) {
    final f = FocusManager.instance.primaryFocus;
    debugPrint('[Nova][key] ${event.runtimeType} ${_keyName(event.logicalKey)} '
      '| focus=${f?.context?.widget.runtimeType}#${identityHashCode(f)}');
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
