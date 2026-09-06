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
  StreamSubscription? faultSub;

  Timer? refreshTimer;
  Timer? durationTimer;

  int page = 0;

  bool loading = false;
  bool testing = false;
  bool connected = false;
  bool connecting = false;

  // true = بهترین سرور توسط sing-box
  // false = سرور انتخاب‌شده توسط کاربر
  bool autoSelect = true;

  int selectedServerIndex = 0;

  String stateText = 'آماده اتصال';

  String download = '0 Mbps';
  String upload = '0 Mbps';

  String lastFault = '';

  int downloadTotalBytes = 0;
  int uploadTotalBytes = 0;

  int? totalBytes;
  int? usedBytes;
  int? expireAt;

  DateTime? connectedAt;

  Duration connectionDuration = Duration.zero;

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

      try {
        setState(() {
          download = speed(s.downlinkBps);
          upload = speed(s.uplinkBps);

          downloadTotalBytes =
              (s.downlinkTotalBytes as num).toInt();

          uploadTotalBytes =
              (s.uplinkTotalBytes as num).toInt();
        });
      } catch (_) {}
    });

    try {
      faultSub = vpn.faultStream.listen((e) {
        if (!mounted) return;

        setState(() {
          lastFault = e.toString();
        });
      });
    } catch (_) {}

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

  Future<void> loadSaved() async {
    final p = await SharedPreferences.getInstance();

    final saved = p.getString('subscription_url');

    if (saved == null || saved.isEmpty) return;

    url.text = saved;

    await loadSubscription(silent: true);
  }

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final text = url.text.trim();

    if (text.isEmpty) {
      if (!silent && mounted) {
        setState(() {
          stateText = 'Subscription URL را وارد کن';
        });
      }
      return;
    }

    if (!silent && mounted) {
      setState(() {
        stateText = 'در حال دریافت سرورها...';
      });
    }

    if (mounted) {
      setState(() {
        loading = true;
      });
    }

    try {
      final response = await http.get(
        Uri.parse(text),
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

      final result = <Server>[];

      for (final line in decodeSubscription(body)) {
        final server = parseServer(line);

        if (server != null) {
          result.add(server);
        }
      }

      if (result.isEmpty) {
        throw Exception(
          'هیچ کانفیگ قابل استفاده‌ای پیدا نشد',
        );
      }

      final p = await SharedPreferences.getInstance();

      await p.setString(
        'subscription_url',
        text,
      );

      if (!mounted) return;

      setState(() {
        servers
          ..clear()
          ..addAll(result);

        selectedServerIndex = 0;

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
          'دریافت Subscription ناموفق بود:\n$e',
        );
      }
    }
  }

  void _readUserInfo(String? raw) {
    if (raw == null || raw.isEmpty) return;

    final values = <String, int>{};

    for (final item in raw.split(';')) {
      final parts = item.trim().split('=');

      if (parts.length == 2) {
        values[parts[0]] =
            int.tryParse(parts[1]) ?? 0;
      }
    }

    if (!mounted || values.isEmpty) return;

    setState(() {
      totalBytes = values['total'];

      usedBytes =
          (values['upload'] ?? 0) +
          (values['download'] ?? 0);

      expireAt = values['expire'];
    });
  }

  List<String> decodeSubscription(String body) {
    List<String> extractLinks(String text) {
      return text
          .split(RegExp(r'\r?\n'))
          .map((x) => x.trim())
          .where(
            (x) => RegExp(
              r'^[a-zA-Z][a-zA-Z0-9+.-]*://',
            ).hasMatch(x),
          )
          .toList();
    }

    var direct = extractLinks(body);

    if (direct.isNotEmpty) {
      return direct;
    }

    var decoded = body
        .trim()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');

    for (int i = 0; i < 3; i++) {
      try {
        decoded +=
            '=' * ((4 - decoded.length % 4) % 4);

        final text = utf8.decode(
          base64.decode(decoded),
          allowMalformed: true,
        );

        direct = extractLinks(text);

        if (direct.isNotEmpty) {
          return direct;
        }

        decoded = text
            .trim()
            .replaceAll(RegExp(r'\s+'), '')
            .replaceAll('-', '+')
            .replaceAll('_', '/');
      } catch (_) {
        break;
      }
    }

    return [];
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
        'hysteria',
        'tuic',
      ].contains(scheme)) {
        return null;
      }

      if (uri.host.isEmpty ||
          !uri.hasPort) {
        return null;
      }

      late Map<String, dynamic> outbound;

      if (scheme == 'vless') {
        outbound = vless(uri);
      } else if (scheme == 'trojan') {
        outbound = trojan(uri);
      } else if (scheme == 'ss') {
        outbound =
            shadowsocks(uri, raw) ?? {};
      } else if (scheme == 'tuic') {
        outbound = tuic(uri);
      } else {
        outbound = hysteria2(uri);
      }

      if (outbound.isEmpty) {
        return null;
      }

      final name = Uri.decodeComponent(
        uri.fragment.isEmpty
            ? '${scheme.toUpperCase()} ${uri.host}'
            : uri.fragment,
      );

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
      var data =
          raw.substring(raw.indexOf('://') + 3);

      data = data
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      data +=
          '=' * ((4 - data.length % 4) % 4);

      final decoded = utf8.decode(
        base64.decode(data),
        allowMalformed: true,
      );

      final map =
          json.decode(decoded)
              as Map<String, dynamic>;

      final host =
          '${map['add'] ?? ''}';

      final port =
          int.tryParse(
                '${map['port'] ?? ''}',
              ) ??
              0;

      final uuid =
          '${map['id'] ?? ''}';

      if (host.isEmpty ||
          port <= 0 ||
          uuid.isEmpty) {
        return null;
      }

      final outbound =
          <String, dynamic>{
        'type': 'vmess',
        'server': host,
        'server_port': port,
        'uuid': uuid,
        'security':
            '${map['scy'] ?? 'auto'}',
      };

      final tls =
          '${map['tls'] ?? ''}';

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
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> vless(
    Uri uri,
  ) {
    final p = uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'vless',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uri.userInfo,
    };

    if ((p['flow'] ?? '').isNotEmpty) {
      outbound['flow'] = p['flow'];
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

  Map<String, dynamic> trojan(
    Uri uri,
  ) {
    final p = uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'trojan',
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
        var data =
            raw.substring(
          raw.indexOf('://') + 3,
        );

        data = data
            .split('#')
            .first
            .replaceAll('-', '+')
            .replaceAll('_', '/');

        data +=
            '=' * ((4 - data.length % 4) % 4);

        user = utf8.decode(
          base64.decode(data),
          allowMalformed: true,
        );
      }

      final index = user.indexOf(':');

      if (index <= 0) {
        return null;
      }

      return {
        'type': 'shadowsocks',
        'server': uri.host,
        'server_port': uri.port,
        'method': Uri.decodeComponent(
          user.substring(0, index),
        ),
        'password': Uri.decodeComponent(
          user.substring(index + 1),
        ),
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> hysteria2(
    Uri uri,
  ) {
    final p = uri.queryParameters;

    return {
      'type': 'hysteria2',
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

  Map<String, dynamic> tuic(
    Uri uri,
  ) {
    final p = uri.queryParameters;

    return {
      'type': 'tuic',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uri.userInfo,
      'password':
          p['password'] ?? '',
      'congestion_control':
          p['congestion_control'] ??
              'bbr',
      'tls': {
        'enabled': true,
        'server_name':
            p['sni'] ?? uri.host,
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
    } else if (n == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        'service_name': path,
      };
    } else if (n == 'httpupgrade') {
      outbound['transport'] = {
        'type': 'httpupgrade',
        'path':
            path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': host,
      };
    } else if (n == 'h2' ||
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

  Future<void> testAll({
    bool silent = false,
  }) async {
    if (servers.isEmpty) return;

    if (!silent && mounted) {
      setState(() {
        testing = true;
        stateText =
            'در حال تست Ping...';
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

  String buildConfig() {
    if (servers.isEmpty) {
      throw Exception(
        'هیچ سروری وجود ندارد',
      );
    }

    final nodes =
        <Map<String, dynamic>>[];

    final tags = <String>[];

    for (int i = 0;
        i < servers.length;
        i++) {
      final outbound =
          Map<String, dynamic>.from(
        servers[i].outbound,
      );

      final tag = 'node-$i';

      outbound['tag'] = tag;

      nodes.add(outbound);
      tags.add(tag);
    }

    nodes.add({
      'type': 'direct',
      'tag': 'direct',
    });

    /*
     * فقط در حالت انتخاب خودکار
     * URLTest ساخته می‌شود.
     *
     * در حالت دستی:
     * route.final مستقیماً به node انتخاب‌شده
     * اشاره می‌کند.
     */
    if (autoSelect &&
        tags.length > 1) {
      nodes.add({
        'type': 'urltest',
        'tag': 'auto',
        'outbounds': tags,
        'url':
            'https://www.gstatic.com/generate_204',
        'interval': '3m',
        'tolerance': 50,
        'idle_timeout': '10m',
        'interrupt_exist_connections':
            true,
      });
    }

    String finalOutbound;

    if (autoSelect) {
      finalOutbound =
          tags.length > 1
              ? 'auto'
              : tags.first;
    } else {
      if (selectedServerIndex < 0 ||
          selectedServerIndex >=
              tags.length) {
        selectedServerIndex = 0;
      }

      finalOutbound =
          tags[selectedServerIndex];
    }

    /*
     * نکته مهم:
     *
     * dns_mode و dns_address عمداً
     * از TUN حذف شده‌اند.
     *
     * DNS از طریق DNS module و
     * hijack-dns route rule مدیریت می‌شود.
     */
    return jsonEncode({
      'log': {
        'level': 'info',
      },

      'dns': {
        'servers': [
          {
            'type': 'local',
            'tag': 'local',
          },
        ],
        'final': 'local',
        'strategy': 'ipv4_only',
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

      'outbounds': nodes,

      'route': {
        'override_android_vpn': true,

        'rules': [
          {
            'protocol': 'dns',
            'action': 'hijack-dns',
          },
        ],

        'final': finalOutbound,
      },
    });
  }

  Future<void> connect() async {
    if (servers.isEmpty) {
      snack(
        'ابتدا از بخش اشتراک کانفیگ را وارد کن',
      );
      return;
    }

    if (connected || connecting) {
      return;
    }

    if (!autoSelect &&
        (selectedServerIndex < 0 ||
            selectedServerIndex >=
                servers.length)) {
      selectedServerIndex = 0;
    }

    final selectedName =
        autoSelect
            ? 'بهترین سرور'
            : servers[
                selectedServerIndex
              ].name;

    setState(() {
      connecting = true;
      stateText =
          'در حال آماده‌سازی VPN...';
      lastFault = '';
    });

    try {
      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'اجازه VPN داده نشد',
        );
      }

      final config = buildConfig();

      setState(() {
        stateText =
            'در حال بررسی کانفیگ...';
      });

      await vpn.checkConfig(config);

      setState(() {
        stateText =
            'در حال اتصال به $selectedName...';
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
        connected = true;
        connecting = false;

        stateText = autoSelect
            ? 'متصل • بهترین سرور'
            : 'متصل • $selectedName';
      });

      connectedAt =
          DateTime.now();

      durationTimer?.cancel();

      durationTimer =
          Timer.periodic(
        const Duration(seconds: 1),
        (_) {
          if (!mounted ||
              !connected ||
              connectedAt == null) {
            return;
          }

          setState(() {
            connectionDuration =
                DateTime.now().difference(
              connectedAt!,
            );
          });
        },
      );
    } catch (e) {
      try {
        await vpn.disconnect();
      } catch (_) {}

      if (!mounted) return;

      setState(() {
        connecting = false;
        connected = false;
        stateText = 'اتصال ناموفق';
        lastFault = e.toString();
      });

      snack(
        'خطای VPN:\n$e',
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

      download = '0 Mbps';
      upload = '0 Mbps';

      downloadTotalBytes = 0;
      uploadTotalBytes = 0;

      connectionDuration =
          Duration.zero;
    });
  }

  void selectServer(int index) {
    if (index < 0 ||
        index >= servers.length) {
      return;
    }

    if (connected || connecting) {
      snack(
        'ابتدا اتصال VPN را قطع کن',
      );
      return;
    }

    setState(() {
      autoSelect = false;
      selectedServerIndex = index;

      stateText =
          'سرور انتخاب شد: ${servers[index].name}';
    });
  }

  void enableAutoSelection() {
    if (connected || connecting) {
      snack(
        'ابتدا اتصال VPN را قطع کن',
      );
      return;
    }

    setState(() {
      autoSelect = true;
      stateText =
          'انتخاب خودکار بهترین سرور فعال شد';
    });
  }

  String speed(dynamic bps) {
    final n = bps is num
        ? bps.toDouble()
        : 0.0;

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

    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String remaining() {
    if (expireAt == null ||
        expireAt! <= 0) {
      return 'نامشخص';
    }

    final expire =
        DateTime.fromMillisecondsSinceEpoch(
      expireAt! * 1000,
    );

    final difference =
        expire.difference(
      DateTime.now(),
    );

    if (difference.isNegative) {
      return 'منقضی شده';
    }

    return '${difference.inDays} روز و '
        '${difference.inHours % 24} ساعت';
  }

  String connectionTime() {
    final h = connectionDuration
        .inHours
        .toString()
        .padLeft(2, '0');

    final m = (connectionDuration
            .inMinutes %
        60)
        .toString()
        .padLeft(2, '0');

    final s = (connectionDuration
            .inSeconds %
        60)
        .toString()
        .padLeft(2, '0');

    return '$h:$m:$s';
  }

  void snack(String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content: Text(text),
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
              label: 'خانه',
            ),
            NavigationDestination(
              icon:
                  Icon(Icons.dns_outlined),
              label: 'سرورها',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.bar_chart_outlined,
              ),
              label: 'ترافیک',
            ),
            NavigationDestination(
              icon:
                  Icon(Icons.link_outlined),
              label: 'اشتراک',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.settings_outlined,
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
    final percent =
        totalBytes == null ||
                totalBytes! <= 0
            ? 0.0
            : ((usedBytes ?? 0) /
                    totalBytes!)
                .clamp(0.0, 1.0);

    final selectedName =
        servers.isEmpty
            ? 'هیچ سروری انتخاب نشده'
            : autoSelect
                ? 'بهترین سرور'
                : servers[
                    selectedServerIndex
                  ].name;

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
                    color:
                        (connected
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
                                    ? Icons.power
                                    : Icons.bolt,
                                size: 48,
                                color:
                                    connected
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

        const SizedBox(height: 10),

        Center(
          child: Text(
            selectedName,
            maxLines: 1,
            overflow:
                TextOverflow.ellipsis,
            style:
                const TextStyle(
              color: Colors.white54,
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
                child: Text(
                  servers.isEmpty
                      ? 'هنوز کانفیگی وارد نشده'
                      : '${servers.length} سرور آماده اتصال',
                ),
              ),

              if (servers.isNotEmpty)
                Text(
                  '${servers.where((s) => s.ping != null).length} تست',
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

            const SizedBox(width: 10),

            Expanded(
              child: card(
                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
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
                CrossAxisAlignment.start,
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
                'زمان باقی‌مانده: ${remaining()}',
              ),
            ],
          ),
        ),

        if (lastFault.isNotEmpty)
          card(
            ListTile(
              contentPadding:
                  EdgeInsets.zero,
              leading:
                  const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
              ),
              title:
                  const Text(
                'آخرین خطا',
              ),
              subtitle:
                  Text(lastFault),
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

        /*
         * انتخاب خودکار
         */
        card(
          SwitchListTile(
            contentPadding:
                EdgeInsets.zero,

            value: autoSelect,

            onChanged: (value) {
              if (connected ||
                  connecting) {
                snack(
                  'ابتدا VPN را قطع کن',
                );
                return;
              }

              setState(() {
                autoSelect = value;

                if (value) {
                  stateText =
                      'انتخاب خودکار بهترین سرور فعال شد';
                } else {
                  stateText =
                      'یک سرور را از لیست انتخاب کن';
                }
              });
            },

            title:
                const Text(
              'انتخاب خودکار',
              style:
                  TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            subtitle:
                Text(
              autoSelect
                  ? 'sing-box بهترین سرور را انتخاب می‌کند'
                  : 'انتخاب دستی فعال است',
            ),

            secondary:
                const Icon(
              Icons.flash_on,
            ),
          ),
        ),

        if (!autoSelect &&
            servers.isNotEmpty)
          card(
            ListTile(
              contentPadding:
                  EdgeInsets.zero,

              leading:
                  const Icon(
                Icons.touch_app,
              ),

              title:
                  const Text(
                'انتخاب دستی',
              ),

              subtitle:
                  Text(
                selectedServerIndex <
                        servers.length
                    ? servers[
                        selectedServerIndex
                      ].name
                    : 'انتخاب نشده',
              ),

              trailing:
                  const Icon(
                Icons.arrow_forward_ios,
                size: 16,
              ),
            ),
          ),

        FilledButton.icon(
          onPressed:
              testing
                  ? null
                  : () => testAll(),

          icon:
              const Icon(
            Icons.speed,
          ),

          label: Text(
            testing
                ? 'در حال تست...'
                : 'تست Ping همه سرورها',
          ),
        ),

        const SizedBox(
          height: 14,
        ),

        if (servers.isEmpty)
          card(
            const Center(
              child: Padding(
                padding:
                    EdgeInsets.all(24),
                child: Text(
                  'هنوز سروری وارد نشده است.\n'
                  'از بخش «اشتراک» Subscription را وارد کن.',
                  textAlign:
                      TextAlign.center,
                ),
              ),
            ),
          ),

        ...servers.asMap().entries.map(
          (entry) {
            final index =
                entry.key;

            final server =
                entry.value;

            final selected =
                !autoSelect &&
                index ==
                    selectedServerIndex;

            return card(
              ListTile(
                contentPadding:
                    EdgeInsets.zero,

                onTap: () =>
                    selectServer(index),

                leading:
                    CircleAvatar(
                  backgroundColor:
                      selected
                          ? const Color(
                              0xFF00E5FF,
                            )
                          : null,

                  child: selected
                      ? const Icon(
                          Icons.check,
                          color:
                              Colors.black,
                        )
                      : Text(
                          '${index + 1}',
                        ),
                ),

                title: Text(
                  server.name,
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
                ),

                subtitle:
                    Text(
                  '${server.type} • '
                  '${server.host}:'
                  '${server.port}',
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
                ),

                trailing:
                    Column(
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  crossAxisAlignment:
                      CrossAxisAlignment.end,
                  children: [
                    Text(
                      server.ping ==
                              null
                          ? '---'
                          : '${server.ping} ms',
                      style:
                          TextStyle(
                        color:
                            server.ping ==
                                    null
                                ? Colors.white54
                                : server.ping! <
                                        100
                                    ? const Color(
                                        0xFF00E676,
                                      )
                                    : server.ping! <
                                            200
                                        ? Colors.orange
                                        : Colors.redAccent,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    if (selected)
                      const Text(
                        'انتخاب شده',
                        style:
                            TextStyle(
                          fontSize: 11,
                          color:
                              Color(
                            0xFF00E5FF,
                          ),
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
                const Text('دانلود'),
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
                const Text('آپلود'),
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
              'آپلود این جلسه',
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
              size(
                totalBytes == null
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
              'مدت اتصال',
            ),
            subtitle:
                Text(connectionTime()),
            leading:
                const Icon(
              Icons.timer,
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
                        : () =>
                            loadSubscription(),

                icon:
                    const Icon(
                  Icons.refresh,
                ),

                label:
                    Text(
                  loading
                      ? 'در حال دریافت...'
                      : 'دریافت و بروزرسانی',
                ),
              ),
            ),

            const SizedBox(
              width: 8,
            ),

            IconButton(
              onPressed: () {
                setState(() {
                  url.clear();
                });
              },

              icon:
                  const Icon(
                Icons.clear,
              ),
            ),
          ],
        ),

        const SizedBox(
          height: 18,
        ),

        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                'تعداد سرورها: ${servers.length}',
              ),

              const SizedBox(
                height: 8,
              ),

              Text(
                'حجم کل: ${size(totalBytes)}',
              ),

              Text(
                'مصرف: ${size(usedBytes)}',
              ),

              Text(
                'زمان باقی‌مانده: ${remaining()}',
              ),

              const SizedBox(
                height: 8,
              ),

              const Text(
                'بروزرسانی خودکار: هر ۱۵ دقیقه',
                style:
                    TextStyle(
                  color:
                      Colors.white54,
                ),
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
          const EdgeInsets.all(18),
      children: [
        header(
          'تنظیمات',
          'Light speed',
        ),

        card(
          ListTile(
            leading:
                const Icon(
              Icons.flash_on,
            ),

            title:
                const Text(
              'انتخاب سرور',
            ),

            subtitle:
                Text(
              autoSelect
                  ? 'خودکار — بهترین سرور'
                  : selectedServerIndex <
                          servers.length
                      ? 'دستی — ${servers[selectedServerIndex].name}'
                      : 'دستی — انتخاب نشده',
            ),
          ),
        ),

        card(
          const ListTile(
            leading:
                Icon(Icons.language),
            title:
                Text('شبکه'),
            subtitle:
                Text('IPv4 / TUN'),
          ),
        ),

        card(
          const ListTile(
            leading:
                Icon(Icons.sync),
            title:
                Text('Auto Refresh'),
            subtitle:
                Text('هر ۱۵ دقیقه'),
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
              'sing-box / Android VpnService\n'
              '$stateText',
            ),
          ),
        ),

        if (lastFault.isNotEmpty)
          card(
            ListTile(
              leading:
                  const Icon(
                Icons.error_outline,
                color:
                    Colors.redAccent,
              ),

              title:
                  const Text(
                'آخرین خطا',
              ),

              subtitle:
                  Text(lastFault),
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
    durationTimer?.cancel();

    url.dispose();

    super.dispose();
  }
}
