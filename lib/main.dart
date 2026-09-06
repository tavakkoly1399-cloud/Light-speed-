import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_singbox_client/flutter_singbox_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

final vpn = SingboxClient();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await vpn.initialize();
  } catch (e) {
    debugPrint('VPN initialize error: $e');
  }

  runApp(const LightSpeedApp());
}

class LightSpeedApp extends StatelessWidget {
  const LightSpeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Light speed',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF05070D),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
        fontFamily: 'sans',
      ),
      home: const HomePage(),
    );
  }
}

enum ServerSelectionMode {
  auto,
  manual,
}

class Server {
  Server({
    required this.raw,
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    required this.outbound,
  });

  final String raw;
  final String name;
  final String type;
  final String host;
  final int port;
  final Map<String, dynamic> outbound;

  int? ping;
}

// ============================================================================
// HOME PAGE
// ============================================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver {
  final TextEditingController url = TextEditingController();

  final List<Server> servers = [];

  StreamSubscription? stateSub;
  StreamSubscription? trafficSub;
  StreamSubscription? faultSub;
  StreamSubscription? networkQualitySub;
  StreamSubscription? stunSub;

  Timer? timer;

  int page = 0;

  bool loading = false;
  bool testing = false;
  bool connected = false;
  bool connecting = false;

  bool networkTestRunning = false;
  bool stunTestRunning = false;

  String stateText = 'آماده اتصال';

  String download = '0 Mbps';
  String upload = '0 Mbps';

  String testDownload = '0 Mbps';
  String testUpload = '0 Mbps';
  String testPing = '—';

  String stunLatency = '—';
  String externalIp = '—';
  String natType = '—';

  int downloadTotalBytes = 0;
  int uploadTotalBytes = 0;

  int? totalBytes;
  int? usedBytes;
  int? uploadBytes;
  int? downloadBytes;
  int? expireAt;

  double downloadCapacityBps = 0;
  double uploadCapacityBps = 0;

  int? idleLatencyMs;
  int? downloadRpm;
  int? uploadRpm;

  Server? selectedServer;

  ServerSelectionMode selectionMode =
      ServerSelectionMode.auto;

  String? lastUpdate;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _listenVpn();
    loadSaved();

    timer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => loadSubscription(silent: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    stateSub?.cancel();
    trafficSub?.cancel();
    faultSub?.cancel();
    networkQualitySub?.cancel();
    stunSub?.cancel();

    timer?.cancel();
    url.dispose();

    super.dispose();
  }

  // ==========================================================================
  // APP LIFECYCLE
  // ==========================================================================

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (state == AppLifecycleState.resumed) {
      _syncVpnState();
    }
  }

  Future<void> _syncVpnState() async {
    try {
      final current = await vpn.getServiceState();

      if (!mounted) return;

      final text = current.toString().toLowerCase();

      setState(() {
        if (text.contains('started') ||
            text.contains('running') ||
            text.contains('connected')) {
          connected = true;
          connecting = false;
          stateText = 'VPN متصل است';
        } else if (text.contains('starting')) {
          connecting = true;
          stateText = 'در حال اتصال...';
        } else if (text.contains('stopping')) {
          connecting = true;
          stateText = 'در حال قطع اتصال...';
        } else if (text.contains('stopped') ||
            text.contains('disconnected')) {
          connected = false;
          connecting = false;
          stateText = 'VPN متوقف است';
        }
      });
    } catch (e) {
      debugPrint('getServiceState: $e');
    }
  }

  // ==========================================================================
  // VPN EVENTS
  // ==========================================================================

  void _listenVpn() {
    stateSub = vpn.serviceStateStream.listen(
      (state) {
        if (!mounted) return;

        final text = state.toString();
        final low = text.toLowerCase();

        setState(() {
          stateText = _prettyState(text);

          if (low.contains('started') ||
              low.contains('running') ||
              low.contains('connected')) {
            connected = true;
            connecting = false;
          }

          if (low.contains('stopped') ||
              low.contains('disconnected')) {
            connected = false;
            connecting = false;
            download = '0 Mbps';
            upload = '0 Mbps';
          }

          if (low.contains('starting') ||
              low.contains('stopping')) {
            connecting = true;
          }
        });
      },
      onError: (Object error) {
        debugPrint('VPN state stream error: $error');
      },
    );

    trafficSub = vpn.trafficStatsStream.listen(
      (stats) {
        if (!mounted) return;

        try {
          setState(() {
            download = speed(stats.downlinkBps);
            upload = speed(stats.uplinkBps);

            downloadTotalBytes =
                stats.downlinkTotalBytes;

            uploadTotalBytes =
                stats.uplinkTotalBytes;
          });
        } catch (e) {
          debugPrint('Traffic stats error: $e');
        }
      },
      onError: (Object error) {
        debugPrint('Traffic stream error: $error');
      },
    );

    faultSub = vpn.faultStream.listen(
      (error) {
        if (!mounted) return;

        final message = error.toString();

        debugPrint('SINGBOX FAULT: $message');

        setState(() {
          stateText = 'خطای VPN';
          connected = false;
          connecting = false;
        });

        snack(
          'خطای sing-box:\n$message',
        );
      },
      onError: (Object error) {
        debugPrint('Fault stream error: $error');
      },
    );

    // ------------------------------------------------------------------------
    // Network quality
    //
    // dynamic is intentional here so minor model-property differences between
    // flutter_singbox_client versions don't break compilation.
    // ------------------------------------------------------------------------

    networkQualitySub =
        vpn.networkQualityProgressStream.listen(
      (progress) {
        if (!mounted) return;

        try {
          final dynamic p = progress;

          final running =
              _dynamicBool(p, 'isRunning') ?? false;

          final down =
              _dynamicNum(
                    p,
                    'downloadCapacityBps',
                  ) ??
                  0;

          final up =
              _dynamicNum(
                    p,
                    'uploadCapacityBps',
                  ) ??
                  0;

          final latency =
              _dynamicInt(
                p,
                'idleLatencyMs',
              );

          final dRpm =
              _dynamicInt(
                p,
                'downloadRPM',
              );

          final uRpm =
              _dynamicInt(
                p,
                'uploadRPM',
              );

          setState(() {
            networkTestRunning = running;

            downloadCapacityBps = down;
            uploadCapacityBps = up;

            idleLatencyMs = latency;
            downloadRpm = dRpm;
            uploadRpm = uRpm;

            testDownload = speed(down);
            testUpload = speed(up);

            if (latency != null && latency > 0) {
              testPing = '$latency ms';
            }
          });
        } catch (e) {
          debugPrint(
            'Network quality error: $e',
          );
        }
      },
      onError: (Object error) {
        debugPrint(
          'Network quality stream error: $error',
        );

        if (!mounted) return;

        setState(() {
          networkTestRunning = false;
        });
      },
    );

    // ------------------------------------------------------------------------
    // STUN
    // ------------------------------------------------------------------------

    stunSub = vpn.stunProgressStream.listen(
      (progress) {
        if (!mounted) return;

        try {
          final dynamic p = progress;

          final running =
              _dynamicBool(p, 'isRunning') ?? false;

          final latency =
              _dynamicInt(
                p,
                'latencyMs',
              );

          final ip =
              _dynamicString(
                p,
                'externalIp',
              );

          final nat =
              _dynamicString(
                p,
                'natType',
              );

          setState(() {
            stunTestRunning = running;

            if (latency != null && latency > 0) {
              stunLatency = '$latency ms';
            }

            if (ip != null && ip.isNotEmpty) {
              externalIp = ip;
            }

            if (nat != null && nat.isNotEmpty) {
              natType = nat;
            }
          });
        } catch (e) {
          debugPrint('STUN error: $e');
        }
      },
      onError: (Object error) {
        debugPrint(
          'STUN stream error: $error',
        );

        if (!mounted) return;

        setState(() {
          stunTestRunning = false;
        });
      },
    );
  }

  dynamic _readDynamic(
    dynamic object,
    String property,
  ) {
    try {
      if (property == 'isRunning') {
        return object.isRunning;
      }

      if (property == 'downloadCapacityBps') {
        return object.downloadCapacityBps;
      }

      if (property == 'uploadCapacityBps') {
        return object.uploadCapacityBps;
      }

      if (property == 'idleLatencyMs') {
        return object.idleLatencyMs;
      }

      if (property == 'downloadRPM') {
        return object.downloadRPM;
      }

      if (property == 'uploadRPM') {
        return object.uploadRPM;
      }

      if (property == 'latencyMs') {
        return object.latencyMs;
      }

      if (property == 'externalIp') {
        return object.externalIp;
      }

      if (property == 'natType') {
        return object.natType;
      }
    } catch (_) {}

    return null;
  }

  bool? _dynamicBool(
    dynamic object,
    String property,
  ) {
    final value = _readDynamic(
      object,
      property,
    );

    return value is bool ? value : null;
  }

  num? _dynamicNum(
    dynamic object,
    String property,
  ) {
    final value = _readDynamic(
      object,
      property,
    );

    return value is num ? value : null;
  }

  int? _dynamicInt(
    dynamic object,
    String property,
  ) {
    final value = _readDynamic(
      object,
      property,
    );

    if (value is int) return value;

    if (value is num) {
      return value.toInt();
    }

    return null;
  }

  String? _dynamicString(
    dynamic object,
    String property,
  ) {
    final value = _readDynamic(
      object,
      property,
    );

    if (value == null) return null;

    return value.toString();
  }

  // ==========================================================================
  // SAVED DATA
  // ==========================================================================

  Future<void> loadSaved() async {
    try {
      final prefs =
          await SharedPreferences.getInstance();

      final saved =
          prefs.getString(
        'subscription_url',
      );

      final savedMode =
          prefs.getString(
        'selection_mode',
      );

      final savedServer =
          prefs.getString(
        'selected_server_raw',
      );

      final savedLastUpdate =
          prefs.getString(
        'last_update',
      );

      selectionMode =
          savedMode == 'manual'
              ? ServerSelectionMode.manual
              : ServerSelectionMode.auto;

      lastUpdate = savedLastUpdate;

      if (saved != null &&
          saved.isNotEmpty) {
        url.text = saved;

        await loadSubscription(
          silent: true,
          restoreSelectedRaw: savedServer,
        );
      }

      await _syncVpnState();
    } catch (e) {
      debugPrint('loadSaved: $e');
    }
  }

  Future<void> saveSelectionMode() async {
    final prefs =
        await SharedPreferences.getInstance();

    await prefs.setString(
      'selection_mode',
      selectionMode ==
              ServerSelectionMode.manual
          ? 'manual'
          : 'auto',
    );
  }

  Future<void> saveSelectedServer() async {
    final prefs =
        await SharedPreferences.getInstance();

    if (selectedServer == null) {
      await prefs.remove(
        'selected_server_raw',
      );
      return;
    }

    await prefs.setString(
      'selected_server_raw',
      selectedServer!.raw,
    );
  }

  // ==========================================================================
  // SUBSCRIPTION
  // ==========================================================================

  Future<void> addSubscription() async {
    final controller =
        TextEditingController(
      text: url.text,
    );

    final result =
        await showDialog<String>(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            backgroundColor:
                const Color(0xFF101522),
            title: const Text(
              'افزودن Subscription',
            ),
            content: TextField(
              controller: controller,
              autofocus: true,
              textDirection:
                  TextDirection.ltr,
              keyboardType:
                  TextInputType.url,
              decoration:
                  const InputDecoration(
                hintText:
                    'https://example.com/sub...',
                border:
                    OutlineInputBorder(),
                prefixIcon:
                    Icon(Icons.link),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(
                    context,
                  );
                },
                child: const Text(
                  'لغو',
                ),
              ),
              FilledButton(
                onPressed: () {
                  final value =
                      controller.text.trim();

                  if (value.isEmpty) {
                    return;
                  }

                  Navigator.pop(
                    context,
                    value,
                  );
                },
                child: const Text(
                  'افزودن',
                ),
              ),
            ],
          ),
        );
      },
    );

    controller.dispose();

    if (result == null ||
        result.trim().isEmpty) {
      return;
    }

    url.text = result.trim();

    await loadSubscription();
  }

  Future<void> loadSubscription({
    bool silent = false,
    String? restoreSelectedRaw,
  }) async {
    final subscription =
        url.text.trim();

    if (subscription.isEmpty) {
      if (!silent && mounted) {
        snack(
          'ابتدا Subscription را اضافه کن',
        );
      }
      return;
    }

    Uri uri;

    try {
      uri = Uri.parse(subscription);

      if (!uri.hasScheme ||
          uri.host.isEmpty) {
        throw Exception(
          'آدرس Subscription معتبر نیست',
        );
      }
    } catch (_) {
      if (!silent && mounted) {
        snack(
          'آدرس Subscription نامعتبر است',
        );
      }
      return;
    }

    if (mounted) {
      setState(() {
        loading = true;

        if (!silent) {
          stateText =
              'در حال دریافت Subscription...';
        }
      });
    }

    try {
      final response = await http
          .get(
        uri,
        headers: const {
          'User-Agent':
              'LightSpeed/6.0',
          'Accept': '*/*',
          'Cache-Control':
              'no-cache',
          'Pragma': 'no-cache',
        },
      )
          .timeout(
        const Duration(
          seconds: 60,
        ),
      );

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw Exception(
          'HTTP ${response.statusCode}',
        );
      }

      if (response.bodyBytes.isEmpty) {
        throw Exception(
          'Subscription خالی است',
        );
      }

      final body = utf8.decode(
        response.bodyBytes,
        allowMalformed: true,
      );

      // Subscription info
      _readUserInfo(
        responseHeader(
          response.headers,
          'subscription-userinfo',
        ),
      );

      final rawLines =
          decodeSubscription(body);

      final parsed =
          <Server>[];

      final fingerprints =
          <String>{};

      for (final line in rawLines) {
        final server =
            parseServer(line);

        if (server == null) {
          continue;
        }

        final key = _serverFingerprint(
          server,
        );

        if (fingerprints.add(key)) {
          parsed.add(server);
        }
      }

      if (parsed.isEmpty) {
        throw Exception(
          'هیچ کانفیگ معتبر و قابل استفاده‌ای پیدا نشد',
        );
      }

      final prefs =
          await SharedPreferences
              .getInstance();

      await prefs.setString(
        'subscription_url',
        subscription,
      );

      final updateTime =
          DateTime.now()
              .toLocal()
              .toIso8601String();

      await prefs.setString(
        'last_update',
        updateTime,
      );

      Server? restored;

      final rawToRestore =
          restoreSelectedRaw ??
              prefs.getString(
                'selected_server_raw',
              );

      if (rawToRestore != null) {
        for (final server in parsed) {
          if (server.raw ==
              rawToRestore) {
            restored = server;
            break;
          }
        }
      }

      if (!mounted) return;

      setState(() {
        servers
          ..clear()
          ..addAll(parsed);

        selectedServer = restored;

        lastUpdate = updateTime;

        loading = false;

        stateText =
            '${servers.length} سرور دریافت شد';
      });

      await saveSelectedServer();

      if (!silent) {
        snack(
          '${servers.length} سرور با موفقیت دریافت شد',
        );
      }

      // Auto mode:
      // only run a full server test when user explicitly updates the
      // subscription. Silent background refresh doesn't unexpectedly
      // switch the selected server.
      if (selectionMode ==
              ServerSelectionMode.auto &&
          !silent) {
        await testAll(
          silent: true,
        );

        final best = fastest();

        if (mounted && best != null) {
          setState(() {
            selectedServer = best;
          });

          await saveSelectedServer();
        }
      }
    } catch (e) {
      debugPrint(
        'SUB ERROR: $e',
      );

      if (!mounted) return;

      setState(() {
        loading = false;
        stateText =
            'خطا در دریافت Subscription';
      });

      if (!silent) {
        snack(
          'دریافت Subscription ناموفق بود:\n$e',
        );
      }
    }
  }

  String? responseHeader(
    Map<String, String> headers,
    String wanted,
  ) {
    final target =
        wanted.toLowerCase();

    for (final entry
        in headers.entries) {
      if (entry.key.toLowerCase() ==
          target) {
        return entry.value;
      }
    }

    return null;
  }

  // ==========================================================================
  // USER INFO
  // ==========================================================================

  void _readUserInfo(String? raw) {
    if (raw == null ||
        raw.trim().isEmpty) {
      return;
    }

    final values =
        <String, int>{};

    for (final item
        in raw.split(';')) {
      final index =
          item.indexOf('=');

      if (index <= 0) continue;

      final key = item
          .substring(0, index)
          .trim()
          .toLowerCase();

      final value = int.tryParse(
        item
            .substring(index + 1)
            .trim(),
      );

      if (value == null) continue;

      if (key == 'upload') {
        values['upload'] = value;
      }

      if (key == 'download') {
        values['download'] = value;
      }

      if (key == 'total' ||
          key == 'transfer_enable') {
        values['total'] = value;
      }

      if (key == 'expire' ||
          key == 'expired_at') {
        values['expire'] = value;
      }
    }

    if (!mounted) return;

    setState(() {
      if (values.containsKey('total')) {
        totalBytes = values['total'];
      }

      if (values.containsKey('upload')) {
        uploadBytes = values['upload'];
      }

      if (values.containsKey('download')) {
        downloadBytes =
            values['download'];
      }

      if (values.containsKey('upload') ||
          values.containsKey('download')) {
        usedBytes =
            (uploadBytes ?? 0) +
                (downloadBytes ?? 0);
      }

      if (values.containsKey('expire')) {
        expireAt = values['expire'];
      }
    });
  }

  // ==========================================================================
  // SUBSCRIPTION DECODER
  // ==========================================================================

  List<String> decodeSubscription(
    String body,
  ) {
    final result =
        <String>[];

    final trimmed =
        body.trim();

    if (trimmed.isEmpty) {
      return result;
    }

    // ------------------------------------------------------------------------
    // 1. Direct URI lines
    // ------------------------------------------------------------------------

    final directLines = trimmed
        .split(RegExp(r'\r?\n'))
        .map(
          (e) => e.trim(),
        )
        .where(
          (e) =>
              e.isNotEmpty &&
              _looksLikeConfig(e),
        )
        .toList();

    if (directLines.isNotEmpty) {
      result.addAll(directLines);
    }

    // ------------------------------------------------------------------------
    // 2. JSON / sing-box JSON
    // ------------------------------------------------------------------------

    if (result.isEmpty &&
        (trimmed.startsWith('{') ||
            trimmed.startsWith('['))) {
      result.addAll(
        _decodeJsonSubscription(
          trimmed,
        ),
      );
    }

    // ------------------------------------------------------------------------
    // 3. Base64 / URL-safe Base64
    // ------------------------------------------------------------------------

    if (result.isEmpty) {
      final decoded =
          _tryDecodeBase64Text(
        trimmed,
      );

      if (decoded != null &&
          decoded.isNotEmpty) {
        final nested =
            decodeSubscription(
          decoded,
        );

        result.addAll(nested);
      }
    }

    // ------------------------------------------------------------------------
    // 4. Final cleanup
    // ------------------------------------------------------------------------

    final unique =
        <String>{};

    final clean =
        <String>[];

    for (final line in result) {
      final value =
          line.trim();

      if (value.isEmpty) continue;

      if (!_looksLikeConfig(value)) {
        continue;
      }

      if (unique.add(value)) {
        clean.add(value);
      }
    }

    return clean;
  }

  bool _looksLikeConfig(
    String value,
  ) {
    final low =
        value.toLowerCase();

    return low.startsWith('vmess://') ||
        low.startsWith('vless://') ||
        low.startsWith('trojan://') ||
        low.startsWith('ss://') ||
        low.startsWith('shadowsocks://') ||
        low.startsWith('hysteria2://') ||
        low.startsWith('hy2://') ||
        low.startsWith('tuic://') ||
        low.startsWith('socks://') ||
        low.startsWith('socks5://');
  }

  String? _tryDecodeBase64Text(
    String value,
  ) {
    try {
      var encoded =
          value.replaceAll(
        RegExp(r'\s+'),
        '',
      );

      encoded = encoded
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      encoded +=
          '=' *
              ((4 -
                      encoded.length % 4) %
                  4);

      final bytes =
          base64.decode(encoded);

      final text =
          utf8.decode(
        bytes,
        allowMalformed: true,
      );

      if (text.trim().isEmpty) {
        return null;
      }

      return text;
    } catch (_) {
      return null;
    }
  }

  // ==========================================================================
  // JSON SUBSCRIPTION
  // ==========================================================================

  List<String> _decodeJsonSubscription(
    String body,
  ) {
    final result =
        <String>[];

    try {
      final decoded =
          jsonDecode(body);

      _extractJsonConfigs(
        decoded,
        result,
      );
    } catch (e) {
      debugPrint(
        'JSON subscription error: $e',
      );
    }

    return result;
  }

  void _extractJsonConfigs(
    dynamic object,
    List<String> result,
  ) {
    if (object is List) {
      for (final item in object) {
        _extractJsonConfigs(
          item,
          result,
        );
      }
      return;
    }

    if (object is! Map) {
      return;
    }

    // ------------------------------------------------------------------------
    // Common JSON subscription fields
    // ------------------------------------------------------------------------

    final possibleLinks = [
      object['url'],
      object['uri'],
      object['link'],
      object['config'],
      object['server'],
    ];

    for (final value in possibleLinks) {
      if (value is String &&
          _looksLikeConfig(value.trim())) {
        result.add(value.trim());
      }
    }

    // ------------------------------------------------------------------------
    // Common "links" array
    // ------------------------------------------------------------------------

    final links =
        object['links'];

    if (links is List) {
      for (final link in links) {
        if (link is String &&
            _looksLikeConfig(link.trim())) {
          result.add(link.trim());
        } else {
          _extractJsonConfigs(
            link,
            result,
          );
        }
      }
    }

    // ------------------------------------------------------------------------
    // sing-box outbounds
    // ------------------------------------------------------------------------

    final outbounds =
        object['outbounds'];

    if (outbounds is List) {
      for (final outbound
          in outbounds) {
        if (outbound is Map) {
          final converted =
              _singboxOutboundToServer(
            Map<String, dynamic>.from(
              outbound,
            ),
          );

          if (converted != null) {
            result.add(
              converted,
            );
          }
        }
      }
    }

    // ------------------------------------------------------------------------
    // Generic recursive JSON search
    // ------------------------------------------------------------------------

    for (final value
        in object.values) {
      if (value is Map ||
          value is List) {
        _extractJsonConfigs(
          value,
          result,
        );
      }
    }
  }

  String? _singboxOutboundToServer(
    Map<String, dynamic> outbound,
  ) {
    final type =
        '${outbound['type'] ?? ''}'
            .toLowerCase();

    final host =
        '${outbound['server'] ?? ''}';

    final port =
        _toInt(
          outbound['server_port'],
        );

    if (host.isEmpty ||
        port <= 0) {
      return null;
    }

    if (![
      'vless',
      'vmess',
      'trojan',
      'shadowsocks',
      'ss',
      'hysteria2',
      'tuic',
      'socks',
      'socks5',
    ].contains(type)) {
      return null;
    }

    // We already have the native sing-box object.
    // Encode it using a private marker that parseServer can understand.
    final copy =
        Map<String, dynamic>.from(
      outbound,
    );

    copy['server'] = host;
    copy['server_port'] = port;

    return 'singbox-json://${base64UrlEncode(
      utf8.encode(
        jsonEncode(copy),
      ),
    )}';
  }

  // ==========================================================================
  // SERVER PARSER
  // ==========================================================================

  Server? parseServer(
    String raw,
  ) {
    try {
      if (raw.startsWith(
        'singbox-json://',
      )) {
        return _parseSingboxInternal(
          raw,
        );
      }

      final uri =
          Uri.parse(raw);

      final scheme =
          uri.scheme.toLowerCase();

      if (scheme == 'vmess') {
        return parseVmess(raw);
      }

      if (scheme == 'vless') {
        return _parseVless(raw);
      }

      if (scheme == 'trojan') {
        return _parseTrojan(raw);
      }

      if (scheme == 'ss' ||
          scheme == 'shadowsocks') {
        return _parseShadowsocks(
          raw,
        );
      }

      if (scheme == 'hysteria2' ||
          scheme == 'hy2') {
        return _parseHysteria2(
          raw,
        );
      }

      if (scheme == 'tuic') {
        return _parseTuic(raw);
      }

      if (scheme == 'socks' ||
          scheme == 'socks5') {
        return _parseSocks(raw);
      }

      return null;
    } catch (e) {
      debugPrint(
        'parseServer: $e',
      );

      return null;
    }
  }

  Server? _parseSingboxInternal(
    String raw,
  ) {
    try {
      final encoded =
          raw.substring(
        'singbox-json://'.length,
      );

      final decoded =
          utf8.decode(
        base64Url.decode(
          base64Url.normalize(
            encoded,
          ),
        ),
      );

      final map =
          Map<String, dynamic>.from(
        jsonDecode(decoded),
      );

      final host =
          '${map['server'] ?? ''}';

      final port =
          _toInt(
            map['server_port'],
          );

      final type =
          '${map['type'] ?? ''}'
              .toUpperCase();

      if (host.isEmpty ||
          port <= 0 ||
          type.isEmpty) {
        return null;
      }

      final tag =
          '${map['tag'] ?? ''}';

      return Server(
        raw: raw,
        name:
            tag.isNotEmpty
                ? tag
                : '$type $host',
        type: type,
        host: host,
        port: port,
        outbound:
            Map<String, dynamic>.from(
          map,
        ),
      );
    } catch (e) {
      debugPrint(
        'sing-box JSON parse error: $e',
      );

      return null;
    }
  }

  // ==========================================================================
  // VMESS
  // ==========================================================================

  Server? parseVmess(
    String raw,
  ) {
    try {
      var encoded =
          raw.substring(
        raw.indexOf('://') + 3,
      );

      encoded = encoded
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      encoded +=
          '=' *
              ((4 -
                      encoded.length % 4) %
                  4);

      final decoded =
          utf8.decode(
        base64.decode(encoded),
        allowMalformed: true,
      );

      final map =
          Map<String, dynamic>.from(
        json.decode(decoded),
      );

      final host =
          '${map['add'] ?? ''}'
              .trim();

      final port =
          _toInt(map['port']);

      final uuid =
          '${map['id'] ?? ''}'
              .trim();

      if (host.isEmpty ||
          port <= 0 ||
          uuid.isEmpty) {
        return null;
      }

      final outbound =
          <String, dynamic>{
        'type': 'vmess',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'uuid': uuid,
        'security':
            '${map['scy'] ?? 'auto'}',
      };

      final tls =
          '${map['tls'] ?? ''}'
              .toLowerCase();

      final sni =
          '${map['sni'] ?? map['host'] ?? ''}';

      if (tls.isNotEmpty &&
          tls != 'none') {
        outbound['tls'] = {
          'enabled': true,
          if (sni.isNotEmpty)
            'server_name': sni,
        };
      }

      addTransport(
        outbound,
        '${map['net'] ?? 'tcp'}',
        '${map['path'] ?? ''}',
        '${map['host'] ?? ''}',
      );

      return Server(
        raw: raw,
        name:
            '${map['ps'] ?? 'VMess'}',
        type: 'VMESS',
        host: host,
        port: port,
        outbound: outbound,
      );
    } catch (e) {
      debugPrint(
        'VMess parse error: $e',
      );

      return null;
    }
  }

  // ==========================================================================
  // VLESS
  // ==========================================================================

  Server? _parseVless(
    String raw,
  ) {
    final uri =
        Uri.parse(raw);

    if (uri.host.isEmpty ||
        !uri.hasPort ||
        uri.userInfo.isEmpty) {
      return null;
    }

    final outbound =
        vless(uri);

    return Server(
      raw: raw,
      name:
          _uriName(
        uri,
        'VLESS',
      ),
      type: 'VLESS',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  Map<String, dynamic> vless(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uri.userInfo,
    };

    final flow =
        p['flow'] ?? '';

    if (flow.isNotEmpty) {
      outbound['flow'] = flow;
    }

    final security =
        (p['security'] ?? '')
            .toLowerCase();

    if (security == 'tls' ||
        security == 'reality') {
      final tls =
          <String, dynamic>{
        'enabled': true,
        'server_name':
            p['sni'] ??
                p['host'] ??
                uri.host,
      };

      final fp =
          p['fp'] ?? '';

      if (fp.isNotEmpty) {
        tls['utls'] = {
          'enabled': true,
          'fingerprint': fp,
        };
      }

      if (security == 'reality' &&
          (p['pbk'] ?? '').isNotEmpty) {
        tls['reality'] = {
          'enabled': true,
          'public_key': p['pbk'],
          if ((p['sid'] ?? '')
              .isNotEmpty)
            'short_id': p['sid'],
        };
      }

      outbound['tls'] = tls;
    }

    addTransport(
      outbound,
      p['type'] ??
          p['network'] ??
          'tcp',
      p['path'] ?? '',
      p['host'] ?? '',
    );

    return outbound;
  }

  // ==========================================================================
  // TROJAN
  // ==========================================================================

  Server? _parseTrojan(
    String raw,
  ) {
    final uri =
        Uri.parse(raw);

    if (uri.host.isEmpty ||
        !uri.hasPort ||
        uri.userInfo.isEmpty) {
      return null;
    }

    final outbound =
        trojan(uri);

    return Server(
      raw: raw,
      name:
          _uriName(
        uri,
        'TROJAN',
      ),
      type: 'TROJAN',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  Map<String, dynamic> trojan(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'password': uri.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            p['sni'] ??
                p['host'] ??
                uri.host,
      },
    };

    if (p['allowInsecure'] == '1' ||
        p['allow_insecure'] == '1' ||
        p['insecure'] == '1') {
      (outbound['tls']
          as Map<String, dynamic>)['insecure'] =
          true;
    }

    addTransport(
      outbound,
      p['type'] ?? 'tcp',
      p['path'] ?? '',
      p['host'] ?? '',
    );

    return outbound;
  }

  // ==========================================================================
  // SHADOWSOCKS
  // ==========================================================================

  Server? _parseShadowsocks(
    String raw,
  ) {
    final uri =
        Uri.parse(raw);

    if (uri.host.isEmpty ||
        !uri.hasPort) {
      return null;
    }

    final outbound =
        shadowsocks(
      uri,
      raw,
    );

    if (outbound == null) {
      return null;
    }

    return Server(
      raw: raw,
      name:
          _uriName(
        uri,
        'SS',
      ),
      type: 'SS',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  Map<String, dynamic>?
      shadowsocks(
    Uri uri,
    String raw,
  ) {
    try {
      var user =
          uri.userInfo;

      // ss://BASE64@host:port
      if (user.isEmpty) {
        var encoded =
            raw.substring(
          raw.indexOf('://') + 3,
        );

        encoded =
            encoded.split('#').first;

        encoded =
            encoded.split('?').first;

        encoded = encoded
            .replaceAll('-', '+')
            .replaceAll('_', '/');

        encoded +=
            '=' *
                ((4 -
                        encoded.length %
                            4) %
                    4);

        user = utf8.decode(
          base64.decode(encoded),
          allowMalformed: true,
        );
      }

      final separator =
          user.indexOf(':');

      if (separator <= 0) {
        return null;
      }

      return {
        'type': 'shadowsocks',
        'tag': 'proxy',
        'server': uri.host,
        'server_port': uri.port,
        'method':
            Uri.decodeComponent(
          user.substring(
            0,
            separator,
          ),
        ),
        'password':
            Uri.decodeComponent(
          user.substring(
            separator + 1,
          ),
        ),
      };
    } catch (e) {
      debugPrint(
        'Shadowsocks parse error: $e',
      );

      return null;
    }
  }

  // ==========================================================================
  // HYSTERIA 2
  // ==========================================================================

  Server? _parseHysteria2(
    String raw,
  ) {
    final uri =
        Uri.parse(raw);

    if (uri.host.isEmpty ||
        !uri.hasPort ||
        uri.userInfo.isEmpty) {
      return null;
    }

    return Server(
      raw: raw,
      name:
          _uriName(
        uri,
        'HYSTERIA2',
      ),
      type: 'HYSTERIA2',
      host: uri.host,
      port: uri.port,
      outbound:
          hysteria2(uri),
    );
  }

  Map<String, dynamic> hysteria2(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'password': uri.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            p['sni'] ??
                p['peer'] ??
                uri.host,
      },
    };

    if (p['insecure'] == '1') {
      (outbound['tls']
          as Map<String, dynamic>)['insecure'] =
          true;
    }

    return outbound;
  }

  // ==========================================================================
  // TUIC
  // ==========================================================================

  Server? _parseTuic(
    String raw,
  ) {
    final uri =
        Uri.parse(raw);

    if (uri.host.isEmpty ||
        !uri.hasPort ||
        uri.userInfo.isEmpty) {
      return null;
    }

    return Server(
      raw: raw,
      name:
          _uriName(
        uri,
        'TUIC',
      ),
      type: 'TUIC',
      host: uri.host,
      port: uri.port,
      outbound:
          tuic(uri),
    );
  }

  Map<String, dynamic> tuic(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'tuic',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uri.userInfo,
      'password':
          p['password'] ?? '',
      'congestion_control':
          p['congestion_control'] ??
              'cubic',
      'udp_relay_mode':
          p['udp_relay_mode'] ??
              'native',
      'zero_rtt_handshake':
          false,
      'tls': {
        'enabled': true,
        'server_name':
            p['sni'] ??
                p['peer'] ??
                uri.host,
      },
    };

    if (p['insecure'] == '1') {
      (outbound['tls']
          as Map<String, dynamic>)['insecure'] =
          true;
    }

    return outbound;
  }

  // ==========================================================================
  // SOCKS
  // ==========================================================================

  Server? _parseSocks(
    String raw,
  ) {
    final uri =
        Uri.parse(raw);

    if (uri.host.isEmpty ||
        !uri.hasPort) {
      return null;
    }

    final outbound =
        <String, dynamic>{
      'type': 'socks',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'version': '5',
    };

    if (uri.userInfo.isNotEmpty) {
      final separator =
          uri.userInfo.indexOf(':');

      if (separator > 0) {
        outbound['username'] =
            Uri.decodeComponent(
          uri.userInfo.substring(
            0,
            separator,
          ),
        );

        outbound['password'] =
            Uri.decodeComponent(
          uri.userInfo.substring(
            separator + 1,
          ),
        );
      }
    }

    return Server(
      raw: raw,
      name:
          _uriName(
        uri,
        'SOCKS',
      ),
      type: 'SOCKS',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ==========================================================================
  // TRANSPORT
  // ==========================================================================

  void addTransport(
    Map<String, dynamic> outbound,
    String network,
    String path,
    String host,
  ) {
    final n =
        network.toLowerCase();

    if (n == 'ws' ||
        n == 'websocket') {
      outbound['transport'] = {
        'type': 'ws',
        'path':
            path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'headers': {
            'Host': host,
          },
      };

      return;
    }

    if (n == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        'service_name': path,
      };

      return;
    }

    if (n == 'httpupgrade') {
      outbound['transport'] = {
        'type': 'httpupgrade',
        'path':
            path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': host,
      };

      return;
    }

    if (n == 'h2' ||
        n == 'http') {
      outbound['transport'] = {
        'type': 'http',
        'path':
            path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': [host],
      };
    }
  }

  // ==========================================================================
  // SING-BOX CONFIG
  // ==========================================================================

  String makeConfig(
    Server server,
  ) {
    final proxy =
        Map<String, dynamic>.from(
      server.outbound,
    );

    proxy['tag'] = 'proxy';

    final config =
        <String, dynamic>{
      'log': {
        'level': 'warn',
      },

      'dns': {
        'servers': [
          {
            'type': 'https',
            'tag': 'dns-remote',
            'server': '1.1.1.1',
            'server_port': 443,
            'path': '/dns-query',
            'tls': {
              'enabled': true,
              'server_name':
                  'cloudflare-dns.com',
            },
          },
          {
            'type': 'local',
            'tag': 'dns-local',
          },
        ],
        'final': 'dns-remote',
        'strategy': 'ipv4_only',
      },

      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': [
            '172.19.0.1/30',
          ],
          'mtu': 1400,
          'auto_route': true,
          'stack': 'system',
        },
      ],

      'outbounds': [
        proxy,
        {
          'type': 'direct',
          'tag': 'direct',
        },
        {
          'type': 'block',
          'tag': 'block',
        },
      ],

      'route': {
        'rules': [
          {
            'protocol': 'dns',
            'action': 'hijack-dns',
          },
          {
            'port': 53,
            'action': 'hijack-dns',
          },
          {
            'ip_is_private': true,
            'outbound': 'direct',
          },
        ],
        'final': 'proxy',
      },
    };

    return jsonEncode(config);
  }

  // ==========================================================================
  // SERVER TEST
  // ==========================================================================

  Future<void> testAll({
    bool silent = false,
  }) async {
    if (servers.isEmpty ||
        testing) {
      return;
    }

    if (mounted) {
      setState(() {
        testing = true;

        if (!silent) {
          stateText =
              'در حال تست سرورها...';
        }
      });
    }

    await Future.wait(
      servers.map(
        (server) async {
          final stopwatch =
              Stopwatch()..start();

          try {
            final socket =
                await Socket.connect(
              server.host,
              server.port,
              timeout:
                  const Duration(
                seconds: 4,
              ),
            );

            stopwatch.stop();

            socket.destroy();

            server.ping =
                stopwatch
                    .elapsedMilliseconds;
          } catch (_) {
            server.ping = null;
          }
        },
      ),
    );

    if (mounted) {
      setState(() {
        testing = false;

        if (!silent) {
          stateText =
              'تست سرورها تمام شد';
        }
      });
    }
  }

  Server? fastest() {
    final good =
        servers
            .where(
              (s) => s.ping != null,
            )
            .toList();

    if (good.isEmpty) {
      return null;
    }

    good.sort(
      (a, b) =>
          a.ping!.compareTo(
        b.ping!,
      ),
    );

    return good.first;
  }

  // ==========================================================================
  // MANUAL SERVER
  // ==========================================================================

  Future<void> selectManualServer(
    Server server,
  ) async {
    if (connected ||
        connecting) {
      snack(
        'ابتدا VPN را قطع کن',
      );
      return;
    }

    setState(() {
      selectionMode =
          ServerSelectionMode.manual;

      selectedServer = server;

      stateText =
          'سرور انتخاب شد: ${server.name}';
    });

    await saveSelectionMode();
    await saveSelectedServer();

    snack(
      'سرور ${server.name} انتخاب شد',
    );
  }

  Future<void> selectAutoMode() async {
    if (connected ||
        connecting) {
      snack(
        'ابتدا VPN را قطع کن',
      );
      return;
    }

    setState(() {
      selectionMode =
          ServerSelectionMode.auto;

      stateText =
          'در حال پیدا کردن سریع‌ترین سرور...';
    });

    await saveSelectionMode();

    if (servers.isEmpty) {
      snack(
        'ابتدا Subscription را اضافه کن',
      );
      return;
    }

    await testAll(
      silent: true,
    );

    final best =
        fastest();

    if (mounted) {
      setState(() {
        selectedServer = best;

        stateText = best == null
            ? 'سرور قابل دسترس پیدا نشد'
            : 'سریع‌ترین سرور: ${best.name}';
      });
    }

    await saveSelectedServer();

    if (best != null) {
      snack(
        'سریع‌ترین سرور: '
        '${best.name} • ${best.ping} ms',
      );
    }
  }

  // ==========================================================================
  // CONNECT
  // ==========================================================================

  Future<void> connect() async {
    if (servers.isEmpty) {
      snack(
        'ابتدا Subscription را اضافه کن',
      );
      return;
    }

    if (connected ||
        connecting) {
      return;
    }

    setState(() {
      connecting = true;
      stateText =
          'در حال آماده‌سازی VPN...';
    });

    try {
      Server? selected;

      if (selectionMode ==
              ServerSelectionMode.manual &&
          selectedServer != null) {
        selected =
            selectedServer;
      } else {
        setState(() {
          stateText =
              'در حال تست سریع‌ترین سرور...';
        });

        await testAll(
          silent: true,
        );

        selected =
            fastest();

        selected ??=
            servers.first;

        if (mounted) {
          setState(() {
            selectedServer =
                selected;
          });
        }

        await saveSelectedServer();
      }

      if (selected == null) {
        throw Exception(
          'سروری برای اتصال وجود ندارد',
        );
      }

      if (mounted) {
        setState(() {
          stateText =
              'سرور: ${selected!.name}';
        });
      }

      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'مجوز VPN داده نشد',
        );
      }

      final config =
          makeConfig(selected);

      if (mounted) {
        setState(() {
          stateText =
              'در حال بررسی کانفیگ...';
        });
      }

      await vpn.checkConfig(
        config,
      );

      if (mounted) {
        setState(() {
          stateText =
              'در حال اتصال به سرور...';
        });
      }

      await vpn.connect(
        SessionOptions(
          config: config,
          networkMode:
              NetworkMode.vpn,
          notification:
              NotificationConfig(
            title: 'Light speed',
            showTrafficStats: true,
            showStopButton: true,
            stopButtonLabel:
                'قطع اتصال',
          ),
        ),
      );

      if (!mounted) return;

      setState(() {
        connecting = false;
        connected = true;
        stateText =
            'متصل • ${selected!.name}';
      });

      snack(
        'VPN با موفقیت متصل شد',
      );
    } catch (e, stack) {
      debugPrint(
        'CONNECT ERROR: $e',
      );

      debugPrint(
        'CONNECT STACK:\n$stack',
      );

      try {
        await vpn.disconnect();
      } catch (_) {}

      if (!mounted) return;

      setState(() {
        connected = false;
        connecting = false;
        stateText =
            'اتصال ناموفق';
      });

      snack(
        'خطای VPN:\n$e',
      );
    }
  }

  // ==========================================================================
  // DISCONNECT
  // ==========================================================================

  Future<void> disconnect() async {
    if (connecting) {
      return;
    }

    try {
      await vpn.disconnect();
    } catch (e) {
      debugPrint(
        'Disconnect error: $e',
      );
    }

    if (!mounted) return;

    setState(() {
      connected = false;
      connecting = false;

      stateText =
          'اتصال قطع شد';

      download = '0 Mbps';
      upload = '0 Mbps';

      downloadTotalBytes = 0;
      uploadTotalBytes = 0;
    });
  }

  // ==========================================================================
  // NETWORK SPEED TEST
  // ==========================================================================

  Future<void> startSpeedTest() async {
    if (networkTestRunning) {
      return;
    }

    try {
      setState(() {
        networkTestRunning = true;

        testDownload =
            'در حال تست...';

        testUpload =
            'در حال تست...';

        testPing =
            'در حال تست...';
      });

      await vpn.startNetworkQualityTest();
    } catch (e) {
      debugPrint(
        'Speed test error: $e',
      );

      if (!mounted) return;

      setState(() {
        networkTestRunning = false;
      });

      snack(
        'تست سرعت ناموفق بود:\n$e',
      );
    }
  }

  Future<void> stopSpeedTest() async {
    try {
      await vpn.stopNetworkQualityTest();
    } catch (e) {
      debugPrint(
        'Stop speed test: $e',
      );
    }

    if (!mounted) return;

    setState(() {
      networkTestRunning = false;
    });
  }

  // ==========================================================================
  // STUN TEST
  // ==========================================================================

  Future<void> startStunTest() async {
    if (stunTestRunning) {
      return;
    }

    try {
      setState(() {
        stunTestRunning = true;
        stunLatency =
            'در حال تست...';
        externalIp =
            'در حال تست...';
        natType =
            'در حال تست...';
      });

      await vpn.startStunTest();
    } catch (e) {
      debugPrint(
        'STUN test error: $e',
      );

      if (!mounted) return;

      setState(() {
        stunTestRunning = false;
      });

      snack(
        'تست STUN ناموفق بود:\n$e',
      );
    }
  }

  Future<void> stopStunTest() async {
    try {
      await vpn.stopStunTest();
    } catch (e) {
      debugPrint(
        'Stop STUN: $e',
      );
    }

    if (!mounted) return;

    setState(() {
      stunTestRunning = false;
    });
  }

  // ==========================================================================
  // HELPERS
  // ==========================================================================

  int _toInt(
    dynamic value,
  ) {
    if (value is int) return value;

    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(
          '$value',
        ) ??
        0;
  }

  String _uriName(
    Uri uri,
    String fallback,
  ) {
    if (uri.fragment.isNotEmpty) {
      try {
        return Uri.decodeComponent(
          uri.fragment,
        );
      } catch (_) {
        return uri.fragment;
      }
    }

    return '$fallback ${uri.host}';
  }

  String _serverFingerprint(
    Server server,
  ) {
    final outbound =
        Map<String, dynamic>.from(
      server.outbound,
    );

    outbound.remove('tag');

    return jsonEncode(
      outbound,
    );
  }

  String speed(
    dynamic bps,
  ) {
    final value =
        bps is num
            ? bps.toDouble()
            : 0.0;

    if (value <= 0) {
      return '0 Mbps';
    }

    if (value >= 1000000000) {
      return
          '${(value / 1000000000).toStringAsFixed(2)} Gbps';
    }

    if (value >= 1000000) {
      return
          '${(value / 1000000).toStringAsFixed(2)} Mbps';
    }

    if (value >= 1000) {
      return
          '${(value / 1000).toStringAsFixed(1)} Kbps';
    }

    return
        '${value.toStringAsFixed(0)} bps';
  }

  String size(
    int? bytes,
  ) {
    if (bytes == null) {
      return 'نامشخص';
    }

    if (bytes == 0) {
      return '0 B';
    }

    if (bytes < 1024 * 1024) {
      return
          '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    if (bytes <
        1024 *
            1024 *
            1024) {
      return
          '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    return
        '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _dateFromUnix(
    int timestamp,
  ) {
    try {
      final milliseconds =
          timestamp > 20000000000
              ? timestamp
              : timestamp * 1000;

      final date =
          DateTime
              .fromMillisecondsSinceEpoch(
        milliseconds,
      );

      return
          '${date.year}/'
          '${date.month.toString().padLeft(2, '0')}/'
          '${date.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return 'نامشخص';
    }
  }

  String _prettyState(
    String value,
  ) {
    final low =
        value.toLowerCase();

    if (low.contains('started') ||
        low.contains('running') ||
        low.contains('connected')) {
      return 'VPN متصل است';
    }

    if (low.contains('starting')) {
      return 'در حال اتصال...';
    }

    if (low.contains('stopping')) {
      return 'در حال قطع اتصال...';
    }

    if (low.contains('stopped') ||
        low.contains('disconnected')) {
      return 'VPN متوقف است';
    }

    return value;
  }

  void snack(
    String text,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).hideCurrentSnackBar();

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(text),
        duration:
            const Duration(
          seconds: 4,
        ),
        behavior:
            SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(
            16,
          ),
        ),
      ),
    );
  }

  LinearGradient get mainGradient {
    return const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF00E5FF),
        Color(0xFF7C4DFF),
      ],
    );
  }

  Widget card(
    Widget child, {
    EdgeInsetsGeometry? padding,
  }) {
    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 12,
      ),
      padding:
          padding ??
              const EdgeInsets.all(
                16,
              ),
      decoration:
          BoxDecoration(
        color:
            const Color(0xFF0D121D),
        borderRadius:
            BorderRadius.circular(
          22,
        ),
        border:
            Border.all(
          color:
              Colors.white.withValues(
            alpha: .06,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color:
                Colors.black.withValues(
              alpha: .18,
            ),
            blurRadius: 18,
            offset:
                const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget header(
    String title,
    String subtitle,
  ) {
    return Padding(
      padding:
          const EdgeInsets.only(
        bottom: 18,
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration:
                BoxDecoration(
              shape:
                  BoxShape.circle,
              gradient:
                  mainGradient,
              boxShadow: [
                BoxShadow(
                  color:
                      const Color(
                    0xFF7C4DFF,
                  ).withValues(
                    alpha: .3,
                  ),
                  blurRadius: 18,
                ),
              ],
            ),
            child:
                const Icon(
              Icons.bolt,
              color:
                  Colors.white,
              size: 27,
            ),
          ),
          const SizedBox(
            width: 12,
          ),
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style:
                    const TextStyle(
                  fontSize: 23,
                  fontWeight:
                      FontWeight.w900,
                ),
              ),
              const SizedBox(
                height: 2,
              ),
              Text(
                subtitle,
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final pages = [
      _home(),
      _servers(),
      _traffic(),
      _subscription(),
      _settings(),
    ];

    return Directionality(
      textDirection:
          TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: pages[page],
        ),
        bottomNavigationBar:
            NavigationBar(
          height: 72,
          selectedIndex: page,
          backgroundColor:
              const Color(0xFF090D15),
          indicatorColor:
              const Color(0xFF34216B),
          onDestinationSelected:
              (index) {
            setState(() {
              page = index;
            });
          },
          destinations:
              const [
            NavigationDestination(
              icon:
                  Icon(
                Icons.home_outlined,
              ),
              selectedIcon:
                  Icon(
                Icons.home,
              ),
              label: 'خانه',
            ),
            NavigationDestination(
              icon:
                  Icon(
                Icons.dns_outlined,
              ),
              selectedIcon:
                  Icon(
                Icons.dns,
              ),
              label: 'سرورها',
            ),
            NavigationDestination(
              icon:
                  Icon(
                Icons.bar_chart_outlined,
              ),
              selectedIcon:
                  Icon(
                Icons.bar_chart,
              ),
              label: 'ترافیک',
            ),
            NavigationDestination(
              icon:
                  Icon(
                Icons.link_outlined,
              ),
              selectedIcon:
                  Icon(
                Icons.link,
              ),
              label: 'اشتراک',
            ),
            NavigationDestination(
              icon:
                  Icon(
                Icons.settings_outlined,
              ),
              selectedIcon:
                  Icon(
                Icons.settings,
              ),
              label: 'تنظیمات',
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // HOME
  // ==========================================================================

  Widget _home() {
    final best = fastest();

    final displayServer =
        selectionMode ==
                ServerSelectionMode.manual
            ? selectedServer
            : selectedServer ?? best;

    final percent =
        totalBytes == null ||
                totalBytes! <= 0
            ? 0.0
            : ((usedBytes ?? 0) /
                    totalBytes!)
                .clamp(
                0.0,
                1.0,
              );

    return ListView(
      padding:
          const EdgeInsets.fromLTRB(
        18,
        18,
        18,
        24,
      ),
      children: [
        header(
          'Light speed',
          'VPN واقعی با sing-box',
        ),

        const SizedBox(
          height: 4,
        ),

        _connectionHero(),

        const SizedBox(
          height: 18,
        ),

        Center(
          child: Text(
            stateText,
            textAlign:
                TextAlign.center,
            style: TextStyle(
              color: connected
                  ? const Color(
                      0xFF00E676,
                    )
                  : Colors.white70,
              fontWeight:
                  FontWeight.w600,
            ),
          ),
        ),

        const SizedBox(
          height: 18,
        ),

        _modeSelector(),

        const SizedBox(
          height: 10,
        ),

        _selectedServerCard(
          displayServer,
        ),

        const SizedBox(
          height: 4,
        ),

        Row(
          children: [
            Expanded(
              child:
                  _statCard(
                icon:
                    Icons.download_rounded,
                title:
                    'دانلود',
                value:
                    download,
                iconColor:
                    const Color(
                  0xFF00E5FF,
                ),
              ),
            ),
            const SizedBox(
              width: 10,
            ),
            Expanded(
              child:
                  _statCard(
                icon:
                    Icons.upload_rounded,
                title:
                    'آپلود',
                value:
                    upload,
                iconColor:
                    const Color(
                  0xFF9C6CFF,
                ),
              ),
            ),
          ],
        ),

        card(
          Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration:
                        BoxDecoration(
                      borderRadius:
                          BorderRadius.circular(
                        14,
                      ),
                      color:
                          const Color(
                        0xFF7C4DFF,
                      ).withValues(
                        alpha: .12,
                      ),
                    ),
                    child:
                        const Icon(
                      Icons.data_usage,
                      color:
                          Color(
                        0xFF9C6CFF,
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 12,
                  ),
                  const Expanded(
                    child:
                        Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children: [
                        Text(
                          'حجم اشتراک',
                          style:
                              TextStyle(
                            fontWeight:
                                FontWeight
                                    .bold,
                          ),
                        ),
                        SizedBox(
                          height: 3,
                        ),
                        Text(
                          'مصرف اینترنت',
                          style:
                              TextStyle(
                            color:
                                Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    size(
                      totalBytes,
                    ),
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 14,
              ),
              ClipRRect(
                borderRadius:
                    BorderRadius.circular(
                  20,
                ),
                child:
                    LinearProgressIndicator(
                  value: percent,
                  minHeight: 8,
                  backgroundColor:
                      Colors.white
                          .withValues(
                    alpha: .06,
                  ),
                ),
              ),
              const SizedBox(
                height: 10,
              ),
              Row(
                children: [
                  const Text(
                    'مصرف شده',
                    style:
                        TextStyle(
                      color:
                          Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    size(
                      usedBytes,
                    ),
                    style:
                        const TextStyle(
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==========================================================================
  // CONNECTION HERO
  // ==========================================================================

  Widget _connectionHero() {
    return Center(
      child: GestureDetector(
        onTap:
            connecting
                ? null
                : connected
                    ? disconnect
                    : connect,
        child: Container(
          width: 225,
          height: 225,
          decoration:
              BoxDecoration(
            shape:
                BoxShape.circle,
            gradient:
                connected
                    ? const LinearGradient(
                        colors: [
                          Color(
                            0xFF00E676,
                          ),
                          Color(
                            0xFF00B8D4,
                          ),
                        ],
                      )
                    : mainGradient,
            boxShadow: [
              BoxShadow(
                color:
                    (connected
                            ? const Color(
                                0xFF00E676,
                              )
                            : const Color(
                                0xFF7C4DFF,
                              ))
                        .withValues(
                  alpha: .30,
                ),
                blurRadius: 45,
                spreadRadius: 8,
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: 199,
              height: 199,
              decoration:
                  const BoxDecoration(
                shape:
                    BoxShape.circle,
                color:
                    Color(0xFF080C14),
              ),
              child: Center(
                child:
                    connecting
                        ? Column(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .center,
                            children: [
                              const SizedBox(
                                width: 42,
                                height: 42,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth:
                                      3,
                                ),
                              ),
                              const SizedBox(
                                height: 14,
                              ),
                              const Text(
                                'در حال اتصال',
                                style:
                                    TextStyle(
                                  fontWeight:
                                      FontWeight
                                          .bold,
                                ),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .center,
                            children: [
                              Icon(
                                Icons
                                    .power_settings_new,
                                size: 58,
                                color:
                                    connected
                                        ? const Color(
                                            0xFF00E676,
                                          )
                                        : const Color(
                                            0xFF9C6CFF,
                                          ),
                              ),
                              const SizedBox(
                                height: 10,
                              ),
                              Text(
                                connected
                                    ? 'قطع اتصال'
                                    : 'اتصال',
                                style:
                                    const TextStyle(
                                  fontSize: 18,
                                  fontWeight:
                                      FontWeight
                                          .w800,
                                ),
                              ),
                              const SizedBox(
                                height: 4,
                              ),
                              Text(
                                connected
                                    ? 'VPN فعال است'
                                    : 'برای اتصال لمس کنید',
                                style:
                                    const TextStyle(
                                  color:
                                      Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // MODE SELECTOR
  // ==========================================================================

  Widget _modeSelector() {
    return card(
      Row(
        children: [
          Expanded(
            child:
                _modeButton(
              icon:
                  Icons.auto_awesome,
              title:
                  'خودکار',
              subtitle:
                  'سریع‌ترین سرور',
              active:
                  selectionMode ==
                      ServerSelectionMode
                          .auto,
              onTap:
                  selectAutoMode,
            ),
          ),
          const SizedBox(
            width: 10,
          ),
          Expanded(
            child:
                _modeButton(
              icon:
                  Icons.touch_app,
              title:
                  'دستی',
              subtitle:
                  'انتخاب سرور',
              active:
                  selectionMode ==
                      ServerSelectionMode
                          .manual,
              onTap: () {
                setState(() {
                  page = 1;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeButton({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius:
          BorderRadius.circular(
        18,
      ),
      child:
          AnimatedContainer(
        duration:
            const Duration(
          milliseconds: 200,
        ),
        padding:
            const EdgeInsets.all(
          13,
        ),
        decoration:
            BoxDecoration(
          borderRadius:
              BorderRadius.circular(
            18,
          ),
          gradient:
              active
                  ? mainGradient
                  : null,
          color:
              active
                  ? null
                  : const Color(
                      0xFF151B28,
                    ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color:
                  active
                      ? Colors.white
                      : Colors.white60,
            ),
            const SizedBox(
              width: 8,
            ),
            Expanded(
              child:
                  Column(
                crossAxisAlignment:
                    CrossAxisAlignment
                        .start,
                children: [
                  Text(
                    title,
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  Text(
                    subtitle,
                    style:
                        TextStyle(
                      color:
                          active
                              ? Colors.white70
                              : Colors.white38,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // SELECTED SERVER
  // ==========================================================================

  Widget _selectedServerCard(
    Server? server,
  ) {
    return card(
      InkWell(
        onTap: () {
          setState(() {
            page = 1;
          });
        },
        borderRadius:
            BorderRadius.circular(
          18,
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration:
                  BoxDecoration(
                borderRadius:
                    BorderRadius.circular(
                  15,
                ),
                gradient:
                    mainGradient,
              ),
              child:
                  const Icon(
                Icons.public,
                color:
                    Colors.white,
              ),
            ),
            const SizedBox(
              width: 12,
            ),
            Expanded(
              child:
                  Column(
                crossAxisAlignment:
                    CrossAxisAlignment
                        .start,
                children: [
                  Text(
                    selectionMode ==
                            ServerSelectionMode
                                .auto
                        ? 'سرور سریع‌ترین'
                        : 'سرور انتخاب‌شده',
                    style:
                        const TextStyle(
                      color:
                          Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(
                    height: 4,
                  ),
                  Text(
                    server?.name ??
                        'هنوز سروری انتخاب نشده',
                    maxLines: 1,
                    overflow:
                        TextOverflow
                            .ellipsis,
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  if (server != null)
                    Text(
                      '${server.type} • ${server.host}',
                      maxLines: 1,
                      overflow:
                          TextOverflow
                              .ellipsis,
                      style:
                          const TextStyle(
                        color:
                            Colors.white38,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
            if (server?.ping != null)
              Column(
                children: [
                  Text(
                    '${server!.ping}',
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'ms',
                    style:
                        TextStyle(
                      color:
                          Colors.white38,
                      fontSize: 10,
                    ),
                  ),
                ],
              )
            else
              const Icon(
                Icons.chevron_left,
                color:
                    Colors.white38,
              ),
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // STAT CARD
  // ==========================================================================

  Widget _statCard({
    required IconData icon,
    required String title,
    required String value,
    required Color iconColor,
  }) {
    return card(
      Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: iconColor,
                size: 20,
              ),
              const SizedBox(
                width: 6,
              ),
              Text(
                title,
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(
            height: 9,
          ),
          Text(
            value,
            style:
                const TextStyle(
              fontSize: 17,
              fontWeight:
                  FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // SERVERS PAGE
  // ==========================================================================

  Widget _servers() {
    return ListView(
      padding:
          const EdgeInsets.fromLTRB(
        18,
        18,
        18,
        24,
      ),
      children: [
        header(
          'سرورها',
          '${servers.length} کانفیگ',
        ),

        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    testing ||
                            servers.isEmpty
                        ? null
                        : () =>
                            testAll(),
                icon:
                    testing
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child:
                                CircularProgressIndicator(
                              strokeWidth:
                                  2,
                            ),
                          )
                        : const Icon(
                            Icons.speed,
                          ),
                label:
                    Text(
                  testing
                      ? 'در حال تست'
                      : 'تست سرورها',
                ),
              ),
            ),
            const SizedBox(
              width: 10,
            ),
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    loading
                        ? null
                        : () =>
                            loadSubscription(),
                icon:
                    const Icon(
                  Icons.refresh,
                ),
                label:
                    const Text(
                  'بروزرسانی',
                ),
              ),
            ),
          ],
        ),

        const SizedBox(
          height: 12,
        ),

        if (servers.isEmpty)
          card(
            Column(
              children: [
                const Icon(
                  Icons.dns_outlined,
                  size: 52,
                  color:
                      Colors.white38,
                ),
                const SizedBox(
                  height: 12,
                ),
                const Text(
                  'هنوز سروری وجود ندارد',
                  style:
                      TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                const SizedBox(
                  height: 6,
                ),
                const Text(
                  'از بخش اشتراک، لینک Subscription خود را اضافه کن.',
                  textAlign:
                      TextAlign.center,
                  style:
                      TextStyle(
                    color:
                        Colors.white54,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

        ...servers.asMap().entries.map(
          (entry) {
            final index =
                entry.key;
            final server =
                entry.value;

            final isSelected =
                selectedServer?.raw ==
                    server.raw;

            return card(
              InkWell(
                onTap: () =>
                    selectManualServer(
                  server,
                ),
                borderRadius:
                    BorderRadius.circular(
                  18,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration:
                          BoxDecoration(
                        borderRadius:
                            BorderRadius
                                .circular(
                          14,
                        ),
                        gradient:
                            isSelected
                                ? mainGradient
                                : null,
                        color:
                            isSelected
                                ? null
                                : const Color(
                                    0xFF151B28,
                                  ),
                      ),
                      child:
                          Icon(
                        isSelected
                            ? Icons.check
                            : Icons.public,
                      ),
                    ),
                    const SizedBox(
                      width: 12,
                    ),
                    Expanded(
                      child:
                          Column(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                        children: [
                          Text(
                            server.name,
                            maxLines: 1,
                            overflow:
                                TextOverflow
                                    .ellipsis,
                            style:
                                const TextStyle(
                              fontWeight:
                                  FontWeight
                                      .bold,
                            ),
                          ),
                          const SizedBox(
                            height: 4,
                          ),
                          Text(
                            '${server.type} • ${server.host}:${server.port}',
                            maxLines: 1,
                            overflow:
                                TextOverflow
                                    .ellipsis,
                            style:
                                const TextStyle(
                              color:
                                  Colors.white38,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _pingWidget(
                      server.ping,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _pingWidget(
    int? ping,
  ) {
    if (ping == null) {
      return const Text(
        '—',
        style:
            TextStyle(
          color:
              Colors.white38,
        ),
      );
    }

    return Column(
      children: [
        Text(
          '$ping',
          style:
              const TextStyle(
            fontWeight:
                FontWeight.bold,
          ),
        ),
        const Text(
          'ms',
          style:
              TextStyle(
            color:
                Colors.white38,
            fontSize: 9,
          ),
        ),
      ],
    );
  }

  // ==========================================================================
  // TRAFFIC PAGE
  // ==========================================================================

  Widget _traffic() {
    return ListView(
      padding:
          const EdgeInsets.fromLTRB(
        18,
        18,
        18,
        24,
      ),
      children: [
        header(
          'ترافیک و تست',
          'وضعیت واقعی اتصال',
        ),

        Row(
          children: [
            Expanded(
              child:
                  _statCard(
                icon:
                    Icons.download,
                title:
                    'دانلود لحظه‌ای',
                value:
                    download,
                iconColor:
                    const Color(
                  0xFF00E5FF,
                ),
              ),
            ),
            const SizedBox(
              width: 10,
            ),
            Expanded(
              child:
                  _statCard(
                icon:
                    Icons.upload,
                title:
                    'آپلود لحظه‌ای',
                value:
                    upload,
                iconColor:
                    const Color(
                  0xFF9C6CFF,
                ),
              ),
            ),
          ],
        ),

        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'مصرف جلسه',
                style:
                    TextStyle(
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 16,
              ),
              _trafficRow(
                'دانلود',
                size(
                  downloadTotalBytes,
                ),
                Icons.download,
              ),
              const SizedBox(
                height: 12,
              ),
              _trafficRow(
                'آپلود',
                size(
                  uploadTotalBytes,
                ),
                Icons.upload,
              ),
              const SizedBox(
                height: 12,
              ),
              _trafficRow(
                'مجموع',
                size(
                  downloadTotalBytes +
                      uploadTotalBytes,
                ),
                Icons.data_usage,
              ),
            ],
          ),
        ),

        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'تست سرعت واقعی',
                style:
                    TextStyle(
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 5,
              ),
              const Text(
                'این تست ظرفیت شبکه را با موتور sing-box اندازه‌گیری می‌کند.',
                style:
                    TextStyle(
                  color:
                      Colors.white54,
                  fontSize: 11,
                ),
              ),
              const SizedBox(
                height: 16,
              ),
              Row(
                children: [
                  Expanded(
                    child:
                        _testValue(
                      'دانلود',
                      testDownload,
                      Icons.download,
                    ),
                  ),
                  Expanded(
                    child:
                        _testValue(
                      'آپلود',
                      testUpload,
                      Icons.upload,
                    ),
                  ),
                  Expanded(
                    child:
                        _testValue(
                      'Latency',
                      testPing,
                      Icons.timer,
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 16,
              ),
              SizedBox(
                width:
                    double.infinity,
                child:
                    FilledButton.icon(
                  onPressed:
                      networkTestRunning
                          ? stopSpeedTest
                          : startSpeedTest,
                  icon:
                      Icon(
                    networkTestRunning
                        ? Icons.stop
                        : Icons.speed,
                  ),
                  label:
                      Text(
                    networkTestRunning
                        ? 'توقف تست'
                        : 'شروع تست سرعت',
                  ),
                ),
              ),
            ],
          ),
        ),

        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'STUN / NAT',
                style:
                    TextStyle(
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 14,
              ),
              _infoRow(
                'Latency',
                stunLatency,
              ),
              _infoRow(
                'IP عمومی',
                externalIp,
              ),
              _infoRow(
                'NAT',
                natType,
              ),
              const SizedBox(
                height: 10,
              ),
              SizedBox(
                width:
                    double.infinity,
                child:
                    OutlinedButton.icon(
                  onPressed:
                      stunTestRunning
                          ? stopStunTest
                          : startStunTest,
                  icon:
                      Icon(
                    stunTestRunning
                        ? Icons.stop
                        : Icons.network_check,
                  ),
                  label:
                      Text(
                    stunTestRunning
                        ? 'توقف STUN'
                        : 'تست STUN',
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _trafficRow(
    String title,
    String value,
    IconData icon,
  ) {
    return Row(
      children: [
        Icon(
          icon,
          size: 20,
          color:
              Colors.white54,
        ),
        const SizedBox(
          width: 10,
        ),
        Expanded(
          child: Text(
            title,
            style:
                const TextStyle(
              color:
                  Colors.white54,
            ),
          ),
        ),
        Text(
          value,
          style:
              const TextStyle(
            fontWeight:
                FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _testValue(
    String title,
    String value,
    IconData icon,
  ) {
    return Column(
      children: [
        Icon(
          icon,
          size: 20,
          color:
              Colors.white54,
        ),
        const SizedBox(
          height: 6,
        ),
        Text(
          value,
          textAlign:
              TextAlign.center,
          style:
              const TextStyle(
            fontWeight:
                FontWeight.bold,
            fontSize: 12,
          ),
        ),
        const SizedBox(
          height: 3,
        ),
        Text(
          title,
          style:
              const TextStyle(
            color:
                Colors.white38,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _infoRow(
    String title,
    String value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        vertical: 7,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style:
                  const TextStyle(
                color:
                    Colors.white54,
              ),
            ),
          ),
          Text(
            value,
            style:
                const TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // SUBSCRIPTION PAGE
  // ==========================================================================

  Widget _subscription() {
    final percent =
        totalBytes == null ||
                totalBytes! <= 0
            ? 0.0
            : ((usedBytes ?? 0) /
                    totalBytes!)
                .clamp(
                0.0,
                1.0,
              );

    final expired =
        expireAt != null &&
            expireAt! > 0 &&
            DateTime.fromMillisecondsSinceEpoch(
              expireAt! > 20000000000
                  ? expireAt!
                  : expireAt! * 1000,
            ).isBefore(
              DateTime.now(),
            );

    return ListView(
      padding:
          const EdgeInsets.fromLTRB(
        18,
        18,
        18,
        24,
      ),
      children: [
        header(
          'اشتراک',
          'مدیریت Subscription',
        ),

        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'آدرس Subscription',
                style:
                    TextStyle(
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 10,
              ),
              Container(
                width:
                    double.infinity,
                padding:
                    const EdgeInsets.all(
                  12,
                ),
                decoration:
                    BoxDecoration(
                  color:
                      const Color(
                    0xFF080C14,
                  ),
                  borderRadius:
                      BorderRadius.circular(
                    14,
                  ),
                ),
                child: Text(
                  url.text.isEmpty
                      ? 'هنوز اضافه نشده'
                      : url.text,
                  maxLines: 3,
                  overflow:
                      TextOverflow.ellipsis,
                  textDirection:
                      TextDirection.ltr,
                  style:
                      const TextStyle(
                    color:
                        Colors.white70,
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(
                height: 12,
              ),
              Row(
                children: [
                  Expanded(
                    child:
                        FilledButton.icon(
                      onPressed:
                          loading
                              ? null
                              : addSubscription,
                      icon:
                          const Icon(
                        Icons.link,
                      ),
                      label:
                          const Text(
                        'افزودن / تغییر',
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 10,
                  ),
                  IconButton(
                    onPressed:
                        loading ||
                                url.text
                                    .isEmpty
                            ? null
                            : () =>
                                loadSubscription(),
                    tooltip:
                        'بروزرسانی',
                    icon:
                        loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth:
                                      2,
                                ),
                              )
                            : const Icon(
                                Icons.refresh,
                              ),
                  ),
                ],
              ),
            ],
          ),
        ),

        card(
          Column(
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.data_usage,
                    color:
                        Color(
                      0xFF9C6CFF,
                    ),
                  ),
                  const SizedBox(
                    width: 10,
                  ),
                  const Expanded(
                    child:
                        Text(
                      'حجم مصرفی',
                      style:
                          TextStyle(
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ),
                  Text(
                    '${size(usedBytes)} / ${size(totalBytes)}',
                  ),
                ],
              ),
              const SizedBox(
                height: 14,
              ),
              ClipRRect(
                borderRadius:
                    BorderRadius.circular(
                  20,
                ),
                child:
                    LinearProgressIndicator(
                  value:
                      percent,
                  minHeight: 9,
                ),
              ),
            ],
          ),
        ),

        card(
          Column(
            children: [
              _infoRow(
                'دانلود',
                size(
                  downloadBytes,
                ),
              ),
              _infoRow(
                'آپلود',
                size(
                  uploadBytes,
                ),
              ),
              _infoRow(
                'کل حجم',
                size(
                  totalBytes,
                ),
              ),
              _infoRow(
                'وضعیت',
                expired
                    ? 'منقضی شده'
                    : 'فعال',
              ),
              _infoRow(
                'انقضا',
                expireAt == null ||
                        expireAt! <= 0
                    ? 'نامشخص'
                    : _dateFromUnix(
                        expireAt!,
                      ),
              ),
              _infoRow(
                'آخرین بروزرسانی',
                lastUpdate == null
                    ? 'هنوز انجام نشده'
                    : _formatUpdate(
                        lastUpdate!,
                      ),
              ),
            ],
          ),
        ),

        card(
          const Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                'فرمت‌های قابل پشتیبانی',
                style:
                    TextStyle(
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              SizedBox(
                height: 10,
              ),
              Text(
                '• Plain URI\n'
                '• Base64\n'
                '• URL-safe Base64\n'
                '• JSON\n'
                '• sing-box JSON\n'
                '• VMess\n'
                '• VLESS\n'
                '• Trojan\n'
                '• Shadowsocks\n'
                '• Hysteria2\n'
                '• TUIC\n'
                '• SOCKS5',
                style:
                    TextStyle(
                  color:
                      Colors.white54,
                  height: 1.7,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatUpdate(
    String value,
  ) {
    try {
      final date =
          DateTime.parse(value)
              .toLocal();

      return
          '${date.year}/'
          '${date.month.toString().padLeft(2, '0')}/'
          '${date.day.toString().padLeft(2, '0')} '
          '${date.hour.toString().padLeft(2, '0')}:'
          '${date.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return value;
    }
  }

  // ==========================================================================
  // SETTINGS
  // ==========================================================================

  Widget _settings() {
    return ListView(
      padding:
          const EdgeInsets.fromLTRB(
        18,
        18,
        18,
        24,
      ),
      children: [
        header(
          'تنظیمات',
          'Light speed',
        ),

        card(
          Column(
            children: [
              ListTile(
                contentPadding:
                    EdgeInsets.zero,
                leading:
                    const Icon(
                  Icons.auto_awesome,
                ),
                title:
                    const Text(
                  'انتخاب خودکار',
                ),
                subtitle:
                    const Text(
                  'اتصال به سریع‌ترین سرور',
                ),
                trailing:
                    Switch(
                  value:
                      selectionMode ==
                          ServerSelectionMode
                              .auto,
                  onChanged:
                      (value) {
                    if (value) {
                      selectAutoMode();
                    } else {
                      setState(() {
                        selectionMode =
                            ServerSelectionMode
                                .manual;
                      });

                      saveSelectionMode();
                    }
                  },
                ),
              ),
              const Divider(
                height: 1,
              ),
              ListTile(
                contentPadding:
                    EdgeInsets.zero,
                leading:
                    const Icon(
                  Icons.speed,
                ),
                title:
                    const Text(
                  'تست سرعت شبکه',
                ),
                subtitle:
                    Text(
                  '$testDownload / $testUpload',
                ),
                trailing:
                    IconButton(
                  onPressed:
                      networkTestRunning
                          ? stopSpeedTest
                          : startSpeedTest,
                  icon:
                      Icon(
                    networkTestRunning
                        ? Icons.stop
                        : Icons.play_arrow,
                  ),
                ),
              ),
              const Divider(
                height: 1,
              ),
              ListTile(
                contentPadding:
                    EdgeInsets.zero,
                leading:
                    const Icon(
                  Icons.network_check,
                ),
                title:
                    const Text(
                  'تست STUN',
                ),
                subtitle:
                    Text(
                  stunLatency == '—'
                      ? 'اجرا نشده'
                      : stunLatency,
                ),
                trailing:
                    IconButton(
                  onPressed:
                      stunTestRunning
                          ? stopStunTest
                          : startStunTest,
                  icon:
                      Icon(
                    stunTestRunning
                        ? Icons.stop
                        : Icons.play_arrow,
                  ),
                ),
              ),
            ],
          ),
        ),

        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'اطلاعات برنامه',
                style:
                    TextStyle(
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 12,
              ),
              const Text(
                'Light speed',
                style:
                    TextStyle(
                  color:
                      Colors.white70,
                ),
              ),
              const SizedBox(
                height: 4,
              ),
              const Text(
                'sing-box VPN Client',
                style:
                    TextStyle(
                  color:
                      Colors.white38,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
