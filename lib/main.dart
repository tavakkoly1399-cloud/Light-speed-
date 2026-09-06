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
  } catch (_) {}

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
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0D1728),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
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

  Timer? refreshTimer;
  Timer? durationTimer;

  int page = 0;

  bool loading = false;
  bool testing = false;
  bool connecting = false;
  bool connected = false;
  bool speedTesting = false;

  String stateText = 'آماده اتصال';

  double downloadBps = 0;
  double uploadBps = 0;

  int downloadTotalBytes = 0;
  int uploadTotalBytes = 0;

  int? totalBytes;
  int? usedBytes;
  int? expireAt;

  DateTime? connectedAt;
  Duration connectionDuration = Duration.zero;

  double speedTestDownload = 0;
  double speedTestUpload = 0;

  final List<double> downloadHistory = [];
  final List<double> uploadHistory = [];

  @override
  void initState() {
    super.initState();

    _listenVpnState();
    _listenTraffic();

    refreshTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) {
        if (!connected) {
          loadSubscription(silent: true);
        }
      },
    );

    loadSaved();
  }

  void _listenVpnState() {
    stateSub = vpn.serviceStateStream.listen((s) {
      if (!mounted) return;

      final text = s.toString();
      final low = text.toLowerCase();

      if (low.contains('running') || low.contains('connected')) {
        if (!connected) {
          setState(() {
            connected = true;
            stateText = 'متصل';
            connectedAt ??= DateTime.now();
          });

          _startDurationTimer();
        }
      }

      if (low.contains('stopped') ||
          low.contains('disconnected') ||
          low.contains('idle')) {
        if (connected) {
          setState(() {
            connected = false;
            stateText = 'قطع شد';
          });
        }

        durationTimer?.cancel();
      }
    });
  }

  void _listenTraffic() {
    trafficSub = vpn.trafficStatsStream.listen((stats) {
      if (!mounted) return;

      try {
        final dynamic s = stats;

        final dynamic down = s.downlinkBps;
        final dynamic up = s.uplinkBps;
        final dynamic downTotal = s.downlinkTotalBytes;
        final dynamic upTotal = s.uplinkTotalBytes;

        final double d =
            down is num ? down.toDouble() : 0.0;

        final double u =
            up is num ? up.toDouble() : 0.0;

        final int dt =
            downTotal is num ? downTotal.toInt() : downloadTotalBytes;

        final int ut =
            upTotal is num ? upTotal.toInt() : uploadTotalBytes;

        setState(() {
          downloadBps = max(0, d);
          uploadBps = max(0, u);

          downloadTotalBytes = max(0, dt);
          uploadTotalBytes = max(0, ut);

          _pushHistory(downloadHistory, downloadBps);
          _pushHistory(uploadHistory, uploadBps);
        });
      } catch (_) {}
    });
  }

  void _pushHistory(List<double> list, double value) {
    list.add(value);

    if (list.length > 30) {
      list.removeAt(0);
    }
  }

  Future<void> loadSaved() async {
    final prefs = await SharedPreferences.getInstance();

    final saved = prefs.getString('subscription_url');

    if (saved == null || saved.isEmpty) {
      return;
    }

    url.text = saved;

    await loadSubscription(silent: true);
  }

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final address = url.text.trim();

    if (address.isEmpty) {
      if (!silent && mounted) {
        setState(() {
          stateText = 'Subscription URL را وارد کن';
        });
      }
      return;
    }

    if (!silent && mounted) {
      setState(() {
        loading = true;
        stateText = 'در حال دریافت Subscription...';
      });
    } else {
      loading = true;
    }

    try {
      final response = await http.get(
        Uri.parse(address),
        headers: const {
          'User-Agent': 'LightSpeed/3.0',
          'Accept': '*/*',
        },
      ).timeout(
        const Duration(seconds: 20),
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

      _readUserInfo(
        response.headers['subscription-userinfo'],
      );

      final List<Server> result = [];

      for (final line in decodeSubscription(body)) {
        final server = parseServer(line);

        if (server != null) {
          result.add(server);
        }
      }

      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(
        'subscription_url',
        address,
      );

      if (!mounted) return;

      setState(() {
        servers
          ..clear()
          ..addAll(result);

        loading = false;

        stateText = result.isEmpty
            ? 'هیچ سروری پیدا نشد'
            : '${result.length} سرور دریافت شد';
      });

      if (result.isNotEmpty) {
        await testAll(silent: true);
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        stateText = 'خطا در دریافت Subscription';
      });

      if (!silent) {
        snack(
          'دریافت Subscription ناموفق بود',
        );
      }
    }
  }

  void _readUserInfo(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return;
    }

    final values = <String, int>{};

    for (final item in raw.split(';')) {
      final parts = item.trim().split('=');

      if (parts.length == 2) {
        final value = int.tryParse(parts[1]);

        if (value != null) {
          values[parts[0]] = value;
        }
      }
    }

    final upload = values['upload'] ?? 0;
    final download = values['download'] ?? 0;

    if (!mounted) return;

    setState(() {
      totalBytes = values['total'];
      usedBytes = upload + download;
      expireAt = values['expire'];
    });
  }

  List<String> decodeSubscription(String body) {
    final direct = body
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.contains('://'))
        .toList();

    if (direct.isNotEmpty) {
      return direct;
    }

    try {
      var encoded = body.trim();

      encoded = encoded.replaceAll(
        RegExp(r'\s+'),
        '',
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

      return decoded
          .split(RegExp(r'\r?\n'))
          .map((e) => e.trim())
          .where((e) => e.contains('://'))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Server? parseServer(String raw) {
    try {
      final uri = Uri.parse(raw);

      final scheme = uri.scheme.toLowerCase();

      if (scheme == 'vmess') {
        return parseVmess(raw);
      }

      const supported = [
        'vless',
        'trojan',
        'ss',
        'hysteria2',
        'hy2',
      ];

      if (!supported.contains(scheme)) {
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

      if (scheme == 'vless') {
        outbound = vless(uri);
      } else if (scheme == 'trojan') {
        outbound = trojan(uri);
      } else if (scheme == 'ss') {
        outbound = shadowsocks(uri, raw) ?? {};
      } else {
        outbound = hysteria2(uri);
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
    } catch (_) {
      return null;
    }
  }

  Server? parseVmess(String raw) {
    try {
      var encoded = raw.substring(
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
          json.decode(decoded) as Map<String, dynamic>;

      final host = '${map['add'] ?? ''}';

      final port =
          int.tryParse('${map['port'] ?? ''}') ?? 0;

      final uuid = '${map['id'] ?? ''}';

      if (host.isEmpty ||
          port <= 0 ||
          uuid.isEmpty) {
        return null;
      }

      final outbound = <String, dynamic>{
        'type': 'vmess',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'uuid': uuid,
        'security': '${map['scy'] ?? 'auto'}',
      };

      final tlsValue = '${map['tls'] ?? ''}';

      final sni =
          '${map['sni'] ?? map['host'] ?? ''}';

      if (tlsValue.isNotEmpty &&
          tlsValue != 'none') {
        outbound['tls'] = {
          'enabled': true,
          if (sni.isNotEmpty) 'server_name': sni,
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
        name: map['ps'] ?? 'VMess',
        type: 'VMESS',
        host: host,
        port: port,
        outbound: outbound,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> vless(Uri uri) {
    final params = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uri.userInfo,
    };

    final flow = params['flow'] ?? '';

    if (flow.isNotEmpty) {
      outbound['flow'] = flow;
    }

    final security =
        (params['security'] ?? '').toLowerCase();

    if (security == 'tls' ||
        security == 'reality') {
      final tls = <String, dynamic>{
        'enabled': true,
        'server_name':
            params['sni'] ??
            params['host'] ??
            uri.host,
      };

      final fingerprint = params['fp'] ?? '';

      if (fingerprint.isNotEmpty) {
        tls['utls'] = {
          'enabled': true,
          'fingerprint': fingerprint,
        };
      }

      if (security == 'reality') {
        final publicKey = params['pbk'] ?? '';

        if (publicKey.isNotEmpty) {
          tls['reality'] = {
            'enabled': true,
            'public_key': publicKey,
            if ((params['sid'] ?? '').isNotEmpty)
              'short_id': params['sid'],
          };
        }
      }

      outbound['tls'] = tls;
    }

    addTransport(
      outbound,
      params['type'] ??
          params['network'] ??
          'tcp',
      params['path'] ?? '',
      params['host'] ?? '',
    );

    return outbound;
  }

  Map<String, dynamic> trojan(Uri uri) {
    final params = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'password': uri.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            params['sni'] ??
            params['host'] ??
            uri.host,
      },
    };

    addTransport(
      outbound,
      params['type'] ?? 'tcp',
      params['path'] ?? '',
      params['host'] ?? '',
    );

    return outbound;
  }

  Map<String, dynamic>? shadowsocks(
    Uri uri,
    String raw,
  ) {
    try {
      var user = uri.userInfo;

      if (user.isEmpty) {
        var encoded = raw.substring(
          raw.indexOf('://') + 3,
        );

        encoded = encoded
            .split('#')
            .first
            .replaceAll('-', '+')
            .replaceAll('_', '/');

        encoded += '=' *
            ((4 - encoded.length % 4) % 4);

        user = utf8.decode(
          base64.decode(encoded),
          allowMalformed: true,
        );
      }

      final colon = user.indexOf(':');

      if (colon <= 0) {
        return null;
      }

      return {
        'type': 'shadowsocks',
        'tag': 'proxy',
        'server': uri.host,
        'server_port': uri.port,
        'method': Uri.decodeComponent(
          user.substring(0, colon),
        ),
        'password': Uri.decodeComponent(
          user.substring(colon + 1),
        ),
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> hysteria2(Uri uri) {
    final params = uri.queryParameters;

    return {
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'password': uri.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            params['sni'] ??
            params['peer'] ??
            uri.host,
        if (params['insecure'] == '1')
          'insecure': true,
      },
    };
  }

  void addTransport(
    Map<String, dynamic> outbound,
    String network,
    String path,
    String host,
  ) {
    final type = network.toLowerCase();

    if (type == 'ws' ||
        type == 'websocket') {
      outbound['transport'] = {
        'type': 'ws',
        'path': path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'headers': {
            'Host': host,
          },
      };
    } else if (type == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        'service_name': path,
      };
    } else if (type == 'httpupgrade') {
      outbound['transport'] = {
        'type': 'httpupgrade',
        'path': path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': host,
      };
    } else if (type == 'h2' ||
        type == 'http') {
      outbound['transport'] = {
        'type': 'http',
        'path': path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': [host],
      };
    }
  }

  String makeConfig(Server server) {
    final outbound =
        Map<String, dynamic>.from(
      server.outbound,
    );

    outbound['tag'] = 'proxy';

    return jsonEncode({
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
        ],
        'final': 'dns-remote',
      },

      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': [
            '172.19.0.1/30',
          ],
          'auto_route': true,
          'stack': 'mixed',
          'mtu': 1500,
        },
      ],

      'outbounds': [
        outbound,
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
        'auto_detect_interface': true,
        'override_android_vpn': true,
        'rules': [
          {
            'protocol': 'dns',
            'action': 'hijack-dns',
          },
        ],
        'final': 'proxy',
      },
    });
  }

  Future<void> testAll({
    bool silent = false,
  }) async {
    if (servers.isEmpty) {
      return;
    }

    if (!silent && mounted) {
      setState(() {
        testing = true;
        stateText = 'در حال تست Ping سرورها...';
      });
    }

    for (final server in servers) {
      final stopwatch = Stopwatch()..start();

      try {
        final socket = await Socket.connect(
          server.host,
          server.port,
          timeout: const Duration(
            seconds: 3,
          ),
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

    servers.sort((a, b) {
      if (a.ping == null &&
          b.ping == null) {
        return 0;
      }

      if (a.ping == null) {
        return 1;
      }

      if (b.ping == null) {
        return -1;
      }

      return a.ping!.compareTo(
        b.ping!,
      );
    });

    if (mounted && !silent) {
      setState(() {
        testing = false;
        stateText = 'Ping سرورها تست شد';
      });
    }
  }

  Server? fastest() {
    final good = servers
        .where(
          (server) => server.ping != null,
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

  Future<void> connect() async {
    if (servers.isEmpty) {
      snack(
        'ابتدا Subscription را دریافت کن',
      );
      return;
    }

    if (mounted) {
      setState(() {
        connecting = true;
        stateText =
            'در حال انتخاب سریع‌ترین سرور...';
      });
    }

    if (servers.every(
      (server) => server.ping == null,
    )) {
      await testAll(silent: true);
    }

    final best = fastest();

    if (best == null) {
      if (mounted) {
        setState(() {
          connecting = false;
          stateText =
              'سرور قابل اتصال پیدا نشد';
        });
      }

      return;
    }

    try {
      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'VPN permission denied',
        );
      }

      final config = makeConfig(best);

      await vpn.checkConfig(config);

      await vpn.connect(
        SessionOptions(
          config: config,
          networkMode: NetworkMode.vpn,
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

      if (!mounted) return;

      setState(() {
        connecting = false;
        connected = true;
        connectedAt = DateTime.now();

        downloadBps = 0;
        uploadBps = 0;

        downloadTotalBytes = 0;
        uploadTotalBytes = 0;

        downloadHistory.clear();
        uploadHistory.clear();

        stateText =
            'متصل • ${best.name}';
      });

      _startDurationTimer();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        connecting = false;
        connected = false;
        stateText = 'اتصال ناموفق';
      });

      snack(
        'خطای VPN: $e',
      );
    }
  }

  Future<void> disconnect() async {
    try {
      await vpn.disconnect();
    } catch (_) {}

    durationTimer?.cancel();

    if (!mounted) return;

    setState(() {
      connected = false;
      connecting = false;

      stateText = 'اتصال قطع شد';

      downloadBps = 0;
      uploadBps = 0;

      downloadTotalBytes = 0;
      uploadTotalBytes = 0;

      connectionDuration =
          Duration.zero;

      connectedAt = null;

      downloadHistory.clear();
      uploadHistory.clear();
    });
  }

  void _startDurationTimer() {
    durationTimer?.cancel();

    durationTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted ||
            connectedAt == null) {
          return;
        }

        setState(() {
          connectionDuration =
              DateTime.now()
                  .difference(
                    connectedAt!,
                  );
        });
      },
    );
  }

  Future<void> runSpeedTest() async {
    if (!connected) {
      snack(
        'ابتدا VPN را وصل کن',
      );
      return;
    }

    if (speedTesting) {
      return;
    }

    setState(() {
      speedTesting = true;
      speedTestDownload = 0;
      speedTestUpload = 0;
      stateText =
          'در حال تست سرعت دانلود...';
    });

    try {
      final download =
          await _downloadSpeedTest();

      if (!mounted) return;

      setState(() {
        speedTestDownload = download;
        stateText =
            'در حال تست سرعت آپلود...';
      });

      final upload =
          await _uploadSpeedTest();

      if (!mounted) return;

      setState(() {
        speedTestUpload = upload;
        speedTesting = false;
        stateText =
            'تست سرعت کامل شد';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        speedTesting = false;
        stateText =
            'تست سرعت ناموفق بود';
      });

      snack(
        'تست سرعت انجام نشد',
      );
    }
  }

  Future<double> _downloadSpeedTest() async {
    final client = http.Client();

    try {
      final uri = Uri.parse(
        'https://speed.cloudflare.com/__down?bytes=8000000',
      );

      final request =
          http.Request(
        'GET',
        uri,
      );

      final stopwatch =
          Stopwatch()..start();

      final response =
          await client.send(request);

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw Exception(
          'Download test failed',
        );
      }

      int bytes = 0;

      await for (final chunk
          in response.stream) {
        bytes += chunk.length;

        if (stopwatch.elapsedMilliseconds >=
            5000) {
          break;
        }
      }

      stopwatch.stop();

      final seconds =
          max(
            stopwatch.elapsedMilliseconds /
                1000,
            0.001,
          );

      return (bytes * 8) / seconds;
    } finally {
      client.close();
    }
  }

  Future<double> _uploadSpeedTest() async {
    final client = http.Client();

    try {
      final uri = Uri.parse(
        'https://speed.cloudflare.com/__up',
      );

      final payload =
          List<int>.generate(
        2000000,
        (_) => Random().nextInt(256),
      );

      final stopwatch =
          Stopwatch()..start();

      final response =
          await client.post(
        uri,
        body: payload,
        headers: const {
          'Content-Type':
              'application/octet-stream',
        },
      );

      stopwatch.stop();

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw Exception(
          'Upload test failed',
        );
      }

      final seconds =
          max(
            stopwatch.elapsedMilliseconds /
                1000,
            0.001,
          );

      return (payload.length * 8) /
          seconds;
    } finally {
      client.close();
    }
  }

  String formatSpeed(double bps) {
    if (bps <= 0) {
      return '0 Mbps';
    }

    if (bps >= 1000000000) {
      return
          '${(bps / 1000000000).toStringAsFixed(2)} Gbps';
    }

    if (bps >= 1000000) {
      return
          '${(bps / 1000000).toStringAsFixed(2)} Mbps';
    }

    if (bps >= 1000) {
      return
          '${(bps / 1000).toStringAsFixed(1)} Kbps';
    }

    return
        '${bps.toStringAsFixed(0)} bps';
  }

  String formatBytes(
    int? bytes, {
    String unknown = 'نامشخص',
  }) {
    if (bytes == null ||
        bytes <= 0) {
      return unknown;
    }

    if (bytes < 1024) {
      return '$bytes B';
    }

    if (bytes < 1024 * 1024) {
      return
          '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    if (bytes < 1024 * 1024 * 1024) {
      return
          '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    if (bytes <
        1024 *
            1024 *
            1024 *
            1024) {
      return
          '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }

    return
        '${(bytes / 1024 / 1024 / 1024 / 1024).toStringAsFixed(2)} TB';
  }

  String formatDuration(
    Duration duration,
  ) {
    final hours =
        duration.inHours
            .toString()
            .padLeft(2, '0');

    final minutes =
        (duration.inMinutes % 60)
            .toString()
            .padLeft(2, '0');

    final seconds =
        (duration.inSeconds % 60)
            .toString()
            .padLeft(2, '0');

    return '$hours:$minutes:$seconds';
  }

  String expiryText() {
    if (expireAt == null ||
        expireAt! <= 0) {
      return 'نامشخص';
    }

    final date =
        DateTime.fromMillisecondsSinceEpoch(
      expireAt! * 1000,
    );

    final remaining =
        date.difference(DateTime.now());

    if (remaining.isNegative) {
      return 'منقضی شده';
    }

    final days =
        remaining.inDays;

    final hours =
        remaining.inHours % 24;

    return '$days روز و $hours ساعت';
  }

  String expiryDateText() {
    if (expireAt == null ||
        expireAt! <= 0) {
      return 'نامشخص';
    }

    final date =
        DateTime.fromMillisecondsSinceEpoch(
      expireAt! * 1000,
    );

    return
        '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
  }

  int remainingBytes() {
    if (totalBytes == null) {
      return 0;
    }

    return max(
      0,
      totalBytes! -
          (usedBytes ?? 0),
    );
  }

  double usagePercent() {
    if (totalBytes == null ||
        totalBytes! <= 0) {
      return 0;
    }

    return (
      (usedBytes ?? 0) /
      totalBytes!
    ).clamp(0.0, 1.0);
  }

  void snack(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior:
            SnackBarBehavior.floating,
      ),
    );
  }

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
          onDestinationSelected: (index) {
            setState(() {
              page = index;
            });
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(
                Icons.home_outlined,
              ),
              selectedIcon: Icon(
                Icons.home,
              ),
              label: 'خانه',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.dns_outlined,
              ),
              selectedIcon: Icon(
                Icons.dns,
              ),
              label: 'سرورها',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.bar_chart_outlined,
              ),
              selectedIcon: Icon(
                Icons.bar_chart,
              ),
              label: 'ترافیک',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.link_outlined,
              ),
              selectedIcon: Icon(
                Icons.link,
              ),
              label: 'اشتراک',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.settings_outlined,
              ),
              selectedIcon: Icon(
                Icons.settings,
              ),
              label: 'تنظیمات',
            ),
          ],
        ),
      ),
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
              const SizedBox(height: 3),
              Text(
                subtitle,
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget card(Widget child) {
    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 12,
      ),
      padding:
          const EdgeInsets.all(16),
      decoration:
          BoxDecoration(
        color:
            const Color(0xFF0D1728),
        borderRadius:
            BorderRadius.circular(22),
        border: Border.all(
          color: Colors.white
              .withValues(alpha: .05),
        ),
      ),
      child: child,
    );
  }

  Widget statCard({
    required IconData icon,
    required String title,
    required String value,
    String? subtitle,
  }) {
    return card(
      Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration:
                BoxDecoration(
              color: const Color(
                0xFF00E5FF,
              ).withValues(
                alpha: .10,
              ),
              borderRadius:
                  BorderRadius.circular(
                14,
              ),
            ),
            child: Icon(
              icon,
              color:
                  const Color(
                0xFF00E5FF,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment
                      .start,
              children: [
                Text(
                  title,
                  style:
                      const TextStyle(
                    color:
                        Colors.white54,
                  ),
                ),
                const SizedBox(
                  height: 3,
                ),
                Text(
                  value,
                  style:
                      const TextStyle(
                    fontSize: 19,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style:
                        const TextStyle(
                      color:
                          Colors.white38,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _home() {
    final best = fastest();

    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        header(
          'Light speed 🔥',
          'VPN Client • sing-box',
        ),

        _connectionButton(),

        const SizedBox(height: 14),

        Center(
          child: Text(
            stateText,
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

        const SizedBox(height: 18),

        if (best != null)
          card(
            Row(
              children: [
                const Icon(
                  Icons.public,
                  color:
                      Color(0xFF00E5FF),
                ),
                const SizedBox(
                  width: 12,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment
                            .start,
                    children: [
                      const Text(
                        'سرور انتخاب‌شده',
                        style:
                            TextStyle(
                          color:
                              Colors.white54,
                        ),
                      ),
                      const SizedBox(
                        height: 3,
                      ),
                      Text(
                        best.name,
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
                    ],
                  ),
                ),
                if (best.ping != null)
                  Text(
                    '${best.ping} ms',
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),

        Row(
          children: [
            Expanded(
              child: statCard(
                icon:
                    Icons.download,
                title: 'دانلود زنده',
                value:
                    formatSpeed(
                  downloadBps,
                ),
                subtitle:
                    'سرعت لحظه‌ای',
              ),
            ),
            const SizedBox(
              width: 10,
            ),
            Expanded(
              child: statCard(
                icon: Icons.upload,
                title: 'آپلود زنده',
                value:
                    formatSpeed(
                  uploadBps,
                ),
                subtitle:
                    'سرعت لحظه‌ای',
              ),
            ),
          ],
        ),

        card(
          Column(
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.timer,
                    color:
                        Color(0xFF7C4DFF),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  const Expanded(
                    child: Text(
                      'مدت اتصال',
                    ),
                  ),
                  Text(
                    formatDuration(
                      connectionDuration,
                    ),
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const Divider(
                height: 24,
              ),
              Row(
                children: [
                  const Icon(
                    Icons.download_done,
                    color:
                        Color(0xFF00E5FF),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  const Expanded(
                    child: Text(
                      'دریافت این جلسه',
                    ),
                  ),
                  Text(
                    formatBytes(
                      downloadTotalBytes,
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 10,
              ),
              Row(
                children: [
                  const Icon(
                    Icons.upload_file,
                    color:
                        Color(0xFF00E676),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  const Expanded(
                    child: Text(
                      'ارسال این جلسه',
                    ),
                  ),
                  Text(
                    formatBytes(
                      uploadTotalBytes,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.data_usage,
                    color:
                        Color(0xFF7C4DFF),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'اشتراک',
                    style:
                        TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 14,
              ),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment
                        .spaceBetween,
                children: [
                  Text(
                    'کل: ${formatBytes(totalBytes)}',
                  ),
                  Text(
                    'باقی‌مانده: ${formatBytes(remainingBytes())}',
                  ),
                ],
              ),
              const SizedBox(
                height: 10,
              ),
              LinearProgressIndicator(
                value: usagePercent(),
                minHeight: 9,
                borderRadius:
                    BorderRadius.circular(
                  20,
                ),
              ),
              const SizedBox(
                height: 10,
              ),
              Text(
                'مصرف: ${formatBytes(usedBytes)}',
                style:
                    const TextStyle(
                  color:
                      Colors.white60,
                ),
              ),
            ],
          ),
        ),

        card(
          Row(
            children: [
              const Icon(
                Icons.event,
                color:
                    Color(0xFFFFC107),
              ),
              const SizedBox(
                width: 10,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    const Text(
                      'انقضا',
                      style:
                          TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                    Text(
                      expiryDateText(),
                      style:
                          const TextStyle(
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                expiryText(),
                style:
                    const TextStyle(
                  color:
                      Colors.white70,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(
          height: 8,
        ),

        OutlinedButton.icon(
          onPressed:
              speedTesting ||
                      !connected
                  ? null
                  : runSpeedTest,
          icon: speedTesting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child:
                      CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                )
              : const Icon(
                  Icons.speed,
                ),
          label: Text(
            speedTesting
                ? 'در حال تست سرعت...'
                : 'تست واقعی سرعت',
          ),
        ),
      ],
    );
  }

  Widget _connectionButton() {
    final glowColor = connected
        ? const Color(0xFF00E676)
        : const Color(0xFF00E5FF);

    return Center(
      child: GestureDetector(
        onTap: connecting
            ? null
            : connected
                ? disconnect
                : connect,
        child: AnimatedContainer(
          duration:
              const Duration(
            milliseconds: 300,
          ),
          width: 210,
          height: 210,
          decoration:
              BoxDecoration(
            shape: BoxShape.circle,
            gradient:
                LinearGradient(
              colors: connected
                  ? const [
                      Color(0xFF00E676),
                      Color(0xFF00B8D4),
                    ]
                  : const [
                      Color(0xFF00E5FF),
                      Color(0xFF7C4DFF),
                    ],
            ),
            boxShadow: [
              BoxShadow(
                color: glowColor
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
              width: 184,
              height: 184,
              decoration:
                  const BoxDecoration(
                shape: BoxShape.circle,
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
                            size: 50,
                            color: glowColor,
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
    );
  }

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
          onPressed: testing
              ? null
              : () => testAll(),
          icon: const Icon(
            Icons.speed,
          ),
          label: Text(
            testing
                ? 'در حال تست...'
                : 'تست Ping همه',
          ),
        ),

        const SizedBox(
          height: 14,
        ),

        if (servers.isEmpty)
          card(
            const Column(
              children: [
                Icon(
                  Icons.dns_outlined,
                  size: 48,
                  color:
                      Colors.white38,
                ),
                SizedBox(height: 10),
                Text(
                  'هنوز سروری دریافت نشده',
                ),
              ],
            ),
          ),

        ...servers
            .asMap()
            .entries
            .map(
          (entry) {
            final index =
                entry.key;
            final server =
                entry.value;

            return card(
              ListTile(
                contentPadding:
                    EdgeInsets.zero,
                leading:
                    CircleAvatar(
                  child: Text(
                    '${index + 1}',
                  ),
                ),
                title: Text(
                  server.name,
                  maxLines: 1,
                  overflow:
                      TextOverflow
                          .ellipsis,
                ),
                subtitle: Text(
                  '${server.type} • ${server.host}:${server.port}',
                  maxLines: 2,
                  overflow:
                      TextOverflow
                          .ellipsis,
                ),
                trailing:
                    server.ping == null
                        ? const Text(
                            '---',
                            style:
                                TextStyle(
                              color:
                                  Colors.white38,
                            ),
                          )
                        : Text(
                            '${server.ping} ms',
                            style:
                                TextStyle(
                              color:
                                  server.ping! < 150
                                      ? const Color(
                                          0xFF00E676,
                                        )
                                      : Colors
                                          .orange,
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _traffic() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        header(
          'ترافیک',
          'آمار زنده VPN',
        ),

        Row(
          children: [
            Expanded(
              child: statCard(
                icon:
                    Icons.download,
                title:
                    'دانلود زنده',
                value:
                    formatSpeed(
                  downloadBps,
                ),
              ),
            ),
            const SizedBox(
              width: 10,
            ),
            Expanded(
              child: statCard(
                icon:
                    Icons.upload,
                title:
                    'آپلود زنده',
                value:
                    formatSpeed(
                  uploadBps,
                ),
              ),
            ),
          ],
        ),

        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment
                    .start,
            children: [
              const Text(
                'نمودار سرعت',
                style:
                    TextStyle(
                  fontSize: 17,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 15,
              ),
              SizedBox(
                height: 180,
                child:
                    SpeedChart(
                  download:
                      downloadHistory,
                  upload:
                      uploadHistory,
                ),
              ),
              const SizedBox(
                height: 8,
              ),
              const Row(
                mainAxisAlignment:
                    MainAxisAlignment
                        .spaceAround,
                children: [
                  Text(
                    '● دانلود',
                    style:
                        TextStyle(
                      color:
                          Color(0xFF00E5FF),
                    ),
                  ),
                  Text(
                    '● آپلود',
                    style:
                        TextStyle(
                      color:
                          Color(0xFF00E676),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        statCard(
          icon:
              Icons.download_done,
          title:
              'دریافت این جلسه',
          value:
              formatBytes(
            downloadTotalBytes,
          ),
          subtitle:
              'از زمان اتصال VPN',
        ),

        statCard(
          icon:
              Icons.upload_file,
          title:
              'ارسال این جلسه',
          value:
              formatBytes(
            uploadTotalBytes,
          ),
          subtitle:
              'از زمان اتصال VPN',
        ),

        statCard(
          icon:
              Icons.data_usage,
          title:
              'مصرف کل اشتراک',
          value:
              formatBytes(
            usedBytes,
          ),
        ),

        statCard(
          icon:
              Icons.storage,
          title:
              'باقی‌مانده اشتراک',
          value:
              formatBytes(
            remainingBytes(),
          ),
        ),

        statCard(
          icon:
              Icons.timer,
          title:
              'مدت اتصال',
          value:
              formatDuration(
            connectionDuration,
          ),
        ),

        const SizedBox(
          height: 4,
        ),

        card(
          Column(
            children: [
              const Text(
                'تست سرعت',
                style:
                    TextStyle(
                  fontSize: 17,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 16,
              ),
              Row(
                children: [
                  Expanded(
                    child:
                        _speedResult(
                      Icons.download,
                      'Download',
                      formatSpeed(
                        speedTestDownload,
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 10,
                  ),
                  Expanded(
                    child:
                        _speedResult(
                      Icons.upload,
                      'Upload',
                      formatSpeed(
                        speedTestUpload,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 14,
              ),
              FilledButton.icon(
                onPressed:
                    speedTesting ||
                            !connected
                        ? null
                        : runSpeedTest,
                icon:
                    const Icon(
                  Icons.speed,
                ),
                label: Text(
                  speedTesting
                      ? 'در حال تست...'
                      : 'شروع تست',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _speedResult(
    IconData icon,
    String title,
    String value,
  ) {
    return Container(
      padding:
          const EdgeInsets.all(14),
      decoration:
          BoxDecoration(
        color:
            const Color(0xFF081322),
        borderRadius:
            BorderRadius.circular(
          16,
        ),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color:
                const Color(0xFF00E5FF),
          ),
          const SizedBox(
            height: 7,
          ),
          Text(
            title,
            style:
                const TextStyle(
              color:
                  Colors.white54,
            ),
          ),
          const SizedBox(
            height: 4,
          ),
          Text(
            value,
            style:
                const TextStyle(
              fontSize: 16,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

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
          ),
        ),

        const SizedBox(
          height: 12,
        ),

        FilledButton.icon(
          onPressed: loading
              ? null
              : () =>
                  loadSubscription(),
          icon:
              const Icon(Icons.refresh),
          label: Text(
            loading
                ? 'در حال دریافت...'
                : 'بروزرسانی اشتراک',
          ),
        ),

        const SizedBox(
          height: 18,
        ),

        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment
                    .start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.cloud_download,
                    color:
                        Color(0xFF00E5FF),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'وضعیت اشتراک',
                    style:
                        TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 15,
              ),
              Text(
                'سرورها: ${servers.length}',
              ),
              const SizedBox(
                height: 7,
              ),
              Text(
                'کل حجم: ${formatBytes(totalBytes)}',
              ),
              const SizedBox(
                height: 7,
              ),
              Text(
                'مصرف: ${formatBytes(usedBytes)}',
              ),
              const SizedBox(
                height: 7,
              ),
              Text(
                'باقی‌مانده: ${formatBytes(remainingBytes())}',
              ),
              const SizedBox(
                height: 7,
              ),
              Text(
                'انقضا: ${expiryDateText()}',
              ),
              const SizedBox(
                height: 7,
              ),
              Text(
                'زمان باقی‌مانده: ${expiryText()}',
              ),
            ],
          ),
        ),

        card(
          const ListTile(
            contentPadding:
                EdgeInsets.zero,
            leading:
                Icon(Icons.sync),
            title:
                Text('Auto Refresh'),
            subtitle:
                Text(
              'هر ۱۵ دقیقه، در صورت قطع بودن VPN',
            ),
          ),
        ),
      ],
    );
  }

  Widget _settings() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        header(
          'تنظیمات',
          'Light speed 🔥',
        ),

        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,
            leading: const Icon(
              Icons.flash_on,
              color:
                  Color(0xFFFFC107),
            ),
            title: const Text(
              'انتخاب سریع‌ترین سرور',
            ),
            subtitle: const Text(
              'بر اساس TCP Connect Ping',
            ),
          ),
        ),

        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,
            leading: const Icon(
              Icons.speed,
              color:
                  Color(0xFF00E5FF),
            ),
            title: const Text(
              'تست سرعت',
            ),
            subtitle: const Text(
              'Download / Upload واقعی',
            ),
          ),
        ),

        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,
            leading: const Icon(
              Icons.sync,
              color:
                  Color(0xFF7C4DFF),
            ),
            title: const Text(
              'Auto Refresh',
            ),
            subtitle: const Text(
              'هر ۱۵ دقیقه',
            ),
          ),
        ),

        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,
            leading: const Icon(
              Icons.shield,
              color:
                  Color(0xFF00E676),
            ),
            title: const Text(
              'VPN Engine',
            ),
            subtitle: Text(
              'sing-box / Android VpnService\n$stateText',
            ),
          ),
        ),

        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,
            leading: const Icon(
              Icons.info_outline,
            ),
            title: const Text(
              'Light speed 🔥',
            ),
            subtitle: Text(
              'Servers: ${servers.length}\n'
              'VPN: ${connected ? 'Connected' : 'Disconnected'}',
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    stateSub?.cancel();
    trafficSub?.cancel();

    refreshTimer?.cancel();
    durationTimer?.cancel();

    url.dispose();

    super.dispose();
  }
}

class SpeedChart extends StatelessWidget {
  const SpeedChart({
    super.key,
    required this.download,
    required this.upload,
  });

  final List<double> download;
  final List<double> upload;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SpeedChartPainter(
        download: download,
        upload: upload,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _SpeedChartPainter
    extends CustomPainter {
  _SpeedChartPainter({
    required this.download,
    required this.upload,
  });

  final List<double> download;
  final List<double> upload;

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final paintGrid = Paint()
      ..color = Colors.white
          .withValues(alpha: .06)
      ..strokeWidth = 1;

    for (int i = 1; i < 5; i++) {
      final y =
          size.height *
          i /
          5;

      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        paintGrid,
      );
    }

    _drawLine(
      canvas,
      size,
      download,
      const Color(0xFF00E5FF),
    );

    _drawLine(
      canvas,
      size,
      upload,
      const Color(0xFF00E676),
    );
  }

  void _drawLine(
    Canvas canvas,
    Size size,
    List<double> values,
    Color color,
  ) {
    if (values.length < 2) {
      return;
    }

    final maxValue = max(
      1.0,
      values.reduce(max),
    );

    final path = Path();

    for (int i = 0;
        i < values.length;
        i++) {
      final x =
          i *
          size.width /
          max(
            values.length - 1,
            1,
          );

      final normalized =
          values[i] /
          maxValue;

      final y =
          size.height -
          (normalized *
              (size.height - 12)) -
          6;

      final point =
          Offset(x, y);

      if (i == 0) {
        path.moveTo(
          point.dx,
          point.dy,
        );
      } else {
        path.lineTo(
          point.dx,
          point.dy,
        );
      }
    }

    final paint = Paint()
      ..color = color
      ..style =
          PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap =
          StrokeCap.round
      ..strokeJoin =
          StrokeJoin.round;

    canvas.drawPath(
      path,
      paint,
    );
  }

  @override
  bool shouldRepaint(
    covariant _SpeedChartPainter oldDelegate,
  ) {
    return true;
  }
}
