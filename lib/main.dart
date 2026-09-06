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
  bool usable = true;
}

class SubscriptionInfo {
  const SubscriptionInfo({
    this.total,
    this.used,
    this.expire,
  });

  final int? total;
  final int? used;
  final int? expire;
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
  bool internetTestRunning = false;

  String stateText = 'آماده اتصال';
  String lastFault = '';
  String internetStatus = 'تست نشده';

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
        if (!connected && !loading) {
          loadSubscription(silent: true);
        }
      },
    );

    loadSavedSubscription();
  }

  // ============================================================
  // VPN STATE
  // ============================================================

  void _listenState() {
    stateSubscription = vpn.serviceStateStream.listen((state) {
      if (!mounted) return;

      final value = state.toString().toLowerCase();

      if (value.contains('started')) {
        setState(() {
          connected = true;
          connecting = false;
          stateText = 'VPN متصل است';
          connectedAt ??= DateTime.now();
        });

        _startDuration();

        Future.delayed(
          const Duration(seconds: 3),
          () {
            if (mounted && connected) {
              testInternet();
            }
          },
        );
      } else if (value.contains('stopped')) {
        setState(() {
          connected = false;
          connecting = false;
          stateText = 'قطع شد';
          internetStatus = 'VPN قطع است';
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

  // ============================================================
  // REAL TRAFFIC
  // ============================================================

  void _listenTraffic() {
    trafficSubscription =
        vpn.trafficStatsStream.listen((stats) {
      if (!mounted) return;

      final down = max(
        0,
        stats.downlinkBps,
      ).toDouble();

      final up = max(
        0,
        stats.uplinkBps,
      ).toDouble();

      final downTotal = max(
        0,
        stats.downlinkTotalBytes,
      );

      final upTotal = max(
        0,
        stats.uplinkTotalBytes,
      );

      setState(() {
        downloadBps = down;
        uploadBps = up;

        downloadTotalBytes = downTotal;
        uploadTotalBytes = upTotal;

        _addHistory(
          downloadHistory,
          down,
        );

        _addHistory(
          uploadHistory,
          up,
        );

        // اگر ترافیک واقعی مشاهده شد،
        // یعنی TUN فقط روشن نیست و واقعاً
        // در حال عبور دادن داده است.
        if (connected &&
            (downTotal > 0 || upTotal > 0)) {
          internetStatus =
              '🟢 اینترنت در حال عبور است';
        }
      });
    });
  }

  void _listenFaults() {
    faultSubscription =
        vpn.faultStream.listen((fault) {
      if (!mounted) return;

      final text = fault.toString();

      setState(() {
        lastFault = text;

        if (text.isNotEmpty) {
          stateText = 'خطای sing-box';
        }
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

  // ============================================================
  // SUBSCRIPTION
  // ============================================================

  Future<void> loadSavedSubscription() async {
    final prefs =
        await SharedPreferences.getInstance();

    final saved =
        prefs.getString('subscription_url');

    if (saved == null ||
        saved.trim().isEmpty) {
      return;
    }

    urlController.text = saved;

    await loadSubscription(
      silent: true,
    );
  }

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final url =
        urlController.text.trim();

    if (url.isEmpty) {
      if (!silent) {
        _showMessage(
          'آدرس Subscription وارد نشده است',
        );
      }
      return;
    }

    if (connected) {
      if (!silent) {
        _showMessage(
          'ابتدا VPN را قطع کن',
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
      final uri = Uri.parse(url);

      final response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'LightSpeed/2.0',
          'Accept': '*/*',
          'Cache-Control': 'no-cache',
        },
      ).timeout(
        const Duration(seconds: 30),
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

      final info =
          _parseSubscriptionInfo(
        response.headers[
          'subscription-userinfo'
        ],
      );

      final parsed =
          _parseSubscriptionBody(body);

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

        totalBytes = info.total;
        usedBytes = info.used;
        expireAt = info.expire;

        loading = false;

        stateText = parsed.isEmpty
            ? 'هیچ کانفیگ معتبری پیدا نشد'
            : '${parsed.length} کانفیگ دریافت شد';

        lastFault = '';
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
        lastFault = e.toString();
      });

      if (!silent) {
        _showMessage(
          'دریافت Subscription ناموفق بود',
        );
      }
    }
  }

  SubscriptionInfo _parseSubscriptionInfo(
    String? header,
  ) {
    if (header == null ||
        header.trim().isEmpty) {
      return const SubscriptionInfo();
    }

    final map = <String, int>{};

    for (final item in header.split(';')) {
      final parts = item.trim().split('=');

      if (parts.length != 2) continue;

      final value =
          int.tryParse(parts[1].trim());

      if (value != null) {
        map[parts[0].trim()] = value;
      }
    }

    final upload = map['upload'] ?? 0;
    final download = map['download'] ?? 0;

    return SubscriptionInfo(
      total: map['total'],
      used: upload + download,
      expire: map['expire'],
    );
  }

  // ============================================================
  // UNIVERSAL SUBSCRIPTION PARSER
  // ============================================================

  List<Server> _parseSubscriptionBody(
    String body,
  ) {
    var text = body.trim();

    if (text.isEmpty) {
      return [];
    }

    // ----------------------------------------------------------
    // 1. مستقیم JSON
    // ----------------------------------------------------------

    final jsonServers =
        _parseJsonAnything(text);

    if (jsonServers.isNotEmpty) {
      return jsonServers;
    }

    // ----------------------------------------------------------
    // 2. URIهای مستقیم
    // ----------------------------------------------------------

    final direct =
        _extractUriLines(text);

    if (direct.isNotEmpty) {
      return _parseUriList(direct);
    }

    // ----------------------------------------------------------
    // 3. Base64
    // ----------------------------------------------------------

    final decoded =
        _decodeBase64(text);

    if (decoded != null) {
      final decodedJson =
          _parseJsonAnything(decoded);

      if (decodedJson.isNotEmpty) {
        return decodedJson;
      }

      final lines =
          _extractUriLines(decoded);

      if (lines.isNotEmpty) {
        return _parseUriList(lines);
      }
    }

    // ----------------------------------------------------------
    // 4. ممکن است متن Base64 چند لایه باشد
    // ----------------------------------------------------------

    if (text.length > 20) {
      final second =
          _decodeBase64(
        _removeWhitespace(text),
      );

      if (second != null &&
          second != text) {
        final lines =
            _extractUriLines(second);

        if (lines.isNotEmpty) {
          return _parseUriList(lines);
        }
      }
    }

    return [];
  }

  String _removeWhitespace(
    String text,
  ) {
    return text.replaceAll(
      RegExp(r'\s+'),
      '',
    );
  }

  List<Server> _parseJsonAnything(
    String text,
  ) {
    try {
      final decoded = jsonDecode(text);

      if (decoded is Map<String, dynamic>) {
        return _parseJsonRoot(decoded);
      }

      if (decoded is List) {
        return _parseJsonOutboundList(decoded);
      }
    } catch (_) {}

    return [];
  }

  List<Server> _parseJsonRoot(
    Map<String, dynamic> root,
  ) {
    final result = <Server>[];

    // sing-box
    final outbounds = root['outbounds'];

    if (outbounds is List) {
      result.addAll(
        _parseJsonOutboundList(
          outbounds,
        ),
      );
    }

    // بعضی Subscriptionها
    // از proxies استفاده می‌کنند.
    final proxies = root['proxies'];

    if (proxies is List) {
      result.addAll(
        _parseClashLikeProxies(
          proxies,
        ),
      );
    }

    return _uniqueServers(result);
  }

  List<Server> _parseJsonOutboundList(
    List list,
  ) {
    final result = <Server>[];

    for (int i = 0;
        i < list.length;
        i++) {
      final item = list[i];

      if (item is! Map) {
        continue;
      }

      final outbound =
          Map<String, dynamic>.from(item);

      final type =
          '${outbound['type'] ?? ''}'
              .toLowerCase();

      if (!_supportedOutboundType(type)) {
        continue;
      }

      /*
       * outboundهای گروهی مثل selector/urltest
       * را به عنوان سرور جداگانه وارد نمی‌کنیم.
       */
      if (_isGroupOutbound(type)) {
        continue;
      }

      final host =
          '${outbound['server'] ?? ''}';

      final port =
          int.tryParse(
            '${outbound['server_port'] ?? 0}',
          ) ??
          0;

      /*
       * بعضی پروتکل‌ها مثل WireGuard ممکن است
       * server نداشته باشند و endpoint داشته باشند.
       */
      var finalHost = host;
      var finalPort = port;

      if (finalHost.isEmpty) {
        final endpoint =
            '${outbound['endpoint'] ?? ''}';

        if (endpoint.isNotEmpty) {
          final parsed =
              _splitHostPort(endpoint);

          finalHost = parsed.$1;
          finalPort = parsed.$2;
        }
      }

      if (finalHost.isEmpty) {
        continue;
      }

      final tag =
          '${outbound['tag'] ?? '$type-$i'}';

      result.add(
        Server(
          raw: jsonEncode(outbound),
          name: tag,
          type: type.toUpperCase(),
          host: finalHost,
          port: finalPort,
          outbound: outbound,
        ),
      );
    }

    return _uniqueServers(result);
  }

  List<Server> _parseClashLikeProxies(
    List list,
  ) {
    final result = <Server>[];

    for (final item in list) {
      if (item is! Map) continue;

      final p =
          Map<String, dynamic>.from(item);

      final type =
          '${p['type'] ?? ''}'.toLowerCase();

      final name =
          '${p['name'] ?? p['server'] ?? type}';

      final host =
          '${p['server'] ?? ''}';

      final port =
          int.tryParse(
            '${p['port'] ?? 0}',
          ) ??
          0;

      if (host.isEmpty || port <= 0) {
        continue;
      }

      Map<String, dynamic>? outbound;

      switch (type) {
        case 'vless':
          outbound = _clashVless(p);
          break;

        case 'vmess':
          outbound = _clashVmess(p);
          break;

        case 'trojan':
          outbound = _clashTrojan(p);
          break;

        case 'ss':
        case 'shadowsocks':
          outbound = _clashShadowsocks(p);
          break;

        case 'hysteria2':
        case 'hy2':
          outbound = _clashHysteria2(p);
          break;

        case 'tuic':
          outbound = _clashTuic(p);
          break;
      }

      if (outbound == null) {
        continue;
      }

      result.add(
        Server(
          raw: jsonEncode(p),
          name: name,
          type: type.toUpperCase(),
          host: host,
          port: port,
          outbound: outbound,
        ),
      );
    }

    return result;
  }

  bool _isGroupOutbound(
    String type,
  ) {
    return {
      'selector',
      'urltest',
      'fallback',
      'loadbalance',
      'random',
      'block',
      'dns',
      'direct',
    }.contains(type);
  }

  bool _supportedOutboundType(
    String type,
  ) {
    const supported = {
      'vless',
      'vmess',
      'trojan',
      'shadowsocks',
      'hysteria',
      'hysteria2',
      'tuic',
      'anytls',
      'shadowtls',
      'http',
      'socks',
      'ssh',
      'naive',
      'wireguard',
    };

    return supported.contains(
      type.toLowerCase(),
    );
  }

  List<Server> _uniqueServers(
    List<Server> input,
  ) {
    final result = <Server>[];
    final seen = <String>{};

    for (final server in input) {
      final key =
          '${server.type}|${server.host}|${server.port}|${server.raw}';

      if (seen.add(key)) {
        result.add(server);
      }
    }

    return result;
  }

  List<String> _extractUriLines(
    String text,
  ) {
    final result = <String>[];

    for (final line
        in text.split(RegExp(r'\r?\n'))) {
      var value = line.trim();

      if (value.isEmpty) continue;

      if (value.startsWith('#') ||
          value.startsWith('//')) {
        continue;
      }

      if (value.startsWith(
        '-----BEGIN',
      )) {
        continue;
      }

      /*
       * ممکن است قبل از URI شماره یا فاصله باشد.
       */
      final match = RegExp(
        r'((?:vless|vmess|trojan|ss|shadowsocks|hysteria2|hy2|hysteria|tuic|anytls|shadowtls|http|socks5|socks)://\S+)',
        caseSensitive: false,
      ).firstMatch(value);

      if (match != null) {
        result.add(match.group(1)!);
      }
    }

    return result;
  }

  String? _decodeBase64(
    String value,
  ) {
    try {
      var encoded =
          _removeWhitespace(value);

      encoded = encoded
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      encoded += '=' *
          ((4 - encoded.length % 4) % 4);

      final bytes =
          base64.decode(encoded);

      final decoded =
          utf8.decode(
        bytes,
        allowMalformed: true,
      ).trim();

      if (decoded.contains('://') ||
          decoded.startsWith('{') ||
          decoded.startsWith('[')) {
        return decoded;
      }
    } catch (_) {}

    return null;
  }

  List<Server> _parseUriList(
    List<String> lines,
  ) {
    final result = <Server>[];

    for (final raw in lines) {
      try {
        final server =
            _parseServer(raw);

        if (server != null) {
          result.add(server);
        }
      } catch (_) {}
    }

    return _uniqueServers(result);
  }

  // ============================================================
  // URI PARSER
  // ============================================================

  Server? _parseServer(
    String raw,
  ) {
    final uri = Uri.tryParse(raw);

    if (uri == null) {
      return null;
    }

    switch (uri.scheme.toLowerCase()) {
      case 'vless':
        return _parseVless(uri, raw);

      case 'vmess':
        return _parseVmess(raw);

      case 'trojan':
        return _parseTrojan(uri, raw);

      case 'ss':
      case 'shadowsocks':
        return _parseShadowsocks(uri, raw);

      case 'hysteria2':
      case 'hy2':
        return _parseHysteria2(uri, raw);

      case 'hysteria':
        return _parseHysteria(uri, raw);

      case 'tuic':
        return _parseTuic(uri, raw);

      case 'anytls':
        return _parseAnyTLS(uri, raw);

      case 'shadowtls':
        return _parseShadowTLS(uri, raw);

      case 'http':
        return _parseHttp(uri, raw);

      case 'socks':
      case 'socks5':
        return _parseSocks(uri, raw);
    }

    return null;
  }

  // ============================================================
  // VLESS
  // ============================================================

  Server? _parseVless(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty ||
        !uri.hasPort ||
        uri.userInfo.isEmpty) {
      return null;
    }

    final q = uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'vless',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': Uri.decodeComponent(
        uri.userInfo,
      ),
    };

    final flow = q['flow'] ?? '';

    if (flow.isNotEmpty) {
      outbound['flow'] = flow;
    }

    _applyTls(
      outbound,
      q,
      defaultEnabled:
          q['security'] == 'tls' ||
          q['security'] == 'reality',
      server: uri.host,
    );

    _applyTransport(
      outbound,
      q,
    );

    return Server(
      raw: raw,
      name: _name(
        uri,
        'VLESS ${uri.host}',
      ),
      type: 'VLESS',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ============================================================
  // VMESS
  // ============================================================

  Server? _parseVmess(
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

      final decoded =
          utf8.decode(
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
        'server': host,
        'server_port': port,
        'uuid': uuid,
        'security':
            '${map['scy'] ?? 'auto'}',
      };

      final network =
          '${map['net'] ?? 'tcp'}';

      final tls =
          '${map['tls'] ?? ''}';

      final q =
          <String, String>{
        'sni':
            '${map['sni'] ?? ''}',
        'host':
            '${map['host'] ?? ''}',
        'path':
            '${map['path'] ?? ''}',
        'type': network,
        'security': tls,
        'fp':
            '${map['fp'] ?? ''}',
        'pbk':
            '${map['pbk'] ?? ''}',
        'sid':
            '${map['sid'] ?? ''}',
      };

      _applyTls(
        outbound,
        q,
        defaultEnabled:
            tls == 'tls',
        server: host,
      );

      if (tls.toLowerCase() == 'reality') {
        _applyTls(
          outbound,
          q,
          defaultEnabled: true,
          server: host,
        );
      }

      _applyTransport(
        outbound,
        q,
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
  // TROJAN
  // ============================================================

  Server? _parseTrojan(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty ||
        !uri.hasPort ||
        uri.userInfo.isEmpty) {
      return null;
    }

    final q = uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'trojan',
      'server': uri.host,
      'server_port': uri.port,
      'password':
          Uri.decodeComponent(
        uri.userInfo,
      ),
    };

    _applyTls(
      outbound,
      q,
      defaultEnabled: true,
      server: uri.host,
    );

    _applyTransport(
      outbound,
      q,
    );

    return Server(
      raw: raw,
      name: _name(
        uri,
        'Trojan ${uri.host}',
      ),
      type: 'TROJAN',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ============================================================
  // SHADOWSOCKS
  // ============================================================

  Server? _parseShadowsocks(
    Uri uri,
    String raw,
  ) {
    try {
      String user = uri.userInfo;

      if (user.isEmpty) {
        var encoded =
            raw.substring(
          raw.indexOf('://') + 3,
        );

        encoded = encoded
            .split('#')
            .first
            .replaceAll('-', '+')
            .replaceAll('_', '/');

        encoded += '=' *
            ((4 - encoded.length % 4) %
                4);

        user = utf8.decode(
          base64.decode(encoded),
          allowMalformed: true,
        );
      }

      final index = user.indexOf(':');

      if (index <= 0 ||
          uri.host.isEmpty ||
          !uri.hasPort) {
        return null;
      }

      final method =
          Uri.decodeComponent(
        user.substring(0, index),
      );

      final password =
          Uri.decodeComponent(
        user.substring(index + 1),
      );

      final q = uri.queryParameters;

      final outbound =
          <String, dynamic>{
        'type': 'shadowsocks',
        'server': uri.host,
        'server_port': uri.port,
        'method': method,
        'password': password,
      };

      if ((q['plugin'] ?? '').isNotEmpty) {
        final plugin =
            q['plugin']!;

        final parts =
            plugin.split(';');

        outbound['plugin'] =
            parts.first;

        if (parts.length > 1) {
          outbound['plugin_opts'] =
              parts.skip(1).join(';');
        }
      }

      return Server(
        raw: raw,
        name: _name(
          uri,
          'SS ${uri.host}',
        ),
        type: 'SHADOWSOCKS',
        host: uri.host,
        port: uri.port,
        outbound: outbound,
      );
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // HYSTERIA2
  // ============================================================

  Server? _parseHysteria2(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty ||
        !uri.hasPort) {
      return null;
    }

    final q = uri.queryParameters;

    final password =
        Uri.decodeComponent(
      uri.userInfo,
    );

    final outbound =
        <String, dynamic>{
      'type': 'hysteria2',
      'server': uri.host,
      'server_port': uri.port,
      'password': password,
      'tls': {
        'enabled': true,
        'server_name':
            q['sni'] ??
            q['peer'] ??
            uri.host,
      },
    };

    if (q['insecure'] == '1' ||
        q['insecure'] == 'true') {
      outbound['tls']['insecure'] = true;
    }

    final obfs =
        q['obfs'] ?? '';

    final obfsPassword =
        q['obfs-password'] ??
            q['obfs_password'] ??
            '';

    if (obfs.isNotEmpty &&
        obfsPassword.isNotEmpty) {
      outbound['obfs'] = {
        'type': obfs,
        'password': obfsPassword,
      };
    }

    if ((q['hop-interval'] ?? '')
        .isNotEmpty) {
      outbound['hop_interval'] =
          q['hop-interval'];
    }

    return Server(
      raw: raw,
      name: _name(
        uri,
        'Hysteria2 ${uri.host}',
      ),
      type: 'HYSTERIA2',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ============================================================
  // HYSTERIA OLD
  // ============================================================

  Server? _parseHysteria(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty ||
        !uri.hasPort) {
      return null;
    }

    final q = uri.queryParameters;

    final password =
        uri.userInfo.isNotEmpty
            ? Uri.decodeComponent(
                uri.userInfo,
              )
            : (q['auth'] ??
                q['password'] ??
                '');

    final outbound =
        <String, dynamic>{
      'type': 'hysteria',
      'server': uri.host,
      'server_port': uri.port,
      if (password.isNotEmpty)
        'auth_str': password,
      'tls': {
        'enabled': true,
        'server_name':
            q['sni'] ??
            q['peer'] ??
            uri.host,
      },
    };

    if (q['insecure'] == '1' ||
        q['insecure'] == 'true') {
      outbound['tls']['insecure'] = true;
    }

    return Server(
      raw: raw,
      name: _name(
        uri,
        'Hysteria ${uri.host}',
      ),
      type: 'HYSTERIA',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ============================================================
  // TUIC
  // ============================================================

  Server? _parseTuic(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty ||
        !uri.hasPort) {
      return null;
    }

    final q = uri.queryParameters;

    String uuid = '';
    String password = '';

    if (uri.userInfo.contains(':')) {
      final split =
          uri.userInfo.split(':');

      uuid =
          Uri.decodeComponent(
        split.first,
      );

      password =
          Uri.decodeComponent(
        split.sublist(1).join(':'),
      );
    } else {
      uuid =
          Uri.decodeComponent(
        q['uuid'] ?? '',
      );

      password =
          Uri.decodeComponent(
        q['password'] ?? '',
      );
    }

    if (uuid.isEmpty ||
        password.isEmpty) {
      return null;
    }

    final outbound =
        <String, dynamic>{
      'type': 'tuic',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uuid,
      'password': password,
      'congestion_control':
          q['congestion_control'] ??
          'cubic',
      'udp_relay_mode':
          q['udp_relay_mode'] ??
          'native',
      'zero_rtt_handshake':
          q['zero_rtt_handshake'] ==
              'true',
      'tls': {
        'enabled': true,
        'server_name':
            q['sni'] ??
            q['server_name'] ??
            uri.host,
      },
    };

    return Server(
      raw: raw,
      name: _name(
        uri,
        'TUIC ${uri.host}',
      ),
      type: 'TUIC',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ============================================================
  // ANYTLS
  // ============================================================

  Server? _parseAnyTLS(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty ||
        !uri.hasPort ||
        uri.userInfo.isEmpty) {
      return null;
    }

    final q = uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'anytls',
      'server': uri.host,
      'server_port': uri.port,
      'password':
          Uri.decodeComponent(
        uri.userInfo,
      ),
      'tls': {
        'enabled': true,
        'server_name':
            q['sni'] ??
            uri.host,
      },
    };

    return Server(
      raw: raw,
      name: _name(
        uri,
        'AnyTLS ${uri.host}',
      ),
      type: 'ANYTLS',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ============================================================
  // SHADOWTLS
  // ============================================================

  Server? _parseShadowTLS(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty ||
        !uri.hasPort) {
      return null;
    }

    final q = uri.queryParameters;

    final password =
        Uri.decodeComponent(
      uri.userInfo,
    );

    final version =
        int.tryParse(
          q['version'] ?? '3',
        ) ??
        3;

    final outbound =
        <String, dynamic>{
      'type': 'shadowtls',
      'server': uri.host,
      'server_port': uri.port,
      'version': version,
      if (password.isNotEmpty)
        'password': password,
      'tls': {
        'enabled': true,
        'server_name':
            q['sni'] ??
            q['host'] ??
            uri.host,
      },
    };

    return Server(
      raw: raw,
      name: _name(
        uri,
        'ShadowTLS ${uri.host}',
      ),
      type: 'SHADOWTLS',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ============================================================
  // HTTP PROXY
  // ============================================================

  Server? _parseHttp(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty ||
        !uri.hasPort) {
      return null;
    }

    final outbound =
        <String, dynamic>{
      'type': 'http',
      'server': uri.host,
      'server_port': uri.port,
    };

    if (uri.userInfo.isNotEmpty) {
      final split =
          uri.userInfo.split(':');

      if (split.isNotEmpty) {
        outbound['username'] =
            Uri.decodeComponent(
          split.first,
        );
      }

      if (split.length > 1) {
        outbound['password'] =
            Uri.decodeComponent(
          split.sublist(1).join(':'),
        );
      }
    }

    final q = uri.queryParameters;

    if (q['security'] == 'tls' ||
        q['tls'] == '1') {
      outbound['tls'] = {
        'enabled': true,
        'server_name':
            q['sni'] ??
            uri.host,
      };
    }

    return Server(
      raw: raw,
      name: _name(
        uri,
        'HTTP ${uri.host}',
      ),
      type: 'HTTP',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ============================================================
  // SOCKS
  // ============================================================

  Server? _parseSocks(
    Uri uri,
    String raw,
  ) {
    if (uri.host.isEmpty ||
        !uri.hasPort) {
      return null;
    }

    final version =
        uri.scheme.toLowerCase() == 'socks'
            ? '5'
            : '5';

    final outbound =
        <String, dynamic>{
      'type': 'socks',
      'server': uri.host,
      'server_port': uri.port,
      'version': version,
    };

    if (uri.userInfo.isNotEmpty) {
      final split =
          uri.userInfo.split(':');

      if (split.isNotEmpty) {
        outbound['username'] =
            Uri.decodeComponent(
          split.first,
        );
      }

      if (split.length > 1) {
        outbound['password'] =
            Uri.decodeComponent(
          split.sublist(1).join(':'),
        );
      }
    }

    return Server(
      raw: raw,
      name: _name(
        uri,
        'SOCKS ${uri.host}',
      ),
      type: 'SOCKS',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ============================================================
  // TLS
  // ============================================================

  void _applyTls(
    Map<String, dynamic> outbound,
    Map<String, String> q, {
    required bool defaultEnabled,
    required String server,
  }) {
    final security =
        (q['security'] ?? '')
            .toLowerCase();

    final enabled =
        defaultEnabled ||
        security == 'tls' ||
        security == 'reality';

    if (!enabled) {
      return;
    }

    final serverName =
        q['sni'] ??
        q['serverName'] ??
        q['server_name'] ??
        q['host'] ??
        server;

    final tls =
        <String, dynamic>{
      'enabled': true,
      'server_name': serverName,
    };

    final fp =
        q['fp'] ??
        q['fingerprint'] ??
        '';

    if (fp.isNotEmpty) {
      tls['utls'] = {
        'enabled': true,
        'fingerprint': fp,
      };
    }

    if (security == 'reality') {
      final publicKey =
          q['pbk'] ??
          q['publicKey'] ??
          '';

      final shortId =
          q['sid'] ??
          q['shortId'] ??
          '';

      if (publicKey.isNotEmpty) {
        tls['reality'] = {
          'enabled': true,
          'public_key': publicKey,
          if (shortId.isNotEmpty)
            'short_id': shortId,
        };
      }
    }

    outbound['tls'] = tls;
  }

  // ============================================================
  // V2RAY TRANSPORT
  // ============================================================

  void _applyTransport(
    Map<String, dynamic> outbound,
    Map<String, String> q,
  ) {
    final network =
        (q['type'] ??
                q['network'] ??
                'tcp')
            .toLowerCase();

    final path =
        q['path'] ?? '';

    final host =
        q['host'] ??
        q['Host'] ??
        '';

    switch (network) {
      case 'ws':
      case 'websocket':
        outbound['transport'] = {
          'type': 'ws',
          'path':
              path.isEmpty ? '/' : path,
          if (host.isNotEmpty)
            'headers': {
              'Host': host,
            },
        };
        break;

      case 'grpc':
        outbound['transport'] = {
          'type': 'grpc',
          'service_name': path,
        };
        break;

      case 'httpupgrade':
      case 'http-upgrade':
        outbound['transport'] = {
          'type': 'httpupgrade',
          'path':
              path.isEmpty ? '/' : path,
          if (host.isNotEmpty)
            'host': host,
        };
        break;

      case 'h2':
      case 'http':
        outbound['transport'] = {
          'type': 'http',
          'path':
              path.isEmpty ? '/' : path,
          if (host.isNotEmpty)
            'host': [host],
        };
        break;

      case 'quic':
        outbound['transport'] = {
          'type': 'quic',
        };
        break;

      case 'tcp':
      default:
        break;
    }
  }

  // ============================================================
  // CLASH -> SING-BOX
  // ============================================================

  Map<String, dynamic>? _clashVless(
    Map<String, dynamic> p,
  ) {
    final uuid =
        '${p['uuid'] ?? ''}';

    final server =
        '${p['server'] ?? ''}';

    final port =
        int.tryParse(
          '${p['port'] ?? 0}',
        ) ??
        0;

    if (uuid.isEmpty ||
        server.isEmpty ||
        port <= 0) {
      return null;
    }

    final o =
        <String, dynamic>{
      'type': 'vless',
      'server': server,
      'server_port': port,
      'uuid': uuid,
    };

    if ('${p['flow'] ?? ''}'.isNotEmpty) {
      o['flow'] = '${p['flow']}';
    }

    if (p['tls'] == true) {
      o['tls'] = {
        'enabled': true,
        'server_name':
            '${p['servername'] ?? server}',
      };
    }

    final network =
        '${p['network'] ?? ''}';

    if (network == 'ws') {
      o['transport'] = {
        'type': 'ws',
        'path':
            '${p['ws-opts']?['path'] ?? '/'}',
      };
    }

    return o;
  }

  Map<String, dynamic>? _clashVmess(
    Map<String, dynamic> p,
  ) {
    final uuid =
        '${p['uuid'] ?? ''}';

    final server =
        '${p['server'] ?? ''}';

    final port =
        int.tryParse(
          '${p['port'] ?? 0}',
        ) ??
        0;

    if (uuid.isEmpty ||
        server.isEmpty ||
        port <= 0) {
      return null;
    }

    final o =
        <String, dynamic>{
      'type': 'vmess',
      'server': server,
      'server_port': port,
      'uuid': uuid,
      'security':
          '${p['cipher'] ?? 'auto'}',
    };

    if (p['tls'] == true) {
      o['tls'] = {
        'enabled': true,
        'server_name':
            '${p['servername'] ?? server}',
      };
    }

    return o;
  }

  Map<String, dynamic>? _clashTrojan(
    Map<String, dynamic> p,
  ) {
    final password =
        '${p['password'] ?? ''}';

    final server =
        '${p['server'] ?? ''}';

    final port =
        int.tryParse(
          '${p['port'] ?? 0}',
        ) ??
        0;

    if (password.isEmpty ||
        server.isEmpty ||
        port <= 0) {
      return null;
    }

    return {
      'type': 'trojan',
      'server': server,
      'server_port': port,
      'password': password,
      'tls': {
        'enabled': true,
        'server_name':
            '${p['sni'] ?? p['servername'] ?? server}',
      },
    };
  }

  Map<String, dynamic>? _clashShadowsocks(
    Map<String, dynamic> p,
  ) {
    final server =
        '${p['server'] ?? ''}';

    final port =
        int.tryParse(
          '${p['port'] ?? 0}',
        ) ??
        0;

    final method =
        '${p['cipher'] ?? ''}';

    final password =
        '${p['password'] ?? ''}';

    if (server.isEmpty ||
        port <= 0 ||
        method.isEmpty ||
        password.isEmpty) {
      return null;
    }

    return {
      'type': 'shadowsocks',
      'server': server,
      'server_port': port,
      'method': method,
      'password': password,
    };
  }

  Map<String, dynamic>? _clashHysteria2(
    Map<String, dynamic> p,
  ) {
    final server =
        '${p['server'] ?? ''}';

    final port =
        int.tryParse(
          '${p['port'] ?? 0}',
        ) ??
        0;

    final password =
        '${p['password'] ?? ''}';

    if (server.isEmpty ||
        port <= 0) {
      return null;
    }

    return {
      'type': 'hysteria2',
      'server': server,
      'server_port': port,
      'password': password,
      'tls': {
        'enabled': true,
        'server_name':
            '${p['sni'] ?? server}',
        if (p['skip-cert-verify'] == true)
          'insecure': true,
      },
    };
  }

  Map<String, dynamic>? _clashTuic(
    Map<String, dynamic> p,
  ) {
    final server =
        '${p['server'] ?? ''}';

    final port =
        int.tryParse(
          '${p['port'] ?? 0}',
        ) ??
        0;

    final uuid =
        '${p['uuid'] ?? ''}';

    final password =
        '${p['password'] ?? ''}';

    if (server.isEmpty ||
        port <= 0 ||
        uuid.isEmpty ||
        password.isEmpty) {
      return null;
    }

    return {
      'type': 'tuic',
      'server': server,
      'server_port': port,
      'uuid': uuid,
      'password': password,
      'tls': {
        'enabled': true,
        'server_name':
            '${p['sni'] ?? server}',
      },
    };
  }

  // ============================================================
  // HOST:PORT
  // ============================================================

  (String, int) _splitHostPort(
    String value,
  ) {
    var text = value.trim();

    if (text.startsWith('[')) {
      final end = text.indexOf(']');

      if (end > 0) {
        final host =
            text.substring(1, end);

        var port = 0;

        if (text.length > end + 1 &&
            text[end + 1] == ':') {
          port =
              int.tryParse(
                text.substring(end + 2),
              ) ??
              0;
        }

        return (
          host,
          port,
        );
      }
    }

    final index = text.lastIndexOf(':');

    if (index > 0) {
      final host =
          text.substring(0, index);

      final port =
          int.tryParse(
            text.substring(index + 1),
          ) ??
          0;

      return (
        host,
        port,
      );
    }

    return (
      text,
      0,
    );
  }

  String _name(
    Uri uri,
    String fallback,
  ) {
    if (uri.fragment.isEmpty) {
      return fallback;
    }

    try {
      return Uri.decodeComponent(
        uri.fragment,
      );
    } catch (_) {
      return uri.fragment;
    }
  }

  // ============================================================
  // SING-BOX CONFIG
  // ============================================================

  String _buildConfig() {
    final valid =
        servers
            .where(
              (s) => s.usable,
            )
            .toList();

    if (valid.isEmpty) {
      throw Exception(
        'هیچ outbound معتبری وجود ندارد',
      );
    }

    final outbounds =
        <Map<String, dynamic>>[];

    final tags =
        <String>[];

    for (int i = 0;
        i < valid.length;
        i++) {
      final server = valid[i];

      final outbound =
          _deepCopyMap(
        server.outbound,
      );

      final tag =
          'node-$i';

      outbound['tag'] = tag;

      /*
       * بعضی JSONها ممکن است tag یا فیلدهای
       * اضافی نامعتبر داشته باشند.
       *
       * type/server/server_port را دست نمی‌زنیم.
       */
      outbounds.add(outbound);
      tags.add(tag);
    }

    /*
     * خروجی مستقیم فقط برای fallback و
     * سرویس‌های داخلی است.
     */
    outbounds.add({
      'type': 'direct',
      'tag': 'direct',
    });

    final useAuto =
        tags.length > 1;

    if (useAuto) {
      outbounds.add({
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

    /*
     * مهم:
     *
     * TUN تمام ترافیک گوشی را می‌گیرد.
     *
     * DNS داخل TUN hijack می‌شود.
     *
     * final = auto یعنی تمام ترافیک عادی
     * از URLTest عبور می‌کند.
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
        'strategy': 'prefer_ipv4',
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

      'outbounds': outbounds,

      'route': {
        /*
         * برای Android VPN/TUN.
         */
        'override_android_vpn': true,

        'rules': [
          {
            'protocol': 'dns',
            'action': 'hijack-dns',
          },
        ],

        'final':
            useAuto
                ? 'auto'
                : tags.first,
      },
    });
  }

  Map<String, dynamic> _deepCopyMap(
    Map<String, dynamic> source,
  ) {
    final decoded =
        jsonDecode(
      jsonEncode(source),
    );

    return Map<String, dynamic>.from(
      decoded,
    );
  }

  // ============================================================
  // SERVER TEST
  // ============================================================

  Future<void> testAllServers() async {
    if (servers.isEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        testing = true;
        stateText =
            'در حال بررسی سرورها...';
      });
    }

    /*
     * این تست فقط TCP diagnostic است.
     *
     * معیار اتصال نهایی نیست.
     *
     * سروری که TCP مستقیمش جواب نمی‌دهد
     * را حذف نمی‌کنیم؛ چون ممکن است TLS/
     * Reality/Proxy آن کار کند.
     */
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

    if (mounted) {
      setState(() {
        testing = false;
        stateText =
            '${servers.length} سرور آماده اتصال';
      });
    }
  }

  // ============================================================
  // CONNECT
  // ============================================================

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
      internetStatus =
          'در حال اتصال...';
      stateText =
          'در حال آماده‌سازی VPN...';
    });

    try {
      /*
       * Android VpnService permission
       */
      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'اجازه VPN داده نشد',
        );
      }

      /*
       * تمام سرورها وارد sing-box می‌شوند.
       *
       * دیگر با Socket.connect تصمیم
       * نمی‌گیریم که کدام سرور استفاده شود.
       */
      final config =
          _buildConfig();

      setState(() {
        stateText =
            'در حال بررسی کانفیگ...';
      });

      await vpn.checkConfig(config);

      setState(() {
        stateText =
            'در حال راه‌اندازی TUN...';
      });

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

        internetStatus =
            '🟡 در حال بررسی عبور اینترنت...';

        stateText =
            'VPN متصل است';
      });

      _startDuration();

      /*
       * اجازه می‌دهیم TUN کاملاً بالا بیاید.
       */
      Future.delayed(
        const Duration(seconds: 3),
        () {
          if (mounted && connected) {
            testInternet();
          }
        },
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        connected = false;
        connecting = false;

        stateText =
            'اتصال ناموفق';

        internetStatus =
            '🔴 اینترنت عبور نمی‌کند';

        lastFault =
            e.toString();
      });

      _showMessage(
        'اتصال ناموفق بود؛ خطای sing-box را پایین صفحه ببین',
      );
    }
  }

  // ============================================================
  // INTERNET TEST
  // ============================================================

  Future<void> testInternet() async {
    if (!connected ||
        internetTestRunning) {
      return;
    }

    setState(() {
      internetTestRunning = true;
      internetStatus =
          'در حال تست اینترنت...';
    });

    try {
      final client =
          HttpClient();

      client.connectionTimeout =
          const Duration(seconds: 8);

      /*
       * یک درخواست HTTPS واقعی انجام می‌دهیم.
       *
       * اگر TUN درست کار کند، این درخواست
       * باید از مسیر VPN عبور کند.
       */
      final request =
          await client.getUrl(
        Uri.parse(
          'https://www.gstatic.com/generate_204',
        ),
      );

      request.headers.set(
        HttpHeaders.userAgentHeader,
        'LightSpeed/2.0',
      );

      request.headers.set(
        HttpHeaders.cacheControlHeader,
        'no-cache',
      );

      final response =
          await request.close().timeout(
        const Duration(seconds: 8),
      );

      await response.drain();
      client.close();

      if (!mounted) return;

      if (response.statusCode == 204 ||
          (response.statusCode >= 200 &&
              response.statusCode < 400)) {
        setState(() {
          internetStatus =
              '🟢 اینترنت عبور می‌کند';
        });
      } else {
        setState(() {
          internetStatus =
              '🔴 پاسخ اینترنت نامعتبر';
        });
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        internetStatus =
            '🔴 اینترنت عبور نمی‌کند';

        lastFault =
            'Internet test: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          internetTestRunning = false;
        });
      }
    }
  }

  // ============================================================
  // DISCONNECT
  // ============================================================

  Future<void> disconnect() async {
    try {
      await vpn.disconnect();
    } catch (e) {
      if (mounted) {
        setState(() {
          lastFault =
              'Disconnect: $e';
        });
      }
    }

    durationTimer?.cancel();

    if (!mounted) return;

    setState(() {
      connected = false;
      connecting = false;

      stateText =
          'اتصال قطع شد';

      internetStatus =
          'VPN قطع است';

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

  // ============================================================
  // DURATION
  // ============================================================

  void _startDuration() {
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
  }

  // ============================================================
  // FORMAT
  // ============================================================

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

    if (bytes < 1024 * 1024) {
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

    final days =
        remaining.inDays;

    final hours =
        remaining.inHours % 24;

    return '$days روز و $hours ساعت';
  }

  void _showMessage(
    String message,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content:
            Text(message),
        behavior:
            SnackBarBehavior.floating,
      ),
    );
  }

  // ============================================================
  // UI
  // ============================================================

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
            /*
             * ظاهر فعلی حفظ شده.
             */
            _showMessage(
              'بخش $index در مرحله بعدی فعال می‌شود',
            );
          },
        ),
      ),
    );
  }

  Widget _home() {
    final alive =
        servers
            .where(
              (s) => s.ping != null,
            )
            .length;

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
            const SizedBox(
              width: 12,
            ),
            Expanded(
              child: Column(
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
            ),
            IconButton(
              onPressed:
                  loading || connected
                      ? null
                      : () =>
                          loadSubscription(),
              icon:
                  const Icon(Icons.refresh),
            ),
          ],
        ),

        const SizedBox(
          height: 25,
        ),

        _connectButton(),

        const SizedBox(
          height: 20,
        ),

        _internetCard(),

        const SizedBox(
          height: 10,
        ),

        Row(
          children: [
            Expanded(
              child: _statCard(
                Icons.dns,
                'سرورها',
                '${servers.length}',
              ),
            ),
            const SizedBox(
              width: 10,
            ),
            Expanded(
              child: _statCard(
                Icons.check_circle,
                'قابل بررسی',
                '$alive',
              ),
            ),
          ],
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
            const SizedBox(
              width: 10,
            ),
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
          'VPN',
        ),

        _infoCard(
          Icons.upload_file,
          'ارسال این جلسه',
          _formatBytes(
            uploadTotalBytes,
          ),
          'VPN',
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
          _formatBytes(
            usedBytes,
          ),
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
              color:
                  Colors.red.withValues(
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
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }

  Widget _internetCard() {
    final good =
        internetStatus.contains('🟢');

    final bad =
        internetStatus.contains('🔴');

    final color = good
        ? Colors.greenAccent
        : bad
            ? Colors.redAccent
            : Colors.white54;

    return Container(
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
              color.withValues(
            alpha: .25,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            good
                ? Icons.wifi
                : bad
                    ? Icons.wifi_off
                    : Icons.wifi_find,
            color: color,
            size: 30,
          ),
          const SizedBox(
            width: 12,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                const Text(
                  'وضعیت عبور اینترنت',
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
                  internetStatus,
                  style:
                      TextStyle(
                    color: color,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          if (internetTestRunning)
            const SizedBox(
              width: 20,
              height: 20,
              child:
                  CircularProgressIndicator(
                strokeWidth: 2,
              ),
            )
          else
            IconButton(
              onPressed:
                  connected
                      ? testInternet
                      : null,
              icon:
                  const Icon(
                Icons.refresh,
              ),
            ),
        ],
      ),
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
            size: 30,
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
            height: 3,
          ),
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
          const SizedBox(
            width: 12,
          ),
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
                const SizedBox(
                  height: 3,
                ),
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
              fontSize: 11,
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
