import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

// ============================================================
// APP
// ============================================================

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
          seedColor: const Color(0xFF00D4FF),
          brightness: Brightness.dark,
        ),
        fontFamily: 'sans',
      ),
      home: const HomePage(),
    );
  }
}

// ============================================================
// SERVER MODEL
// ============================================================

class Server {
  final String raw;
  final String name;
  final String type;
  final String host;
  final int port;
  final Map<String, dynamic> outbound;

  int? ping;

  Server({
    required this.raw,
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    required this.outbound,
    this.ping,
  });
}

// ============================================================
// HOME
// ============================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver {
  String url = '';

  List<Server> servers = [];

  StreamSubscription? stateSub;
  StreamSubscription? trafficSub;
  StreamSubscription? faultSub;

  Timer? refreshTimer;

  int page = 0;

  bool loading = false;
  bool testing = false;
  bool connected = false;
  bool connecting = false;

  bool autoSelectFastest = true;

  int selectedServerIndex = 0;

  String stateText = 'آماده اتصال';

  int download = 0;
  int upload = 0;

  int downloadTotalBytes = 0;
  int uploadTotalBytes = 0;

  int? totalBytes;
  int? usedBytes;
  int? uploadBytes;
  int? downloadBytes;
  int? expireAt;

  String subscriptionTitle = '';

  String lastFault = '';

  DateTime? connectedAt;

  final TextEditingController urlController =
      TextEditingController();

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    stateSub = vpn.serviceStateStream.listen((state) {
      if (!mounted) return;

      final value = state.toString().toLowerCase();

      setState(() {
        connected = value.contains('connected');
        connecting = value.contains('connecting');

        if (value.contains('disconnected')) {
          connected = false;
          connecting = false;
          stateText = 'قطع شده';
        } else if (value.contains('connected')) {
          connected = true;
          connecting = false;
          stateText = 'متصل';
        } else if (value.contains('connecting')) {
          connecting = true;
          stateText = 'در حال اتصال...';
        }
      });
    });

    trafficSub = vpn.trafficStatsStream.listen((stats) {
      if (!mounted) return;

      setState(() {
        download = stats.downlinkBps;
        upload = stats.uplinkBps;

        downloadTotalBytes = stats.downlinkTotalBytes;
        uploadTotalBytes = stats.uplinkTotalBytes;
      });
    });

    faultSub = vpn.faultStream.listen((error) {
      if (!mounted) return;

      setState(() {
        lastFault = error.toString();
        connecting = false;
      });

      _showSnack(error.toString());
    });

    refreshTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) {
        if (!connected && !loading) {
          loadSubscription(silent: true);
        }
      },
    );

    loadSaved();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !connected &&
        !loading) {
      loadSubscription(silent: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    stateSub?.cancel();
    trafficSub?.cancel();
    faultSub?.cancel();

    refreshTimer?.cancel();

    urlController.dispose();

    super.dispose();
  }

  // ==========================================================
  // STORAGE
  // ==========================================================

  Future<void> loadSaved() async {
    final prefs = await SharedPreferences.getInstance();

    final saved = prefs.getString('subscription_url');

    if (saved != null && saved.trim().isNotEmpty) {
      url = saved.trim();
      urlController.text = url;

      if (mounted) {
        setState(() {});
      }

      await loadSubscription(silent: true);
    }
  }

  Future<void> saveUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'subscription_url',
      value.trim(),
    );
  }

  // ==========================================================
  // HTTP HEADER
  // ==========================================================

  String? responseHeader(
    Map<String, String> headers,
    String name,
  ) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) {
        return entry.value;
      }
    }

    return null;
  }

  // ==========================================================
  // SUBSCRIPTION USERINFO
  // ==========================================================

  void readSubscriptionUserInfo(String? value) {
    if (value == null || value.trim().isEmpty) return;

    int? uploadValue;
    int? downloadValue;
    int? totalValue;
    int? expireValue;

    final parts = value.split(RegExp(r'[;,]'));

    for (final part in parts) {
      final p = part.trim();

      if (!p.contains('=')) continue;

      final index = p.indexOf('=');

      final key = p
          .substring(0, index)
          .trim()
          .toLowerCase();

      final raw = p.substring(index + 1).trim();

      final number = int.tryParse(raw);

      if (number == null) continue;

      switch (key) {
        case 'upload':
        case 'u':
          uploadValue = number;
          break;

        case 'download':
        case 'd':
          downloadValue = number;
          break;

        case 'total':
        case 'transfer_enable':
        case 'transfer-enabled':
        case 'transfer':
          totalValue = number;
          break;

        case 'expire':
        case 'expired':
        case 'expired_at':
        case 'expire_at':
          expireValue = number;
          break;
      }
    }

    uploadBytes = uploadValue;
    downloadBytes = downloadValue;

    if (uploadValue != null || downloadValue != null) {
      usedBytes =
          (uploadValue ?? 0) + (downloadValue ?? 0);
    }

    if (totalValue != null) {
      totalBytes =
          totalValue == 0 ? null : totalValue;
    }

    if (expireValue != null && expireValue > 0) {
      expireAt = expireValue;
    }
  }

  void readSubscriptionHeaders(
    Map<String, String> headers,
  ) {
    final userInfo =
        responseHeader(
      headers,
      'subscription-userinfo',
    );

    final title =
        responseHeader(
      headers,
      'profile-title',
    );

    readSubscriptionUserInfo(userInfo);

    if (title != null &&
        title.trim().isNotEmpty) {
      subscriptionTitle = title.trim();
    }
  }

  // ==========================================================
  // BASE64
  // ==========================================================

  String _normalizeBase64(String input) {
    var value = input.trim();

    value = value.replaceAll(
      RegExp(r'\s+'),
      '',
    );

    value = value.replaceAll('-', '+');
    value = value.replaceAll('_', '/');

    while (value.length % 4 != 0) {
      value += '=';
    }

    return value;
  }

  String? decodeBase64(String input) {
    try {
      final normalized =
          _normalizeBase64(input);

      final bytes =
          base64.decode(normalized);

      final text =
          utf8.decode(bytes);

      if (text.trim().isEmpty) {
        return null;
      }

      return text;
    } catch (_) {
      return null;
    }
  }

  bool looksLikeConfig(String text) {
    final lower =
        text.trim().toLowerCase();

    return lower.startsWith('vless://') ||
        lower.startsWith('vmess://') ||
        lower.startsWith('trojan://') ||
        lower.startsWith('ss://') ||
        lower.startsWith('hysteria2://') ||
        lower.startsWith('hy2://') ||
        lower.startsWith('tuic://');
  }

  // ==========================================================
  // SUBSCRIPTION DECODER
  // ==========================================================

  List<String> decodeSubscription(
    String body,
  ) {
    final result = <String>{};

    final cleaned = body.trim();

    if (cleaned.isEmpty) {
      return [];
    }

    // --------------------------------------------------------
    // Direct share links
    // --------------------------------------------------------

    final directRegex = RegExp(
      r'(vless|vmess|trojan|ss|hysteria2|hy2|tuic)://[^\s]+',
      caseSensitive: false,
    );

    for (final match
        in directRegex.allMatches(cleaned)) {
      var line =
          match.group(0)?.trim();

      if (line == null ||
          line.isEmpty) {
        continue;
      }

      line = line.replaceAll(
        RegExp(r'[\r\n]+$'),
        '',
      );

      result.add(line);
    }

    // --------------------------------------------------------
    // Entire response Base64
    // --------------------------------------------------------

    final decodedWhole =
        decodeBase64(cleaned);

    if (decodedWhole != null) {
      for (final line
          in decodedWhole.split(
        RegExp(r'\r?\n'),
      )) {
        final value = line.trim();

        if (looksLikeConfig(value)) {
          result.add(value);
        }
      }

      // Nested Base64
      if (!looksLikeConfig(decodedWhole) &&
          decodedWhole.length > 20) {
        final decodedAgain =
            decodeBase64(decodedWhole);

        if (decodedAgain != null) {
          for (final line
              in decodedAgain.split(
            RegExp(r'\r?\n'),
          )) {
            final value = line.trim();

            if (looksLikeConfig(value)) {
              result.add(value);
            }
          }
        }
      }
    }

    // --------------------------------------------------------
    // Each line Base64
    // --------------------------------------------------------

    for (final rawLine
        in cleaned.split(
      RegExp(r'\r?\n'),
    )) {
      final line = rawLine.trim();

      if (line.isEmpty) continue;

      if (looksLikeConfig(line)) {
        result.add(line);
        continue;
      }

      final decodedLine =
          decodeBase64(line);

      if (decodedLine == null) continue;

      for (final item
          in decodedLine.split(
        RegExp(r'\r?\n'),
      )) {
        final value = item.trim();

        if (looksLikeConfig(value)) {
          result.add(value);
        }
      }
    }

    return result.toList();
  }

  // ==========================================================
  // LOAD SUBSCRIPTION
  // ==========================================================

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    if (url.trim().isEmpty) {
      if (!silent) {
        _showSnack(
          'آدرس Subscription وارد نشده است',
        );
      }

      return;
    }

    if (loading) return;

    setStateSafe(() {
      loading = true;
      stateText =
          'در حال دریافت Subscription...';
    });

    try {
      final uri =
          Uri.parse(url.trim());

      final response = await http
          .get(
            uri,
            headers: const {
              'User-Agent':
                  'LightSpeed/3.0',
              'Accept': '*/*',
              'Cache-Control':
                  'no-cache',
              'Pragma':
                  'no-cache',
            },
          )
          .timeout(
        const Duration(seconds: 60),
      );

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw Exception(
          'HTTP ${response.statusCode}',
        );
      }

      totalBytes = null;
      usedBytes = null;
      uploadBytes = null;
      downloadBytes = null;
      expireAt = null;
      subscriptionTitle = '';

      readSubscriptionHeaders(
        response.headers,
      );

      final links =
          decodeSubscription(
        response.body,
      );

      if (links.isEmpty) {
        throw Exception(
          'هیچ کانفیگ معتبری در Subscription پیدا نشد',
        );
      }

      final parsed = <Server>[];

      for (final link in links) {
        try {
          final server =
              parseServer(link);

          if (server != null) {
            parsed.add(server);
          }
        } catch (_) {}
      }

      final unique =
          <String, Server>{};

      for (final server in parsed) {
        unique[server.raw] = server;
      }

      servers =
          unique.values.toList();

      if (servers.isEmpty) {
        throw Exception(
          'Subscription دریافت شد ولی هیچ پروتکل پشتیبانی‌شده‌ای پیدا نشد',
        );
      }

      selectedServerIndex = 0;

      await saveUrl(url);

      setStateSafe(() {
        stateText =
            '${servers.length} سرور دریافت شد';

        loading = false;
      });

      await testAll(silent: true);

      setStateSafe(() {
        stateText =
            '${servers.length} سرور آماده است';
      });
    } catch (e) {
      setStateSafe(() {
        loading = false;
        stateText =
            'خطا در دریافت Subscription';
      });

      if (!silent) {
        _showSnack(
          'خطا در دریافت Subscription:\n'
          '${_cleanError(e)}',
        );
      }
    }
  }

  // ==========================================================
  // SERVER PARSER
  // ==========================================================

  Server? parseServer(String raw) {
    final uri =
        Uri.tryParse(raw.trim());

    if (uri == null ||
        uri.scheme.isEmpty) {
      return null;
    }

    switch (
        uri.scheme.toLowerCase()) {
      case 'vless':
        return parseVless(
          raw,
          uri,
        );

      case 'vmess':
        return parseVmess(
          raw,
          uri,
        );

      case 'trojan':
        return parseTrojan(
          raw,
          uri,
        );

      case 'ss':
        return parseShadowsocks(
          raw,
          uri,
        );

      case 'hysteria2':
      case 'hy2':
        return parseHysteria2(
          raw,
          uri,
        );

      case 'tuic':
        return parseTuic(
          raw,
          uri,
        );
    }

    return null;
  }

  String displayName(
    Uri uri,
    String fallback,
  ) {
    final fragment =
        uri.fragment.trim();

    if (fragment.isNotEmpty) {
      try {
        return Uri.decodeComponent(
          fragment,
        );
      } catch (_) {
        return fragment;
      }
    }

    return fallback;
  }

  Map<String, dynamic>
      parseCommonTransport(
    Uri uri,
  ) {
    final query =
        uri.queryParameters;

    final network =
        (query['type'] ??
                query['network'] ??
                'tcp')
            .toLowerCase();

    final outbound =
        <String, dynamic>{
      'type': '',
      'server': uri.host,
      'server_port': uri.port,
    };

    addTransport(
      outbound,
      uri,
      network,
    );

    return outbound;
  }

  void addTransport(
    Map<String, dynamic> outbound,
    Uri uri,
    String network,
  ) {
    final query =
        uri.queryParameters;

    if (network == 'ws') {
      outbound['transport'] = {
        'type': 'ws',
        if (query['path'] != null)
          'path': query['path'],
        if (query['host'] != null)
          'headers': {
            'Host': query['host'],
          },
      };
    } else if (network == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        'service_name':
            query['serviceName'] ??
                query['service_name'] ??
                '',
      };
    } else if (network ==
        'httpupgrade') {
      outbound['transport'] = {
        'type': 'httpupgrade',
        if (query['path'] != null)
          'path': query['path'],
        if (query['host'] != null)
          'host': query['host'],
      };
    } else if (network == 'h2' ||
        network == 'http') {
      outbound['transport'] = {
        'type': 'http',
        if (query['path'] != null)
          'path': query['path'],
        if (query['host'] != null)
          'host': query['host'],
      };
    }

    final security =
        (query['security'] ?? '')
            .toLowerCase();

    if (security == 'tls') {
      outbound['tls'] = {
        'enabled': true,
        if (query['sni'] != null)
          'server_name':
              query['sni'],
        if (query['fp'] != null)
          'utls': {
            'enabled': true,
            'fingerprint':
                query['fp'],
          },
      };
    }

    if (security == 'reality') {
      final reality =
          <String, dynamic>{
        'enabled': true,
      };

      if (query['pbk'] != null) {
        reality['public_key'] =
            query['pbk'];
      }

      if (query['publicKey'] != null) {
        reality['public_key'] =
            query['publicKey'];
      }

      if (query['sid'] != null) {
        reality['short_id'] =
            query['sid'];
      }

      if (query['shortId'] != null) {
        reality['short_id'] =
            query['shortId'];
      }

      outbound['tls'] = {
        'enabled': true,
        if (query['sni'] != null)
          'server_name':
              query['sni'],
        if (query['fp'] != null)
          'utls': {
            'enabled': true,
            'fingerprint':
                query['fp'],
          },
        'reality': reality,
      };
    }
  }

  // ==========================================================
  // VLESS
  // ==========================================================

  Server? parseVless(
    String raw,
    Uri uri,
  ) {
    final uuid =
        Uri.decodeComponent(
      uri.userInfo,
    );

    if (uuid.isEmpty ||
        uri.host.isEmpty ||
        uri.port == 0) {
      return null;
    }

    final outbound =
        parseCommonTransport(uri);

    outbound['type'] = 'vless';
    outbound['uuid'] = uuid;

    final flow =
        uri.queryParameters['flow'];

    if (flow != null &&
        flow.isNotEmpty) {
      outbound['flow'] = flow;
    }

    return Server(
      raw: raw,
      name: displayName(
        uri,
        'VLESS',
      ),
      type: 'vless',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ==========================================================
  // VMESS
  // ==========================================================

  Server? parseVmess(
    String raw,
    Uri uri,
  ) {
    var encoded =
        raw.substring(
      'vmess://'.length,
    );

    encoded = encoded.trim();

    final jsonText =
        decodeBase64(encoded);

    if (jsonText == null) {
      return null;
    }

    dynamic decoded;

    try {
      decoded =
          jsonDecode(jsonText);
    } catch (_) {
      return null;
    }

    if (decoded is! Map) {
      return null;
    }

    final map =
        Map<String, dynamic>.from(
      decoded,
    );

    final address =
        '${map['add'] ?? map['address'] ?? ''}';

    final port =
        int.tryParse(
          '${map['port'] ?? 0}',
        ) ??
        0;

    final id =
        '${map['id'] ?? map['uuid'] ?? ''}';

    if (address.isEmpty ||
        port <= 0 ||
        id.isEmpty) {
      return null;
    }

    final outbound =
        <String, dynamic>{
      'type': 'vmess',
      'server': address,
      'server_port': port,
      'uuid': id,
      'security':
          '${map['scy'] ?? map['security'] ?? 'auto'}',
    };

    final network =
        '${map['net'] ?? 'tcp'}'
            .toLowerCase();

    final path =
        '${map['path'] ?? ''}';

    final host =
        '${map['host'] ?? ''}';

    if (network == 'ws') {
      outbound['transport'] = {
        'type': 'ws',
        if (path.isNotEmpty)
          'path': path,
        if (host.isNotEmpty)
          'headers': {
            'Host': host,
          },
      };
    } else if (network == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        'service_name':
            '${map['path'] ?? map['serviceName'] ?? ''}',
      };
    } else if (network ==
            'httpupgrade' ||
        network == 'http') {
      outbound['transport'] = {
        'type':
            network == 'httpupgrade'
                ? 'httpupgrade'
                : 'http',
        if (path.isNotEmpty)
          'path': path,
        if (host.isNotEmpty)
          'host': host,
      };
    }

    final tls =
        '${map['tls'] ?? ''}'
            .toLowerCase();

    if (tls == 'tls') {
      outbound['tls'] = {
        'enabled': true,
        if ('${map['sni'] ?? ''}'
            .isNotEmpty)
          'server_name':
              '${map['sni']}',
      };
    }

    final name =
        '${map['ps'] ?? 'VMess'}';

    return Server(
      raw: raw,
      name: name,
      type: 'vmess',
      host: address,
      port: port,
      outbound: outbound,
    );
  }

  // ==========================================================
  // TROJAN
  // ==========================================================

  Server? parseTrojan(
    String raw,
    Uri uri,
  ) {
    final password =
        Uri.decodeComponent(
      uri.userInfo,
    );

    if (password.isEmpty ||
        uri.host.isEmpty ||
        uri.port == 0) {
      return null;
    }

    final outbound =
        parseCommonTransport(uri);

    outbound['type'] = 'trojan';
    outbound['password'] =
        password;

    return Server(
      raw: raw,
      name: displayName(
        uri,
        'Trojan',
      ),
      type: 'trojan',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ==========================================================
  // SHADOWSOCKS
  // ==========================================================

  Server? parseShadowsocks(
    String raw,
    Uri uri,
  ) {
    var userInfo =
        Uri.decodeComponent(
      uri.userInfo,
    );

    if (!userInfo.contains(':')) {
      final decoded =
          decodeBase64(userInfo);

      if (decoded != null &&
          decoded.contains(':')) {
        userInfo = decoded;
      }
    }

    final split =
        userInfo.split(':');

    if (split.length < 2 ||
        uri.host.isEmpty ||
        uri.port == 0) {
      return null;
    }

    final method = split.first;

    final password =
        split.sublist(1).join(':');

    if (method.isEmpty ||
        password.isEmpty) {
      return null;
    }

    final outbound =
        <String, dynamic>{
      'type': 'shadowsocks',
      'server': uri.host,
      'server_port': uri.port,
      'method': method,
      'password': password,
    };

    return Server(
      raw: raw,
      name: displayName(
        uri,
        'Shadowsocks',
      ),
      type: 'shadowsocks',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ==========================================================
  // HYSTERIA2
  // ==========================================================

  Server? parseHysteria2(
    String raw,
    Uri uri,
  ) {
    final password =
        Uri.decodeComponent(
      uri.userInfo,
    );

    if (password.isEmpty ||
        uri.host.isEmpty ||
        uri.port == 0) {
      return null;
    }

    final query =
        uri.queryParameters;

    final tls =
        <String, dynamic>{
      'enabled': true,
    };

    if (query['sni'] != null &&
        query['sni']!.isNotEmpty) {
      tls['server_name'] =
          query['sni'];
    }

    final outbound =
        <String, dynamic>{
      'type': 'hysteria2',
      'server': uri.host,
      'server_port': uri.port,
      'password': password,
      'tls': tls,
    };

    return Server(
      raw: raw,
      name: displayName(
        uri,
        'Hysteria2',
      ),
      type: 'hysteria2',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ==========================================================
  // TUIC
  // ==========================================================

  Server? parseTuic(
    String raw,
    Uri uri,
  ) {
    final userInfo =
        Uri.decodeComponent(
      uri.userInfo,
    );

    final split =
        userInfo.split(':');

    if (split.length < 2 ||
        uri.host.isEmpty ||
        uri.port == 0) {
      return null;
    }

    final uuid = split[0];

    final password =
        split.sublist(1).join(':');

    if (uuid.isEmpty ||
        password.isEmpty) {
      return null;
    }

    final tls =
        <String, dynamic>{
      'enabled': true,
    };

    final query =
        uri.queryParameters;

    if (query['sni'] != null &&
        query['sni']!.isNotEmpty) {
      tls['server_name'] =
          query['sni'];
    }

    final outbound =
        <String, dynamic>{
      'type': 'tuic',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uuid,
      'password': password,
      'congestion_control': 'cubic',
      'tls': tls,
    };

    return Server(
      raw: raw,
      name: displayName(
        uri,
        'TUIC',
      ),
      type: 'tuic',
      host: uri.host,
      port: uri.port,
      outbound: outbound,
    );
  }

  // ==========================================================
  // PING
  // ==========================================================

  Future<int?> pingServer(
    Server server,
  ) async {
    final stopwatch =
        Stopwatch()..start();

    try {
      final socket =
          await Socket.connect(
        server.host,
        server.port,
        timeout:
            const Duration(
          seconds: 4,
        ),
      );

      stopwatch.stop();

      socket.destroy();

      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  Future<void> testAll({
    bool silent = false,
  }) async {
    if (servers.isEmpty) return;
    if (testing) return;

    setStateSafe(() {
      testing = true;

      if (!silent) {
        stateText =
            'در حال تست سرورها...';
      }
    });

    for (int i = 0;
        i < servers.length;
        i++) {
      final ping =
          await pingServer(
        servers[i],
      );

      servers[i].ping = ping;

      if (mounted && !silent) {
        setState(() {});
      }
    }

    setStateSafe(() {
      testing = false;

      if (!silent) {
        stateText =
            'تست سرورها انجام شد';
      }
    });
  }

  Server? fastestServer() {
    Server? best;

    for (final server in servers) {
      final ping = server.ping;

      if (ping == null) continue;

      if (best == null ||
          ping < (best.ping ?? 999999)) {
        best = server;
      }
    }

    return best;
  }

  // ==========================================================
  // SING-BOX CONFIG
  // ==========================================================

  String makeConfig(
    Server selected,
  ) {
    final config =
        <String, dynamic>{
      'log': {
        'level': 'warn',
      },

      'dns': {
        'servers': [
          {
            'tag': 'remote',
            'address': '1.1.1.1',
          },
          {
            'tag': 'local',
            'address': 'local',
          },
        ],
        'final': 'remote',
      },

      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',

          // استاندارد sing-box TUN address
          'address': [
            '172.19.0.1/30',
          ],

          'auto_route': true,

          // strict_route حذف شد
          // تا روی Android مشکل checkConfig ایجاد نکند.

          'stack': 'system',
        },
      ],

      'outbounds': [
        {
          ...selected.outbound,
          'tag': 'proxy',
        },

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
    };

    return jsonEncode(config);
  }

  // ==========================================================
  // CONNECT
  // ==========================================================

  Future<void> connect() async {
    if (connecting) return;

    if (connected) {
      await disconnect();
      return;
    }

    if (servers.isEmpty) {
      _showSnack(
        'ابتدا Subscription را دریافت کن',
      );
      return;
    }

    setStateSafe(() {
      connecting = true;
      stateText =
          'آماده‌سازی اتصال...';
      lastFault = '';
    });

    try {
      Server? chosen;

      if (autoSelectFastest) {
        chosen = fastestServer();

        if (chosen == null) {
          await testAll(
            silent: true,
          );

          chosen =
              fastestServer();
        }

        if (chosen == null) {
          throw Exception(
            'هیچ سرور قابل دسترسی پیدا نشد',
          );
        }
      } else {
        if (selectedServerIndex < 0 ||
            selectedServerIndex >=
                servers.length) {
          selectedServerIndex = 0;
        }

        chosen =
            servers[selectedServerIndex];
      }

      setStateSafe(() {
        stateText =
            'در حال اتصال به ${chosen!.name}...';
      });

      final config =
          makeConfig(chosen);

      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'مجوز VPN داده نشد',
        );
      }

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
            showTrafficStats:
                true,
            showStopButton:
                true,
            stopButtonLabel:
                'قطع اتصال',
          ),
        ),
      );

      connectedAt =
          DateTime.now();

      setStateSafe(() {
        connected = true;
        connecting = false;
        stateText =
            'متصل به ${chosen!.name}';
      });
    } catch (e) {
      setStateSafe(() {
        connected = false;
        connecting = false;
        stateText =
            'اتصال ناموفق';
        lastFault =
            _cleanError(e);
      });

      _showSnack(
        'اتصال برقرار نشد:\n'
        '${_cleanError(e)}',
      );
    }
  }

  Future<void> disconnect() async {
    try {
      await vpn.disconnect();
    } catch (_) {}

    setStateSafe(() {
      connected = false;
      connecting = false;
      stateText = 'قطع شده';
    });
  }

  // ==========================================================
  // HELPERS
  // ==========================================================

  void setStateSafe(
    VoidCallback callback,
  ) {
    if (!mounted) return;

    setState(callback);
  }

  String _cleanError(
    Object error,
  ) {
    return error
        .toString()
        .replaceFirst(
          'Exception: ',
          '',
        )
        .trim();
  }

  void _showSnack(
    String text,
  ) {
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
          duration:
              const Duration(
            seconds: 4,
          ),
        ),
      );
  }

  String formatBytes(
    int? bytes,
  ) {
    if (bytes == null) {
      return 'نامشخص';
    }

    if (bytes < 1024) {
      return '$bytes B';
    }

    if (bytes <
        1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    if (bytes <
        1024 *
            1024 *
            1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }

    if (bytes <
        1024 *
            1024 *
            1024 *
            1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }

    return '${(bytes / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(2)} TB';
  }

  String formatSpeed(
    int bitsPerSecond,
  ) {
    final bytesPerSecond =
        bitsPerSecond / 8;

    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    }

    if (bytesPerSecond <
        1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }

    if (bytesPerSecond <
        1024 *
            1024 *
            1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s';
    }

    return '${(bytesPerSecond / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB/s';
  }

  String expiryText() {
    if (expireAt == null) {
      return 'نامشخص';
    }

    final date =
        DateTime.fromMillisecondsSinceEpoch(
      expireAt! * 1000,
    );

    return '${date.year}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.day.toString().padLeft(2, '0')}';
  }

  String remainingTimeText() {
    if (expireAt == null) {
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

    final days =
        difference.inDays;

    final hours =
        difference.inHours
            .remainder(24);

    return '$days روز و $hours ساعت';
  }

  int? remainingBytes() {
    if (totalBytes == null) {
      return null;
    }

    final used =
        usedBytes ?? 0;

    if (totalBytes! <= used) {
      return 0;
    }

    return totalBytes! - used;
  }

  // ==========================================================
  // UI CARD
  // ==========================================================

  Widget card({
    required Widget child,
    EdgeInsetsGeometry padding =
        const EdgeInsets.all(16),
  }) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration:
          BoxDecoration(
        color:
            const Color(0xFF0D1A2D),
        borderRadius:
            BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white
              .withValues(
            alpha: .06,
          ),
        ),
      ),
      child: child,
    );
  }

  Widget statCard(
    String title,
    String value,
    IconData icon,
  ) {
    return Expanded(
      child: card(
        padding:
            const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              color:
                  const Color(0xFF00D4FF),
              size: 22,
            ),
            const SizedBox(
              height: 10,
            ),
            Text(
              title,
              style: TextStyle(
                color: Colors.white
                    .withValues(
                  alpha: .55,
                ),
                fontSize: 12,
              ),
            ),
            const SizedBox(
              height: 4,
            ),
            Text(
              value,
              style:
                  const TextStyle(
                fontSize: 15,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // HOME PAGE
  // ==========================================================

  Widget homePage() {
    final fastest =
        fastestServer();

    return RefreshIndicator(
      onRefresh: () =>
          loadSubscription(),
      child: ListView(
        padding:
            const EdgeInsets.all(16),
        children: [
          const SizedBox(
            height: 12,
          ),

          Center(
            child: Column(
              children: [
                const Text(
                  'Light speed 🔥',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight:
                        FontWeight.w900,
                  ),
                ),
                const SizedBox(
                  height: 5,
                ),
                Text(
                  stateText,
                  style: TextStyle(
                    color: connected
                        ? Colors
                            .greenAccent
                        : Colors.white54,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(
            height: 28,
          ),

          Center(
            child: GestureDetector(
              onTap:
                  connecting
                      ? null
                      : connect,
              child:
                  AnimatedContainer(
                duration:
                    const Duration(
                  milliseconds: 250,
                ),
                width: 190,
                height: 190,
                decoration:
                    BoxDecoration(
                  shape:
                      BoxShape.circle,
                  color: connected
                      ? Colors.green
                          .withValues(
                          alpha: .16,
                        )
                      : const Color(
                          0xFF00D4FF,
                        ).withValues(
                          alpha: .10,
                        ),
                  border:
                      Border.all(
                    color: connected
                        ? Colors
                            .greenAccent
                        : const Color(
                            0xFF00D4FF,
                          ),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: connected
                          ? Colors.green
                              .withValues(
                              alpha: .16,
                            )
                          : const Color(
                              0xFF00D4FF,
                            ).withValues(
                              alpha: .14,
                            ),
                      blurRadius: 35,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment:
                      MainAxisAlignment
                          .center,
                  children: [
                    Icon(
                      connected
                          ? Icons.power
                          : Icons
                              .power_settings_new,
                      size: 62,
                      color: connected
                          ? Colors
                              .greenAccent
                          : const Color(
                              0xFF00D4FF,
                            ),
                    ),
                    const SizedBox(
                      height: 10,
                    ),
                    Text(
                      connecting
                          ? 'در حال اتصال'
                          : connected
                              ? 'قطع اتصال'
                              : 'اتصال',
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
          ),

          const SizedBox(
            height: 28,
          ),

          Row(
            children: [
              statCard(
                'دانلود',
                formatSpeed(
                  download,
                ),
                Icons.download,
              ),
              const SizedBox(
                width: 10,
              ),
              statCard(
                'آپلود',
                formatSpeed(
                  upload,
                ),
                Icons.upload,
              ),
            ],
          ),

          const SizedBox(
            height: 12,
          ),

          card(
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.speed,
                      color:
                          Color(0xFF00D4FF),
                    ),
                    const SizedBox(
                      width: 10,
                    ),
                    const Expanded(
                      child: Text(
                        'سریع‌ترین سرور',
                        style:
                            TextStyle(
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ),
                    Text(
                      fastest?.ping !=
                              null
                          ? '${fastest!.ping} ms'
                          : '---',
                      style:
                          const TextStyle(
                        color:
                            Colors.greenAccent,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(
                  height: 10,
                ),
                Align(
                  alignment:
                      Alignment.centerRight,
                  child: Text(
                    fastest?.name ??
                        'هنوز تست نشده',
                    textDirection:
                        TextDirection.rtl,
                    style:
                        const TextStyle(
                      color:
                          Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(
            height: 12,
          ),

          card(
            child: Column(
              children: [
                _infoRow(
                  'حجم کل',
                  formatBytes(
                    totalBytes,
                  ),
                ),
                _infoRow(
                  'مصرف شده',
                  formatBytes(
                    usedBytes,
                  ),
                ),
                _infoRow(
                  'باقی‌مانده',
                  formatBytes(
                    remainingBytes(),
                  ),
                ),
                _infoRow(
                  'انقضا',
                  expiryText(),
                ),
                _infoRow(
                  'زمان باقی‌مانده',
                  remainingTimeText(),
                ),
              ],
            ),
          ),

          const SizedBox(
            height: 12,
          ),

          OutlinedButton.icon(
            onPressed:
                loading
                    ? null
                    : loadSubscription,
            icon: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child:
                        CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(
                    Icons.refresh,
                  ),
            label: const Text(
              'به‌روزرسانی Subscription',
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(
    String title,
    String value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        vertical: 8,
      ),
      child: Row(
        children: [
          Text(
            title,
            style:
                const TextStyle(
              color: Colors.white54,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign:
                  TextAlign.end,
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // SERVERS PAGE
  // ==========================================================

  Widget serversPage() {
    return ListView(
      padding:
          const EdgeInsets.all(16),
      children: [
        card(
          child:
              SwitchListTile(
            contentPadding:
                EdgeInsets.zero,
            value:
                autoSelectFastest,
            onChanged: (value) {
              setState(() {
                autoSelectFastest =
                    value;
              });
            },
            title:
                const Text(
              'انتخاب خودکار سریع‌ترین سرور',
            ),
            subtitle:
                const Text(
              'قبل از اتصال، کمترین Ping انتخاب می‌شود',
            ),
          ),
        ),

        const SizedBox(
          height: 12,
        ),

        Row(
          children: [
            Expanded(
              child:
                  OutlinedButton.icon(
                onPressed: testing
                    ? null
                    : () =>
                        testAll(),
                icon:
                    const Icon(
                  Icons.speed,
                ),
                label:
                    const Text(
                  'تست Ping',
                ),
              ),
            ),
            const SizedBox(
              width: 10,
            ),
            Expanded(
              child:
                  OutlinedButton.icon(
                onPressed:
                    loading
                        ? null
                        : loadSubscription,
                icon:
                    const Icon(
                  Icons.sync,
                ),
                label:
                    const Text(
                  'Sync',
                ),
              ),
            ),
          ],
        ),

        const SizedBox(
          height: 12,
        ),

        if (servers.isEmpty)
          card(
            child:
                const Center(
              child: Padding(
                padding:
                    EdgeInsets.all(
                  30,
                ),
                child:
                    Text(
                  'هنوز سروری دریافت نشده است',
                ),
              ),
            ),
          ),

        for (int i = 0;
            i < servers.length;
            i++)
          serverTile(
            servers[i],
            i,
          ),
      ],
    );
  }

  Widget serverTile(
    Server server,
    int index,
  ) {
    final selected =
        !autoSelectFastest &&
            selectedServerIndex ==
                index;

    final ping =
        server.ping;

    Color pingColor;

    if (ping == null) {
      pingColor =
          Colors.white38;
    } else if (ping < 100) {
      pingColor =
          Colors.greenAccent;
    } else if (ping < 250) {
      pingColor =
          Colors.orangeAccent;
    } else {
      pingColor =
          Colors.redAccent;
    }

    return Padding(
      padding:
          const EdgeInsets.only(
        bottom: 10,
      ),
      child: InkWell(
        borderRadius:
            BorderRadius.circular(
          18,
        ),
        onTap: () {
          if (autoSelectFastest) {
            return;
          }

          setState(() {
            selectedServerIndex =
                index;
          });
        },
        child: card(
          padding:
              const EdgeInsets.all(
            14,
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration:
                    BoxDecoration(
                  shape:
                      BoxShape.circle,
                  color:
                      pingColor
                          .withValues(
                    alpha: .12,
                  ),
                ),
                child: Icon(
                  selected
                      ? Icons.check
                      : Icons.dns,
                  color:
                      pingColor,
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
                      server.name,
                      maxLines: 1,
                      overflow:
                          TextOverflow
                              .ellipsis,
                      style:
                          const TextStyle(
                        fontWeight:
                            FontWeight
                                .bold,
                      ),
                    ),
                    const SizedBox(
                      height: 4,
                    ),
                    Text(
                      '${server.type.toUpperCase()} • ${server.host}:${server.port}',
                      maxLines: 1,
                      overflow:
                          TextOverflow
                              .ellipsis,
                      style:
                          const TextStyle(
                        fontSize: 11,
                        color:
                            Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),

              Text(
                ping == null
                    ? '---'
                    : '$ping ms',
                style:
                    TextStyle(
                  color:
                      pingColor,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================================
  // TRAFFIC PAGE
  // ==========================================================

  Widget trafficPage() {
    return ListView(
      padding:
          const EdgeInsets.all(16),
      children: [
        card(
          child: Column(
            children: [
              const Text(
                'ترافیک لحظه‌ای VPN',
                style:
                    TextStyle(
                  fontSize: 19,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              const SizedBox(
                height: 20,
              ),

              Row(
                children: [
                  statCard(
                    'دانلود',
                    formatSpeed(
                      download,
                    ),
                    Icons.download,
                  ),
                  const SizedBox(
                    width: 10,
                  ),
                  statCard(
                    'آپلود',
                    formatSpeed(
                      upload,
                    ),
                    Icons.upload,
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(
          height: 12,
        ),

        card(
          child: Column(
            children: [
              const Align(
                alignment:
                    Alignment.centerRight,
                child:
                    Text(
                  'ترافیک این Session',
                  style:
                      TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),

              const SizedBox(
                height: 15,
              ),

              _infoRow(
                'دانلود',
                formatBytes(
                  downloadTotalBytes,
                ),
              ),

              _infoRow(
                'آپلود',
                formatBytes(
                  uploadTotalBytes,
                ),
              ),

              _infoRow(
                'مجموع',
                formatBytes(
                  downloadTotalBytes +
                      uploadTotalBytes,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(
          height: 12,
        ),

        card(
          child: Column(
            children: [
              const Align(
                alignment:
                    Alignment.centerRight,
                child:
                    Text(
                  'مصرف Subscription',
                  style:
                      TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),

              const SizedBox(
                height: 15,
              ),

              _infoRow(
                'دانلود Subscription',
                formatBytes(
                  downloadBytes,
                ),
              ),

              _infoRow(
                'آپلود Subscription',
                formatBytes(
                  uploadBytes,
                ),
              ),

              _infoRow(
                'مصرف کل',
                formatBytes(
                  usedBytes,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==========================================================
  // SUBSCRIPTION PAGE
  // ==========================================================

  Widget subscriptionPage() {
    return ListView(
      padding:
          const EdgeInsets.all(16),
      children: [
        card(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment
                    .stretch,
            children: [
              const Text(
                'Subscription',
                textAlign:
                    TextAlign.right,
                style:
                    TextStyle(
                  fontSize: 20,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              const SizedBox(
                height: 8,
              ),

              if (subscriptionTitle
                  .isNotEmpty)
                Text(
                  subscriptionTitle,
                  textAlign:
                      TextAlign.right,
                  style:
                      const TextStyle(
                    color:
                        Colors.white70,
                  ),
                ),

              const SizedBox(
                height: 16,
              ),

              TextField(
                controller:
                    urlController,
                textDirection:
                    TextDirection.ltr,
                keyboardType:
                    TextInputType.url,
                decoration:
                    InputDecoration(
                  labelText:
                      'Subscription URL',
                  hintText:
                      'https://...',
                  border:
                      OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(
                      14,
                    ),
                  ),
                ),
                onChanged:
                    (value) {
                  url = value;
                },
              ),

              const SizedBox(
                height: 12,
              ),

              FilledButton.icon(
                onPressed:
                    loading
                        ? null
                        : () async {
                            FocusScope.of(
                              context,
                            ).unfocus();

                            url =
                                urlController
                                    .text
                                    .trim();

                            if (url.isEmpty) {
                              _showSnack(
                                'آدرس Subscription را وارد کن',
                              );
                              return;
                            }

                            await saveUrl(
                              url,
                            );

                            await loadSubscription();
                          },
                icon: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(
                        Icons.download,
                      ),
                label:
                    const Text(
                  'دریافت و بروزرسانی',
                ),
              ),
            ],
          ),
        ),

        const SizedBox(
          height: 12,
        ),

        card(
          child: Column(
            children: [
              _infoRow(
                'سرورها',
                '${servers.length}',
              ),
              _infoRow(
                'حجم کل',
                formatBytes(
                  totalBytes,
                ),
              ),
              _infoRow(
                'دانلود',
                formatBytes(
                  downloadBytes,
                ),
              ),
              _infoRow(
                'آپلود',
                formatBytes(
                  uploadBytes,
                ),
              ),
              _infoRow(
                'مصرف',
                formatBytes(
                  usedBytes,
                ),
              ),
              _infoRow(
                'باقی‌مانده',
                formatBytes(
                  remainingBytes(),
                ),
              ),
              _infoRow(
                'تاریخ انقضا',
                expiryText(),
              ),
              _infoRow(
                'زمان باقی‌مانده',
                remainingTimeText(),
              ),
            ],
          ),
        ),

        const SizedBox(
          height: 12,
        ),

        card(
          child:
              const Text(
            'نکته: حجم دانلود، آپلود، حجم کل و تاریخ انقضا زمانی '
            'نمایش داده می‌شوند که سرویس Subscription این اطلاعات '
            'را در Subscription-Userinfo ارسال کند.',
            textDirection:
                TextDirection.rtl,
            style:
                TextStyle(
              color:
                  Colors.white54,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }

  // ==========================================================
  // SETTINGS PAGE
  // ==========================================================

  Widget settingsPage() {
    return ListView(
      padding:
          const EdgeInsets.all(16),
      children: [
        card(
          child: Column(
            children: [
              const Icon(
                Icons.flash_on,
                size: 55,
                color:
                    Color(0xFF00D4FF),
              ),
              const SizedBox(
                height: 10,
              ),
              const Text(
                'Light speed 🔥',
                style:
                    TextStyle(
                  fontSize: 24,
                  fontWeight:
                      FontWeight.w900,
                ),
              ),
              const SizedBox(
                height: 5,
              ),
              const Text(
                'Real VPN Client',
                style:
                    TextStyle(
                  color:
                      Colors.white54,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(
          height: 12,
        ),

        card(
          child: Column(
            children: [
              _settingRow(
                Icons.security,
                'VPN Engine',
                'sing-box',
              ),
              _settingRow(
                Icons.bolt,
                'انتخاب سرور',
                autoSelectFastest
                    ? 'خودکار'
                    : 'دستی',
              ),
              _settingRow(
                Icons.dns,
                'DNS',
                '1.1.1.1',
              ),
              _settingRow(
                Icons.sync,
                'Refresh',
                'هر ۱۵ دقیقه',
              ),
            ],
          ),
        ),

        const SizedBox(
          height: 12,
        ),

        OutlinedButton.icon(
          onPressed: () {
            Clipboard.setData(
              ClipboardData(
                text: url,
              ),
            );

            _showSnack(
              'Subscription URL کپی شد',
            );
          },
          icon:
              const Icon(Icons.copy),
          label:
              const Text(
            'کپی Subscription URL',
          ),
        ),
      ],
    );
  }

  Widget _settingRow(
    IconData icon,
    String title,
    String value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        vertical: 10,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color:
                const Color(0xFF00D4FF),
          ),
          const SizedBox(
            width: 12,
          ),
          Expanded(
            child:
                Text(title),
          ),
          Text(
            value,
            style:
                const TextStyle(
              color:
                  Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // MAIN SCAFFOLD
  // ==========================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final pages = [
      homePage(),
      serversPage(),
      trafficPage(),
      subscriptionPage(),
      settingsPage(),
    ];

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title:
            const Text(
          'Light speed 🔥',
          style:
              TextStyle(
            fontWeight:
                FontWeight.bold,
          ),
        ),
        backgroundColor:
            Colors.transparent,
      ),

      body: SafeArea(
        child:
            pages[page],
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
        backgroundColor:
            const Color(0xFF091526),
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
                Icon(Icons.swap_vert),
            label: 'ترافیک',
          ),
          NavigationDestination(
            icon: Icon(
              Icons
                  .subscriptions_outlined,
            ),
            selectedIcon:
                Icon(
              Icons.subscriptions,
            ),
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
    );
  }
}
