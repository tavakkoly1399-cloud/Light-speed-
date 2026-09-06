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
  final TextEditingController urlController =
      TextEditingController();

  final List<Server> servers = [];

  StreamSubscription? stateSubscription;
  StreamSubscription? trafficSubscription;
  StreamSubscription? faultSubscription;

  Timer? refreshTimer;
  Timer? durationTimer;

  bool connected = false;
  bool connecting = false;
  bool loading = false;
  bool testing = false;

  String stateText = 'آماده اتصال';
  String lastFault = '';

  double downloadBps = 0;
  double uploadBps = 0;

  int downloadTotalBytes = 0;
  int uploadTotalBytes = 0;

  int? totalBytes;
  int? usedBytes;
  int? expireAt;

  DateTime? connectedAt;
  Duration connectionDuration = Duration.zero;

  final List<double> downloadHistory = [];
  final List<double> uploadHistory = [];

  @override
  void initState() {
    super.initState();

    _listenState();
    _listenTraffic();
    _listenFaults();

    refreshTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) {
        if (!connected) {
          loadSubscription(silent: true);
        }
      },
    );

    loadSavedSubscription();
  }

  void _listenState() {
    stateSubscription =
        vpn.serviceStateStream.listen((state) {
      if (!mounted) return;

      final value = state.toString().toLowerCase();

      if (value.contains('started')) {
        setState(() {
          connected = true;
          connecting = false;
          stateText = 'متصل';
          connectedAt ??= DateTime.now();
        });

        _startDuration();
      } else if (value.contains('stopped')) {
        setState(() {
          connected = false;
          connecting = false;
          stateText = 'قطع شد';
        });

        durationTimer?.cancel();
      } else if (value.contains('starting')) {
        setState(() {
          connecting = true;
          stateText = 'در حال اتصال...';
        });
      } else if (value.contains('stopping')) {
        setState(() {
          stateText = 'در حال قطع اتصال...';
        });
      }
    });
  }

  void _listenTraffic() {
    trafficSubscription =
        vpn.trafficStatsStream.listen((stats) {
      if (!mounted) return;

      setState(() {
        downloadBps = max(
          0,
          stats.downlinkBps.toDouble(),
        );

        uploadBps = max(
          0,
          stats.uplinkBps.toDouble(),
        );

        downloadTotalBytes =
            max(0, stats.downlinkTotalBytes);

        uploadTotalBytes =
            max(0, stats.uplinkTotalBytes);

        _addHistory(
          downloadHistory,
          downloadBps,
        );

        _addHistory(
          uploadHistory,
          uploadBps,
        );
      });
    });
  }

  void _listenFaults() {
    faultSubscription =
        vpn.faultStream.listen((fault) {
      if (!mounted) return;

      final message = fault.toString();

      setState(() {
        lastFault = message;
      });
    });
  }

  void _addHistory(
    List<double> list,
    double value,
  ) {
    list.add(value);

    if (list.length > 40) {
      list.removeAt(0);
    }
  }

  Future<void> loadSavedSubscription() async {
    final prefs =
        await SharedPreferences.getInstance();

    final saved =
        prefs.getString('subscription_url');

    if (saved == null || saved.isEmpty) {
      return;
    }

    urlController.text = saved;

    await loadSubscription(silent: true);
  }

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final url = urlController.text.trim();

    if (url.isEmpty) {
      if (!silent) {
        _showMessage(
          'آدرس Subscription وارد نشده است',
        );
      }
      return;
    }

    if (mounted) {
      setState(() {
        loading = true;

        if (!silent) {
          stateText =
              'در حال دریافت اشتراک...';
        }
      });
    }

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: const {
          'User-Agent': 'LightSpeed/1.0',
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

      _parseSubscriptionInfo(
        response.headers[
          'subscription-userinfo'
        ],
      );

      final parsed = <Server>[];

      for (final line
          in _decodeSubscription(body)) {
        final server = _parseServer(line);

        if (server != null) {
          parsed.add(server);
        }
      }

      final prefs =
          await SharedPreferences.getInstance();

      await prefs.setString(
        'subscription_url',
        url,
      );

      if (!mounted) return;

      setState(() {
        servers
          ..clear()
          ..addAll(parsed);

        loading = false;

        stateText = parsed.isEmpty
            ? 'سروری پیدا نشد'
            : '${parsed.length} سرور دریافت شد';
      });

      if (parsed.isNotEmpty) {
        await testAllServers();
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        stateText =
            'خطا در دریافت Subscription';
      });

      if (!silent) {
        _showMessage(
          'دریافت اشتراک ناموفق بود',
        );
      }
    }
  }

  void _parseSubscriptionInfo(
    String? header,
  ) {
    if (header == null ||
        header.trim().isEmpty) {
      return;
    }

    final map = <String, int>{};

    for (final item in header.split(';')) {
      final parts = item.trim().split('=');

      if (parts.length == 2) {
        final value =
            int.tryParse(parts[1]);

        if (value != null) {
          map[parts[0]] = value;
        }
      }
    }

    final upload =
        map['upload'] ?? 0;

    final download =
        map['download'] ?? 0;

    if (!mounted) return;

    setState(() {
      totalBytes = map['total'];
      usedBytes =
          upload + download;
      expireAt = map['expire'];
    });
  }

  List<String> _decodeSubscription(
    String body,
  ) {
    final direct = body
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where(
          (e) => e.contains('://'),
        )
        .toList();

    if (direct.isNotEmpty) {
      return direct;
    }

    try {
      var encoded = body
          .trim()
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
            (e) => e.contains('://'),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Server? _parseServer(String raw) {
    try {
      final uri = Uri.parse(raw);

      final scheme =
          uri.scheme.toLowerCase();

      if (scheme == 'vmess') {
        return _parseVmess(raw);
      }

      if (scheme == 'vless') {
        if (uri.host.isEmpty ||
            !uri.hasPort) {
          return null;
        }

        return Server(
          raw: raw,
          name: _fragmentName(
            uri,
            'VLESS ${uri.host}',
          ),
          type: 'VLESS',
          host: uri.host,
          port: uri.port,
          outbound: _makeVless(uri),
        );
      }

      if (scheme == 'trojan') {
        if (uri.host.isEmpty ||
            !uri.hasPort) {
          return null;
        }

        return Server(
          raw: raw,
          name: _fragmentName(
            uri,
            'Trojan ${uri.host}',
          ),
          type: 'TROJAN',
          host: uri.host,
          port: uri.port,
          outbound: _makeTrojan(uri),
        );
      }

      if (scheme == 'ss') {
        final outbound =
            _makeShadowsocks(
          uri,
          raw,
        );

        if (outbound == null) {
          return null;
        }

        return Server(
          raw: raw,
          name: _fragmentName(
            uri,
            'SS ${uri.host}',
          ),
          type: 'SS',
          host: uri.host,
          port: uri.port,
          outbound: outbound,
        );
      }

      if (scheme == 'hysteria2' ||
          scheme == 'hy2') {
        if (uri.host.isEmpty ||
            !uri.hasPort) {
          return null;
        }

        return Server(
          raw: raw,
          name: _fragmentName(
            uri,
            'Hysteria2 ${uri.host}',
          ),
          type: 'HYSTERIA2',
          host: uri.host,
          port: uri.port,
          outbound: _makeHysteria2(uri),
        );
      }
    } catch (_) {}

    return null;
  }

  String _fragmentName(
    Uri uri,
    String fallback,
  ) {
    if (uri.fragment.isEmpty) {
      return fallback;
    }

    return Uri.decodeComponent(
      uri.fragment,
    );
  }

  Map<String, dynamic> _makeVless(
    Uri uri,
  ) {
    final q = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uri.userInfo,
    };

    if ((q['flow'] ?? '').isNotEmpty) {
      outbound['flow'] = q['flow'];
    }

    final security =
        (q['security'] ?? '').toLowerCase();

    if (security == 'tls' ||
        security == 'reality') {
      final tls = <String, dynamic>{
        'enabled': true,
        'server_name':
            q['sni'] ??
            q['host'] ??
            uri.host,
      };

      final fingerprint =
          q['fp'] ?? '';

      if (fingerprint.isNotEmpty) {
        tls['utls'] = {
          'enabled': true,
          'fingerprint': fingerprint,
        };
      }

      if (security == 'reality') {
        final publicKey =
            q['pbk'] ?? '';

        if (publicKey.isNotEmpty) {
          tls['reality'] = {
            'enabled': true,
            'public_key': publicKey,
            if ((q['sid'] ?? '').isNotEmpty)
              'short_id': q['sid'],
          };
        }
      }

      outbound['tls'] = tls;
    }

    _addTransport(
      outbound,
      q['type'] ??
          q['network'] ??
          'tcp',
      q['path'] ?? '',
      q['host'] ?? '',
    );

    return outbound;
  }

  Map<String, dynamic> _makeTrojan(
    Uri uri,
  ) {
    final q = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'password': uri.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            q['sni'] ??
            q['host'] ??
            uri.host,
      },
    };

    _addTransport(
      outbound,
      q['type'] ?? 'tcp',
      q['path'] ?? '',
      q['host'] ?? '',
    );

    return outbound;
  }

  Map<String, dynamic>? _makeShadowsocks(
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

      final index =
          user.indexOf(':');

      if (index <= 0) {
        return null;
      }

      return {
        'type': 'shadowsocks',
        'tag': 'proxy',
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

  Map<String, dynamic> _makeHysteria2(
    Uri uri,
  ) {
    final q = uri.queryParameters;

    return {
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'password': uri.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            q['sni'] ??
            q['peer'] ??
            uri.host,
        if (q['insecure'] == '1')
          'insecure': true,
      },
    };
  }

  Server? _parseVmess(String raw) {
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
          jsonDecode(decoded)
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
        'tag': 'proxy',
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

      _addTransport(
        outbound,
        '${map['net'] ?? 'tcp'}',
        '${map['path'] ?? ''}',
        '${map['host'] ?? ''}',
      );

      return Server(
        raw: raw,
        name:
            map['ps'] ?? 'VMess',
        type: 'VMESS',
        host: host,
        port: port,
        outbound: outbound,
      );
    } catch (_) {
      return null;
    }
  }

  void _addTransport(
    Map<String, dynamic> outbound,
    String network,
    String path,
    String host,
  ) {
    final type =
        network.toLowerCase();

    if (type == 'ws' ||
        type == 'websocket') {
      outbound['transport'] = {
        'type': 'ws',
        'path':
            path.isEmpty ? '/' : path,
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
        'path':
            path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': host,
      };
    } else if (type == 'h2' ||
        type == 'http') {
      outbound['transport'] = {
        'type': 'http',
        'path':
            path.isEmpty ? '/' : path,
        if (host.isNotEmpty)
          'host': [host],
      };
    }
  }

  /*
   * مهم‌ترین قسمت این نسخه:
   *
   * 1. TUN با auto_route
   * 2. DNS روی خود TUN با dns_mode=hijack
   * 3. DNS از local Android resolver
   * 4. حذف override_android_vpn
   * 5. حذف auto_detect_interface
   * 6. حذف strict_route
   * 7. تمام ترافیک به proxy
   */
  String _buildConfig(
    Server server,
  ) {
    final proxy =
        Map<String, dynamic>.from(
      server.outbound,
    );

    proxy['tag'] = 'proxy';

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
      },

      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',

          'address': [
            '172.19.0.1/30',
            'fdfe:dcba:9876::1/126',
          ],

          'mtu': 1500,

          'stack': 'mixed',

          'auto_route': true,

          'dns_mode': 'hijack',

          'dns_address': [
            '172.19.0.2',
            'fdfe:dcba:9876::2',
          ],
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
        ],

        'final': 'proxy',
      },
    });
  }

  Future<void> testAllServers() async {
    if (servers.isEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        testing = true;
        stateText =
            'در حال تست سرورها...';
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

      if (mounted) {
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
        stateText =
            'تست سرورها کامل شد';
      });
    }
  }

  Server? _fastestServer() {
    final available = servers
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

  Future<void> connect() async {
    if (servers.isEmpty) {
      _showMessage(
        'ابتدا Subscription را دریافت کن',
      );
      return;
    }

    if (connected || connecting) {
      return;
    }

    setState(() {
      connecting = true;
      lastFault = '';
      stateText =
          'در حال آماده‌سازی VPN...';
    });

    try {
      if (servers.every(
        (server) => server.ping == null,
      )) {
        await testAllServers();
      }

      final server =
          _fastestServer();

      if (server == null) {
        throw Exception(
          'هیچ سرور قابل اتصالی پیدا نشد',
        );
      }

      setState(() {
        stateText =
            'اتصال به ${server.name}...';
      });

      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'VPN permission denied',
        );
      }

      final config =
          _buildConfig(server);

      /*
       * اول کانفیگ را validate می‌کنیم.
       * اگر sing-box مشکلی داشته باشد
       * همینجا باید خطای واقعی بدهد.
       */
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
        connected = true;
        connecting = false;
        connectedAt =
            DateTime.now();

        downloadBps = 0;
        uploadBps = 0;

        downloadTotalBytes = 0;
        uploadTotalBytes = 0;

        downloadHistory.clear();
        uploadHistory.clear();

        stateText =
            'متصل • ${server.name}';
      });

      _startDuration();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        connected = false;
        connecting = false;
        stateText =
            'اتصال ناموفق';
        lastFault = e.toString();
      });

      _showMessage(
        'VPN وصل نشد',
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

      stateText =
          'اتصال قطع شد';

      connectedAt = null;
      connectionDuration =
          Duration.zero;

      downloadBps = 0;
      uploadBps = 0;

      downloadTotalBytes = 0;
      uploadTotalBytes = 0;

      downloadHistory.clear();
      uploadHistory.clear();
    });
  }

  void _startDuration() {
    durationTimer?.cancel();

    durationTimer =
        Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted ||
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
  }

  String _formatSpeed(
    double bps,
  ) {
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

  String _formatBytes(
    int? bytes,
  ) {
    if (bytes == null ||
        bytes <= 0) {
      return 'نامشخص';
    }

    if (bytes < 1024) {
      return '$bytes B';
    }

    if (bytes <
        1024 * 1024) {
      return
          '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    if (bytes <
        1024 * 1024 * 1024) {
      return
          '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    return
        '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _formatDuration(
    Duration d,
  ) {
    final h =
        d.inHours
            .toString()
            .padLeft(2, '0');

    final m =
        (d.inMinutes % 60)
            .toString()
            .padLeft(2, '0');

    final s =
        (d.inSeconds % 60)
            .toString()
            .padLeft(2, '0');

    return '$h:$m:$s';
  }

  int _remainingBytes() {
    if (totalBytes == null) {
      return 0;
    }

    return max(
      0,
      totalBytes! -
          (usedBytes ?? 0),
    );
  }

  String _expiryText() {
    if (expireAt == null ||
        expireAt! <= 0) {
      return 'نامشخص';
    }

    final expiry =
        DateTime.fromMillisecondsSinceEpoch(
      expireAt! * 1000,
    );

    final remaining =
        expiry.difference(
      DateTime.now(),
    );

    if (remaining.isNegative) {
      return 'منقضی شده';
    }

    return
        '${remaining.inDays} روز';
  }

  void _showMessage(
    String message,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior:
            SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Directionality(
      textDirection:
          TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: _home(),
        ),
        bottomNavigationBar:
            NavigationBar(
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
          onDestinationSelected:
              (index) {
            _showMessage(
              'این بخش در نسخه بعدی تکمیل می‌شود',
            );
          },
        ),
      ),
    );
  }

  Widget _home() {
    final best =
        _fastestServer();

    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        const SizedBox(height: 8),

        Row(
          children: [
            Container(
              width: 52,
              height: 52,
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
                size: 30,
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                const Text(
                  'Light speed 🔥',
                  style:
                      TextStyle(
                    fontSize: 23,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                Text(
                  stateText,
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

        const SizedBox(height: 30),

        _connectButton(),

        const SizedBox(height: 20),

        if (best != null)
          _infoCard(
            Icons.public,
            'سریع‌ترین سرور',
            best.name,
            '${best.ping ?? '-'} ms',
          ),

        Row(
          children: [
            Expanded(
              child: _statCard(
                Icons.download,
                'دانلود',
                _formatSpeed(
                  downloadBps,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _statCard(
                Icons.upload,
                'آپلود',
                _formatSpeed(
                  uploadBps,
                ),
              ),
            ),
          ],
        ),

        _infoCard(
          Icons.download_done,
          'دریافت این جلسه',
          _formatBytes(
            downloadTotalBytes,
          ),
          'از زمان اتصال',
        ),

        _infoCard(
          Icons.upload_file,
          'ارسال این جلسه',
          _formatBytes(
            uploadTotalBytes,
          ),
          'از زمان اتصال',
        ),

        _infoCard(
          Icons.timer,
          'مدت اتصال',
          _formatDuration(
            connectionDuration,
          ),
          'VPN',
        ),

        _infoCard(
          Icons.data_usage,
          'مصرف اشتراک',
          _formatBytes(usedBytes),
          'باقی‌مانده: ${_formatBytes(_remainingBytes())}',
        ),

        _infoCard(
          Icons.event,
          'انقضا',
          _expiryText(),
          'Subscription',
        ),

        if (lastFault.isNotEmpty)
          Container(
            margin:
                const EdgeInsets.only(
              top: 10,
            ),
            padding:
                const EdgeInsets.all(14),
            decoration:
                BoxDecoration(
              color: Colors.red
                  .withValues(
                alpha: .10,
              ),
              borderRadius:
                  BorderRadius.circular(
                16,
              ),
            ),
            child: Text(
              'خطای اخیر:\n$lastFault',
              style:
                  const TextStyle(
                color:
                    Colors.redAccent,
              ),
            ),
          ),
      ],
    );
  }

  Widget _connectButton() {
    final color = connected
        ? const Color(0xFF00E676)
        : const Color(0xFF00E5FF);

    return Center(
      child: GestureDetector(
        onTap: connecting
            ? null
            : connected
                ? disconnect
                : connect,
        child: Container(
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
                color:
                    color.withValues(
                  alpha: .30,
                ),
                blurRadius: 45,
                spreadRadius: 5,
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
                            color: color,
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

  Widget _statCard(
    IconData icon,
    String title,
    String value,
  ) {
    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 10,
      ),
      padding:
          const EdgeInsets.all(15),
      decoration:
          BoxDecoration(
        color:
            const Color(0xFF0D1728),
        borderRadius:
            BorderRadius.circular(
          20,
        ),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            size: 32,
            color:
                const Color(0xFF00E5FF),
          ),
          const SizedBox(height: 7),
          Text(
            title,
            style:
                const TextStyle(
              color:
                  Colors.white54,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style:
                const TextStyle(
              fontSize: 17,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard(
    IconData icon,
    String title,
    String value,
    String subtitle,
  ) {
    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 10,
      ),
      padding:
          const EdgeInsets.all(16),
      decoration:
          BoxDecoration(
        color:
            const Color(0xFF0D1728),
        borderRadius:
            BorderRadius.circular(
          20,
        ),
        border: Border.all(
          color:
              Colors.white.withValues(
            alpha: .04,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration:
                BoxDecoration(
              color:
                  const Color(
                0xFF00E5FF,
              ).withValues(
                alpha: .10,
              ),
              borderRadius:
                  BorderRadius.circular(
                15,
              ),
            ),
            child: Icon(
              icon,
              color:
                  const Color(0xFF00E5FF),
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
                    color:
                        Colors.white54,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
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
    );
  }

  @override
  void dispose() {
    stateSubscription?.cancel();
    trafficSubscription?.cancel();
    faultSubscription?.cancel();

    refreshTimer?.cancel();
    durationTimer?.cancel();

    urlController.dispose();

    super.dispose();
  }
}
