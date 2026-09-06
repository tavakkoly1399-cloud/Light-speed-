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

  await vpn.initialize();

  runApp(const LightSpeedApp());
}

class LightSpeedApp extends StatelessWidget {
  const LightSpeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Light speed 🔥',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF07101F),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E5FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController url = TextEditingController();

  final List<Server> servers = [];

  StreamSubscription? stateSub;
  StreamSubscription? trafficSub;
  StreamSubscription? faultSub;

  Timer? timer;

  int page = 0;

  bool loading = false;
  bool testing = false;
  bool connected = false;
  bool connecting = false;

  String stateText = 'آماده اتصال';

  String download = '0 Mbps';
  String upload = '0 Mbps';

  int downloadTotalBytes = 0;
  int uploadTotalBytes = 0;

  int? totalBytes;
  int? usedBytes;
  int? uploadBytes;
  int? downloadBytes;
  int? expireAt;

  @override
  void initState() {
    super.initState();

    _listenVpn();

    timer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => loadSubscription(silent: true),
    );

    loadSaved();
  }

  // ============================================================
  // VPN EVENTS
  // ============================================================

  void _listenVpn() {
    stateSub = vpn.serviceStateStream.listen(
      (state) {
        if (!mounted) return;

        final text = state.toString();
        final low = text.toLowerCase();

        debugPrint('VPN STATE: $text');

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

          if (low.contains('starting')) {
            connecting = true;
          }

          if (low.contains('stopping')) {
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
          final down = stats.downlinkBps;
          final up = stats.uplinkBps;

          setState(() {
            download = speed(down);
            upload = speed(up);

            downloadTotalBytes = stats.downlinkTotalBytes;
            uploadTotalBytes = stats.uplinkTotalBytes;
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

        snack('خطای sing-box:\n$message');
      },
      onError: (Object error) {
        debugPrint('Fault stream error: $error');
      },
    );
  }

  // ============================================================
  // LOAD SAVED
  // ============================================================

  Future<void> loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final saved = prefs.getString('subscription_url');

      if (saved == null || saved.isEmpty) {
        return;
      }

      url.text = saved;

      await loadSubscription(silent: true);
    } catch (e) {
      debugPrint('loadSaved: $e');
    }
  }

  // ============================================================
  // SUBSCRIPTION
  // ============================================================

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final subscription = url.text.trim();

    if (subscription.isEmpty) {
      if (!silent && mounted) {
        setState(() {
          stateText = 'Subscription URL را وارد کن';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        loading = true;

        if (!silent) {
          stateText = 'در حال دریافت سرورها...';
        }
      });
    }

    try {
      final uri = Uri.parse(subscription);

      final response = await http
          .get(
            uri,
            headers: const {
              'User-Agent': 'LightSpeed/5.0',
              'Accept': '*/*',
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
            },
          )
          .timeout(
            const Duration(seconds: 60),
          );

      debugPrint(
        'SUB HTTP: ${response.statusCode}',
      );

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw Exception(
          'HTTP ${response.statusCode}',
        );
      }

      final body = utf8.decode(
        response.bodyBytes,
        allowMalformed: true,
      );

      debugPrint(
        'SUB BODY LENGTH: ${body.length}',
      );

      _readUserInfo(
        responseHeader(
          response.headers,
          'subscription-userinfo',
        ),
      );

      final result = <Server>[];

      final lines = decodeSubscription(body);

      debugPrint(
        'SUB CONFIG COUNT: ${lines.length}',
      );

      for (final line in lines) {
        final server = parseServer(line);

        if (server != null) {
          result.add(server);
        }
      }

      if (result.isEmpty) {
        throw Exception(
          'هیچ کانفیگ معتبری پیدا نشد',
        );
      }

      final prefs =
          await SharedPreferences.getInstance();

      await prefs.setString(
        'subscription_url',
        subscription,
      );

      if (!mounted) return;

      setState(() {
        servers
          ..clear()
          ..addAll(result);

        loading = false;

        stateText =
            '${servers.length} سرور دریافت شد';
      });

      await testAll(silent: true);
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
    final target = wanted.toLowerCase();

    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == target) {
        return entry.value;
      }
    }

    return null;
  }

  // ============================================================
  // USER INFO
  // ============================================================

  void _readUserInfo(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return;
    }

    final values = <String, int>{};

    for (final item in raw.split(';')) {
      final index = item.indexOf('=');

      if (index <= 0) {
        continue;
      }

      final key = item
          .substring(0, index)
          .trim()
          .toLowerCase();

      final value = int.tryParse(
        item.substring(index + 1).trim(),
      );

      if (value == null) {
        continue;
      }

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
        downloadBytes = values['download'];
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

  // ============================================================
  // SUB DECODER
  // ============================================================

  List<String> decodeSubscription(
    String body,
  ) {
    final direct = body
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where(
          (e) =>
              e.isNotEmpty &&
              e.contains('://'),
        )
        .toList();

    if (direct.isNotEmpty) {
      return direct;
    }

    try {
      var encoded = body.trim();

      encoded = encoded
          .replaceAll(RegExp(r'\s+'), '')
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      encoded += '=' *
          ((4 - encoded.length % 4) % 4);

      final decoded = utf8.decode(
        base64.decode(encoded),
        allowMalformed: true,
      );

      return decoded
          .split(RegExp(r'\r?\n'))
          .map((e) => e.trim())
          .where(
            (e) =>
                e.isNotEmpty &&
                e.contains('://'),
          )
          .toList();
    } catch (e) {
      debugPrint(
        'Subscription decode error: $e',
      );
      return [];
    }
  }

  // ============================================================
  // SERVER PARSER
  // ============================================================

  Server? parseServer(
    String raw,
  ) {
    try {
      final uri = Uri.parse(raw);

      final scheme = uri.scheme.toLowerCase();

      if (scheme == 'vmess') {
        return parseVmess(raw);
      }

      if (![
        'vless',
        'trojan',
        'ss',
        'shadowsocks',
        'hysteria2',
        'hy2',
        'tuic',
      ].contains(scheme)) {
        return null;
      }

      if (uri.host.isEmpty || !uri.hasPort) {
        return null;
      }

      final name = Uri.decodeComponent(
        uri.fragment.isEmpty
            ? '${scheme.toUpperCase()} ${uri.host}'
            : uri.fragment,
      );

      late Map<String, dynamic> outbound;

      switch (scheme) {
        case 'vless':
          outbound = vless(uri);
          break;

        case 'trojan':
          outbound = trojan(uri);
          break;

        case 'ss':
        case 'shadowsocks':
          outbound =
              shadowsocks(uri, raw) ?? {};
          break;

        case 'hysteria2':
        case 'hy2':
          outbound = hysteria2(uri);
          break;

        case 'tuic':
          outbound = tuic(uri);
          break;

        default:
          return null;
      }

      if (outbound.isEmpty) {
        return null;
      }

      return Server(
        raw: raw,
        name: name,
        type: scheme.toUpperCase(),
        host: uri.host,
        port: uri.port,
        outbound: outbound,
      );
    } catch (e) {
      debugPrint(
        'parseServer: $e',
      );
      return null;
    }
  }

  // ============================================================
  // VMESS
  // ============================================================

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

      encoded += '=' *
          ((4 - encoded.length % 4) % 4);

      final decoded = utf8.decode(
        base64.decode(encoded),
        allowMalformed: true,
      );

      final map =
          json.decode(decoded)
              as Map<String, dynamic>;

      final host = '${map['add'] ?? ''}';

      final port = int.tryParse(
            '${map['port'] ?? ''}',
          ) ??
          0;

      final uuid = '${map['id'] ?? ''}';

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
          '${map['tls'] ?? ''}'.toLowerCase();

      final sni =
          '${map['sni'] ?? map['host'] ?? ''}';

      if (tls.isNotEmpty && tls != 'none') {
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
        name: '${map['ps'] ?? 'VMess'}',
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

  // ============================================================
  // VLESS
  // ============================================================

  Map<String, dynamic> vless(
    Uri uri,
  ) {
    final p = uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uri.userInfo,
    };

    final flow = p['flow'] ?? '';

    if (flow.isNotEmpty) {
      outbound['flow'] = flow;
    }

    final security =
        (p['security'] ?? '').toLowerCase();

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

      final fp = p['fp'] ?? '';

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
          if ((p['sid'] ?? '').isNotEmpty)
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

  // ============================================================
  // TROJAN
  // ============================================================

  Map<String, dynamic> trojan(
    Uri uri,
  ) {
    final p = uri.queryParameters;

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

  // ============================================================
  // SHADOWSOCKS
  // ============================================================

  Map<String, dynamic>? shadowsocks(
    Uri uri,
    String raw,
  ) {
    try {
      var user = uri.userInfo;

      if (user.isEmpty) {
        var encoded =
            raw.substring(
              raw.indexOf('://') + 3,
            ).split('#').first;

        encoded = encoded
            .replaceAll('-', '+')
            .replaceAll('_', '/');

        encoded += '=' *
            ((4 - encoded.length % 4) % 4);

        user = utf8.decode(
          base64.decode(encoded),
          allowMalformed: true,
        );
      }

      final separator = user.indexOf(':');

      if (separator <= 0) {
        return null;
      }

      return {
        'type': 'shadowsocks',
        'tag': 'proxy',
        'server': uri.host,
        'server_port': uri.port,
        'method': Uri.decodeComponent(
          user.substring(0, separator),
        ),
        'password': Uri.decodeComponent(
          user.substring(separator + 1),
        ),
      };
    } catch (e) {
      debugPrint(
        'Shadowsocks parse error: $e',
      );
      return null;
    }
  }

  // ============================================================
  // HYSTERIA 2
  // ============================================================

  Map<String, dynamic> hysteria2(
    Uri uri,
  ) {
    final p = uri.queryParameters;

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

  // ============================================================
  // TUIC
  // ============================================================

  Map<String, dynamic> tuic(
    Uri uri,
  ) {
    final p = uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'tuic',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uri.userInfo,
      'password': p['password'] ?? '',
      'congestion_control':
          p['congestion_control'] ?? 'cubic',
      'udp_relay_mode':
          p['udp_relay_mode'] ?? 'native',
      'zero_rtt_handshake': false,
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

  // ============================================================
  // TRANSPORT
  // ============================================================

  void addTransport(
    Map<String, dynamic> outbound,
    String network,
    String path,
    String host,
  ) {
    final n = network.toLowerCase();

    if (n == 'ws' ||
        n == 'websocket') {
      outbound['transport'] = {
        'type': 'ws',
        'path': path.isEmpty ? '/' : path,
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
        'path': path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': host,
      };

      return;
    }

    if (n == 'h2' ||
        n == 'http') {
      outbound['transport'] = {
        'type': 'http',
        'path': path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': [host],
      };

      return;
    }
  }

  // ============================================================
  // ANDROID SING-BOX CONFIG
  // ============================================================

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
        'level': 'info',
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

  // ============================================================
  // TEST SERVERS
  // ============================================================

  Future<void> testAll({
    bool silent = false,
  }) async {
    if (servers.isEmpty) {
      return;
    }

    if (!silent && mounted) {
      setState(() {
        testing = true;
        stateText = 'در حال تست سرورها...';
      });
    }

    for (final server in servers) {
      final stopwatch = Stopwatch()..start();

      try {
        final socket = await Socket.connect(
          server.host,
          server.port,
          timeout:
              const Duration(seconds: 3),
        );

        socket.destroy();

        server.ping =
            stopwatch.elapsedMilliseconds;
      } catch (_) {
        server.ping = null;
      }

      if (mounted && !silent) {
        setState(() {});
      }
    }

    if (mounted) {
      setState(() {
        testing = false;

        if (!silent) {
          stateText = 'تست سرورها تمام شد';
        }
      });
    }
  }

  // ============================================================
  // FASTEST
  // ============================================================

  Server? fastest() {
    final good = servers
        .where(
          (s) => s.ping != null,
        )
        .toList();

    if (good.isEmpty) {
      return null;
    }

    good.sort(
      (a, b) => a.ping!.compareTo(
        b.ping!,
      ),
    );

    return good.first;
  }

  // ============================================================
  // CONNECT
  // ============================================================

  Future<void> connect() async {
    if (servers.isEmpty) {
      snack(
        'ابتدا Subscription را دریافت کن',
      );
      return;
    }

    if (connected || connecting) {
      return;
    }

    setState(() {
      connecting = true;
      stateText =
          'در حال آماده‌سازی VPN...';
    });

    try {
      if (servers.every(
        (s) => s.ping == null,
      )) {
        await testAll(
          silent: true,
        );
      }

      Server? selected = fastest();

      selected ??= servers.first;

      debugPrint(
        'SELECTED SERVER: '
        '${selected.name} '
        '${selected.type} '
        '${selected.host}:${selected.port}',
      );

      setState(() {
        stateText =
            'سرور: ${selected!.name}';
      });

      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'مجوز VPN داده نشد',
        );
      }

      final config =
          makeConfig(selected);

      debugPrint(
        'SINGBOX CONFIG:\n$config',
      );

      setState(() {
        stateText =
            'در حال بررسی کانفیگ...';
      });

      await vpn.checkConfig(config);

      setState(() {
        stateText =
            'در حال اتصال به سرور...';
      });

      await vpn.connect(
        SessionOptions(
          config: config,
          networkMode:
              NetworkMode.vpn,
          notification:
              NotificationConfig(
            title: 'Light speed 🔥',
            showTrafficStats: true,
            showStopButton: true,
            stopButtonLabel:
                'قطع اتصال',
          ),
        ),
      );

      if (!mounted) {
        return;
      }

      setState(() {
        connected = true;
        connecting = false;

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
        stateText = 'اتصال ناموفق';
      });

      snack(
        'خطای VPN:\n$e',
      );
    }
  }

  // ============================================================
  // DISCONNECT
  // ============================================================

  Future<void> disconnect() async {
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

      stateText = 'اتصال قطع شد';

      download = '0 Mbps';
      upload = '0 Mbps';

      downloadTotalBytes = 0;
      uploadTotalBytes = 0;
    });
  }

  // ============================================================
  // SPEED
  // ============================================================

  String speed(dynamic bps) {
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

  // ============================================================
  // SIZE
  // ============================================================

  String size(int? bytes) {
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

    if (bytes < 1024 * 1024 * 1024) {
      return
          '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    return
        '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  // ============================================================
  // DATE
  // ============================================================

  String _dateFromUnix(
    int timestamp,
  ) {
    try {
      final milliseconds =
          timestamp > 20000000000
              ? timestamp
              : timestamp * 1000;

      final date =
          DateTime.fromMillisecondsSinceEpoch(
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

  // ============================================================
  // STATE
  // ============================================================

  String _prettyState(String value) {
    final low = value.toLowerCase();

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

  // ============================================================
  // SNACK
  // ============================================================

  void snack(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(text),
        duration:
            const Duration(seconds: 4),
      ),
    );
  }

  // ============================================================
  // CARD
  // ============================================================

  Widget card(Widget child) {
    return Container(
      margin:
          const EdgeInsets.only(bottom: 12),
      padding:
          const EdgeInsets.all(16),
      decoration:
          BoxDecoration(
        color: const Color(0xFF0D1728),
        borderRadius:
            BorderRadius.circular(22),
        border: Border.all(
          color:
              Colors.white.withValues(alpha: .05),
        ),
      ),
      child: child,
    );
  }

  // ============================================================
  // HEADER
  // ============================================================

  Widget header(
    String title,
    String subtitle,
  ) {
    return Padding(
      padding:
          const EdgeInsets.only(bottom: 18),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration:
                const BoxDecoration(
              shape: BoxShape.circle,
              gradient:
                  LinearGradient(
                colors: [
                  Color(0xFF00E5FF),
                  Color(0xFF7C4DFF),
                ],
              ),
            ),
            child: const Icon(
              Icons.bolt,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style:
                    const TextStyle(
                  fontSize: 22,
                  fontWeight:
                      FontWeight.w800,
                ),
              ),
              Text(
                subtitle,
                style:
                    const TextStyle(
                  color: Colors.white54,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ============================================================
  // BUILD
  // ============================================================

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
          selectedIndex: page,
          onDestinationSelected:
              (index) {
            setState(() {
              page = index;
            });
          },
          destinations:
              const [
            NavigationDestination(
              icon: Icon(
                Icons.home_outlined,
              ),
              selectedIcon:
                  Icon(Icons.home),
              label: 'خانه',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.dns_outlined,
              ),
              selectedIcon:
                  Icon(Icons.dns),
              label: 'سرورها',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.bar_chart_outlined,
              ),
              selectedIcon:
                  Icon(Icons.bar_chart),
              label: 'ترافیک',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.link_outlined,
              ),
              selectedIcon:
                  Icon(Icons.link),
              label: 'اشتراک',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.settings_outlined,
              ),
              selectedIcon:
                  Icon(Icons.settings),
              label: 'تنظیمات',
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // HOME
  // ============================================================

  Widget _home() {
    final best = fastest();

    final percent =
        totalBytes == null ||
                totalBytes! <= 0
            ? 0.0
            : ((usedBytes ?? 0) /
                    totalBytes!)
                .clamp(0.0, 1.0);

    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        header(
          'Light speed 🔥',
          'VPN واقعی با sing-box',
        ),

        const SizedBox(height: 8),

        Center(
          child: GestureDetector(
            onTap: connecting
                ? null
                : connected
                    ? disconnect
                    : connect,
            child: Container(
              width: 200,
              height: 200,
              decoration:
                  BoxDecoration(
                shape: BoxShape.circle,
                gradient:
                    LinearGradient(
                  colors: connected
                      ? const [
                          Color(
                            0xFF00E676,
                          ),
                          Color(
                            0xFF00B8D4,
                          ),
                        ]
                      : const [
                          Color(
                            0xFF00E5FF,
                          ),
                          Color(
                            0xFF7C4DFF,
                          ),
                        ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: (
                      connected
                          ? const Color(
                              0xFF00E676,
                            )
                          : const Color(
                              0xFF00E5FF,
                            )
                    ).withValues(alpha: .35),
                    blurRadius: 40,
                    spreadRadius: 8,
                  ),
                ],
              ),
              child: Center(
                child: Container(
                  width: 176,
                  height: 176,
                  decoration:
                      const BoxDecoration(
                    shape:
                        BoxShape.circle,
                    color:
                        Color(0xFF081322),
                  ),
                  child: Center(
                    child: connecting
                        ? const CircularProgressIndicator()
                        : Column(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .center,
                            children: [
                              Icon(
                                connected
                                    ? Icons.power
                                    : Icons.bolt,
                                size: 48,
                                color: connected
                                    ? const Color(
                                        0xFF00E676,
                                      )
                                    : const Color(
                                        0xFF00E5FF,
                                      ),
                              ),
                              const SizedBox(
                                height: 8,
                              ),
                              Text(
                                connected
                                    ? 'قطع اتصال'
                                    : 'اتصال',
                                style:
                                    const TextStyle(
                                  fontSize: 18,
                                  fontWeight:
                                      FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),

        Center(
          child: Text(
            stateText,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: connected
                  ? const Color(
                      0xFF00E676,
                    )
                  : Colors.white70,
            ),
          ),
        ),

        const SizedBox(height: 20),

        card(
          Row(
            children: [
              const Icon(
                Icons.public,
                color: Color(0xFF00E5FF),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'سرور انتخاب‌شده',
                      style: TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                    Text(
                      best?.name ??
                          'هنوز انتخاب نشده',
                      maxLines: 1,
                      overflow:
                          TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (best?.ping != null)
                Text(
                  '${best!.ping} ms',
                ),
            ],
          ),
        ),

        Row(
          children: [
            Expanded(
              child: card(
                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.download,
                          size: 18,
                          color:
                              Color(
                            0xFF00E5FF,
                          ),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'دانلود',
                          style:
                              TextStyle(
                            color:
                                Colors.white54,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      download,
                      style:
                          const TextStyle(
                        fontSize: 18,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: card(
                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.upload,
                          size: 18,
                          color:
                              Color(
                            0xFF7C4DFF,
                          ),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'آپلود',
                          style:
                              TextStyle(
                            color:
                                Colors.white54,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      upload,
                      style:
                          const TextStyle(
                        fontSize: 18,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ],
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
              Row(
                children: [
                  const Icon(
                    Icons.data_usage,
                    color: Color(0xFF7C4DFF),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'حجم اشتراک',
                    ),
                  ),
                  Text(
                    size(totalBytes),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: percent,
                minHeight: 9,
              ),
              const SizedBox(height: 10),
              Text(
                'مصرف: ${size(usedBytes)}',
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ============================================================
  // SERVERS
  // ============================================================

  Widget _servers() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        header(
          'سرورها',
          '${servers.length} سرور',
        ),

        FilledButton.icon(
          onPressed:
              testing ? null : () => testAll(),
          icon: const Icon(Icons.speed),
          label: Text(
            testing
                ? 'در حال تست...'
                : 'تست Ping',
          ),
        ),

        const SizedBox(height: 14),

        if (servers.isEmpty)
          card(
            const Center(
              child: Padding(
                padding:
                    EdgeInsets.all(20),
                child: Text(
                  'هنوز سروری دریافت نشده است',
                ),
              ),
            ),
          ),

        ...servers
            .asMap()
            .entries
            .map(
          (entry) {
            final server = entry.value;

            return card(
              ListTile(
                contentPadding:
                    EdgeInsets.zero,
                leading: CircleAvatar(
                  child: Text(
                    '${entry.key + 1}',
                  ),
                ),
                title: Text(
                  server.name,
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${server.type} • '
                  '${server.host}:'
                  '${server.port}',
                ),
                trailing: Text(
                  server.ping == null
                      ? '---'
                      : '${server.ping} ms',
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // ============================================================
  // TRAFFIC
  // ============================================================

  Widget _traffic() {
    final remaining =
        totalBytes == null
            ? null
            : max(
                0,
                totalBytes! -
                    (usedBytes ?? 0),
              );

    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        header(
          'ترافیک',
          'آمار زنده VPN',
        ),

        card(
          ListTile(
            title:
                const Text(
              'سرعت دانلود',
            ),
            subtitle: Text(
              download,
              style:
                  const TextStyle(
                fontSize: 20,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            leading:
                const Icon(
              Icons.download,
              color:
                  Color(0xFF00E5FF),
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'سرعت آپلود',
            ),
            subtitle: Text(
              upload,
              style:
                  const TextStyle(
                fontSize: 20,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            leading:
                const Icon(
              Icons.upload,
              color:
                  Color(0xFF7C4DFF),
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'دانلود این جلسه',
            ),
            subtitle: Text(
              size(
                downloadTotalBytes,
              ),
            ),
            leading:
                const Icon(
              Icons.download_done,
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'آپلود این جلسه',
            ),
            subtitle: Text(
              size(
                uploadTotalBytes,
              ),
            ),
            leading:
                const Icon(
              Icons.upload,
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'حجم مصرف‌شده اشتراک',
            ),
            subtitle: Text(
              size(usedBytes),
            ),
            leading:
                const Icon(
              Icons.data_usage,
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'حجم باقی‌مانده',
            ),
            subtitle: Text(
              size(remaining),
            ),
            leading:
                const Icon(
              Icons.storage,
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'تاریخ انقضا',
            ),
            subtitle:
                Text(
              expireAt == null
                  ? 'نامشخص'
                  : _dateFromUnix(
                      expireAt!,
                    ),
            ),
            leading:
                const Icon(
              Icons.event,
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // SUBSCRIPTION PAGE
  // ============================================================

  Widget _subscription() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        header(
          'Subscription',
          'مدیریت اشتراک',
        ),

        TextField(
          controller: url,
          textDirection:
              TextDirection.ltr,
          decoration:
              const InputDecoration(
            labelText:
                'Subscription URL',
            prefixIcon:
                Icon(Icons.link),
            border:
                OutlineInputBorder(),
          ),
        ),

        const SizedBox(height: 12),

        FilledButton.icon(
          onPressed:
              loading
                  ? null
                  : () =>
                      loadSubscription(),
          icon:
              const Icon(Icons.refresh),
          label:
              Text(
            loading
                ? 'در حال دریافت...'
                : 'دریافت / بروزرسانی',
          ),
        ),

        const SizedBox(height: 18),

        card(
          const ListTile(
            leading:
                Icon(Icons.sync),
            title:
                Text(
              'بروزرسانی خودکار',
            ),
            subtitle:
                Text(
              'هر ۱۵ دقیقه',
            ),
          ),
        ),

        card(
          ListTile(
            leading:
                const Icon(Icons.dns),
            title:
                const Text('سرورها'),
            subtitle:
                Text(
              '${servers.length} سرور',
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // SETTINGS
  // ============================================================

  Widget _settings() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        header(
          'تنظیمات',
          'Light speed',
        ),

        card(
          const ListTile(
            leading:
                Icon(Icons.flash_on),
            title:
                Text(
              'انتخاب سریع‌ترین سرور',
            ),
            subtitle:
                Text(
              'بر اساس TCP Connect',
            ),
          ),
        ),

        card(
          const ListTile(
            leading:
                Icon(Icons.shield),
            title:
                Text(
              'VPN Engine',
            ),
            subtitle:
                Text(
              'sing-box / Android VpnService',
            ),
          ),
        ),

        card(
          ListTile(
            leading:
                const Icon(Icons.route),
            title:
                const Text(
              'Traffic Mode',
            ),
            subtitle:
                Text(
              connected
                  ? 'Full Device VPN فعال است'
                  : 'Full Device VPN',
            ),
          ),
        ),

        card(
          const ListTile(
            leading:
                Icon(Icons.dns),
            title:
                Text('DNS'),
            subtitle:
                Text(
              'DNS Hijack + DNS over HTTPS',
            ),
          ),
        ),

        card(
          ListTile(
            leading: Icon(
              connected
                  ? Icons.check_circle
                  : Icons.info_outline,
              color:
                  connected
                      ? Colors.green
                      : Colors.white54,
            ),
            title:
                const Text('وضعیت'),
            subtitle:
                Text(stateText),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    stateSub?.cancel();
    trafficSub?.cancel();
    faultSub?.cancel();
    timer?.cancel();
    url.dispose();

    super.dispose();
  }
}
