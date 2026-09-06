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
  StreamSubscription? faultSub;

  Timer? refreshTimer;
  Timer? clockTimer;

  int page = 0;

  bool loading = false;
  bool testing = false;
  bool connected = false;
  bool connecting = false;

  String stateText = 'آماده اتصال';
  String lastVpnError = '';

  String download = '0 Mbps';
  String upload = '0 Mbps';

  int downloadTotalBytes = 0;
  int uploadTotalBytes = 0;

  int? totalBytes;
  int? usedBytes;
  int? expireAt;

  @override
  void initState() {
    super.initState();

    _listenVpn();

    refreshTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) {
        if (!connected && !connecting) {
          loadSubscription(silent: true);
        }
      },
    );

    clockTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) {
        if (mounted) {
          setState(() {});
        }
      },
    );

    loadSaved();
  }

  void _listenVpn() {
    stateSub = vpn.serviceStateStream.listen((state) {
      if (!mounted) return;

      final text = state.toString();
      final lower = text.toLowerCase();

      setState(() {
        if (lower.contains('running') ||
            lower.contains('started') ||
            lower.contains('connected')) {
          connected = true;
          connecting = false;
        }

        if (lower.contains('stopped') ||
            lower.contains('disconnected')) {
          connected = false;
          connecting = false;
        }

        if (lower.isNotEmpty) {
          stateText = text;
        }
      });
    });

    trafficSub = vpn.trafficStatsStream.listen((stats) {
      if (!mounted) return;

      try {
        final dynamic x = stats;

        final dynamic downBps = x.downlinkBps;
        final dynamic upBps = x.uplinkBps;

        int downTotal = downloadTotalBytes;
        int upTotal = uploadTotalBytes;

        try {
          final dynamic value = x.downlinkTotalBytes;

          if (value is num) {
            downTotal = value.toInt();
          }
        } catch (_) {}

        try {
          final dynamic value = x.uplinkTotalBytes;

          if (value is num) {
            upTotal = value.toInt();
          }
        } catch (_) {}

        setState(() {
          download = speed(downBps);
          upload = speed(upBps);
          downloadTotalBytes = downTotal;
          uploadTotalBytes = upTotal;
        });
      } catch (_) {}
    });

    faultSub = vpn.faultStream.listen((error) {
      if (!mounted) return;

      final message = error.toString().trim();

      setState(() {
        connected = false;
        connecting = false;
        lastVpnError = message;
        stateText = 'خطای VPN';
      });

      if (message.isNotEmpty) {
        snack('خطای VPN: $message');
      }
    });
  }

  Future<void> loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final saved =
          prefs.getString('subscription_url');

      if (saved == null || saved.isEmpty) {
        return;
      }

      url.text = saved;

      await loadSubscription(silent: true);
    } catch (_) {}
  }

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final address = url.text.trim();

    if (address.isEmpty) {
      if (!silent && mounted) {
        setState(() {
          stateText =
              'Subscription URL را وارد کن';
        });
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
            Uri.parse(address),
            headers: const {
              'User-Agent': 'LightSpeed/2.0',
              'Accept': '*/*',
            },
          )
          .timeout(
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

      final result = <Server>[];

      for (final line in decodeSubscription(body)) {
        final server = parseServer(line);

        if (server != null) {
          result.add(server);
        }
      }

      final prefs =
          await SharedPreferences.getInstance();

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

        lastVpnError = '';

        stateText = result.isEmpty
            ? 'هیچ سروری پیدا نشد'
            : '${result.length} سرور دریافت شد';
      });

      await testAll(silent: true);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        stateText =
            'خطا در دریافت Subscription';
      });

      if (!silent) {
        snack(
          'دریافت Subscription ناموفق بود: $e',
        );
      }
    }
  }

  void _readUserInfo(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      if (!mounted) return;

      setState(() {
        totalBytes = null;
        usedBytes = null;
        expireAt = null;
      });

      return;
    }

    final values = <String, int>{};

    for (final item in raw.split(';')) {
      final parts = item.trim().split('=');

      if (parts.length == 2) {
        final key = parts[0].trim();
        final value =
            int.tryParse(parts[1].trim());

        if (value != null) {
          values[key] = value;
        }
      }
    }

    if (!mounted) return;

    setState(() {
      totalBytes = values['total'];

      usedBytes =
          (values['upload'] ?? 0) +
          (values['download'] ?? 0);

      expireAt = values['expire'];
    });
  }

  List<String> decodeSubscription(String body) {
    final lines = body
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where(
          (line) =>
              line.isNotEmpty &&
              line.contains('://'),
        )
        .toList();

    if (lines.isNotEmpty) {
      return lines;
    }

    try {
      var encoded = body
          .trim()
          .replaceAll(RegExp(r'\s+'), '');

      encoded = encoded
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      encoded +=
          '=' * ((4 - encoded.length % 4) % 4);

      final decoded = utf8.decode(
        base64.decode(encoded),
        allowMalformed: true,
      );

      return decoded
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where(
            (line) =>
                line.isNotEmpty &&
                line.contains('://'),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Server? parseServer(String raw) {
    try {
      final uri = Uri.parse(raw);

      final scheme =
          uri.scheme.toLowerCase();

      if (scheme == 'vmess') {
        return parseVmess(raw);
      }

      if (![
        'vless',
        'trojan',
        'ss',
        'hysteria2',
        'hy2',
      ].contains(scheme)) {
        return null;
      }

      if (uri.host.isEmpty ||
          !uri.hasPort ||
          uri.port <= 0) {
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
          outbound =
              shadowsocks(uri, raw) ?? {};
          break;

        default:
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
      var encoded =
          raw.substring(raw.indexOf('://') + 3);

      encoded = encoded
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      encoded +=
          '=' * ((4 - encoded.length % 4) % 4);

      final decoded = utf8.decode(
        base64.decode(encoded),
        allowMalformed: true,
      );

      final map =
          json.decode(decoded)
              as Map<String, dynamic>;

      final host = '${map['add'] ?? ''}';

      final port =
          int.tryParse(
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
          '${map['tls'] ?? ''}'
              .toLowerCase();

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

      final fingerprint = p['fp'] ?? '';

      if (fingerprint.isNotEmpty) {
        tls['utls'] = {
          'enabled': true,
          'fingerprint': fingerprint,
        };
      }

      if (security == 'reality') {
        final publicKey = p['pbk'] ?? '';

        if (publicKey.isNotEmpty) {
          tls['reality'] = {
            'enabled': true,
            'public_key': publicKey,
            if ((p['sid'] ?? '').isNotEmpty)
              'short_id': p['sid'],
          };
        }
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

  Map<String, dynamic> trojan(Uri uri) {
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

    addTransport(
      outbound,
      p['type'] ?? 'tcp',
      p['path'] ?? '',
      p['host'] ?? '',
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
        var encoded = raw
            .substring(
              raw.indexOf('://') + 3,
            )
            .split('#')
            .first;

        encoded = encoded
            .replaceAll('-', '+')
            .replaceAll('_', '/');

        encoded +=
            '=' * ((4 - encoded.length % 4) % 4);

        user = utf8.decode(
          base64.decode(encoded),
          allowMalformed: true,
        );
      }

      final colon = user.indexOf(':');

      if (colon <= 0) {
        return null;
      }

      final method =
          Uri.decodeComponent(
        user.substring(0, colon),
      );

      final password =
          Uri.decodeComponent(
        user.substring(colon + 1),
      );

      if (method.isEmpty ||
          password.isEmpty) {
        return null;
      }

      return {
        'type': 'shadowsocks',
        'tag': 'proxy',
        'server': uri.host,
        'server_port': uri.port,
        'method': method,
        'password': password,
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> hysteria2(Uri uri) {
    final p = uri.queryParameters;

    return {
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
        if (p['insecure'] == '1')
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
    final n =
        network.toLowerCase().trim();

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

    if (n == 'h2' || n == 'http') {
      outbound['transport'] = {
        'type': 'http',
        'path':
            path.isEmpty ? '/' : path,
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
        'level': 'info',
      },

      'dns': {
        'servers': [
          {
            'type': 'local',
            'tag': 'dns-local',
          },
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
            'detour': 'direct',
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
        stateText = 'در حال تست Ping...';
      });
    }

    for (final server in servers) {
      final stopwatch =
          Stopwatch()..start();

      try {
        final socket =
            await Socket.connect(
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

    if (mounted) {
      setState(() {
        testing = false;

        if (!silent) {
          stateText =
              'سرورها بر اساس Ping مرتب شدند';
        }
      });
    }
  }

  Server? fastest() {
    final good = servers
        .where(
          (server) =>
              server.ping != null,
        )
        .toList();

    if (good.isEmpty) {
      return null;
    }

    good.sort(
      (a, b) =>
          a.ping!.compareTo(b.ping!),
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

    if (connected) {
      await disconnect();
      return;
    }

    if (connecting) {
      return;
    }

    if (mounted) {
      setState(() {
        connecting = true;
        lastVpnError = '';
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

      snack(
        'هیچ سرور قابل دسترسی پیدا نشد',
      );

      return;
    }

    try {
      if (mounted) {
        setState(() {
          stateText =
              'در حال اتصال به ${best.name}...';
        });
      }

      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'مجوز VPN توسط کاربر تأیید نشد',
        );
      }

      final config =
          makeConfig(best);

      await vpn.checkConfig(config);

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

      if (!mounted) return;

      setState(() {
        connecting = false;
        connected = true;

        downloadTotalBytes = 0;
        uploadTotalBytes = 0;

        download = '0 Mbps';
        upload = '0 Mbps';

        lastVpnError = '';

        stateText =
            'متصل • ${best.name}';
      });
    } catch (e) {
      if (!mounted) return;

      final error =
          e.toString().trim();

      setState(() {
        connecting = false;
        connected = false;

        lastVpnError = error;

        stateText =
            'اتصال ناموفق';
      });

      snack(
        'اتصال VPN ناموفق بود:\n$error',
      );
    }
  }

  Future<void> disconnect() async {
    try {
      await vpn.disconnect();
    } catch (e) {
      if (mounted) {
        snack(
          'خطا هنگام قطع اتصال: $e',
        );
      }
    }

    if (mounted) {
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
  }

  String speed(dynamic bps) {
    final n =
        bps is num
            ? bps.toDouble()
            : 0.0;

    if (n <= 0) {
      return '0 Mbps';
    }

    if (n >= 1000000000) {
      return '${(n / 1000000000).toStringAsFixed(2)} Gbps';
    }

    if (n >= 1000000) {
      return '${(n / 1000000).toStringAsFixed(2)} Mbps';
    }

    if (n >= 1000) {
      return '${(n / 1000).toStringAsFixed(1)} Kbps';
    }

    return '${n.toStringAsFixed(0)} bps';
  }

  String size(int? bytes) {
    if (bytes == null || bytes <= 0) {
      return 'نامشخص';
    }

    const units = [
      'B',
      'KB',
      'MB',
      'GB',
      'TB',
    ];

    double value =
        bytes.toDouble();

    int index = 0;

    while (value >= 1024 &&
        index < units.length - 1) {
      value /= 1024;
      index++;
    }

    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[index]}';
  }

  String remainingTime() {
    if (expireAt == null ||
        expireAt! <= 0) {
      return 'نامشخص';
    }

    final now =
        DateTime.now()
                .millisecondsSinceEpoch ~/
            1000;

    final seconds =
        expireAt! - now;

    if (seconds <= 0) {
      return 'منقضی شده';
    }

    final days =
        seconds ~/ 86400;

    final hours =
        (seconds % 86400) ~/ 3600;

    final minutes =
        (seconds % 3600) ~/ 60;

    if (days > 0) {
      return '$days روز و $hours ساعت';
    }

    if (hours > 0) {
      return '$hours ساعت و $minutes دقیقه';
    }

    return '$minutes دقیقه';
  }

  String expiryDate() {
    if (expireAt == null ||
        expireAt! <= 0) {
      return 'نامشخص';
    }

    final date =
        DateTime.fromMillisecondsSinceEpoch(
      expireAt! * 1000,
    );

    final year =
        date.year.toString().padLeft(
              4,
              '0',
            );

    final month =
        date.month.toString().padLeft(
              2,
              '0',
            );

    final day =
        date.day.toString().padLeft(
              2,
              '0',
            );

    final hour =
        date.hour.toString().padLeft(
              2,
              '0',
            );

    final minute =
        date.minute.toString().padLeft(
              2,
              '0',
            );

    return '$year/$month/$day - $hour:$minute';
  }

  String usedPercent() {
    if (totalBytes == null ||
        totalBytes! <= 0) {
      return 'نامشخص';
    }

    final percent =
        ((usedBytes ?? 0) /
                totalBytes!) *
            100;

    final value =
        percent.clamp(
      0.0,
      100.0,
    );

    return '${value.toStringAsFixed(1)}٪';
  }

  void snack(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            text,
            textDirection:
                TextDirection.rtl,
          ),
          behavior:
              SnackBarBehavior.floating,
          duration:
              const Duration(seconds: 4),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
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
              size: 28,
            ),
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
                Text(
                  title,
                  style:
                      const TextStyle(
                    fontSize: 22,
                    fontWeight:
                        FontWeight.w800,
                  ),
                ),
                const SizedBox(
                  height: 3,
                ),
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
          color:
              Colors.white.withValues(
            alpha: .05,
          ),
        ),
      ),
      child: child,
    );
  }

  Widget _home() {
    final best = fastest();

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
          const EdgeInsets.all(18),
      children: [
        header(
          'Light speed 🔥',
          'VPN واقعی با sing-box',
        ),

        const SizedBox(
          height: 8,
        ),

        Center(
          child: GestureDetector(
            onTap:
                connecting
                    ? null
                    : connect,
            child: Container(
              width: 200,
              height: 200,
              decoration:
                  BoxDecoration(
                shape:
                    BoxShape.circle,
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
                    color: (connected
                            ? const Color(
                                0xFF00E676,
                              )
                            : const Color(
                                0xFF00E5FF,
                              ))
                        .withValues(
                      alpha: .35,
                    ),
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
                                    ? Icons
                                        .power
                                    : Icons
                                        .bolt,
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
                                  fontSize:
                                      18,
                                  fontWeight:
                                      FontWeight
                                          .bold,
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

        const SizedBox(
          height: 16,
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

        if (lastVpnError.isNotEmpty) ...[
          const SizedBox(
            height: 10,
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
                      Icons.error_outline,
                      color: Colors.redAccent,
                    ),
                    SizedBox(
                      width: 8,
                    ),
                    Text(
                      'جزئیات خطای VPN',
                      style:
                          TextStyle(
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(
                  height: 10,
                ),
                SelectableText(
                  lastVpnError,
                  style:
                      const TextStyle(
                    color:
                        Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(
          height: 20,
        ),

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
                      'سریع‌ترین سرور',
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
                      best?.name ??
                          'هنوز انتخاب نشده',
                      maxLines: 1,
                      overflow:
                          TextOverflow
                              .ellipsis,
                    ),
                  ],
                ),
              ),
              if (best?.ping != null)
                Text(
                  '${best!.ping} ms',
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
              child: card(
                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons
                              .arrow_downward_rounded,
                          size: 18,
                          color:
                              Color(
                            0xFF00E5FF,
                          ),
                        ),
                        SizedBox(
                          width: 6,
                        ),
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
                    const SizedBox(
                      height: 8,
                    ),
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
            const SizedBox(
              width: 10,
            ),
            Expanded(
              child: card(
                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons
                              .arrow_upward_rounded,
                          size: 18,
                          color:
                              Color(
                            0xFF7C4DFF,
                          ),
                        ),
                        SizedBox(
                          width: 6,
                        ),
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
                    const SizedBox(
                      height: 8,
                    ),
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
                CrossAxisAlignment
                    .start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.data_usage,
                    color:
                        Color(0xFF7C4DFF),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
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
              const SizedBox(
                height: 12,
              ),
              ClipRRect(
                borderRadius:
                    BorderRadius
                        .circular(10),
                child:
                    LinearProgressIndicator(
                  value: percent,
                  minHeight: 9,
                ),
              ),
              const SizedBox(
                height: 10,
              ),
              Text(
                'مصرف: ${size(usedBytes)}',
              ),
              const SizedBox(
                height: 6,
              ),
              Text(
                'درصد مصرف: ${usedPercent()}',
              ),
              const SizedBox(
                height: 6,
              ),
              Text(
                'باقی‌مانده: ${size(totalBytes == null ? null : max(0, totalBytes! - (usedBytes ?? 0)))}',
                style:
                    const TextStyle(
                  color:
                      Colors.white70,
                ),
              ),
              const SizedBox(
                height: 6,
              ),
              Text(
                'تاریخ انقضا: ${expiryDate()}',
                style:
                    const TextStyle(
                  color:
                      Colors.white70,
                ),
              ),
              const SizedBox(
                height: 6,
              ),
              Text(
                'زمان باقی‌مانده: ${remainingTime()}',
                style:
                    const TextStyle(
                  color:
                      Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ],
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
          onPressed:
              testing ? null : testAll,
          icon:
              const Icon(Icons.speed),
          label: Text(
            testing
                ? 'در حال تست...'
                : 'تست Ping',
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
                SizedBox(
                  height: 12,
                ),
                Text(
                  'هنوز سروری دریافت نشده',
                ),
                SizedBox(
                  height: 5,
                ),
                Text(
                  'از بخش Subscription آن را بروزرسانی کن',
                  style:
                      TextStyle(
                    color:
                        Colors.white54,
                  ),
                  textAlign:
                      TextAlign.center,
                ),
              ],
            ),
          ),

        ...servers.asMap().entries.map(
          (entry) {
            final server =
                entry.value;

            return card(
              ListTile(
                contentPadding:
                    EdgeInsets.zero,
                leading:
                    CircleAvatar(
                  backgroundColor:
                      const Color(
                    0xFF16243A,
                  ),
                  child: Text(
                    '${entry.key + 1}',
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
                trailing: Text(
                  server.ping == null
                      ? '---'
                      : '${server.ping} ms',
                  style: TextStyle(
                    color:
                        server.ping == null
                            ? Colors
                                .white38
                            : server.ping! <
                                    100
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
                fontSize: 18,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            leading:
                const Icon(
              Icons
                  .arrow_downward_rounded,
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
                fontSize: 18,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            leading:
                const Icon(
              Icons
                  .arrow_upward_rounded,
              color:
                  Color(0xFF7C4DFF),
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'حجم مصرف‌شده اشتراک',
            ),
            subtitle:
                Text(size(usedBytes)),
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
              'دانلود این جلسه',
            ),
            subtitle: Text(
              size(
                downloadTotalBytes,
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
              color:
                  Color(0xFF7C4DFF),
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'حجم باقی‌مانده',
            ),
            subtitle:
                Text(size(remaining)),
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
                Text(expiryDate()),
            leading:
                const Icon(
              Icons.event,
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'زمان باقی‌مانده',
            ),
            subtitle: Text(
              remainingTime(),
            ),
            leading:
                const Icon(
              Icons.timer_outlined,
            ),
          ),
        ),
      ],
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
          keyboardType:
              TextInputType.url,
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

        SizedBox(
          height: 52,
          child:
              FilledButton.icon(
            onPressed: loading
                ? null
                : () =>
                    loadSubscription(),
            icon: const Icon(
              Icons.refresh,
            ),
            label: Text(
              loading
                  ? 'در حال دریافت...'
                  : 'بروزرسانی اشتراک',
            ),
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
                  SizedBox(
                    width: 8,
                  ),
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
                height: 14,
              ),

              Text(
                'تعداد سرورها: ${servers.length}',
              ),

              const SizedBox(
                height: 7,
              ),

              Text(
                'حجم کل: ${size(totalBytes)}',
              ),

              const SizedBox(
                height: 7,
              ),

              Text(
                'مصرف‌شده: ${size(usedBytes)}',
              ),

              const SizedBox(
                height: 7,
              ),

              Text(
                'درصد مصرف: ${usedPercent()}',
              ),

              const SizedBox(
                height: 7,
              ),

              Text(
                'حجم باقی‌مانده: ${size(totalBytes == null ? null : max(0, totalBytes! - (usedBytes ?? 0)))}',
              ),

              const SizedBox(
                height: 7,
              ),

              Text(
                'تاریخ انقضا: ${expiryDate()}',
              ),

              const SizedBox(
                height: 7,
              ),

              Text(
                'زمان باقی‌مانده: ${remainingTime()}',
              ),
            ],
          ),
        ),

        card(
          const Text(
            'بروزرسانی خودکار هر ۱۵ دقیقه انجام می‌شود.\n'
            'تاریخ و زمان باقی‌مانده نیز خودکار بروزرسانی می‌شوند.\n'
            'بعد از دریافت اشتراک، سرورها دوباره Ping می‌شوند.',
            style: TextStyle(
              color:
                  Colors.white70,
              height: 1.6,
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
          'Light speed',
        ),

        card(
          const ListTile(
            leading:
                Icon(Icons.flash_on),
            title: Text(
              'انتخاب سریع‌ترین سرور',
            ),
            subtitle: Text(
              'بر اساس زمان TCP Connect',
            ),
          ),
        ),

        card(
          const ListTile(
            leading:
                Icon(Icons.sync),
            title: Text(
              'Auto Refresh',
            ),
            subtitle: Text(
              'هر ۱۵ دقیقه',
            ),
          ),
        ),

        card(
          ListTile(
            leading:
                const Icon(Icons.shield),
            title: const Text(
              'VPN Engine',
            ),
            subtitle: Text(
              'sing-box / Android VpnService\n$stateText',
            ),
          ),
        ),

        if (lastVpnError.isNotEmpty)
          card(
            ListTile(
              leading:
                  const Icon(
                Icons.error_outline,
                color:
                    Colors.redAccent,
              ),
              title: const Text(
                'آخرین خطای VPN',
              ),
              subtitle:
                  SelectableText(
                lastVpnError,
              ),
            ),
          ),

        card(
          const ListTile(
            leading:
                Icon(Icons.speed),
            title: Text(
              'Traffic Monitor',
            ),
            subtitle: Text(
              'نمایش سرعت لحظه‌ای دانلود و آپلود',
            ),
          ),
        ),

        card(
          const ListTile(
            leading:
                Icon(Icons.security),
            title: Text(
              'VPN Mode',
            ),
            subtitle: Text(
              'ترافیک دستگاه از TUN عبور می‌کند',
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
    faultSub?.cancel();

    refreshTimer?.cancel();
    clockTimer?.cancel();

    url.dispose();

    super.dispose();
  }
}
