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
  final url = TextEditingController();
  final servers = <Server>[];

  StreamSubscription? stateSub;
  StreamSubscription? trafficSub;
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

    stateSub = vpn.serviceStateStream.listen((s) {
      if (!mounted) return;

      final text = s.toString();
      final low = text.toLowerCase();

      setState(() {
        stateText = text;

        if (low.contains('running') ||
            low.contains('connected') ||
            low.contains('started')) {
          connected = true;
        }

        if (low.contains('stopped') ||
            low.contains('disconnected')) {
          connected = false;
        }
      });
    });

    trafficSub = vpn.trafficStatsStream.listen((s) {
      if (!mounted) return;

      dynamic x = s;

      try {
        setState(() {
          download = speed(x.downlinkBps);
          upload = speed(x.uplinkBps);

          try {
            final d = x.downlinkTotalBytes;

            if (d is num) {
              downloadTotalBytes = d.toInt();
            }
          } catch (_) {}

          try {
            final u = x.uplinkTotalBytes;

            if (u is num) {
              uploadTotalBytes = u.toInt();
            }
          } catch (_) {}
        });
      } catch (_) {}
    });

    timer = Timer.periodic(
      const Duration(minutes: 15),
      (_) {
        if (!connected && url.text.trim().isNotEmpty) {
          loadSubscription(silent: true);
        }
      },
    );

    loadSaved();
  }

  Future<void> loadSaved() async {
    final p = await SharedPreferences.getInstance();

    final saved = p.getString('subscription_url');

    if (saved == null || saved.trim().isEmpty) {
      return;
    }

    url.text = saved;

    await loadSubscription(silent: true);
  }

  String? responseHeader(
    Map<String, String> headers,
    String wanted,
  ) {
    final target = wanted.toLowerCase();

    for (final e in headers.entries) {
      if (e.key.toLowerCase() == target) {
        return e.value;
      }
    }

    return null;
  }

  void _readUserInfo(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return;
    }

    final values = <String, int>{};

    for (final item in raw.split(';')) {
      final separator = item.indexOf('=');

      if (separator <= 0) {
        continue;
      }

      final key = item
          .substring(0, separator)
          .trim()
          .toLowerCase();

      final value = int.tryParse(
        item.substring(separator + 1).trim(),
      );

      if (value == null) {
        continue;
      }

      switch (key) {
        case 'upload':
          values['upload'] = value;
          break;

        case 'download':
          values['download'] = value;
          break;

        case 'total':
        case 'transfer_enable':
        case 'transfer-enabled':
          values['total'] = value;
          break;

        case 'expire':
        case 'expired_at':
        case 'expired':
          values['expire'] = value;
          break;
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

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final subscriptionUrl = url.text.trim();

    if (subscriptionUrl.isEmpty) {
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
    } else if (mounted) {
      setState(() {
        loading = true;
      });
    }

    try {
      final response = await http.get(
        Uri.parse(subscriptionUrl),
        headers: const {
          'User-Agent': 'LightSpeed/3.0',
          'Accept': '*/*',
          'Cache-Control': 'no-cache',
          'Pragma': 'no-cache',
        },
      ).timeout(
        const Duration(seconds: 60),
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
        responseHeader(
          response.headers,
          'subscription-userinfo',
        ),
      );

      final decodedLines = decodeSubscription(body);

      final result = <Server>[];

      for (final line in decodedLines) {
        final server = parseServer(line);

        if (server != null) {
          result.add(server);
        }
      }

      if (result.isEmpty) {
        throw Exception(
          'هیچ کانفیگ قابل شناسایی پیدا نشد',
        );
      }

      final p = await SharedPreferences.getInstance();

      await p.setString(
        'subscription_url',
        subscriptionUrl,
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
      if (!mounted) return;

      setState(() {
        loading = false;
        stateText = 'خطا در دریافت Subscription';
      });

      if (!silent) {
        snack(
          'دریافت Subscription ناموفق بود: $e',
        );
      }
    }
  }

  List<String> decodeSubscription(String body) {
    final direct = body
        .replaceAll('\r', '')
        .split('\n')
        .map((x) => x.trim())
        .where(
          (x) => x.contains('://'),
        )
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
          .replaceAll('\r', '')
          .split('\n')
          .map((x) => x.trim())
          .where(
            (x) => x.contains('://'),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Server? parseServer(String raw) {
    try {
      final u = Uri.parse(raw);
      final scheme = u.scheme.toLowerCase();

      if (scheme == 'vmess') {
        return parseVmess(raw);
      }

      if (![
        'vless',
        'trojan',
        'ss',
        'hysteria2',
        'hy2',
        'tuic',
      ].contains(scheme)) {
        return null;
      }

      if (u.host.isEmpty || !u.hasPort) {
        return null;
      }

      final name = Uri.decodeComponent(
        u.fragment.isEmpty
            ? '${scheme.toUpperCase()} ${u.host}'
            : u.fragment,
      );

      late Map<String, dynamic> out;

      if (scheme == 'vless') {
        out = vless(u);
      } else if (scheme == 'trojan') {
        out = trojan(u);
      } else if (scheme == 'ss') {
        out = shadowsocks(u, raw) ?? {};
      } else if (scheme == 'tuic') {
        out = tuic(u);
      } else {
        out = hysteria2(u);
      }

      if (out.isEmpty) {
        return null;
      }

      return Server(
        raw: raw,
        name: name,
        type: scheme.toUpperCase(),
        host: u.host,
        port: u.port,
        outbound: out,
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

      final jsonData = json.decode(decoded);

      if (jsonData is! Map) {
        return null;
      }

      final m = Map<String, dynamic>.from(
        jsonData,
      );

      final host = '${m['add'] ?? ''}';

      final port =
          int.tryParse(
            '${m['port'] ?? ''}',
          ) ??
          0;

      final uuid = '${m['id'] ?? ''}';

      if (host.isEmpty ||
          port <= 0 ||
          uuid.isEmpty) {
        return null;
      }

      final out = <String, dynamic>{
        'type': 'vmess',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'uuid': uuid,
        'security': '${m['scy'] ?? 'auto'}',
      };

      final tlsType =
          '${m['tls'] ?? ''}'.toLowerCase();

      final sni =
          '${m['sni'] ?? m['host'] ?? ''}';

      if (tlsType.isNotEmpty &&
          tlsType != 'none') {
        final tls = <String, dynamic>{
          'enabled': true,
        };

        if (sni.isNotEmpty) {
          tls['server_name'] = sni;
        }

        final fp = '${m['fp'] ?? ''}';

        if (fp.isNotEmpty) {
          tls['utls'] = {
            'enabled': true,
            'fingerprint': fp,
          };
        }

        out['tls'] = tls;
      }

      addTransport(
        out,
        '${m['net'] ?? 'tcp'}',
        '${m['path'] ?? ''}',
        '${m['host'] ?? ''}',
      );

      return Server(
        raw: raw,
        name: '${m['ps'] ?? 'VMess'}',
        type: 'VMESS',
        host: host,
        port: port,
        outbound: out,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> vless(Uri u) {
    final p = u.queryParameters;

    final out = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': u.host,
      'server_port': u.port,
      'uuid': u.userInfo,
    };

    if ((p['flow'] ?? '').isNotEmpty) {
      out['flow'] = p['flow'];
    }

    final security =
        (p['security'] ?? '').toLowerCase();

    if (security == 'tls' ||
        security == 'reality') {
      final tls = <String, dynamic>{
        'enabled': true,
        'server_name':
            p['sni'] ??
            p['host'] ??
            u.host,
      };

      if ((p['fp'] ?? '').isNotEmpty) {
        tls['utls'] = {
          'enabled': true,
          'fingerprint': p['fp'],
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

      out['tls'] = tls;
    }

    addTransport(
      out,
      p['type'] ??
          p['network'] ??
          'tcp',
      p['path'] ?? '',
      p['host'] ?? '',
    );

    return out;
  }

  Map<String, dynamic> trojan(Uri u) {
    final p = u.queryParameters;

    final tls = <String, dynamic>{
      'enabled': true,
      'server_name':
          p['sni'] ??
          p['host'] ??
          u.host,
    };

    if ((p['fp'] ?? '').isNotEmpty) {
      tls['utls'] = {
        'enabled': true,
        'fingerprint': p['fp'],
      };
    }

    final out = <String, dynamic>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': u.host,
      'server_port': u.port,
      'password': u.userInfo,
      'tls': tls,
    };

    addTransport(
      out,
      p['type'] ?? 'tcp',
      p['path'] ?? '',
      p['host'] ?? '',
    );

    return out;
  }

  Map<String, dynamic>? shadowsocks(
    Uri u,
    String raw,
  ) {
    try {
      var user = u.userInfo;

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

      final method = Uri.decodeComponent(
        user.substring(0, colon),
      );

      final password = Uri.decodeComponent(
        user.substring(colon + 1),
      );

      return {
        'type': 'shadowsocks',
        'tag': 'proxy',
        'server': u.host,
        'server_port': u.port,
        'method': method,
        'password': password,
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> hysteria2(Uri u) {
    final p = u.queryParameters;

    return {
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': u.host,
      'server_port': u.port,
      'password': u.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            p['sni'] ??
            p['peer'] ??
            u.host,
        if (p['insecure'] == '1' ||
            p['allowInsecure'] == '1')
          'insecure': true,
      },
    };
  }

  Map<String, dynamic> tuic(Uri u) {
    final separator =
        u.userInfo.indexOf(':');

    final uuid = separator > 0
        ? u.userInfo.substring(
            0,
            separator,
          )
        : u.userInfo;

    final password = separator > 0
        ? u.userInfo.substring(
            separator + 1,
          )
        : '';

    final p = u.queryParameters;

    return {
      'type': 'tuic',
      'tag': 'proxy',
      'server': u.host,
      'server_port': u.port,
      'uuid': uuid,
      'password': password,
      'congestion_control':
          p['congestion_control'] ??
          'bbr',
      'tls': {
        'enabled': true,
        'server_name':
            p['sni'] ??
            u.host,
      },
    };
  }

  void addTransport(
    Map<String, dynamic> out,
    String network,
    String path,
    String host,
  ) {
    final n = network.toLowerCase();

    if (n == 'ws' ||
        n == 'websocket') {
      out['transport'] = {
        'type': 'ws',
        'path':
            path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'headers': {
            'Host': host,
          },
      };
    } else if (n == 'grpc') {
      out['transport'] = {
        'type': 'grpc',
        'service_name': path,
      };
    } else if (n == 'httpupgrade') {
      out['transport'] = {
        'type': 'httpupgrade',
        'path':
            path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': host,
      };
    } else if (n == 'h2' ||
        n == 'http') {
      out['transport'] = {
        'type': 'http',
        'path':
            path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': [host],
      };
    }
  }

  String makeConfig(Server server) {
    final proxy =
        Map<String, dynamic>.from(
      server.outbound,
    );

    proxy['tag'] = 'proxy';

    return jsonEncode({
      'log': {
        'level': 'warn',
      },

      'dns': {
        'servers': [
          {
            'tag': 'dns-remote',
            'address':
                'https://1.1.1.1/dns-query',
            'detour': 'proxy',
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
          'mtu': 1500,
          'stack': 'mixed',
          'auto_route': true,
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

    if (mounted) {
      setState(() {
        testing = true;

        if (!silent) {
          stateText =
              'در حال تست Ping...';
        }
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

    if (!mounted) return;

    setState(() {
      testing = false;

      if (!silent) {
        stateText =
            'تست Ping سرورها تمام شد';
      }
    });
  }

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

    if (connected || connecting) {
      return;
    }

    setState(() {
      connecting = true;
      stateText =
          'در حال انتخاب سریع‌ترین سرور...';
    });

    if (servers.every(
      (s) => s.ping == null,
    )) {
      await testAll(silent: true);
    }

    final best = fastest();

    if (best == null) {
      if (!mounted) return;

      setState(() {
        connecting = false;
        stateText =
            'سرور قابل اتصال پیدا نشد';
      });

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

      if (!mounted) return;

      setState(() {
        stateText =
            'در حال بررسی کانفیگ...';
      });

      final config =
          makeConfig(best);

      await vpn.checkConfig(config);

      if (!mounted) return;

      setState(() {
        stateText =
            'در حال اتصال به ${best.name}...';
      });

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
        stateText =
            'متصل • ${best.name}';
      });
    } catch (e) {
      try {
        await vpn.disconnect();
      } catch (_) {}

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

  String speed(dynamic bps) {
    final n = bps is num
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
    if (bytes == null) {
      return 'نامشخص';
    }

    if (bytes == 0) {
      return '0 B';
    }

    if (bytes < 1024) {
      return '$bytes B';
    }

    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    if (bytes <
        1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    if (bytes <
        1024 *
            1024 *
            1024 *
            1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }

    return '${(bytes / 1024 / 1024 / 1024 / 1024).toStringAsFixed(2)} TB';
  }

  String _dateFromUnix(int timestamp) {
    try {
      final milliseconds =
          timestamp > 20000000000
              ? timestamp
              : timestamp * 1000;

      final date =
          DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
      );

      return '${date.year}/'
          '${date.month.toString().padLeft(2, '0')}/'
          '${date.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return 'نامشخص';
    }
  }

  String remainingTime() {
    if (expireAt == null ||
        expireAt! <= 0) {
      return 'نامشخص';
    }

    try {
      final milliseconds =
          expireAt! > 20000000000
              ? expireAt!
              : expireAt! * 1000;

      final expire =
          DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
      );

      final difference =
          expire.difference(
        DateTime.now(),
      );

      if (difference.isNegative) {
        return 'منقضی شده';
      }

      final days =
          difference.inDays;

      final hours =
          difference.inHours.remainder(24);

      final minutes =
          difference.inMinutes.remainder(60);

      if (days > 0) {
        return '$days روز و $hours ساعت';
      }

      if (hours > 0) {
        return '$hours ساعت و $minutes دقیقه';
      }

      return '$minutes دقیقه';
    } catch (_) {
      return 'نامشخص';
    }
  }

  void snack(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior:
              SnackBarBehavior.floating,
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
              icon:
                  Icon(Icons.home_outlined),
              selectedIcon:
                  Icon(Icons.home),
              label: 'خانه',
            ),
            NavigationDestination(
              icon:
                  Icon(Icons.dns_outlined),
              selectedIcon:
                  Icon(Icons.dns),
              label: 'سرورها',
            ),
            NavigationDestination(
              icon:
                  Icon(Icons.bar_chart_outlined),
              selectedIcon:
                  Icon(Icons.bar_chart),
              label: 'ترافیک',
            ),
            NavigationDestination(
              icon:
                  Icon(Icons.link_outlined),
              selectedIcon:
                  Icon(Icons.link),
              label: 'اشتراک',
            ),
            NavigationDestination(
              icon:
                  Icon(Icons.settings_outlined),
              selectedIcon:
                  Icon(Icons.settings),
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
          Expanded(
            child: Column(
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
          color: Colors.white
              .withValues(
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
                .clamp(0.0, 1.0);

    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        header(
          'Light speed 🔥',
          'اتصال واقعی با sing-box',
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

        const SizedBox(height: 16),

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
            ),
          ),
        ),

        const SizedBox(height: 20),

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
                    const Text(
                      'دانلود',
                      style:
                          TextStyle(
                        color:
                            Colors.white54,
                      ),
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
                    const Text(
                      'آپلود',
                      style:
                          TextStyle(
                        color:
                            Colors.white54,
                      ),
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

              LinearProgressIndicator(
                value: percent,
                minHeight: 9,
              ),

              const SizedBox(
                height: 10,
              ),

              Text(
                'مصرف: ${size(usedBytes)}',
              ),

              const SizedBox(
                height: 5,
              ),

              Text(
                'باقی‌مانده: ${size(
                  totalBytes == null
                      ? null
                      : max(
                          0,
                          totalBytes! -
                              (usedBytes ??
                                  0),
                        ),
                )}',
              ),
            ],
          ),
        ),

        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment
                    .start,
            children: [
              const Text(
                'اطلاعات اشتراک',
                style:
                    TextStyle(
                  fontSize: 17,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 12,
              ),
              Text(
                'دانلود مصرف‌شده: ${size(downloadBytes)}',
              ),
              const SizedBox(
                height: 6,
              ),
              Text(
                'آپلود مصرف‌شده: ${size(uploadBytes)}',
              ),
              const SizedBox(
                height: 6,
              ),
              Text(
                'تاریخ انقضا: ${expireAt == null ? 'نامشخص' : _dateFromUnix(expireAt!)}',
              ),
              const SizedBox(
                height: 6,
              ),
              Text(
                'زمان باقی‌مانده: ${remainingTime()}',
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
              testing
                  ? null
                  : () => testAll(),
          icon: const Icon(
            Icons.speed,
          ),
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
            const Padding(
              padding:
                  EdgeInsets.all(20),
              child: Text(
                'هنوز سروری دریافت نشده است.',
                textAlign:
                    TextAlign.center,
              ),
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
                      maxLines: 1,
                      overflow:
                          TextOverflow
                              .ellipsis,
                    ),

                    trailing:
                        Column(
                      mainAxisAlignment:
                          MainAxisAlignment
                              .center,
                      children: [
                        Text(
                          server.ping ==
                                  null
                              ? '---'
                              : '${server.ping} ms',
                          style:
                              TextStyle(
                            color: server
                                        .ping ==
                                    null
                                ? Colors
                                    .white38
                                : server.ping! <
                                        150
                                    ? Colors
                                        .greenAccent
                                    : Colors
                                        .orangeAccent,
                          ),
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

  Widget _traffic() {
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
              'دانلود',
            ),
            subtitle:
                Text(download),
            leading:
                const Icon(
              Icons.download,
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'آپلود',
            ),
            subtitle:
                Text(upload),
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
              'حجم کل اشتراک',
            ),
            subtitle:
                Text(
              size(totalBytes),
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
              'مصرف کل اشتراک',
            ),
            subtitle:
                Text(
              size(usedBytes),
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
              'دانلود مصرف‌شده اشتراک',
            ),
            subtitle:
                Text(
              size(downloadBytes),
            ),
            leading:
                const Icon(
              Icons.download,
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'آپلود مصرف‌شده اشتراک',
            ),
            subtitle:
                Text(
              size(uploadBytes),
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
              'حجم باقی‌مانده',
            ),
            subtitle:
                Text(
              size(
                totalBytes ==
                        null
                    ? null
                    : max(
                        0,
                        totalBytes! -
                            (usedBytes ??
                                0),
                      ),
                ),
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

        card(
          ListTile(
            title:
                const Text(
              'زمان باقی‌مانده',
            ),
            subtitle:
                Text(
              remainingTime(),
            ),
            leading:
                const Icon(
              Icons.timer,
            ),
          ),
        ),

        card(
          ListTile(
            title:
                const Text(
              'دانلود این اتصال',
            ),
            subtitle:
                Text(
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
              'آپلود این اتصال',
            ),
            subtitle:
                Text(
              size(
                uploadTotalBytes,
              ),
            ),
            leading:
                const Icon(
              Icons.upload_file,
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
          maxLines: 2,
          decoration:
              const InputDecoration(
            labelText:
                'Subscription URL',
            hintText:
                'https://...',
            prefixIcon:
                Icon(Icons.link),
          ),
        ),

        const SizedBox(
          height: 12,
        ),

        FilledButton.icon(
          onPressed:
              loading
                  ? null
                  : () =>
                      loadSubscription(),
          icon: const Icon(
            Icons.refresh,
          ),
          label: Text(
            loading
                ? 'در حال دریافت...'
                : 'بروزرسانی',
          ),
        ),

        const SizedBox(
          height: 18,
        ),

        card(
          const ListTile(
            contentPadding:
                EdgeInsets.zero,
            leading: Icon(
              Icons.sync,
            ),
            title: Text(
              'بروزرسانی خودکار',
            ),
            subtitle: Text(
              'هر ۱۵ دقیقه، در صورت قطع بودن VPN',
            ),
          ),
        ),

        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,
            leading: const Icon(
              Icons.dns,
            ),
            title: const Text(
              'تعداد سرورها',
            ),
            subtitle:
                Text(
              '${servers.length}',
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
          const ListTile(
            leading:
                Icon(Icons.flash_on),
            title: Text(
              'انتخاب سریع‌ترین سرور',
            ),
            subtitle: Text(
              'ابتدا Ping سرورها بررسی می‌شود و سپس سریع‌ترین سرور برای اتصال انتخاب می‌شود.',
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
              'Subscription هر ۱۵ دقیقه بروزرسانی می‌شود.',
            ),
          ),
        ),

        card(
          ListTile(
            leading:
                const Icon(
              Icons.shield,
            ),
            title:
                const Text(
              'VPN Engine',
            ),
            subtitle:
                Text(
              'sing-box / Android VpnService\n$stateText',
            ),
          ),
        ),

        card(
          const ListTile(
            leading:
                Icon(Icons.info),
            title:
                Text(
              'Light speed 🔥',
            ),
            subtitle:
                Text(
              'Real VPN Client',
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
    timer?.cancel();
    url.dispose();

    super.dispose();
  }
}
