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
  final url = TextEditingController();

  final servers = <Server>[];

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
  String vpnError = '';

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
          connecting = false;
        }

        if (low.contains('stopped') ||
            low.contains('disconnected')) {
          connected = false;
          connecting = false;
        }
      });
    });

    trafficSub = vpn.trafficStatsStream.listen((s) {
      if (!mounted) return;

      final dynamic x = s;

      try {
        setState(() {
          download = speed(x.downlinkBps);
          upload = speed(x.uplinkBps);

          try {
            final dynamic d = x.downlinkTotalBytes;

            if (d is num) {
              downloadTotalBytes = d.toInt();
            }
          } catch (_) {}

          try {
            final dynamic u = x.uplinkTotalBytes;

            if (u is num) {
              uploadTotalBytes = u.toInt();
            }
          } catch (_) {}
        });
      } catch (_) {}
    });

    faultSub = vpn.faultStream.listen((fault) {
      if (!mounted) return;

      final error = fault.toString();

      setState(() {
        connected = false;
        connecting = false;
        stateText = 'خطای VPN';
        vpnError = error;
      });

      snack('VPN: $error');
    });

    timer = Timer.periodic(
      const Duration(minutes: 15),
      (_) {
        if (!connected && !connecting) {
          loadSubscription(silent: true);
        }
      },
    );

    loadSaved();
  }

  Future<void> loadSaved() async {
    try {
      final p = await SharedPreferences.getInstance();

      final saved = p.getString('subscription_url');

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
    if (url.text.trim().isEmpty) {
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
      final r = await http
          .get(
            Uri.parse(url.text.trim()),
            headers: const {
              'User-Agent': 'LightSpeed/2.0',
              'Accept': '*/*',
            },
          )
          .timeout(
            const Duration(seconds: 20),
          );

      if (r.statusCode < 200 || r.statusCode >= 300) {
        throw Exception('HTTP ${r.statusCode}');
      }

      final body = utf8.decode(
        r.bodyBytes,
        allowMalformed: true,
      );

      _readUserInfo(
        r.headers['subscription-userinfo'],
      );

      final result = <Server>[];

      for (final line in decodeSubscription(body)) {
        final s = parseServer(line);

        if (s != null) {
          result.add(s);
        }
      }

      if (result.isEmpty) {
        throw Exception(
          'هیچ کانفیگ معتبری در Subscription پیدا نشد',
        );
      }

      final p = await SharedPreferences.getInstance();

      await p.setString(
        'subscription_url',
        url.text.trim(),
      );

      if (!mounted) return;

      setState(() {
        servers
          ..clear()
          ..addAll(result);

        loading = false;

        stateText = '${servers.length} سرور دریافت شد';
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
          'دریافت Subscription ناموفق بود\n$e',
        );
      }
    }
  }

  void _readUserInfo(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return;
    }

    final m = <String, int>{};

    for (final x in raw.split(';')) {
      final p = x.trim().split('=');

      if (p.length == 2) {
        final key = p[0].trim();

        final value = int.tryParse(
              p[1].trim(),
            ) ??
            0;

        m[key] = value;
      }
    }

    if (!mounted) return;

    setState(() {
      totalBytes = m['total'];

      usedBytes =
          (m['upload'] ?? 0) +
          (m['download'] ?? 0);

      expireAt = m['expire'];
    });
  }

  List<String> decodeSubscription(String body) {
    final direct = body
        .split(RegExp(r'\r?\n'))
        .map((x) => x.trim())
        .where(
          (x) =>
              x.contains('://') &&
              !x.startsWith('#'),
        )
        .toList();

    if (direct.isNotEmpty) {
      return direct;
    }

    try {
      var b = body.trim();

      b = b.replaceAll(
        RegExp(r'\s+'),
        '',
      );

      b = b
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      b += '=' *
          ((4 - b.length % 4) % 4);

      final decoded = utf8.decode(
        base64.decode(b),
        allowMalformed: true,
      );

      return decoded
          .split(RegExp(r'\r?\n'))
          .map((x) => x.trim())
          .where(
            (x) =>
                x.contains('://') &&
                !x.startsWith('#'),
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
      var b = raw.substring(
        raw.indexOf('://') + 3,
      );

      b = b
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      b += '=' *
          ((4 - b.length % 4) % 4);

      final decoded = utf8.decode(
        base64.decode(b),
        allowMalformed: true,
      );

      final m =
          json.decode(decoded)
              as Map<String, dynamic>;

      final host = '${m['add'] ?? ''}';

      final port =
          int.tryParse(
            '${m['port'] ?? ''}',
          ) ??
          0;

      final uuid = '${m['id'] ?? ''}';

      if (host.isEmpty ||
          port == 0 ||
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

      final tls =
          '${m['tls'] ?? ''}';

      final sni =
          '${m['sni'] ?? m['host'] ?? ''}';

      if (tls.isNotEmpty && tls != 'none') {
        out['tls'] = {
          'enabled': true,
          if (sni.isNotEmpty)
            'server_name': sni,
        };
      }

      addTransport(
        out,
        '${m['net'] ?? 'tcp'}',
        '${m['path'] ?? ''}',
        '${m['host'] ?? ''}',
      );

      return Server(
        raw: raw,
        name: m['ps'] ?? 'VMess',
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

    final sec =
        (p['security'] ?? '').toLowerCase();

    if (sec == 'tls' ||
        sec == 'reality') {
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

      if (sec == 'reality' &&
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

    final out = <String, dynamic>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': u.host,
      'server_port': u.port,
      'password': u.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            p['sni'] ??
            p['host'] ??
            u.host,
      },
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
        var b = raw
            .substring(
              raw.indexOf('://') + 3,
            )
            .split('#')
            .first;

        b = b
            .replaceAll('-', '+')
            .replaceAll('_', '/');

        b += '=' *
            ((4 - b.length % 4) % 4);

        user = utf8.decode(
          base64.decode(b),
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
        'server': u.host,
        'server_port': u.port,
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

  Map<String, dynamic> hysteria2(
    Uri u,
  ) {
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
        if (p['insecure'] == '1')
          'insecure': true,
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

  String makeConfig(Server s) {
    final out =
        Map<String, dynamic>.from(
      s.outbound,
    );

    out['tag'] = 'proxy';

    return jsonEncode({
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
          'auto_route': true,
          'strict_route': true,
          'stack': 'mixed',
          'mtu': 1500,
        },
      ],

      'outbounds': [
        out,
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

    for (final s in servers) {
      final sw = Stopwatch()..start();

      try {
        final socket =
            await Socket.connect(
          s.host,
          s.port,
          timeout:
              const Duration(
            seconds: 3,
          ),
        );

        socket.destroy();

        s.ping =
            sw.elapsedMilliseconds;
      } catch (_) {
        s.ping = null;
      }

      if (mounted && !silent) {
        setState(() {});
      }
    }

    servers.sort(
      (a, b) {
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
      },
    );

    if (mounted) {
      setState(() {
        testing = false;

        if (!silent) {
          stateText =
              'سرورها مرتب شدند';
        }
      });
    }
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
          a.ping!.compareTo(
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

    if (connected || connecting) {
      return;
    }

    setState(() {
      connecting = true;
      vpnError = '';
      stateText =
          'در حال انتخاب سریع‌ترین سرور...';
    });

    try {
      if (servers.every(
        (s) => s.ping == null,
      )) {
        await testAll(
          silent: true,
        );
      }

      final best = fastest();

      if (best == null) {
        setState(() {
          connecting = false;
          stateText =
              'سرور قابل اتصال پیدا نشد';
        });

        return;
      }

      setState(() {
        stateText =
            'در حال اتصال به ${best.name}...';
      });

      final ok =
          await vpn.requestVPNPermission();

      if (!ok) {
        throw Exception(
          'VPN permission denied',
        );
      }

      final config =
          makeConfig(best);

      await vpn.checkConfig(
        config,
      );

      await vpn.connect(
        SessionOptions(
          config: config,
          networkMode:
              NetworkMode.vpn,
          notification:
              NotificationConfig(
            title:
                'Light speed 🔥',
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
        connecting = false;
        connected = true;
        vpnError = '';
        stateText =
            'متصل • ${best.name}';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      final error = e.toString();

      setState(() {
        connecting = false;
        connected = false;
        vpnError = error;
        stateText =
            'اتصال ناموفق';
      });

      snack(
        'خطای VPN:\n$error',
      );
    }
  }

  Future<void> disconnect() async {
    try {
      await vpn.disconnect();
    } catch (_) {}

    if (mounted) {
      setState(() {
        connected = false;
        connecting = false;
        stateText =
            'اتصال قطع شد';
        vpnError = '';

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

  String size(int? n) {
    if (n == null || n <= 0) {
      return 'نامشخص';
    }

    if (n < 1024 * 1024) {
      return '${(n / 1024).toStringAsFixed(1)} KB';
    }

    if (n <
        1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
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

  String expireDate() {
    if (expireAt == null ||
        expireAt! <= 0) {
      return 'نامشخص';
    }

    final date =
        DateTime.fromMillisecondsSinceEpoch(
      expireAt! * 1000,
    );

    return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
  }

  void snack(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(text),
        duration:
            const Duration(
          seconds: 5,
        ),
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
              (i) {
            setState(() {
              page = i;
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
    String sub,
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
          const SizedBox(
            width: 12,
          ),
          Column(
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
              Text(
                sub,
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
            BorderRadius.circular(
          22,
        ),
        border:
            Border.all(
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
                .clamp(
                  0.0,
                  1.0,
                );

    return ListView(
      padding:
          const EdgeInsets.all(
        18,
      ),
      children: [
        header(
          'Light speed 🔥',
          'VPN واقعی با sing-box',
        ),

        const SizedBox(
          height: 8,
        ),

        Center(
          child:
              GestureDetector(
            onTap: connecting
                ? null
                : (connected
                    ? disconnect
                    : connect),
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
              child:
                  Center(
                child:
                    Container(
                  width: 176,
                  height: 176,
                  decoration:
                      const BoxDecoration(
                    shape:
                        BoxShape.circle,
                    color:
                        Color(
                      0xFF081322,
                    ),
                  ),
                  child:
                      Center(
                    child: connecting
                        ? const CircularProgressIndicator()
                        : Column(
                            mainAxisAlignment:
                                MainAxisAlignment.center,
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
            ),
          ),
        ),

        if (vpnError.isNotEmpty) ...[
          const SizedBox(
            height: 12,
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
                      Icons.error_outline,
                      color:
                          Colors.redAccent,
                    ),
                    const SizedBox(
                      width: 8,
                    ),
                    const Expanded(
                      child: Text(
                        'جزئیات خطای VPN',
                        style:
                            TextStyle(
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(
                  height: 10,
                ),
                SelectableText(
                  vpnError,
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

        const SizedBox(
          height: 8,
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
                            FontWeight
                                .bold,
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
                            FontWeight
                                .bold,
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
                height: 8,
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
              Row(
                children: [
                  const Icon(
                    Icons.event,
                    color:
                        Color(0xFF00E5FF),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  const Expanded(
                    child: Text(
                      'تاریخ انقضا',
                    ),
                  ),
                  Text(
                    expireDate(),
                  ),
                ],
              ),
              const SizedBox(
                height: 8,
              ),
              Row(
                children: [
                  const Icon(
                    Icons.timer_outlined,
                    color:
                        Color(0xFF7C4DFF),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  const Expanded(
                    child: Text(
                      'زمان باقی‌مانده',
                    ),
                  ),
                  Text(
                    remainingTime(),
                  ),
                ],
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
          const EdgeInsets.all(
        18,
      ),
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
                : 'تست Ping',
          ),
        ),

        const SizedBox(
          height: 14,
        ),

        if (servers.isEmpty)
          card(
            const Center(
              child: Text(
                'هنوز سروری دریافت نشده است.',
              ),
            ),
          ),

        ...servers
            .asMap()
            .entries
            .map(
              (e) => card(
                ListTile(
                  contentPadding:
                      EdgeInsets.zero,
                  leading:
                      CircleAvatar(
                    child: Text(
                      '${e.key + 1}',
                    ),
                  ),
                  title: Text(
                    e.value.name,
                    maxLines: 1,
                    overflow:
                        TextOverflow
                            .ellipsis,
                  ),
                  subtitle: Text(
                    '${e.value.type} • ${e.value.host}:${e.value.port}',
                    maxLines: 2,
                    overflow:
                        TextOverflow
                            .ellipsis,
                  ),
                  trailing: Text(
                    e.value.ping ==
                            null
                        ? '---'
                        : '${e.value.ping} ms',
                  ),
                ),
              ),
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
          const EdgeInsets.all(
        18,
      ),
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
              'حجم مصرف‌شده اشتراک',
            ),
            subtitle:
                Text(
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
              'مصرف دانلود این جلسه',
            ),
            subtitle:
                Text(
              size(
                downloadTotalBytes,
              ),
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
              'مصرف آپلود این جلسه',
            ),
            subtitle:
                Text(
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
              'حجم باقی‌مانده',
            ),
            subtitle:
                Text(
              size(remaining),
            ),
            leading:
                const Icon(
              Icons.storage,
            ),
          ),
        ),
      ],
    );
  }

  Widget _subscription() {
    return ListView(
      padding:
          const EdgeInsets.all(
        18,
      ),
      children: [
        header(
          'Subscription',
          'مدیریت اشتراک',
        ),

        TextField(
          controller: url,
          textDirection:
              TextDirection.ltr,
          maxLines: 3,
          decoration:
              const InputDecoration(
            labelText:
                'Subscription URL',
            hintText:
                'https://...',
            prefixIcon:
                Icon(Icons.link),
            border:
                OutlineInputBorder(),
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
            leading: Icon(
              Icons.sync,
              color:
                  Color(0xFF00E5FF),
            ),
            title: Text(
              'بروزرسانی خودکار',
            ),
            subtitle: Text(
              'هر ۱۵ دقیقه در زمان قطع بودن VPN',
            ),
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
                'حجم کل: ${size(totalBytes)}',
              ),
              const SizedBox(
                height: 6,
              ),
              Text(
                'مصرف: ${size(usedBytes)}',
              ),
              const SizedBox(
                height: 6,
              ),
              Text(
                'انقضا: ${expireDate()}',
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

  Widget _settings() {
    return ListView(
      padding:
          const EdgeInsets.all(
        18,
      ),
      children: [
        header(
          'تنظیمات',
          'Light speed',
        ),

        card(
          const ListTile(
            leading: Icon(
              Icons.flash_on,
            ),
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
            leading: Icon(
              Icons.sync,
            ),
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
            leading: Icon(
              Icons.info_outline,
            ),
            title: Text(
              'Light speed 🔥',
            ),
            subtitle: Text(
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
    faultSub?.cancel();
    timer?.cancel();

    url.dispose();

    super.dispose();
  }
}
