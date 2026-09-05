import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_singbox_client/flutter_singbox_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

final SingboxClient singbox = SingboxClient();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await singbox.initialize();

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
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF07101F),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E5FF),
          brightness: Brightness.dark,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0D1728),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: const LightSpeedHome(),
    );
  }
}

class ServerConfig {
  ServerConfig({
    required this.name,
    required this.protocol,
    required this.host,
    required this.port,
    required this.raw,
    required this.outbound,
  });

  final String name;
  final String protocol;
  final String host;
  final int port;
  final String raw;
  final Map<String, dynamic> outbound;

  int? ping;
}

class LightSpeedHome extends StatefulWidget {
  const LightSpeedHome({super.key});

  @override
  State<LightSpeedHome> createState() => _LightSpeedHomeState();
}

class _LightSpeedHomeState extends State<LightSpeedHome> {
  final TextEditingController subscriptionController =
      TextEditingController();

  final List<ServerConfig> servers = [];

  StreamSubscription? stateSubscription;
  StreamSubscription? trafficSubscription;
  StreamSubscription? faultSubscription;

  Timer? refreshTimer;

  int selectedPage = 0;

  bool loading = false;
  bool testing = false;
  bool connecting = false;
  bool connected = false;

  String status = 'آماده اتصال';

  String downloadSpeed = '0 KB/s';
  String uploadSpeed = '0 KB/s';

  int? totalTraffic;
  int? usedTraffic;
  int? expireTime;

  @override
  void initState() {
    super.initState();

    stateSubscription = singbox.serviceStateStream.listen((state) {
      if (!mounted) return;

      setState(() {
        status = state.toString();

        connected = state == ServiceState.started;
      });
    });

    trafficSubscription = singbox.trafficStatsStream.listen((stats) {
      if (!mounted) return;

      setState(() {
        downloadSpeed = formatSpeed(stats.downlinkBps);
        uploadSpeed = formatSpeed(stats.uplinkBps);
      });
    });

    faultSubscription = singbox.faultStream.listen((error) {
      if (!mounted) return;

      setState(() {
        status = 'خطای VPN';
        connecting = false;
        connected = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطای sing-box: $error'),
        ),
      );
    });

    refreshTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => loadSubscription(silent: true),
    );

    loadSavedSubscription();
  }

  Future<void> loadSavedSubscription() async {
    final prefs = await SharedPreferences.getInstance();

    final saved = prefs.getString('subscription_url');

    if (saved == null || saved.isEmpty) return;

    subscriptionController.text = saved;

    await loadSubscription(silent: true);
  }

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final subscriptionUrl = subscriptionController.text.trim();

    if (subscriptionUrl.isEmpty) {
      if (!silent) {
        showMessage('ابتدا Subscription URL را وارد کن');
      }
      return;
    }

    setState(() {
      loading = true;
      status = 'در حال دریافت Subscription...';
    });

    try {
      final response = await http.get(
        Uri.parse(subscriptionUrl),
        headers: const {
          'User-Agent': 'LightSpeed/1.0',
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

      readSubscriptionInfo(
        response.headers['subscription-userinfo'],
      );

      final body = utf8.decode(
        response.bodyBytes,
        allowMalformed: true,
      );

      final lines = decodeSubscription(body);

      final parsed = <ServerConfig>[];

      for (final line in lines) {
        final server = parseServer(line);

        if (server != null) {
          parsed.add(server);
        }
      }

      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(
        'subscription_url',
        subscriptionUrl,
      );

      if (!mounted) return;

      setState(() {
        servers
          ..clear()
          ..addAll(parsed);

        loading = false;

        status = '${servers.length} سرور دریافت شد';
      });

      await testServers(silent: true);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        status = 'خطا در دریافت Subscription';
      });

      if (!silent) {
        showMessage(
          'دریافت Subscription ناموفق بود',
        );
      }
    }
  }

  void readSubscriptionInfo(String? header) {
    if (header == null || header.isEmpty) return;

    final values = <String, int>{};

    for (final item in header.split(';')) {
      final parts = item.trim().split('=');

      if (parts.length != 2) continue;

      values[parts[0]] =
          int.tryParse(parts[1]) ?? 0;
    }

    if (!mounted) return;

    setState(() {
      final upload = values['upload'] ?? 0;
      final download = values['download'] ?? 0;

      totalTraffic = values['total'];
      usedTraffic = upload + download;
      expireTime = values['expire'];
    });
  }

  List<String> decodeSubscription(String body) {
    final directLines = body
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where(
          (e) => e.contains('://'),
        )
        .toList();

    if (directLines.isNotEmpty) {
      return directLines;
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
          .where(
            (e) => e.contains('://'),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  ServerConfig? parseServer(String raw) {
    try {
      final uri = Uri.parse(raw);

      final scheme = uri.scheme.toLowerCase();

      if (scheme == 'vmess') {
        return parseVmess(raw);
      }

      if (scheme == 'vless') {
        return parseVless(uri, raw);
      }

      if (scheme == 'trojan') {
        return parseTrojan(uri, raw);
      }

      if (scheme == 'ss') {
        return parseShadowsocks(uri, raw);
      }

      if (scheme == 'hysteria2' ||
          scheme == 'hy2') {
        return parseHysteria2(uri, raw);
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  ServerConfig? parseVless(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty || !uri.hasPort) {
      return null;
    }

    final query = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uri.userInfo,
    };

    if ((query['flow'] ?? '').isNotEmpty) {
      outbound['flow'] = query['flow'];
    }

    configureTls(
      outbound,
      query,
      uri.host,
    );

    configureTransport(
      outbound,
      query,
    );

    return ServerConfig(
      name: decodeName(
        uri.fragment,
        'VLESS ${uri.host}',
      ),
      protocol: 'VLESS',
      host: uri.host,
      port: uri.port,
      raw: raw,
      outbound: outbound,
    );
  }

  ServerConfig? parseTrojan(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty || !uri.hasPort) {
      return null;
    }

    final query = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'password': uri.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            query['sni'] ??
            query['host'] ??
            uri.host,
      },
    };

    configureTransport(
      outbound,
      query,
    );

    return ServerConfig(
      name: decodeName(
        uri.fragment,
        'Trojan ${uri.host}',
      ),
      protocol: 'TROJAN',
      host: uri.host,
      port: uri.port,
      raw: raw,
      outbound: outbound,
    );
  }

  ServerConfig? parseShadowsocks(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty || !uri.hasPort) {
      return null;
    }

    String userInfo = uri.userInfo;

    try {
      if (userInfo.isEmpty) {
        var encoded =
            raw.substring(raw.indexOf('://') + 3);

        encoded = encoded.split('#').first;

        encoded = encoded
            .replaceAll('-', '+')
            .replaceAll('_', '/');

        encoded += '=' *
            ((4 - encoded.length % 4) % 4);

        userInfo = utf8.decode(
          base64.decode(encoded),
        );
      }

      final index = userInfo.indexOf(':');

      if (index <= 0) return null;

      final method =
          Uri.decodeComponent(
        userInfo.substring(0, index),
      );

      final password =
          Uri.decodeComponent(
        userInfo.substring(index + 1),
      );

      return ServerConfig(
        name: decodeName(
          uri.fragment,
          'Shadowsocks ${uri.host}',
        ),
        protocol: 'SS',
        host: uri.host,
        port: uri.port,
        raw: raw,
        outbound: {
          'type': 'shadowsocks',
          'tag': 'proxy',
          'server': uri.host,
          'server_port': uri.port,
          'method': method,
          'password': password,
        },
      );
    } catch (_) {
      return null;
    }
  }

  ServerConfig? parseHysteria2(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty || !uri.hasPort) {
      return null;
    }

    final query = uri.queryParameters;

    return ServerConfig(
      name: decodeName(
        uri.fragment,
        'Hysteria2 ${uri.host}',
      ),
      protocol: 'HY2',
      host: uri.host,
      port: uri.port,
      raw: raw,
      outbound: {
        'type': 'hysteria2',
        'tag': 'proxy',
        'server': uri.host,
        'server_port': uri.port,
        'password': uri.userInfo,
        'tls': {
          'enabled': true,
          'server_name':
              query['sni'] ??
              query['peer'] ??
              uri.host,
          if (query['insecure'] == '1')
            'insecure': true,
        },
      },
    );
  }

  ServerConfig? parseVmess(String raw) {
    try {
      var encoded =
          raw.substring(raw.indexOf('://') + 3);

      encoded = encoded
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      encoded += '=' *
          ((4 - encoded.length % 4) % 4);

      final jsonText = utf8.decode(
        base64.decode(encoded),
      );

      final data =
          jsonDecode(jsonText) as Map<String, dynamic>;

      final host =
          '${data['add'] ?? ''}';

      final port =
          int.tryParse(
                '${data['port'] ?? ''}',
              ) ??
              0;

      final uuid =
          '${data['id'] ?? ''}';

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
            '${data['scy'] ?? 'auto'}',
      };

      final tls =
          '${data['tls'] ?? ''}';

      final sni =
          '${data['sni'] ?? data['host'] ?? ''}';

      if (tls.isNotEmpty && tls != 'none') {
        outbound['tls'] = {
          'enabled': true,
          if (sni.isNotEmpty)
            'server_name': sni,
        };
      }

      final network =
          '${data['net'] ?? 'tcp'}';

      configureVmessTransport(
        outbound,
        network,
        '${data['path'] ?? ''}',
        '${data['host'] ?? ''}',
      );

      return ServerConfig(
        name:
            '${data['ps'] ?? 'VMess'}',
        protocol: 'VMESS',
        host: host,
        port: port,
        raw: raw,
        outbound: outbound,
      );
    } catch (_) {
      return null;
    }
  }

  void configureTls(
    Map<String, dynamic> outbound,
    Map<String, String> query,
    String host,
  ) {
    final security =
        (query['security'] ?? '')
            .toLowerCase();

    if (security != 'tls' &&
        security != 'reality') {
      return;
    }

    final tls = <String, dynamic>{
      'enabled': true,
      'server_name':
          query['sni'] ??
          query['host'] ??
          host,
    };

    if ((query['fp'] ?? '').isNotEmpty) {
      tls['utls'] = {
        'enabled': true,
        'fingerprint': query['fp'],
      };
    }

    if (security == 'reality' &&
        (query['pbk'] ?? '').isNotEmpty) {
      tls['reality'] = {
        'enabled': true,
        'public_key': query['pbk'],
        if ((query['sid'] ?? '').isNotEmpty)
          'short_id': query['sid'],
      };
    }

    outbound['tls'] = tls;
  }

  void configureTransport(
    Map<String, dynamic> outbound,
    Map<String, String> query,
  ) {
    final network =
        (query['type'] ??
                query['network'] ??
                'tcp')
            .toLowerCase();

    final path =
        query['path'] ?? '';

    final host =
        query['host'] ?? '';

    configureVmessTransport(
      outbound,
      network,
      path,
      host,
    );
  }

  void configureVmessTransport(
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

  String buildSingboxConfig(
    ServerConfig server,
  ) {
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
          'auto_route': true,
          'strict_route': true,
          'stack': 'mixed',
        },
      ],

      'outbounds': [
        server.outbound,
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
        'final': 'proxy',
      },
    });
  }

  Future<void> testServers({
    bool silent = false,
  }) async {
    if (servers.isEmpty) return;

    if (!silent && mounted) {
      setState(() {
        testing = true;
        status = 'در حال تست سرورها...';
      });
    }

    for (final server in servers) {
      final stopwatch = Stopwatch()
        ..start();

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

      return a.ping!
          .compareTo(b.ping!);
    });

    if (mounted) {
      setState(() {
        testing = false;

        if (!silent) {
          status = 'تست سرورها تمام شد';
        }
      });
    }
  }

  ServerConfig? fastestServer() {
    final available =
        servers
            .where(
              (server) =>
                  server.ping != null,
            )
            .toList();

    if (available.isEmpty) {
      return null;
    }

    available.sort(
      (a, b) =>
          a.ping!.compareTo(
        b.ping!,
      ),
    );

    return available.first;
  }

  Future<void> connectVPN() async {
    if (servers.isEmpty) {
      showMessage(
        'ابتدا Subscription را دریافت کن',
      );
      return;
    }

    setState(() {
      connecting = true;
      status =
          'در حال پیدا کردن سریع‌ترین سرور...';
    });

    if (servers.every(
      (server) => server.ping == null,
    )) {
      await testServers(
        silent: true,
      );
    }

    final server = fastestServer();

    if (server == null) {
      setState(() {
        connecting = false;
        status =
            'سرور قابل دسترسی پیدا نشد';
      });

      return;
    }

    try {
      final permission =
          await singbox
              .requestVPNPermission();

      if (!permission) {
        throw Exception(
          'VPN permission denied',
        );
      }

      final config =
          buildSingboxConfig(server);

      await singbox.checkConfig(
        config,
      );

      await singbox.connect(
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

      if (!mounted) return;

      setState(() {
        connecting = false;
        connected = true;
        status =
            'متصل • ${server.name}';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        connecting = false;
        connected = false;
        status = 'اتصال ناموفق';
      });

      showMessage(
        'خطای اتصال VPN:\n$e',
      );
    }
  }

  Future<void> disconnectVPN() async {
    try {
      await singbox.disconnect();
    } catch (_) {}

    if (!mounted) return;

    setState(() {
      connected = false;
      connecting = false;
      status = 'اتصال قطع شد';
      downloadSpeed = '0 KB/s';
      uploadSpeed = '0 KB/s';
    });
  }

  String decodeName(
    String value,
    String fallback,
  ) {
    if (value.isEmpty) {
      return fallback;
    }

    try {
      return Uri.decodeComponent(
        value,
      );
    } catch (_) {
      return value;
    }
  }

  String formatSpeed(int value) {
    if (value < 1024) {
      return '$value B/s';
    }

    if (value < 1024 * 1024) {
      return '${(value / 1024).toStringAsFixed(1)} KB/s';
    }

    return '${(value / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }

  String formatBytes(int? value) {
    if (value == null || value <= 0) {
      return 'نامشخص';
    }

    if (value < 1024 * 1024) {
      return '${(value / 1024).toStringAsFixed(1)} KB';
    }

    if (value < 1024 * 1024 * 1024) {
      return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    return '${(value / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final pages = [
      buildHome(),
      buildServers(),
      buildTraffic(),
      buildSubscription(),
      buildSettings(),
    ];

    return Directionality(
      textDirection:
          TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: pages[selectedPage],
        ),
        bottomNavigationBar:
            NavigationBar(
          selectedIndex:
              selectedPage,
          onDestinationSelected:
              (index) {
            setState(() {
              selectedPage = index;
            });
          },
          destinations: const [
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

  Widget buildHeader(
    String title,
    String subtitle,
  ) {
    return Row(
      children: [
        Container(
          width: 50,
          height: 50,
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
                color:
                    Colors.white54,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget appCard(
    Widget child,
  ) {
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
              Colors.white.withOpacity(
            .06,
          ),
        ),
      ),
      child: child,
    );
  }

  Widget buildHome() {
    final fastest =
        fastestServer();

    double usage = 0;

    if (totalTraffic != null &&
        totalTraffic! > 0) {
      usage =
          ((usedTraffic ?? 0) /
                  totalTraffic!)
              .clamp(0.0, 1.0);
    }

    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        buildHeader(
          'Light speed 🔥',
          'VPN سریع و امن',
        ),

        const SizedBox(height: 20),

        Center(
          child: GestureDetector(
            onTap: connecting
                ? null
                : connected
                    ? disconnectVPN
                    : connectVPN,
            child: Container(
              width: 210,
              height: 210,
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
                    color:
                        (connected
                                ? const Color(
                                    0xFF00E676,
                                  )
                                : const Color(
                                    0xFF00E5FF,
                                  ))
                            .withOpacity(
                          .30,
                        ),
                    blurRadius: 45,
                    spreadRadius: 8,
                  ),
                ],
              ),
              child: Center(
                child: Container(
                  width: 185,
                  height: 185,
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
                                size: 50,
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

        const SizedBox(height: 18),

        Center(
          child: Text(
            status,
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

        appCard(
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
                    Text(
                      fastest?.name ??
                          'انتخاب نشده',
                      maxLines: 1,
                      overflow:
                          TextOverflow
                              .ellipsis,
                    ),
                  ],
                ),
              ),
              if (fastest?.ping != null)
                Text(
                  '${fastest!.ping} ms',
                ),
            ],
          ),
        ),

        Row(
          children: [
            Expanded(
              child: appCard(
                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    const Icon(
                      Icons.download,
                      color:
                          Color(0xFF00E5FF),
                    ),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text(
                      'دانلود',
                      style:
                          TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                    Text(
                      downloadSpeed,
                      style:
                          const TextStyle(
                        fontSize: 17,
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
              child: appCard(
                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    const Icon(
                      Icons.upload,
                      color:
                          Color(0xFF7C4DFF),
                    ),
                    const SizedBox(
                      height: 8,
                    ),
                    const Text(
                      'آپلود',
                      style:
                          TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                    Text(
                      uploadSpeed,
                      style:
                          const TextStyle(
                        fontSize: 17,
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

        appCard(
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
                      'مصرف اشتراک',
                    ),
                  ),
                  Text(
                    formatBytes(
                      totalTraffic,
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 14,
              ),
              LinearProgressIndicator(
                value: usage,
                minHeight: 9,
              ),
              const SizedBox(
                height: 10,
              ),
              Text(
                'مصرف‌شده: ${formatBytes(usedTraffic)}',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildServers() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        buildHeader(
          'سرورها',
          '${servers.length} سرور',
        ),

        FilledButton.icon(
          onPressed:
              testing
                  ? null
                  : () =>
                      testServers(),
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
          height: 16,
        ),

        ...servers.map(
          (server) => appCard(
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
                  server.protocol
                      .substring(
                    0,
                    1,
                  ),
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
                '${server.protocol} • ${server.host}:${server.port}',
                maxLines: 1,
                overflow:
                    TextOverflow
                        .ellipsis,
              ),
              trailing: Text(
                server.ping == null
                    ? '---'
                    : '${server.ping} ms',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget buildTraffic() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        buildHeader(
          'ترافیک',
          'آمار اتصال VPN',
        ),

        appCard(
          ListTile(
            leading: const Icon(
              Icons.download,
              color:
                  Color(0xFF00E5FF),
            ),
            title:
                const Text('دانلود'),
            subtitle:
                Text(downloadSpeed),
          ),
        ),

        appCard(
          ListTile(
            leading: const Icon(
              Icons.upload,
              color:
                  Color(0xFF7C4DFF),
            ),
            title:
                const Text('آپلود'),
            subtitle:
                Text(uploadSpeed),
          ),
        ),

        appCard(
          ListTile(
            leading: const Icon(
              Icons.data_usage,
            ),
            title: const Text(
              'مصرف‌شده',
            ),
            subtitle: Text(
              formatBytes(
                usedTraffic,
              ),
            ),
          ),
        ),

        appCard(
          ListTile(
            leading: const Icon(
              Icons.storage,
            ),
            title: const Text(
              'حجم کل',
            ),
            subtitle: Text(
              formatBytes(
                totalTraffic,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget buildSubscription() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        buildHeader(
          'Subscription',
          'مدیریت اشتراک',
        ),

        TextField(
          controller:
              subscriptionController,
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
          height: 16,
        ),

        appCard(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment
                    .start,
            children: [
              const Text(
                'حجم کل',
                style:
                    TextStyle(
                  color:
                      Colors.white54,
                ),
              ),
              Text(
                formatBytes(
                  totalTraffic,
                ),
                style:
                    const TextStyle(
                  fontSize: 22,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ],
          ),
        ),

        appCard(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment
                    .start,
            children: [
              const Text(
                'مصرف‌شده',
                style:
                    TextStyle(
                  color:
                      Colors.white54,
                ),
              ),
              Text(
                formatBytes(
                  usedTraffic,
                ),
                style:
                    const TextStyle(
                  fontSize: 22,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ],
          ),
        ),

        appCard(
          const Text(
            'اشتراک به‌صورت خودکار هر ۱۵ دقیقه بررسی می‌شود.',
          ),
        ),
      ],
    );
  }

  Widget buildSettings() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        buildHeader(
          'تنظیمات',
          'Light speed 🔥',
        ),

        appCard(
          const ListTile(
            leading: Icon(
              Icons.flash_on,
              color:
                  Color(0xFF00E5FF),
            ),
            title: Text(
              'انتخاب سریع‌ترین سرور',
            ),
            subtitle: Text(
              'انتخاب بر اساس TCP latency',
            ),
          ),
        ),

        appCard(
          const ListTile(
            leading: Icon(
              Icons.sync,
            ),
            title: Text(
              'بروزرسانی خودکار',
            ),
            subtitle: Text(
              'هر ۱۵ دقیقه',
            ),
          ),
        ),

        appCard(
          ListTile(
            leading: const Icon(
              Icons.security,
              color:
                  Color(0xFF00E676),
            ),
            title: const Text(
              'VPN Engine',
            ),
            subtitle: Text(
              connected
                  ? 'sing-box • فعال'
                  : 'sing-box • متوقف',
            ),
          ),
        ),

        appCard(
          const ListTile(
            leading: Icon(
              Icons.shield,
            ),
            title: Text(
              'TUN / Android VPN',
            ),
            subtitle: Text(
              'Device-wide VPN tunnel',
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    stateSubscription?.cancel();
    trafficSubscription?.cancel();
    faultSubscription?.cancel();
    refreshTimer?.cancel();
    subscriptionController.dispose();

    super.dispose();
  }
}
