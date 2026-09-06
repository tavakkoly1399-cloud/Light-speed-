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
  final TextEditingController url = TextEditingController();

  final List<Server> servers = [];

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

  // true  = sing-box خودش بهترین سرور را انتخاب می‌کند
  // false = کاربر سرور را انتخاب می‌کند
  bool autoSelect = true;

  int selectedServerIndex = 0;

  String stateText = 'آماده اتصال';

  // سرعت لحظه‌ای
  String download = '0 bps';
  String upload = '0 bps';

  String lastFault = '';

  // حجم ترافیک همین جلسه
  int downloadTotalBytes = 0;
  int uploadTotalBytes = 0;

  // اطلاعات Subscription
  int? totalBytes;
  int? usedBytes;
  int? expireAt;

  DateTime? connectedAt;

  Duration connectionDuration = Duration.zero;

  @override
  void initState() {
    super.initState();

    // ------------------------------------------------------------
    // وضعیت VPN
    // ------------------------------------------------------------
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

    // ------------------------------------------------------------
    // آمار واقعی ترافیک sing-box
    // ------------------------------------------------------------
    trafficSub = vpn.trafficStatsStream.listen((s) {
      if (!mounted) return;

      try {
        final downBps =
            (s.downlinkBps as num).toDouble();

        final upBps =
            (s.uplinkBps as num).toDouble();

        final downTotal =
            (s.downlinkTotalBytes as num).toInt();

        final upTotal =
            (s.uplinkTotalBytes as num).toInt();

        setState(() {
          // سرعت لحظه‌ای واقعی
          download = speed(downBps);
          upload = speed(upBps);

          // حجم واقعی همین اتصال
          downloadTotalBytes = downTotal;
          uploadTotalBytes = upTotal;

          /*
           * اگر پنل Subscription مقدار upload/download
           * نداده باشد، مصرف جلسه فعلی را نشان می‌دهیم.
           *
           * اگر پنل مقدار واقعی داشته باشد، آن را دستکاری
           * نمی‌کنیم.
           */
          if (usedBytes == null &&
              (downTotal > 0 || upTotal > 0)) {
            usedBytes = downTotal + upTotal;
          }
        });
      } catch (e) {
        // خطای آمار نباید VPN را قطع کند.
      }
    });

    // ------------------------------------------------------------
    // خطاهای sing-box
    // ------------------------------------------------------------
    try {
      faultSub = vpn.faultStream.listen((e) {
        if (!mounted) return;

        setState(() {
          lastFault = e.toString();
        });
      });
    } catch (_) {}

    // ------------------------------------------------------------
    // بروزرسانی خودکار هر 15 دقیقه
    // فقط وقتی VPN خاموش است
    // ------------------------------------------------------------
    refreshTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) {
        if (!connected &&
            !connecting &&
            !loading) {
          loadSubscription(silent: true);
        }
      },
    );

    loadSaved();
  }

  // ============================================================
  // ذخیره و بازیابی Subscription
  // ============================================================

  Future<void> loadSaved() async {
    final p =
        await SharedPreferences.getInstance();

    final saved =
        p.getString('subscription_url');

    if (saved == null ||
        saved.trim().isEmpty) {
      return;
    }

    url.text = saved;

    await loadSubscription(
      silent: true,
    );
  }

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final text = url.text.trim();

    if (text.isEmpty) {
      if (!silent && mounted) {
        setState(() {
          stateText =
              'Subscription URL را وارد کن';
        });

        snack(
          'ابتدا لینک Subscription را وارد کن',
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
      final uri = Uri.parse(text);

      final response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'LightSpeed/3.0',
          'Accept': '*/*',
          'Accept-Encoding': 'gzip, deflate',
        },
      ).timeout(
        // قبلاً 20 ثانیه بود.
        // برای ساب کند، 60 ثانیه می‌دهیم.
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

      // اطلاعات حجم و تاریخ
      _readUserInfo(
        response.headers[
          'subscription-userinfo'
        ],
      );

      final result = <Server>[];

      for (final line
          in decodeSubscription(body)) {
        final server =
            parseServer(line);

        if (server != null) {
          result.add(server);
        }
      }

      if (result.isEmpty) {
        throw Exception(
          'هیچ کانفیگ قابل استفاده‌ای پیدا نشد',
        );
      }

      final p =
          await SharedPreferences.getInstance();

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

      // تست Ping
      await testAll(
        silent: true,
      );

      if (!mounted) return;

      setState(() {
        stateText =
            '${servers.length} سرور آماده اتصال';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;

        // سرورهای قبلی را نگه می‌داریم.
        stateText =
            'بروزرسانی Subscription ناموفق بود';
      });

      if (!silent) {
        snack(
          'دریافت Subscription ناموفق بود:\n$e',
        );
      }
    }
  }

  // ============================================================
  // Subscription UserInfo
  // ============================================================

  void _readUserInfo(String? raw) {
    if (raw == null ||
        raw.trim().isEmpty) {
      return;
    }

    final values = <String, int>{};

    for (final item in raw.split(';')) {
      final part = item.trim();

      final index =
          part.indexOf('=');

      if (index <= 0) continue;

      final key = part
          .substring(0, index)
          .trim()
          .toLowerCase();

      final value = part
          .substring(index + 1)
          .trim();

      final number =
          int.tryParse(value);

      if (number != null) {
        values[key] = number;
      }
    }

    if (!mounted) return;

    final uploadValue =
        values['upload'];

    final downloadValue =
        values['download'];

    final hasTrafficInfo =
        uploadValue != null ||
        downloadValue != null;

    setState(() {
      totalBytes =
          values['total'];

      expireAt =
          values['expire'];

      if (hasTrafficInfo) {
        usedBytes =
            (uploadValue ?? 0) +
            (downloadValue ?? 0);
      } else {
        /*
         * پنل فقط total/expire داده.
         *
         * مصرف کل اکانت را نمی‌توانیم
         * از خودمان حدس بزنیم.
         */
        usedBytes = null;
      }
    });
  }

  // ============================================================
  // Decode Subscription
  // ============================================================

  List<String> decodeSubscription(
    String body,
  ) {
    List<String> extractLinks(
      String text,
    ) {
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

    var direct =
        extractLinks(body);

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
        final padding =
            (4 - decoded.length % 4) % 4;

        final padded =
            decoded + ('=' * padding);

        final text =
            utf8.decode(
          base64.decode(padded),
          allowMalformed: true,
        );

        direct =
            extractLinks(text);

        if (direct.isNotEmpty) {
          return direct;
        }

        decoded = text
            .trim()
            .replaceAll(
              RegExp(r'\s+'),
              '',
            )
            .replaceAll('-', '+')
            .replaceAll('_', '/');
      } catch (_) {
        break;
      }
    }

    return [];
  }

  // ============================================================
  // Parse Server
  // ============================================================

  Server? parseServer(
    String raw,
  ) {
    try {
      final uri =
          Uri.parse(raw);

      final scheme =
          uri.scheme.toLowerCase();

      if (scheme == 'vmess') {
        return parseVmess(raw);
      }

      const supported = [
        'vless',
        'trojan',
        'ss',
        'hysteria2',
        'hy2',
        'hysteria',
        'tuic',
      ];

      if (!supported.contains(scheme)) {
        return null;
      }

      if (uri.host.isEmpty ||
          !uri.hasPort) {
        return null;
      }

      late Map<String, dynamic>
          outbound;

      if (scheme == 'vless') {
        outbound =
            vless(uri);
      } else if (scheme == 'trojan') {
        outbound =
            trojan(uri);
      } else if (scheme == 'ss') {
        outbound =
            shadowsocks(
              uri,
              raw,
            ) ??
            {};
      } else if (scheme == 'tuic') {
        outbound =
            tuic(uri);
      } else {
        outbound =
            hysteria2(uri);
      }

      if (outbound.isEmpty) {
        return null;
      }

      final name =
          Uri.decodeComponent(
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

  // ============================================================
  // VMess
  // ============================================================

  Server? parseVmess(
    String raw,
  ) {
    try {
      var data =
          raw.substring(
        raw.indexOf('://') + 3,
      );

      data = data
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      final padding =
          (4 - data.length % 4) % 4;

      data += '=' * padding;

      final decoded =
          utf8.decode(
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

  // ============================================================
  // VLESS
  // ============================================================

  Map<String, dynamic> vless(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'vless',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': Uri.decodeComponent(
        uri.userInfo,
      ),
    };

    if ((p['flow'] ?? '').isNotEmpty) {
      outbound['flow'] =
          p['flow'];
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
          'fingerprint':
              p['fp'],
        };
      }

      if (security == 'reality' &&
          (p['pbk'] ?? '').isNotEmpty) {
        tls['reality'] = {
          'enabled': true,
          'public_key':
              p['pbk'],
          if ((p['sid'] ?? '').isNotEmpty)
            'short_id':
                p['sid'],
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
  // Trojan
  // ============================================================

  Map<String, dynamic> trojan(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'trojan',
      'server': uri.host,
      'server_port': uri.port,
      'password':
          Uri.decodeComponent(
        uri.userInfo,
      ),
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

  // ============================================================
  // Shadowsocks
  // ============================================================

  Map<String, dynamic>? shadowsocks(
    Uri uri,
    String raw,
  ) {
    try {
      var user =
          uri.userInfo;

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

        final padding =
            (4 - data.length % 4) % 4;

        data += '=' * padding;

        user =
            utf8.decode(
          base64.decode(data),
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
        'server': uri.host,
        'server_port': uri.port,
        'method':
            Uri.decodeComponent(
          user.substring(
            0,
            index,
          ),
        ),
        'password':
            Uri.decodeComponent(
          user.substring(
            index + 1,
          ),
        ),
      };
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // Hysteria 2
  // ============================================================

  Map<String, dynamic> hysteria2(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    return {
      'type': 'hysteria2',
      'server': uri.host,
      'server_port': uri.port,
      'password':
          Uri.decodeComponent(
        uri.userInfo,
      ),
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

  // ============================================================
  // TUIC
  // ============================================================

  Map<String, dynamic> tuic(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    return {
      'type': 'tuic',
      'server': uri.host,
      'server_port': uri.port,
      'uuid':
          Uri.decodeComponent(
        uri.userInfo,
      ),
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

  // ============================================================
  // Transports
  // ============================================================

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
        'service_name':
            path,
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

  // ============================================================
  // Ping
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
              const Duration(
            seconds: 3,
          ),
        );

        socket.destroy();

        server.ping =
            stopwatch
                .elapsedMilliseconds;
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

  // ============================================================
  // Build sing-box Config
  // ============================================================

  String buildConfig() {
    if (servers.isEmpty) {
      throw Exception(
        'هیچ سروری وجود ندارد',
      );
    }

    final nodes =
        <Map<String, dynamic>>[];

    final tags =
        <String>[];

    for (int i = 0;
        i < servers.length;
        i++) {
      final outbound =
          Map<String, dynamic>.from(
        servers[i].outbound,
      );

      final tag =
          'node-$i';

      outbound['tag'] = tag;

      nodes.add(outbound);
      tags.add(tag);
    }

    // Direct
    nodes.add({
      'type': 'direct',
      'tag': 'direct',
    });

    /*
     * انتخاب خودکار:
     *
     * sing-box بین تمام nodeها
     * URLTest انجام می‌دهد.
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
     * DNS:
     *
     * dns_mode و dns_address را عمداً
     * داخل TUN قرار نداده‌ایم تا به خطای
     * validation قبلی برنخوریم.
     *
     * DNS از طریق DNS server + hijack-dns
     * مدیریت می‌شود.
     */
    final config =
        <String, dynamic>{
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
        /*
         * مخصوص Android VPN
         */
        'override_android_vpn': true,

        'rules': [
          {
            'protocol': 'dns',
            'action': 'hijack-dns',
          },
        ],

        'final': finalOutbound,
      },
    };

    return jsonEncode(config);
  }

  // ============================================================
  // Connect
  // ============================================================

  Future<void> connect() async {
    if (servers.isEmpty) {
      snack(
        'ابتدا از بخش اشتراک کانفیگ را وارد کن',
      );
      return;
    }

    if (connected ||
        connecting) {
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

      // آمار اتصال جدید از صفر شروع می‌شود
      download = '0 bps';
      upload = '0 bps';

      downloadTotalBytes = 0;
      uploadTotalBytes = 0;

      connectionDuration =
          Duration.zero;
    });

    try {
      // ----------------------------------------------------------
      // اجازه VPN
      // ----------------------------------------------------------
      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'اجازه VPN داده نشد',
        );
      }

      // ----------------------------------------------------------
      // ساخت کانفیگ
      // ----------------------------------------------------------
      final config =
          buildConfig();

      setState(() {
        stateText =
            'در حال بررسی کانفیگ...';
      });

      // ----------------------------------------------------------
      // Validate
      // ----------------------------------------------------------
      await vpn.checkConfig(
        config,
      );

      setState(() {
        stateText =
            'در حال اتصال به $selectedName...';
      });

      // ----------------------------------------------------------
      // اتصال واقعی VPN
      // ----------------------------------------------------------
      await vpn.connect(
        SessionOptions(
          config: config,
          networkMode:
              NetworkMode.vpn,
          notification:
              NotificationConfig(
            title:
                'Light speed 🔥',
            showTrafficStats:
                true,
            showStopButton:
                true,
            stopButtonLabel:
                'قطع اتصال',
          ),
        ),
      );

      if (!mounted) return;

      connectedAt =
          DateTime.now();

      durationTimer?.cancel();

      durationTimer =
          Timer.periodic(
        const Duration(
          seconds: 1,
        ),
        (_) {
          if (!mounted ||
              !connected ||
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

      setState(() {
        connected = true;
        connecting = false;

        stateText = autoSelect
            ? 'متصل • بهترین سرور'
            : 'متصل • $selectedName';
      });
    } catch (e) {
      try {
        await vpn.disconnect();
      } catch (_) {}

      durationTimer?.cancel();

      if (!mounted) return;

      setState(() {
        connecting = false;
        connected = false;

        stateText =
            'اتصال ناموفق';

        lastFault =
            e.toString();
      });

      snack(
        'خطای VPN:\n$e',
      );
    }
  }

  // ============================================================
  // Disconnect
  // ============================================================

  Future<void> disconnect() async {
    try {
      await vpn.disconnect();
    } catch (_) {}

    durationTimer?.cancel();

    connectedAt = null;

    if (!mounted) return;

    setState(() {
      connected = false;
      connecting = false;

      stateText =
          'اتصال قطع شد';

      download = '0 bps';
      upload = '0 bps';

      downloadTotalBytes = 0;
      uploadTotalBytes = 0;

      connectionDuration =
          Duration.zero;
    });
  }

  // ============================================================
  // Server Selection
  // ============================================================

  void selectServer(
    int index,
  ) {
    if (index < 0 ||
        index >= servers.length) {
      return;
    }

    if (connected ||
        connecting) {
      snack(
        'ابتدا اتصال VPN را قطع کن',
      );
      return;
    }

    setState(() {
      autoSelect = false;

      selectedServerIndex =
          index;

      stateText =
          'سرور انتخاب شد: '
          '${servers[index].name}';
    });
  }

  void enableAutoSelection() {
    if (connected ||
        connecting) {
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

  // ============================================================
  // Format Speed
  // ============================================================

  String speed(
    dynamic bps,
  ) {
    final n =
        bps is num
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

  // ============================================================
  // Format Size
  // ============================================================

  String size(
    int? n,
  ) {
    if (n == null ||
        n <= 0) {
      return 'نامشخص';
    }

    if (n <
        1024 * 1024) {
      return '${(n / 1024).toStringAsFixed(1)} KB';
    }

    if (n <
        1024 *
            1024 *
            1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  // ============================================================
  // Remaining Subscription Time
  // ============================================================

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

  // ============================================================
  // Connection Time
  // ============================================================

  String connectionTime() {
    final h =
        connectionDuration
            .inHours
            .toString()
            .padLeft(2, '0');

    final m =
        (connectionDuration
                .inMinutes %
            60)
            .toString()
            .padLeft(2, '0');

    final s =
        (connectionDuration
                .inSeconds %
            60)
            .toString()
            .padLeft(2, '0');

    return '$h:$m:$s';
  }

  // ============================================================
  // Snack
  // ============================================================

  void snack(
    String text,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content:
            Text(text),
      ),
    );
  }

  // ============================================================
  // Main Build
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
          selectedIndex:
              page,

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
  // Header
  // ============================================================

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
              shape:
                  BoxShape.circle,
              gradient:
                  LinearGradient(
                colors: [
                  Color(0xFF00E5FF),
                  Color(0xFF7C4DFF),
                ],
              ),
            ),
            child:
                const Icon(
              Icons.bolt,
              color:
                  Colors.white,
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
      ),
    );
  }

  // ============================================================
  // Card
  // ============================================================

  Widget card(
    Widget child,
  ) {
    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 12,
      ),
      padding:
          const EdgeInsets.all(
        16,
      ),
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
          color:
              Colors.white.withValues(
            alpha: .05,
          ),
        ),
      ),
      child: child,
    );
  }

  // ============================================================
  // HOME
  // ============================================================

  Widget _home() {
    final percent =
        totalBytes == null ||
                totalBytes! <= 0 ||
                usedBytes == null
            ? 0.0
            : ((usedBytes! /
                        totalBytes!)
                    .clamp(
              0.0,
              1.0,
            ));

    String selectedName;

    if (servers.isEmpty) {
      selectedName =
          'هیچ سروری انتخاب نشده';
    } else if (autoSelect) {
      selectedName =
          'انتخاب خودکار • بهترین سرور';
    } else if (selectedServerIndex <
        servers.length) {
      selectedName =
          servers[
              selectedServerIndex]
          .name;
    } else {
      selectedName =
          'سرور انتخاب نشده';
    }

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

        // دکمه اصلی اتصال
        Center(
          child:
              GestureDetector(
            onTap: connecting
                ? null
                : (connected
                    ? disconnect
                    : connect),

            child:
                Container(
              width: 200,
              height: 200,

              decoration:
                  BoxDecoration(
                shape:
                    BoxShape.circle,

                gradient:
                    LinearGradient(
                  colors:
                      connected
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
                            .withValues(
                      alpha: .35,
                    ),
                    blurRadius:
                        40,
                    spreadRadius:
                        8,
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
                    child:
                        connecting
                            ? const CircularProgressIndicator()
                            : Column(
                                mainAxisAlignment:
                                    MainAxisAlignment.center,
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

        const SizedBox(
          height: 16,
        ),

        Center(
          child: Text(
            stateText,
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color: connected
                  ? const Color(
                      0xFF00E676,
                    )
                  : Colors.white70,
            ),
          ),
        ),

        const SizedBox(
          height: 8,
        ),

        Center(
          child: Text(
            selectedName,
            maxLines: 1,
            overflow:
                TextOverflow.ellipsis,
            style:
                const TextStyle(
              color:
                  Colors.white54,
            ),
          ),
        ),

        const SizedBox(
          height: 20,
        ),

        // وضعیت سرورها
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
                  style:
                      const TextStyle(
                    color:
                        Colors.white54,
                  ),
                ),
            ],
          ),
        ),

        // سرعت دانلود و آپلود
        Row(
          children: [
            Expanded(
              child:
                  card(
                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons
                          .download_rounded,
                      color:
                          Color(
                        0xFF00E5FF,
                      ),
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

                    const SizedBox(
                      height: 3,
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
              child:
                  card(
                Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons
                          .upload_rounded,
                      color:
                          Color(
                        0xFF7C4DFF,
                      ),
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

                    const SizedBox(
                      height: 3,
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

        // Subscription
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
                        Color(
                      0xFF7C4DFF,
                    ),
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
                usedBytes == null
                    ? 'مصرف اشتراک: نامشخص'
                    : 'مصرف اشتراک: ${size(usedBytes)}',
              ),

              const SizedBox(
                height: 8,
              ),

              Text(
                'زمان باقی‌مانده: ${remaining()}',
              ),

              const SizedBox(
                height: 8,
              ),

              Text(
                'دانلود این اتصال: '
                '${size(downloadTotalBytes)}',
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
                'آپلود این اتصال: '
                '${size(uploadTotalBytes)}',
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                ),
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
                color:
                    Colors.redAccent,
              ),
              title:
                  const Text(
                'آخرین خطا',
              ),
              subtitle:
                  Text(
                lastFault,
              ),
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
          const EdgeInsets.all(
        18,
      ),
      children: [
        header(
          'سرورها',
          '${servers.length} سرور',
        ),

        // Auto Select
        card(
          SwitchListTile(
            contentPadding:
                EdgeInsets.zero,

            value:
                autoSelect,

            onChanged:
                (value) {
              if (connected ||
                  connecting) {
                snack(
                  'ابتدا VPN را قطع کن',
                );
                return;
              }

              setState(() {
                autoSelect =
                    value;

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
                'سرور فعلی',
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
            ),
          ),

        FilledButton.icon(
          onPressed:
              testing
                  ? null
                  : () =>
                      testAll(),

          icon:
              const Icon(
            Icons.speed,
          ),

          label:
              Text(
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
                    EdgeInsets.all(
                  24,
                ),
                child:
                    Text(
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
                    selectServer(
                  index,
                ),

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
                          fontSize:
                              11,
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

  // ============================================================
  // TRAFFIC
  // ============================================================

  Widget _traffic() {
    final sessionTotal =
        downloadTotalBytes +
            uploadTotalBytes;

    final remainingBytes =
        totalBytes != null &&
                usedBytes != null
            ? max(
                0,
                totalBytes! -
                    usedBytes!,
              )
            : null;

    return ListView(
      padding:
          const EdgeInsets.all(
        18,
      ),
      children: [
        header(
          'ترافیک',
          'آمار واقعی VPN',
        ),

        // --------------------------------------------------------
        // Download Speed
        // --------------------------------------------------------
        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,

            leading:
                Container(
              width: 48,
              height: 48,
              decoration:
                  BoxDecoration(
                borderRadius:
                    BorderRadius.circular(
                  15,
                ),
                color:
                    const Color(
                  0xFF00E5FF,
                ).withValues(
                  alpha: .12,
                ),
              ),
              child:
                  const Icon(
                Icons
                    .download_rounded,
                color:
                    Color(
                  0xFF00E5FF,
                ),
              ),
            ),

            title:
                const Text(
              'سرعت دانلود',
              style:
                  TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            subtitle:
                const Text(
              'سرعت لحظه‌ای VPN',
            ),

            trailing:
                Text(
              download,
              style:
                  const TextStyle(
                fontSize: 18,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
        ),

        // --------------------------------------------------------
        // Upload Speed
        // --------------------------------------------------------
        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,

            leading:
                Container(
              width: 48,
              height: 48,
              decoration:
                  BoxDecoration(
                borderRadius:
                    BorderRadius.circular(
                  15,
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
                Icons
                    .upload_rounded,
                color:
                    Color(
                  0xFF7C4DFF,
                ),
              ),
            ),

            title:
                const Text(
              'سرعت آپلود',
              style:
                  TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            subtitle:
                const Text(
              'سرعت لحظه‌ای VPN',
            ),

            trailing:
                Text(
              upload,
              style:
                  const TextStyle(
                fontSize: 18,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
        ),

        // --------------------------------------------------------
        // Download Total
        // --------------------------------------------------------
        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,

            leading:
                const Icon(
              Icons
                  .download_for_offline,
              color:
                  Color(
                0xFF00E5FF,
              ),
            ),

            title:
                const Text(
              'حجم دانلود این اتصال',
            ),

            subtitle:
                const Text(
              'ترافیک دریافت‌شده توسط VPN',
            ),

            trailing:
                Text(
              size(
                downloadTotalBytes,
              ),
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
        ),

        // --------------------------------------------------------
        // Upload Total
        // --------------------------------------------------------
        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,

            leading:
                const Icon(
              Icons.upload_file,
              color:
                  Color(
                0xFF7C4DFF,
              ),
            ),

            title:
                const Text(
              'حجم آپلود این اتصال',
            ),

            subtitle:
                const Text(
              'ترافیک ارسال‌شده توسط VPN',
            ),

            trailing:
                Text(
              size(
                uploadTotalBytes,
              ),
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
        ),

        // --------------------------------------------------------
        // Session Total
        // --------------------------------------------------------
        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'مجموع ترافیک این اتصال',
                style:
                    TextStyle(
                  fontSize: 16,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              const SizedBox(
                height: 14,
              ),

              Row(
                children: [
                  Expanded(
                    child:
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
                        const SizedBox(
                          height: 4,
                        ),
                        Text(
                          size(
                            downloadTotalBytes,
                          ),
                          style:
                              const TextStyle(
                            fontSize:
                                17,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),

                  Expanded(
                    child:
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
                        const SizedBox(
                          height: 4,
                        ),
                        Text(
                          size(
                            uploadTotalBytes,
                          ),
                          style:
                              const TextStyle(
                            fontSize:
                                17,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(
                height: 14,
              ),

              Text(
                'مجموع: ${size(sessionTotal)}',
                style:
                    const TextStyle(
                  color:
                      Color(
                    0xFF00E5FF,
                  ),
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ],
          ),
        ),

        // --------------------------------------------------------
        // Subscription Info
        // --------------------------------------------------------
        card(
          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'اطلاعات اشتراک',
                style:
                    TextStyle(
                  fontSize: 16,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              const SizedBox(
                height: 12,
              ),

              Row(
                children: [
                  const Expanded(
                    child:
                        Text(
                      'حجم کل اشتراک',
                      style:
                          TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                  ),
                  Text(
                    size(
                      totalBytes,
                    ),
                  ),
                ],
              ),

              const SizedBox(
                height: 8,
              ),

              Row(
                children: [
                  const Expanded(
                    child:
                        Text(
                      'مصرف اشتراک',
                      style:
                          TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                  ),
                  Text(
                    size(
                      usedBytes,
                    ),
                  ),
                ],
              ),

              const SizedBox(
                height: 8,
              ),

              Row(
                children: [
                  const Expanded(
                    child:
                        Text(
                      'باقی‌مانده',
                      style:
                          TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                  ),
                  Text(
                    size(
                      remainingBytes,
                    ),
                  ),
                ],
              ),

              const SizedBox(
                height: 8,
              ),

              Row(
                children: [
                  const Expanded(
                    child:
                        Text(
                      'زمان باقی‌مانده',
                      style:
                          TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                  ),
                  Text(
                    remaining(),
                  ),
                ],
              ),
            ],
          ),
        ),

        // --------------------------------------------------------
        // Connection Time
        // --------------------------------------------------------
        card(
          ListTile(
            contentPadding:
                EdgeInsets.zero,

            leading:
                const Icon(
              Icons.timer,
              color:
                  Color(
                0xFF00E676,
              ),
            ),

            title:
                const Text(
              'مدت اتصال',
            ),

            subtitle:
                Text(
              connected
                  ? connectionTime()
                  : 'VPN متصل نیست',
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // SUBSCRIPTION
  // ============================================================

  Widget _subscription() {
    final percent =
        totalBytes == null ||
                totalBytes! <= 0 ||
                usedBytes == null
            ? 0.0
            : (usedBytes! /
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
          'Subscription',
          'مدیریت اشتراک',
        ),

        TextField(
          controller:
              url,

          textDirection:
              TextDirection.ltr,

          decoration:
              const InputDecoration(
            labelText:
                'Subscription URL',
            prefixIcon:
                Icon(
              Icons.link,
            ),
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
                    loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(
                              strokeWidth:
                                  2,
                            ),
                          )
                        : const Icon(
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
              onPressed:
                  loading
                      ? null
                      : () {
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
                'تعداد سرورها: '
                '${servers.length}',
              ),

              const SizedBox(
                height: 8,
              ),

              Text(
                'حجم کل: '
                '${size(totalBytes)}',
              ),

              const SizedBox(
                height: 6,
              ),

              Text(
                usedBytes == null
                    ? 'مصرف: نامشخص'
                    : 'مصرف: ${size(usedBytes)}',
              ),

              const SizedBox(
                height: 6,
              ),

              Text(
                'زمان باقی‌مانده: '
                '${remaining()}',
              ),

              const SizedBox(
                height: 12,
              ),

              LinearProgressIndicator(
                value: percent,
                minHeight: 8,
              ),

              const SizedBox(
                height: 12,
              ),

              const Text(
                'بروزرسانی خودکار: هر ۱۵ دقیقه',
                style:
                    TextStyle(
                  color:
                      Colors.white54,
                ),
              ),

              const SizedBox(
                height: 6,
              ),

              const Text(
                'توجه: مصرف کل فقط در صورت ارسال اطلاعات '
                'upload/download توسط سرویس‌دهنده نمایش داده می‌شود.',
                style:
                    TextStyle(
                  color:
                      Colors.white38,
                  fontSize: 12,
                ),
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
                color:
                    Colors.redAccent,
              ),
              title:
                  const Text(
                'آخرین خطا',
              ),
              subtitle:
                  Text(
                lastFault,
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
          const EdgeInsets.all(
        18,
      ),
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
                      ? 'دستی — '
                          '${servers[selectedServerIndex].name}'
                      : 'دستی — انتخاب نشده',
            ),
          ),
        ),

        card(
          const ListTile(
            leading:
                Icon(
              Icons.language,
            ),
            title:
                Text(
              'شبکه',
            ),
            subtitle:
                Text(
              'IPv4 / TUN',
            ),
          ),
        ),

        card(
          const ListTile(
            leading:
                Icon(
              Icons.sync,
            ),
            title:
                Text(
              'Auto Refresh',
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

        card(
          ListTile(
            leading:
                const Icon(
              Icons.download_rounded,
              color:
                  Color(
                0xFF00E5FF,
              ),
            ),

            title:
                const Text(
              'دانلود',
            ),

            subtitle:
                Text(
              download,
            ),
          ),
        ),

        card(
          ListTile(
            leading:
                const Icon(
              Icons.upload_rounded,
              color:
                  Color(
                0xFF7C4DFF,
              ),
            ),

            title:
                const Text(
              'آپلود',
            ),

            subtitle:
                Text(
              upload,
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
                  Text(
                lastFault,
              ),
            ),
          ),
      ],
    );
  }

  // ============================================================
  // Dispose
  // ============================================================

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
