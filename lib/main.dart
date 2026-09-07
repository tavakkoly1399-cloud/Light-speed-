import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
      ),
      home: const HomePage(),
    );
  }
}

enum ServerSelectionMode { auto, manual }

class ServerNode {
  ServerNode({
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
  int? pingMs;
}

class SubscriptionInfo {
  int? upload;
  int? download;
  int? total;
  int? expire;

  int? get used => (upload == null && download == null)
      ? null
      : (upload ?? 0) + (download ?? 0);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver {
  final urlController = TextEditingController();

  final List<ServerNode> servers = [];
  final subscription = SubscriptionInfo();

  StreamSubscription? stateSub;
  StreamSubscription? trafficSub;
  StreamSubscription? faultSub;
  Timer? refreshTimer;

  ServerNode? selectedServer;
  ServerSelectionMode selectionMode = ServerSelectionMode.auto;

  bool loading = false;
  bool testing = false;
  bool connected = false;
  bool connecting = false;

  String status = 'آماده اتصال';
  String downloadSpeed = '0 B/s';
  String uploadSpeed = '0 B/s';
  int downloadTotal = 0;
  int uploadTotal = 0;
  String? lastUpdate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenVpn();
    _loadSaved();

    refreshTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => (connected || connecting) ? null : loadSubscription(silent: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stateSub?.cancel();
    trafficSub?.cancel();
    faultSub?.cancel();
    refreshTimer?.cancel();
    urlController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncVpnState();
    }
  }

  void _listenVpn() {
    stateSub = vpn.serviceStateStream.listen((state) {
      if (!mounted) return;
      final s = state.toString().toLowerCase();

      setState(() {
        if (s.contains('started') ||
            s.contains('running') ||
            s.contains('connected')) {
          connected = true;
          connecting = false;
          status = 'VPN متصل است';
        } else if (s.contains('starting')) {
          connecting = true;
          status = 'در حال اتصال...';
        } else if (s.contains('stopping')) {
          connecting = true;
          status = 'در حال قطع اتصال...';
        } else if (s.contains('stopped') ||
            s.contains('disconnected')) {
          connected = false;
          connecting = false;
          status = 'VPN متوقف است';
          downloadSpeed = '0 B/s';
          uploadSpeed = '0 B/s';
        }
      });
    });

    trafficSub = vpn.trafficStatsStream.listen((stats) {
      if (!mounted) return;
      setState(() {
        downloadSpeed = formatSpeed(stats.downlinkBps);
        uploadSpeed = formatSpeed(stats.uplinkBps);
        downloadTotal = stats.downlinkTotalBytes;
        uploadTotal = stats.uplinkTotalBytes;
      });
    });

    faultSub = vpn.faultStream.listen((error) {
      if (!mounted) return;
      setState(() {
        connected = false;
        connecting = false;
        status = 'خطای VPN';
      });
      _show('خطای sing-box:\n$error');
    });
  }

  Future<void> _syncVpnState() async {
    try {
      final state = await vpn.getServiceState();
      if (!mounted) return;

      final s = state.toString().toLowerCase();
      setState(() {
        connected = s.contains('started') ||
            s.contains('running') ||
            s.contains('connected');
        connecting = s.contains('starting') ||
            s.contains('stopping');
        status = _stateText(s);
      });
    } catch (e) {
      debugPrint('VPN state error: $e');
    }
  }

  String _stateText(String s) {
    if (s.contains('started') ||
        s.contains('running') ||
        s.contains('connected')) {
      return 'VPN متصل است';
    }
    if (s.contains('starting')) return 'در حال اتصال...';
    if (s.contains('stopping')) return 'در حال قطع اتصال...';
    return 'VPN متوقف است';
  }

  Future<void> _loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final savedUrl = prefs.getString('subscription_url');
      final savedMode = prefs.getString('selection_mode');
      final savedRaw = prefs.getString('selected_server_raw');

      selectionMode = savedMode == 'manual'
          ? ServerSelectionMode.manual
          : ServerSelectionMode.auto;

      if (savedUrl != null && savedUrl.isNotEmpty) {
        urlController.text = savedUrl;
        await loadSubscription(
          silent: true,
          restoreRaw: savedRaw,
        );
      }

      await _syncVpnState();
    } catch (e) {
      debugPrint('load saved error: $e');
    }
  }

  Future<void> loadSubscription({
    bool silent = false,
    String? restoreRaw,
  }) async {
    final value = urlController.text.trim();

    if (value.isEmpty) {
      if (!silent) _show('ابتدا Subscription را وارد کن');
      return;
    }

    Uri uri;
    try {
      uri = Uri.parse(value);
      if (!uri.hasScheme || uri.host.isEmpty) {
        throw const FormatException();
      }
    } catch (_) {
      if (!silent) _show('آدرس Subscription معتبر نیست');
      return;
    }

    setState(() {
      loading = true;
      status = 'در حال دریافت Subscription...';
    });

    try {
      final response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'LightSpeed/7.0',
          'Accept': '*/*',
          'Cache-Control': 'no-cache',
          'Pragma': 'no-cache',
        },
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final body = utf8.decode(
        response.bodyBytes,
        allowMalformed: true,
      );

      _parseUserInfo(_header(response.headers, 'subscription-userinfo'));

      final lines = decodeSubscription(body);
      final parsed = <ServerNode>[];
      final fingerprints = <String>{};

      for (final line in lines) {
        final node = parseNode(line);
        if (node == null) continue;
        final fp = '${node.type}|${node.host}|${node.port}|${node.raw}';
        if (fingerprints.add(fp)) {
          parsed.add(node);
        }
      }

      if (parsed.isEmpty) {
        throw Exception('هیچ کانفیگ قابل استفاده‌ای پیدا نشد');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('subscription_url', value);

      final now = DateTime.now().toIso8601String();
      await prefs.setString('last_update', now);

      ServerNode? restored;
      final wantedRaw = restoreRaw ??
          prefs.getString('selected_server_raw');

      if (wantedRaw != null) {
        for (final node in parsed) {
          if (node.raw == wantedRaw) {
            restored = node;
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
        lastUpdate = now;
        loading = false;
        status = '${servers.length} سرور دریافت شد';
      });

      if (selectionMode == ServerSelectionMode.auto) {
        await testAll(silent: true);
        final best = fastestServer();
        if (best != null && mounted) {
          setState(() => selectedServer = best);
          await _saveSelected();
        }
      }

      if (!silent) {
        _show('${servers.length} سرور دریافت شد');
      }
    } catch (e) {
      debugPrint('Subscription error: $e');
      if (!mounted) return;
      setState(() {
        loading = false;
        status = 'خطا در دریافت Subscription';
      });
      if (!silent) _show('دریافت Subscription ناموفق بود:\n$e');
    }
  }

  String? _header(Map<String, String> headers, String wanted) {
    final target = wanted.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == target) {
        return entry.value;
      }
    }
    return null;
  }

  void _parseUserInfo(String? raw) {
    if (raw == null || raw.trim().isEmpty) return;

    final map = <String, int>{};
    for (final item in raw.split(';')) {
      final i = item.indexOf('=');
      if (i <= 0) continue;

      final key = item.substring(0, i).trim().toLowerCase();
      final value = int.tryParse(
        item.substring(i + 1).trim(),
      );
      if (value == null) continue;

      if (key == 'upload') map['upload'] = value;
      if (key == 'download') map['download'] = value;
      if (key == 'total' || key == 'transfer_enable') {
        map['total'] = value;
      }
      if (key == 'expire' || key == 'expired_at') {
        map['expire'] = value;
      }
    }

    if (!mounted) return;
    setState(() {
      subscription.upload = map['upload'] ?? subscription.upload;
      subscription.download =
          map['download'] ?? subscription.download;
      subscription.total = map['total'] ?? subscription.total;
      subscription.expire = map['expire'] ?? subscription.expire;
    });
  }

  List<String> decodeSubscription(String body) {
    final result = <String>[];
    final visited = <String>{};

    void addText(String text, int depth) {
      if (depth > 4) return;

      final cleaned = text
          .replaceFirst('\uFEFF', '')
          .trim();

      if (cleaned.isEmpty || !visited.add(cleaned)) return;

      for (final line in cleaned.split(RegExp(r'\r?\n'))) {
        final value = line.trim();
        if (value.isEmpty) continue;

        if (looksLikeNode(value)) {
          result.add(value);
        }
      }

      final normalized = cleaned.replaceAll(RegExp(r'\s+'), '');
      final candidates = <String>[cleaned, normalized];

      for (final candidate in candidates) {
        try {
          final decoded = utf8.decode(
            base64Url.decode(
              base64Url.normalize(candidate),
            ),
            allowMalformed: true,
          );

          if (decoded.trim() != cleaned) {
            addText(decoded, depth + 1);
          }
        } catch (_) {}
      }
    }

    addText(body, 0);
    return result.toSet().toList();
  }

  bool looksLikeNode(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith('vless://') ||
        lower.startsWith('vmess://') ||
        lower.startsWith('trojan://') ||
        lower.startsWith('ss://') ||
        lower.startsWith('hysteria2://') ||
        lower.startsWith('hy2://') ||
        lower.startsWith('tuic://');
  }

  ServerNode? parseNode(String raw) {
    try {
      final uri = Uri.parse(raw.trim());
      final scheme = uri.scheme.toLowerCase();

      switch (scheme) {
        case 'vless':
          return _parseVless(uri, raw);
        case 'vmess':
          return _parseVmess(raw);
        case 'trojan':
          return _parseTrojan(uri, raw);
        case 'ss':
          return _parseShadowsocks(uri, raw);
        case 'hysteria2':
        case 'hy2':
          return _parseHysteria2(uri, raw);
        case 'tuic':
          return _parseTuic(uri, raw);
        default:
          return null;
      }
    } catch (e) {
      debugPrint('parse node error: $e');
      return null;
    }
  }

  ServerNode? _parseVless(Uri uri, String raw) {
    final host = uri.host;
    final port = uri.port;
    final uuid = uri.userInfo;

    if (host.isEmpty || port <= 0 || uuid.isEmpty) return null;

    final q = uri.queryParameters;
    final outbound = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': host,
      'server_port': port,
      'uuid': uuid,
    };

    _applyCommonOptions(outbound, q);

    // VLESS Reality/Vision profiles commonly carry
    // flow=xtls-rprx-vision.
    final flow = q['flow'];
    if (flow != null && flow.isNotEmpty) {
      outbound['flow'] = flow;
    }

    final packetEncoding =
        q['packetEncoding'] ?? q['packet_encoding'];
    if (packetEncoding != null && packetEncoding.isNotEmpty) {
      outbound['packet_encoding'] = packetEncoding;
    }

    return ServerNode(
      raw: raw,
      name: _nodeName(uri, 'VLESS'),
      type: 'VLESS',
      host: host,
      port: port,
      outbound: outbound,
    );
  }

  ServerNode? _parseVmess(String raw) {
    var encoded = raw.substring('vmess://'.length).trim();
    encoded = Uri.decodeComponent(encoded);

    final jsonText = utf8.decode(
      base64Url.decode(base64Url.normalize(encoded)),
      allowMalformed: true,
    );

    final data = jsonDecode(jsonText);
    if (data is! Map) return null;

    final host = '${data['add'] ?? ''}'.trim();
    final port = int.tryParse('${data['port'] ?? ''}') ?? 0;
    final id = '${data['id'] ?? ''}'.trim();

    if (host.isEmpty || port <= 0 || id.isEmpty) return null;

    final q = <String, String>{};
    for (final entry in data.entries) {
      q[entry.key.toString()] = '${entry.value ?? ''}';
    }

    final outbound = <String, dynamic>{
      'type': 'vmess',
      'tag': 'proxy',
      'server': host,
      'server_port': port,
      'uuid': id,
      'security': (data['scy'] ?? 'auto').toString(),
    };

    final aid = int.tryParse('${data['aid'] ?? '0'}');
    if (aid != null) outbound['alter_id'] = aid;

    _applyVmessOptions(outbound, q);

    final packetEncoding =
        q['packetEncoding'] ?? q['packet_encoding'];
    if (packetEncoding != null && packetEncoding.isNotEmpty) {
      outbound['packet_encoding'] = packetEncoding;
    }

    return ServerNode(
      raw: raw,
      name: '${data['ps'] ?? 'VMess'}'.trim().isEmpty
          ? 'VMess'
          : '${data['ps']}'.trim(),
      type: 'VMess',
      host: host,
      port: port,
      outbound: outbound,
    );
  }

  ServerNode? _parseTrojan(Uri uri, String raw) {
    if (uri.host.isEmpty ||
        uri.port <= 0 ||
        uri.userInfo.isEmpty) {
      return null;
    }

    final q = uri.queryParameters;
    final outbound = <String, dynamic>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'password': uri.userInfo,
    };

    _applyCommonOptions(outbound, q);

    return ServerNode(
      raw: raw,
      name: _nodeName(uri, 'Trojan'),
      type: 'Trojan',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  ServerNode? _parseShadowsocks(Uri uri, String raw) {
    if (uri.host.isEmpty || uri.port <= 0) return null;

    String userInfo = uri.userInfo;
    if (userInfo.isEmpty) {
      try {
        final decoded = utf8.decode(
          base64Url.decode(base64Url.normalize(uri.host)),
        );
        final parts = decoded.split(':');
        if (parts.length == 2) {
          final method = parts[0];
          final password = parts[1];

          return ServerNode(
            raw: raw,
            name: _nodeName(uri, 'Shadowsocks'),
            type: 'Shadowsocks',
            host: uri.host,
            port: uri.port,
            outbound: {
              'type': 'shadowsocks',
              'tag': 'proxy',
              'server': uri.host,
              'server_port': uri.port,
              'method': method,
              'password': password,
            },
          );
        }
      } catch (_) {}
    }

    String method = '';
    String password = '';

    try {
      final decoded = utf8.decode(
        base64Url.decode(base64Url.normalize(userInfo)),
      );
      final i = decoded.indexOf(':');
      if (i > 0) {
        method = decoded.substring(0, i);
        password = decoded.substring(i + 1);
      }
    } catch (_) {
      final i = userInfo.indexOf(':');
      if (i > 0) {
        method = userInfo.substring(0, i);
        password = userInfo.substring(i + 1);
      }
    }

    if (method.isEmpty || password.isEmpty) return null;

    return ServerNode(
      raw: raw,
      name: _nodeName(uri, 'Shadowsocks'),
      type: 'Shadowsocks',
      host: uri.host,
      port: uri.port,
      outbound: {
        'type': 'shadowsocks',
        'tag': 'proxy',
        'server': uri.host,
        'server_port': uri.port,
        'method': method,
        'password': password,
      },
    );
  }

  ServerNode? _parseHysteria2(Uri uri, String raw) {
    if (uri.host.isEmpty ||
        uri.port <= 0 ||
        uri.userInfo.isEmpty) {
      return null;
    }

    final q = uri.queryParameters;
    final outbound = <String, dynamic>{
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'password': uri.userInfo,
      'tls': <String, dynamic>{
        'enabled': true,
      },
    };

    final tls = outbound['tls'] as Map<String, dynamic>;

    if (q['sni']?.isNotEmpty == true) {
      tls['server_name'] = q['sni'];
    }

    if (q['insecure'] == '1' ||
        q['allowInsecure'] == '1') {
      tls['insecure'] = true;
    }

    if (q['obfs']?.isNotEmpty == true) {
      outbound['obfs'] = {
        'type': q['obfs'],
        if (q['obfs-password']?.isNotEmpty == true)
          'password': q['obfs-password'],
      };
    }

    return ServerNode(
      raw: raw,
      name: _nodeName(uri, 'Hysteria2'),
      type: 'Hysteria2',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  ServerNode? _parseTuic(Uri uri, String raw) {
    if (uri.host.isEmpty ||
        uri.port <= 0 ||
        uri.userInfo.isEmpty) {
      return null;
    }

    final pieces = uri.userInfo.split(':');
    if (pieces.length < 2) return null;

    final q = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'tuic',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': pieces[0],
      'password': pieces.sublist(1).join(':'),
      'tls': <String, dynamic>{
        'enabled': true,
      },
    };

    final tls = outbound['tls'] as Map<String, dynamic>;

    if (q['sni']?.isNotEmpty == true) {
      tls['server_name'] = q['sni'];
    }

    if (q['insecure'] == '1' ||
        q['allow_insecure'] == '1') {
      tls['insecure'] = true;
    }

    if (q['congestion_control']?.isNotEmpty == true) {
      outbound['congestion_control'] =
          q['congestion_control'];
    }

    return ServerNode(
      raw: raw,
      name: _nodeName(uri, 'TUIC'),
      type: 'TUIC',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  void _applyCommonOptions(
    Map<String, dynamic> outbound,
    Map<String, String> q,
  ) {
    final transport =
        (q['type'] ?? q['network'] ?? '').toLowerCase();

    final security =
        (q['security'] ?? '').toLowerCase();

    if (security == 'tls' || security == 'reality') {
      final tls = <String, dynamic>{
        'enabled': true,
      };

      if (q['sni']?.isNotEmpty == true) {
        tls['server_name'] = q['sni'];
      }

      if (q['fp']?.isNotEmpty == true) {
        tls['utls'] = {
          'enabled': true,
          'fingerprint': q['fp'],
        };
      }

      if (q['allowInsecure'] == '1' ||
          q['insecure'] == '1') {
        tls['insecure'] = true;
      }

      if (security == 'reality') {
        final publicKey = q['pbk'];
        final shortId = q['sid'];

        if (publicKey != null && publicKey.isNotEmpty) {
          tls['reality'] = {
            'enabled': true,
            'public_key': publicKey,
            if (shortId != null && shortId.isNotEmpty)
              'short_id': shortId,
          };
        }
      }

      outbound['tls'] = tls;
    }

    if (transport == 'ws') {
      outbound['transport'] = {
        'type': 'ws',
        'path': q['path'] ?? '/',
        if (q['host']?.isNotEmpty == true)
          'headers': {
            'Host': q['host'],
          },
      };
    } else if (transport == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        'service_name':
            q['serviceName'] ??
            q['serviceName'.toLowerCase()] ??
            '',
      };
    } else if (transport == 'httpupgrade') {
      outbound['transport'] = {
        'type': 'httpupgrade',
        'path': q['path'] ?? '/',
        if (q['host']?.isNotEmpty == true)
          'host': q['host'],
      };
    } else if (transport == 'http' ||
        transport == 'h2') {
      outbound['transport'] = {
        'type': 'http',
        'path': q['path'] ?? '/',
        if (q['host']?.isNotEmpty == true)
          'host': [q['host']],
      };
    }
  }

  void _applyVmessOptions(
    Map<String, dynamic> outbound,
    Map<String, String> d,
  ) {
    final security = (d['tls'] ?? '').toLowerCase();

    if (security == 'tls') {
      outbound['tls'] = {
        'enabled': true,
        if ((d['sni'] ?? d['host'] ?? '').isNotEmpty)
          'server_name': d['sni'] ?? d['host'],
        if ((d['fp'] ?? '').isNotEmpty)
          'utls': {
            'enabled': true,
            'fingerprint': d['fp'],
          },
      };
    }

    final network = (d['net'] ?? '').toLowerCase();

    if (network == 'ws') {
      outbound['transport'] = {
        'type': 'ws',
        'path': d['path'] ?? '/',
        if ((d['host'] ?? '').isNotEmpty)
          'headers': {
            'Host': d['host'],
          },
      };
    } else if (network == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        'service_name': d['path'] ?? '',
      };
    } else if (network == 'httpupgrade') {
      outbound['transport'] = {
        'type': 'httpupgrade',
        'path': d['path'] ?? '/',
        if ((d['host'] ?? '').isNotEmpty)
          'host': d['host'],
      };
    }
  }

  String _nodeName(Uri uri, String fallback) {
    final fragment = uri.fragment.trim();

    return fragment.isEmpty
        ? '$fallback • ${uri.host}'
        : Uri.decodeComponent(fragment);
  }

  Future<void> testAll({bool silent = false}) async {
    if (servers.isEmpty) return;

    if (mounted) {
      setState(() {
        testing = true;
        if (!silent) {
          status = 'در حال تست Ping سرورها...';
        }
      });
    }

    await Future.wait(
      servers.map((server) async {
        try {
          final stopwatch = Stopwatch()..start();

          final socket = await Socket.connect(
            server.host,
            server.port,
            timeout: const Duration(seconds: 5),
          );

          stopwatch.stop();
          socket.destroy();

          if (mounted) {
            setState(() {
              server.pingMs =
                  stopwatch.elapsedMilliseconds;
            });
          }
        } catch (_) {
          if (mounted) {
            setState(() {
              server.pingMs = null;
            });
          }
        }
      }),
    );

    final best = fastestServer();

    if (mounted) {
      setState(() {
        testing = false;

        if (!silent) {
          status = best == null
              ? 'Ping موفقی پیدا نشد'
              : 'سریع‌ترین سرور: ${best.name}';
        }
      });
    }
  }

  ServerNode? fastestServer() {
    final valid = servers
        .where((s) => s.pingMs != null)
        .toList();

    if (valid.isEmpty) return null;

    valid.sort(
      (a, b) =>
          a.pingMs!.compareTo(b.pingMs!),
    );

    return valid.first;
  }

  Future<String> _waitForVpnStart({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final result = await Future.any<String>([
        vpn.serviceStateStream
            .map((state) => state.toString().toLowerCase())
            .firstWhere((state) =>
                state.contains('started') ||
                state.contains('running') ||
                state.contains('connected') ||
                state.contains('stopped') ||
                state.contains('disconnected')),
        vpn.faultStream
            .map((error) => 'fault:$error')
            .first,
        Future<String>.delayed(
          timeout,
          () => 'timeout',
        ),
      ]);

      return result;
    } catch (e) {
      return 'fault:$e';
    }
  }

  Future<void> _connectSingleNode(ServerNode node) async {
    final config = buildSingboxConfig(node);
    final json = jsonEncode(config);

    // Validate with the same sing-box core that will actually run.
    await vpn.checkConfig(json);

    final permission = await vpn.requestVPNPermission();
    if (!permission) {
      throw Exception('مجوز VPN داده نشد');
    }

    // If an old session is still running, stop it before starting
    // a new profile. This makes server switching reliable.
    try {
      final current = await vpn.getServiceState();
      final currentText = current.toString().toLowerCase();
      if (currentText.contains('started') ||
          currentText.contains('running') ||
          currentText.contains('connected') ||
          currentText.contains('starting')) {
        await vpn.disconnect();
        await Future<void>.delayed(
          const Duration(milliseconds: 400),
        );
      }
    } catch (_) {}

    await vpn.connect(
      SessionOptions(
        config: json,
        networkMode: NetworkMode.vpn,
        notification: NotificationConfig(
          title: 'Light speed',
          showTrafficStats: true,
          showStopButton: true,
          stopButtonLabel: 'قطع VPN',
        ),
      ),
    );

    final result = await _waitForVpnStart();

    if (result == 'timeout') {
      await _syncVpnState();
      final state = await vpn.getServiceState();
      final text = state.toString().toLowerCase();
      if (text.contains('started') ||
          text.contains('running') ||
          text.contains('connected')) {
        return;
      }
      throw Exception('هسته VPN در زمان مقرر متصل نشد');
    }

    if (result.startsWith('fault:')) {
      throw Exception(result.substring(6));
    }

    if (result.contains('stopped') ||
        result.contains('disconnected')) {
      throw Exception('هسته VPN بلافاصله متوقف شد');
    }
  }

  Future<void> connectVpn() async {
    if (connecting) return;

    if (servers.isEmpty) {
      await loadSubscription();
      if (servers.isEmpty) return;
    }

    setState(() {
      connecting = true;
      status = 'در حال پیدا کردن بهترین سرور...';
    });

    try {
      if (selectionMode == ServerSelectionMode.auto) {
        await testAll(silent: true);
      }

      final candidates = <ServerNode>[];

      if (selectionMode == ServerSelectionMode.manual &&
          selectedServer != null) {
        candidates.add(selectedServer!);
      } else {
        final sorted = servers
            .where((server) => server.pingMs != null)
            .toList()
          ..sort((a, b) =>
              a.pingMs!.compareTo(b.pingMs!));

        candidates.addAll(sorted);

        // Include untested nodes as a fallback.
        for (final server in servers) {
          if (!candidates.contains(server)) {
            candidates.add(server);
          }
        }
      }

      if (candidates.isEmpty) {
        throw Exception('هیچ سرور قابل استفاده‌ای پیدا نشد');
      }

      Object? lastError;

      // Try the fastest server first. If its real tunnel fails,
      // automatically try the next server, similar to Smart/Auto
      // connection behaviour in mature VPN clients.
      for (var i = 0; i < candidates.length; i++) {
        final node = candidates[i];

        if (!mounted) return;
        setState(() {
          selectedServer = node;
          connecting = true;
          status = 'در حال اتصال به ${node.name}...';
        });

        try {
          await _connectSingleNode(node);
          await _saveSelected();

          if (!mounted) return;
          setState(() {
            connected = true;
            connecting = false;
            status = 'VPN متصل است • ${node.name}';
          });
          return;
        } catch (e) {
          lastError = e;
          debugPrint(
            'Node connection failed: ${node.name}: $e',
          );

          try {
            await vpn.disconnect();
          } catch (_) {}

          if (i + 1 < candidates.length && mounted) {
            setState(() {
              status = 'سرور فعلی وصل نشد؛ در حال امتحان سرور بعدی...';
            });
            await Future<void>.delayed(
              const Duration(milliseconds: 500),
            );
          }
        }
      }

      throw Exception(
        'هیچ‌کدام از سرورها به‌صورت واقعی وصل نشدند. آخرین خطا: $lastError',
      );
    } catch (e) {
      debugPrint('Connect error: $e');

      if (!mounted) return;

      setState(() {
        connected = false;
        connecting = false;
        status = 'اتصال ناموفق';
      });

      _show(
        'اتصال VPN ناموفق بود:\n$e',
      );
    }
  }

  Future<void> disconnectVpn() async {
    if (connecting && !connected) return;

    try {
      setState(() {
        connecting = true;
        status = 'در حال قطع VPN...';
      });

      await vpn.disconnect();
      await _syncVpnState();
    } catch (e) {
      debugPrint('Disconnect error: $e');

      if (mounted) {
        setState(() {
          connecting = false;
          status = 'خطا در قطع VPN';
        });

        _show(
          'خطا در قطع VPN:\n$e',
        );
      }
    }
  }
    Map<String, dynamic> buildSingboxConfig(ServerNode node) {
    return {
      'log': {
        'level': 'warn',
        'timestamp': true,
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
              'server_name': 'cloudflare-dns.com',
            },
            'detour': 'proxy',
          },
          {
            'type': 'local',
            'tag': 'dns-direct',
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
            'fdfe:dcba:9876::1/126',
          ],

          'auto_route': true,

          // Force Android's VPN/TUN routing path to handle all routed
          // traffic and help prevent traffic/DNS leaks when auto_route
          // is enabled.

          // mixed is better for normal TCP + UDP apps
          // such as Telegram and other mobile applications.
          'stack': 'mixed',

          'mtu': 1400,


          'endpoint_independent_nat': true,

        },
      ],

      'outbounds': [
        node.outbound,

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
        // Keep the upstream connection outside
        // the Android VPN/TUN loop when supported.
        'override_android_vpn': true,

        'rules': [
          {
            'action': 'sniff',
          },

          {
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {'protocol': 'dns'},
              {'port': 53},
            ],
            'action': 'hijack-dns',
          },

          {
            'ip_is_private': true,
            'outbound': 'direct',
          },
        ],

        // Everything else goes through the selected
        // VLESS / VMess / Trojan / Hysteria2 / TUIC / SS server.
        'final': 'proxy',
      },
    };
  }

  Future<void> _saveSelected() async {
    final prefs =
        await SharedPreferences.getInstance();

    if (selectedServer == null) {
      await prefs.remove('selected_server_raw');
    } else {
      await prefs.setString(
        'selected_server_raw',
        selectedServer!.raw,
      );
    }
  }

  Future<void> addSubscription() async {
    final controller = TextEditingController(
      text: urlController.text,
    );

    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text(
              'افزودن Subscription',
            ),
            content: TextField(
              controller: controller,
              autofocus: true,
              textDirection: TextDirection.ltr,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText:
                    'https://example.com/sub...',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context),
                child: const Text('لغو'),
              ),

              FilledButton(
                onPressed: () =>
                    Navigator.pop(
                  context,
                  controller.text.trim(),
                ),
                child: const Text('ذخیره'),
              ),
            ],
          ),
        );
      },
    );

    controller.dispose();

    if (value == null || value.isEmpty) {
      return;
    }

    urlController.text = value;

    await loadSubscription();
  }

  void _show(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final used = subscription.used;
    final total = subscription.total;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Light speed 🔥',
            style: TextStyle(
              fontWeight: FontWeight.w800,
            ),
          ),

          actions: [
            IconButton(
              tooltip: 'بروزرسانی',
              onPressed:
                  loading ? null : loadSubscription,
              icon: const Icon(
                Icons.refresh_rounded,
              ),
            ),
          ],
        ),

        body: RefreshIndicator(
          onRefresh: () => loadSubscription(),

          child: ListView(
            padding: const EdgeInsets.all(16),

            children: [
              _connectionCard(),

              const SizedBox(height: 14),

              _trafficCard(),

              const SizedBox(height: 14),

              _subscriptionCard(
                used,
                total,
              ),

              const SizedBox(height: 14),

              _serverCard(),

              const SizedBox(height: 14),

              _subscriptionButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectionCard() {
    final color = connected
        ? Colors.greenAccent
        : const Color(0xFF7C4DFF);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),

        child: Column(
          children: [
            Container(
              width: 92,
              height: 92,

              decoration: BoxDecoration(
                shape: BoxShape.circle,

                border: Border.all(
                  color: color,
                  width: 3,
                ),

                boxShadow: [
                  BoxShadow(
                    color:
                        color.withValues(alpha: .18),
                    blurRadius: 28,
                    spreadRadius: 2,
                  ),
                ],
              ),

              child: Icon(
                connected
                    ? Icons.shield_rounded
                    : Icons
                        .power_settings_new_rounded,

                size: 42,
                color: color,
              ),
            ),

            const SizedBox(height: 16),

            Text(
              connected ? 'متصل' : 'قطع',

              style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w900,
              ),
            ),

            const SizedBox(height: 6),

            Text(
              status,

              style: TextStyle(
                color: Colors.white.withValues(
                  alpha: .65,
                ),
              ),

              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 18),

            SizedBox(
              width: double.infinity,
              height: 54,

              child: FilledButton.icon(
                onPressed: connecting
                    ? null
                    : connected
                        ? disconnectVpn
                        : connectVpn,

                icon: Icon(
                  connected
                      ? Icons.stop_circle_outlined
                      : Icons.bolt_rounded,
                ),

                label: Text(
                  connecting
                      ? 'لطفاً صبر کن...'
                      : connected
                          ? 'قطع VPN'
                          : 'اتصال سریع',

                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trafficCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),

        child: Row(
          children: [
            Expanded(
              child: _metric(
                Icons.arrow_downward_rounded,
                'دانلود',
                downloadSpeed,
              ),
            ),

            Container(
              width: 1,
              height: 60,

              color: Colors.white.withValues(
                alpha: .08,
              ),
            ),

            Expanded(
              child: _metric(
                Icons.arrow_upward_rounded,
                'آپلود',
                uploadSpeed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(
    IconData icon,
    String title,
    String value,
  ) {
    return Column(
      children: [
        Icon(
          icon,
          color: const Color(0xFF00D4FF),
        ),

        const SizedBox(height: 6),

        Text(
          title,

          style: TextStyle(
            color: Colors.white.withValues(
              alpha: .6,
            ),
          ),
        ),

        const SizedBox(height: 3),

        Text(
          value,

          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 17,
          ),
        ),
      ],
    );
  }

  Widget _subscriptionCard(
    int? used,
    int? total,
  ) {
    final ratio =
        used != null &&
                total != null &&
                total > 0
            ? (used / total).clamp(
                0.0,
                1.0,
              )
            : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),

        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,

          children: [
            const Text(
              'حساب Subscription',

              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 14),

            if (total != null) ...[
              LinearProgressIndicator(
                value: ratio,
              ),

              const SizedBox(height: 10),

              Text(
                '${formatBytes(used ?? 0)} '
                'مصرف شده از '
                '${formatBytes(total)}',
              ),
            ] else
              const Text(
                'اطلاعات حجم از Subscription '
                'دریافت نشد',
              ),

            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: _info(
                    'آپلود',
                    formatBytes(
                      subscription.upload ??
                          uploadTotal,
                    ),
                  ),
                ),

                Expanded(
                  child: _info(
                    'دانلود',
                    formatBytes(
                      subscription.download ??
                          downloadTotal,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            _info(
              'انقضا',

              subscription.expire == null
                  ? 'نامشخص'
                  : formatExpire(
                      subscription.expire!,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _info(
    String title,
    String value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        vertical: 4,
      ),

      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,

        children: [
          Text(
            title,

            style: TextStyle(
              color:
                  Colors.white.withValues(
                alpha: .55,
              ),
              fontSize: 12,
            ),
          ),

          const SizedBox(height: 2),

          Text(
            value,

            style: const TextStyle(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _serverCard() {
    final best = fastestServer();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),

        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,

          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'سرورها',

                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),

                DropdownButton<
                    ServerSelectionMode>(
                  value: selectionMode,

                  items: const [
                    DropdownMenuItem(
                      value:
                          ServerSelectionMode.auto,
                      child: Text('خودکار'),
                    ),

                    DropdownMenuItem(
                      value:
                          ServerSelectionMode.manual,
                      child: Text('دستی'),
                    ),
                  ],

                  onChanged: (value) async {
                    if (value == null) return;

                    setState(() {
                      selectionMode = value;
                    });

                    final prefs =
                        await SharedPreferences
                            .getInstance();

                    await prefs.setString(
                      'selection_mode',
                      value ==
                              ServerSelectionMode
                                  .auto
                          ? 'auto'
                          : 'manual',
                    );
                  },
                ),
              ],
            ),

            const SizedBox(height: 10),

            if (servers.isEmpty)
              const Text(
                'هنوز سروری دریافت نشده',
              )
            else
              ...servers
                  .take(12)
                  .map(
                    (server) =>
                        _serverTile(
                      server,
                      best == server,
                    ),
                  ),

            if (servers.length > 12)
              Padding(
                padding:
                    const EdgeInsets.only(
                  top: 8,
                ),

                child: Text(
                  '${servers.length - 12} '
                  'سرور دیگر...',

                  style: TextStyle(
                    color:
                        Colors.white.withValues(
                      alpha: .5,
                    ),
                  ),
                ),
              ),

            const SizedBox(height: 12),

            OutlinedButton.icon(
              onPressed:
                  testing ? null : testAll,

              icon: const Icon(
                Icons.speed_rounded,
              ),

              label: Text(
                testing
                    ? 'در حال تست...'
                    : 'Ping همه سرورها',
              ),
            ),
          ],
        ),
      ),
    );
  }
  Widget _serverTile(ServerNode server, bool fastest) {
    final selected = selectedServer?.raw == server.raw;
    final busy = connecting && selected;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: selectionMode == ServerSelectionMode.manual && !connecting
          ? () async {
              setState(() => selectedServer = server);
              await _saveSelected();
            }
          : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF7C4DFF).withValues(alpha: .10)
              : Colors.white.withValues(alpha: .035),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? const Color(0xFF7C4DFF).withValues(alpha: .50)
                : Colors.white.withValues(alpha: .07),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fastest
                    ? Colors.amberAccent.withValues(alpha: .12)
                    : Colors.white.withValues(alpha: .06),
              ),
              child: Icon(
                fastest ? Icons.flash_on_rounded : Icons.public_rounded,
                color: fastest ? Colors.amberAccent : Colors.white70,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          server.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      if (fastest) ...[
                        const SizedBox(width: 6),
                        const Text(
                          'سریع‌ترین',
                          style: TextStyle(
                            color: Colors.amberAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${server.type} • ${server.host}:${server.port}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .45),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(
                server.pingMs == null ? '—' : '${server.pingMs} ms',
                style: TextStyle(
                  color: pingColor(server.pingMs),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _subscriptionButton() {
    return FilledButton.tonalIcon(
      onPressed: loading ? null : addSubscription,
      icon: const Icon(Icons.link_rounded),
      label: const Padding(
        padding: EdgeInsets.symmetric(vertical: 13),
        child: Text(
          'افزودن / تغییر Subscription',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

String formatSpeed(int bitsPerSecond) {
  final bytes = bitsPerSecond / 8;
  return '${formatBytes(bytes.round())}/s';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';

  const units = ['KB', 'MB', 'GB', 'TB'];
  double value = bytes / 1024;
  var index = 0;

  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }

  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[index]}';
}

String formatExpire(int timestamp) {
  var seconds = timestamp;

  if (timestamp > 100000000000) {
    seconds = timestamp ~/ 1000;
  }

  final date = DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
    isUtc: true,
  ).toLocal();

  final now = DateTime.now();
  final remaining = date.difference(now);

  if (remaining.isNegative) {
    return 'منقضی شده';
  }

  final days = remaining.inDays;
  final hours = remaining.inHours % 24;

  return '${date.year}/'
      '${date.month.toString().padLeft(2, '0')}/'
      '${date.day.toString().padLeft(2, '0')} • '
      '$days روز و $hours ساعت';
}

Color pingColor(int? ping) {
  if (ping == null) return Colors.white54;
  if (ping <= 80) return Colors.greenAccent;
  if (ping <= 150) return Colors.orangeAccent;
  return Colors.redAccent;
}
