import 'dart:io';
import 'package:flutter/services.dart';

// Op geheugenarme Android TV-toestellen (bv. een Nvidia Shield met maar
// ~2GB RAM, of een smart-TV waar de TV-software zelf al het meeste
// geheugen inneemt) kan automatisch een zware 4K-bron kiezen de app - en
// soms zelfs andere apps - laten crashen door de systeem-lowmemorykiller.
// Dit bepaalt eenmalig (en cachet) hoeveel RAM het toestel heeft, en welke
// maximale resolutie de automatische bronkeuze daarom mag overwegen. Een
// gebruiker kan via "Bronnen" altijd nog zelf bewust een hogere resolutie
// kiezen - dit beperkt enkel wat de app zelf automatisch pakt.
class DeviceCapabilityService {
  static const _channel = MethodChannel('nova/device_info');
  static int? _totalRamMb;
  static int? _maxAutoResolution;

  static Future<int?> get maxAutoResolution async {
    if (_maxAutoResolution != null) return _maxAutoResolution;
    if (!Platform.isAndroid) {
      _maxAutoResolution = null; // desktop: geen limiet
      return null;
    }
    try {
      final ram = _totalRamMb ??= await _channel.invokeMethod<int>('getTotalRamMb');
      if (ram == null) {
        _maxAutoResolution = null;
        return null;
      }
      // Ruime marge: 4K/HEVC-decodering vraagt zelf ook geheugen bovenop
      // wat de TV-software/launcher/casting-diensten al bezet houden.
      _maxAutoResolution = ram < 3000 ? 1080 : null;
      return _maxAutoResolution;
    } catch (_) {
      _maxAutoResolution = null;
      return null;
    }
  }
}
