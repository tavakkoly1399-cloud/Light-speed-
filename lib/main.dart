import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_singbox_client/flutter_singbox_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LightSpeedApp());
}

final vpn = SingboxClient();

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
        scaffoldBackgroundColor: const Color(0xFF050A12),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00D4FF),
          brightness: Brightness.dark,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF0B1422),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

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

class SubscriptionInfo {
  final int? upload;
  final int? download;
  final int? total;
  final int? expire;

  const SubscriptionInfo({
    this.upload,
    this.download,
    this.total,
    this.expire,
  });

  bool get hasTraffic =>
      upload != null || download != null || total != null;

  int? get used {
    if (upload == null && download == null) {
      return null;
    }

    return (upload ?? 0) + (download ?? 0);
  }

  int? get remaining {
    if (total == null || used == null) {
      return null;
    }

    if (total! <= 0) {
      return null;
    }

    final value = total! - used!;
    return value < 0 ? 0 : value;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver {
  final TextEditingController urlController = TextEditingController();

  SharedPreferences? prefs;

  List<Server> servers = [];

  StreamSubscription? trafficSub;
  StreamSubscription? stateSub;
  StreamSubscription? faultSub;

  Timer? refreshTimer;
  Timer? connectionTimer;

  int page = 0;

  bool loading = false;
  bool testing = false;
  bool connected = false;
  bool connecting = false;

  bool autoSelect = true;

  String stateText = 'آماده اتصال';
  String lastFault = '';

  int selectedServer = 0;

  int uploadSpeed = 0;
  int downloadSpeed = 0;

  int sessionUpload = 0;
  int sessionDownload = 0;

  DateTime? connectedAt;

  SubscriptionInfo subscription = const SubscriptionInfo();

  String subscriptionTitle = 'Subscription';
  String? profileUpdateInterval;

  String? supportUrl;
  String? webPageUrl;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await vpn.initialize();
    } catch (_) {}

    prefs = await SharedPreferences.getInstance();

    final savedUrl = prefs?.getString('subscription_url');

    if (savedUrl != null && savedUrl.trim().isNotEmpty) {
      urlController.text = savedUrl;
    }

    await _restoreSavedData();

    trafficSub = vpn.trafficStatsStream.listen((stats) {
      if (!mounted) return;

      setState(() {
        uploadSpeed = stats.uplinkBps;
        downloadSpeed = stats.downlinkBps;
        sessionUpload = stats.uplinkTotalBytes;
        sessionDownload = stats.downlinkTotalBytes;
      });
    });

    stateSub = vpn.serviceStateStream.listen((state) {
      if (!mounted) return;

      final value = state.toString().toLowerCase();

      setState(() {
        connected = value.contains('started');
        connecting = value.contains('starting') ||
            value.contains('stopping');

        if (connected) {
          stateText = 'متصل';
        } else if (value.contains('starting')) {
          stateText = 'در حال اتصال...';
        } else if (value.contains('stopping')) {
          stateText = 'در حال قطع اتصال...';
        } else {
          stateText = 'قطع';
        }
      });
    });

    faultSub = vpn.faultStream.listen((error) {
      if (!mounted) return;

      setState(() {
        lastFault = error.toString();
      });

      _showMessage('خطای VPN: $error');
    });

    if (urlController.text.trim().isNotEmpty) {
      await Future.delayed(const Duration(milliseconds: 500));
      await loadSubscription(silent: true);
    }

    _startRefreshTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!connected &&
          urlController.text.trim().isNotEmpty) {
        loadSubscription(silent: true);
      }
    }
  }

  void _startRefreshTimer() {
    refreshTimer?.cancel();

    refreshTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) {
        if (!connected &&
            urlController.text.trim().isNotEmpty) {
          loadSubscription(silent: true);
        }
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    refreshTimer?.cancel();
    connectionTimer?.cancel();

    trafficSub?.cancel();
    stateSub?.cancel();
    faultSub?.cancel();

    urlController.dispose();

    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // SUBSCRIPTION
  // ---------------------------------------------------------------------------

  Future<void> _restoreSavedData() async {
    final savedServers = prefs?.getString('servers_json');

    if (savedServers == null || savedServers.isEmpty) {
      return;
    }

    try {
      final list = jsonDecode(savedServers);

      if (list is! List) return;

      final restored = <Server>[];

      for (final item in list) {
        if (item is! Map) continue;

        final outbound = Map<String, dynamic>.from(
          item['outbound'] is Map
              ? item['outbound']
              : <String, dynamic>{},
        );

        restored.add(
          Server(
            raw: item['raw']?.toString() ?? '',
            name: item['name']?.toString() ?? 'Server',
            type: item['type']?.toString() ?? '',
            host: item['host']?.toString() ?? '',
            port: int.tryParse(
                  item['port']?.toString() ?? '',
                ) ??
                443,
            outbound: outbound,
            ping: int.tryParse(
              item['ping']?.toString() ?? '',
            ),
          ),
        );
      }

      if (!mounted) return;

      setState(() {
        servers = restored;
      });
    } catch (_) {}
  }

  Future<void> _saveServers() async {
    final data = servers.map((server) {
      return {
        'raw': server.raw,
        'name': server.name,
        'type': server.type,
        'host': server.host,
        'port': server.port,
        'outbound': server.outbound,
        'ping': server.ping,
      };
    }).toList();

    await prefs?.setString(
      'servers_json',
      jsonEncode(data),
    );
  }

  String? _header(
    Map<String, String> headers,
    String name,
  ) {
    for (final entry in headers.entries) {
      if (entry.key.trim().toLowerCase() ==
          name.trim().toLowerCase()) {
        return entry.value;
      }
    }

    return null;
  }

  int? _parseInt(dynamic value) {
    if (value == null) return null;

    if (value is int) return value;

    final text = value.toString().trim();

    if (text.isEmpty) return null;

    return int.tryParse(text);
  }

  SubscriptionInfo _parseSubscriptionUserInfo(
    String? raw,
  ) {
    if (raw == null || raw.trim().isEmpty) {
      return const SubscriptionInfo();
    }

    int? upload;
    int? download;
    int? total;
    int? expire;

    for (final item in raw.split(';')) {
      final part = item.trim();

      if (part.isEmpty) continue;

      final separator = part.indexOf('=');

      if (separator <= 0) continue;

      final key = part
          .substring(0, separator)
          .trim()
          .toLowerCase();

      final value = part
          .substring(separator + 1)
          .trim();

      final number = int.tryParse(value);

      if (number == null) continue;

      switch (key) {
        case 'upload':
          upload = number;
          break;

        case 'download':
          download = number;
          break;

        case 'total':
        case 'transfer_enable':
        case 'transfer':
          total = number;
          break;

        case 'expire':
        case 'expired_at':
        case 'expires':
          expire = number;
          break;
      }
    }

    return SubscriptionInfo(
      upload: upload,
      download: download,
      total: total,
      expire: expire,
    );
  }

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final urlText = urlController.text.trim();

    if (urlText.isEmpty) {
      if (!silent) {
        _showMessage('لینک Subscription را وارد کن.');
      }

      return;
    }

    Uri uri;

    try {
      uri = Uri.parse(urlText);

      if (!uri.hasScheme ||
          (uri.scheme != 'https' &&
              uri.scheme != 'http')) {
        throw const FormatException();
      }
    } catch (_) {
      if (!silent) {
        _showMessage('لینک Subscription معتبر نیست.');
      }

      return;
    }

    if (mounted) {
      setState(() {
        loading = true;
        stateText = 'در حال دریافت Subscription...';
        lastFault = '';
      });
    }

    try {
      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent':
                  'Light-speed/1.0 (Flutter; Android)',
              'Accept':
                  'application/json, text/plain, */*',
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
            },
          )
          .timeout(
            const Duration(seconds: 60),
          );

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode}',
        );
      }

      // -------------------------------------------------------
      // 1. READ STANDARD SUBSCRIPTION HEADERS
      // -------------------------------------------------------

      final userInfoHeader = _header(
        response.headers,
        'subscription-userinfo',
      );

      final profileTitleHeader = _header(
        response.headers,
        'profile-title',
      );

      final updateIntervalHeader = _header(
        response.headers,
        'profile-update-interval',
      );

      final supportHeader = _header(
        response.headers,
        'support-url',
      );

      final webPageHeader = _header(
        response.headers,
        'profile-web-page-url',
      );

      final contentType = _header(
        response.headers,
        'content-type',
      );

      final contentDisposition = _header(
        response.headers,
        'content-disposition',
      );

      final parsedInfo =
          _parseSubscriptionUserInfo(
        userInfoHeader,
      );

      // -------------------------------------------------------
      // 2. READ PROFILE TITLE
      // -------------------------------------------------------

      String newTitle = subscriptionTitle;

      if (profileTitleHeader != null &&
          profileTitleHeader.trim().isNotEmpty) {
        newTitle = _decodeProfileTitle(
          profileTitleHeader,
        );
      } else if (contentDisposition != null) {
        final fallback =
            _filenameFromContentDisposition(
          contentDisposition,
        );

        if (fallback != null &&
            fallback.isNotEmpty) {
          newTitle = fallback;
        }
      }

      // -------------------------------------------------------
      // 3. BODY
      // -------------------------------------------------------

      final body = response.body.trim();

      if (body.isEmpty) {
        throw const FormatException(
          'Subscription body is empty',
        );
      }

      final parsedServers = _parseSubscriptionBody(
        body,
        contentType: contentType,
      );

      if (parsedServers.isEmpty) {
        throw const FormatException(
          'هیچ کانفیگ معتبری داخل Subscription پیدا نشد.',
        );
      }

      // -------------------------------------------------------
      // 4. UPDATE STATE ONLY AFTER SUCCESS
      // -------------------------------------------------------

      if (!mounted) return;

      setState(() {
        servers = parsedServers;

        subscription = parsedInfo;

        subscriptionTitle = newTitle;

        profileUpdateInterval =
            updateIntervalHeader;

        supportUrl = supportHeader;
        webPageUrl = webPageHeader;

        selectedServer = min(
          selectedServer,
          max(0, servers.length - 1),
        );

        loading = false;
        stateText =
            '${servers.length} سرور دریافت شد';
      });

      await prefs?.setString(
        'subscription_url',
        urlText,
      );

      await _saveServers();

      await testAll();

      if (!mounted) return;

      setState(() {
        stateText =
            '${servers.length} سرور آماده اتصال';
        loading = false;
      });

      if (!silent) {
        _showMessage(
          'Subscription با موفقیت بروزرسانی شد.',
        );
      }
    } on TimeoutException {
      if (!mounted) return;

      setState(() {
        loading = false;
        stateText =
            'بروزرسانی ناموفق؛ اطلاعات قبلی حفظ شد';
      });

      if (!silent) {
        _showMessage(
          'سرور Subscription در ۶۰ ثانیه پاسخ نداد. اطلاعات قبلی حفظ شد.',
        );
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        stateText =
            servers.isNotEmpty
                ? 'بروزرسانی ناموفق؛ اطلاعات قبلی حفظ شد'
                : 'خطا در دریافت Subscription';
        lastFault = e.toString();
      });

      if (!silent) {
        _showMessage(
          'دریافت Subscription ناموفق بود:\n$e',
        );
      }
    }
  }

  String _decodeProfileTitle(String value) {
    final text = value.trim();

    if (text.toLowerCase().startsWith('base64:')) {
      final encoded =
          text.substring('base64:'.length);

      try {
        return utf8.decode(
          base64Decode(
            base64.normalize(encoded),
          ),
        );
      } catch (_) {
        return text;
      }
    }

    return text;
  }

  String? _filenameFromContentDisposition(
    String value,
  ) {
    final regex = RegExp(
      r'filename\*?=(?:UTF-8\'\')?"?([^";]+)"?',
      caseSensitive: false,
    );

    final match = regex.firstMatch(value);

    if (match == null) return null;

    return Uri.decodeComponent(
      match.group(1)!.trim(),
    );
  }

  // ---------------------------------------------------------------------------
  // SUBSCRIPTION BODY PARSER
  // ---------------------------------------------------------------------------

  List<Server> _parseSubscriptionBody(
    String body, {
    String? contentType,
  }) {
    final result = <Server>[];

    final type =
        (contentType ?? '').toLowerCase();

    // JSON subscription
    if (type.contains('application/json') ||
        body.startsWith('{') ||
        body.startsWith('[')) {
      final jsonServers =
          _parseJsonSubscription(body);

      if (jsonServers.isNotEmpty) {
        return jsonServers;
      }
    }

    // Raw body
    final lines = body
        .replaceAll('\r', '')
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    // First try direct links.
    for (final line in lines) {
      final decoded =
          _decodePossibleBase64(line);

      if (decoded != null &&
          decoded != line &&
          decoded.contains('\n')) {
        for (final item
            in decoded.split('\n')) {
          final parsed = _parseSingleServer(
            item.trim(),
          );

          if (parsed != null) {
            result.add(parsed);
          }
        }
      }
    }

    if (result.isNotEmpty) {
      return _deduplicateServers(result);
    }

    // Direct links.
    for (final line in lines) {
      final parsed = _parseSingleServer(line);

      if (parsed != null) {
        result.add(parsed);
      }
    }

    if (result.isNotEmpty) {
      return _deduplicateServers(result);
    }

    // Entire body may be base64.
    final decodedBody =
        _decodePossibleBase64(body);

    if (decodedBody != null &&
        decodedBody != body) {
      for (final line
          in decodedBody
              .replaceAll('\r', '')
              .split('\n')) {
        final parsed =
            _parseSingleServer(line.trim());

        if (parsed != null) {
          result.add(parsed);
        }
      }
    }

    return _deduplicateServers(result);
  }

  List<Server> _parseJsonSubscription(
    String body,
  ) {
    try {
      final decoded = jsonDecode(body);

      final result = <Server>[];

      if (decoded is List) {
        for (final item in decoded) {
          final server =
              _parseJsonServer(item);

          if (server != null) {
            result.add(server);
          }
        }
      } else if (decoded is Map) {
        final map =
            Map<String, dynamic>.from(decoded);

        final candidates = [
          map['servers'],
          map['outbounds'],
          map['proxies'],
          map['configs'],
          map['data'],
        ];

        for (final candidate in candidates) {
          if (candidate is List) {
            for (final item in candidate) {
              final server =
                  _parseJsonServer(item);

              if (server != null) {
                result.add(server);
              }
            }
          }
        }

        if (result.isEmpty) {
          final server =
              _parseJsonServer(map);

          if (server != null) {
            result.add(server);
          }
        }
      }

      return _deduplicateServers(result);
    } catch (_) {
      return [];
    }
  }

  Server? _parseJsonServer(
    dynamic item,
  ) {
    if (item is! Map) return null;

    final map =
        Map<String, dynamic>.from(item);

    final protocol = (
      map['type'] ??
      map['protocol'] ??
      map['scheme']
    )
        ?.toString()
        .toLowerCase();

    if (protocol == null) return null;

    final host = (
      map['server'] ??
      map['address'] ??
      map['host']
    )?.toString();

    final port = _parseInt(
      map['server_port'] ??
          map['port'],
    );

    if (host == null ||
        host.isEmpty ||
        port == null) {
      return null;
    }

    final tag =
        map['tag']?.toString() ??
            map['name']?.toString() ??
            map['remarks']?.toString() ??
            '$protocol $host';

    final outbound =
        _normalizeJsonOutbound(
      map,
      protocol,
      host,
      port,
    );

    if (outbound == null) return null;

    return Server(
      raw: jsonEncode(map),
      name: tag,
      type: protocol,
      host: host,
      port: port,
      outbound: outbound,
    );
  }

  Map<String, dynamic>? _normalizeJsonOutbound(
    Map<String, dynamic> map,
    String protocol,
    String host,
    int port,
  ) {
    if (protocol == 'vless') {
      final uuid =
          map['uuid'] ??
              map['id'] ??
              map['password'];

      if (uuid == null) return null;

      return {
        'type': 'vless',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'uuid': uuid.toString(),
        'tls': _tlsFromMap(map),
        if (map['flow'] != null)
          'flow': map['flow'],
        if (map['transport'] is Map)
          'transport': map['transport'],
      };
    }

    if (protocol == 'vmess') {
      final uuid =
          map['uuid'] ??
              map['id'];

      if (uuid == null) return null;

      return {
        'type': 'vmess',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'uuid': uuid.toString(),
        'security':
            map['security'] ??
                map['cipher'] ??
                'auto',
        'tls': _tlsFromMap(map),
        if (map['transport'] is Map)
          'transport': map['transport'],
      };
    }

    if (protocol == 'trojan') {
      final password =
          map['password'];

      if (password == null) return null;

      return {
        'type': 'trojan',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'password': password.toString(),
        'tls': _tlsFromMap(map),
      };
    }

    if (protocol == 'shadowsocks' ||
        protocol == 'ss') {
      final password =
          map['password'];

      final method =
          map['method'] ??
              map['cipher'];

      if (password == null ||
          method == null) {
        return null;
      }

      return {
        'type': 'shadowsocks',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'method': method.toString(),
        'password': password.toString(),
      };
    }

    if (protocol == 'hysteria2' ||
        protocol == 'hy2') {
      final password =
          map['password'] ??
              map['auth'];

      if (password == null) return null;

      return {
        'type': 'hysteria2',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'password': password.toString(),
        'tls': _tlsFromMap(map),
      };
    }

    if (protocol == 'tuic') {
      final uuid =
          map['uuid'] ??
              map['id'];

      final password =
          map['password'];

      if (uuid == null ||
          password == null) {
        return null;
      }

      return {
        'type': 'tuic',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'uuid': uuid.toString(),
        'password': password.toString(),
        'tls': _tlsFromMap(map),
      };
    }

    return null;
  }

  Map<String, dynamic> _tlsFromMap(
    Map<String, dynamic> map,
  ) {
    final tls =
        map['tls'];

    if (tls is Map) {
      return Map<String, dynamic>.from(tls);
    }

    final security =
        map['security']?.toString();

    if (security == 'tls' ||
        security == 'reality') {
      return {
        'enabled': true,
        if (map['server_name'] != null)
          'server_name': map['server_name'],
        if (map['sni'] != null)
          'server_name': map['sni'],
      };
    }

    return {
      'enabled': false,
    };
  }

  String? _decodePossibleBase64(
    String input,
  ) {
    final value = input.trim();

    if (value.isEmpty) return null;

    if (value.startsWith('vless://') ||
        value.startsWith('vmess://') ||
        value.startsWith('trojan://') ||
        value.startsWith('ss://') ||
        value.startsWith('hysteria2://') ||
        value.startsWith('hy2://') ||
        value.startsWith('tuic://')) {
      return value;
    }

    try {
      final normalized =
          base64.normalize(
        value.replaceAll(RegExp(r'\s+'), ''),
      );

      final bytes =
          base64Decode(normalized);

      final decoded =
          utf8.decode(bytes);

      if (_looksLikeConfig(decoded)) {
        return decoded;
      }
    } catch (_) {}

    return value;
  }

  bool _looksLikeConfig(String text) {
    return text.contains('vless://') ||
        text.contains('vmess://') ||
        text.contains('trojan://') ||
        text.contains('ss://') ||
        text.contains('hysteria2://') ||
        text.contains('hy2://') ||
        text.contains('tuic://');
  }

  // ---------------------------------------------------------------------------
  // URI PARSER
  // ---------------------------------------------------------------------------

  Server? _parseSingleServer(
    String raw,
  ) {
    final value = raw.trim();

    if (value.isEmpty) return null;

    try {
      if (value.startsWith('vless://')) {
        return _parseVless(value);
      }

      if (value.startsWith('vmess://')) {
        return _parseVmess(value);
      }

      if (value.startsWith('trojan://')) {
        return _parseTrojan(value);
      }

      if (value.startsWith('ss://')) {
        return _parseShadowsocks(value);
      }

      if (value.startsWith('hysteria2://') ||
          value.startsWith('hy2://')) {
        return _parseHysteria2(value);
      }

      if (value.startsWith('tuic://')) {
        return _parseTuic(value);
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  Server? _parseVless(String raw) {
    final uri = Uri.parse(raw);

    final uuid =
        uri.userInfo;

    final host =
        uri.host;

    final port =
        uri.port;

    if (uuid.isEmpty ||
        host.isEmpty ||
        port <= 0) {
      return null;
    }

    final q = uri.queryParameters;

    final security =
        q['security']?.toLowerCase();

    final tls = <String, dynamic>{
      'enabled':
          security == 'tls' ||
              security == 'reality',
    };

    if (q['sni'] != null) {
      tls['server_name'] = q['sni'];
    }

    if (security == 'reality') {
      tls['reality'] = {
        if (q['pbk'] != null)
          'public_key': q['pbk'],
        if (q['sid'] != null)
          'short_id': q['sid'],
      };

      if (q['fp'] != null) {
        tls['utls'] = {
          'enabled': true,
          'fingerprint': q['fp'],
        };
      }
    }

    final outbound =
        <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': host,
      'server_port': port,
      'uuid': uuid,
      'tls': tls,
    };

    final flow = q['flow'];

    if (flow != null &&
        flow.isNotEmpty) {
      outbound['flow'] = flow;
    }

    _applyTransport(
      outbound,
      q,
    );

    return Server(
      raw: raw,
      name: _serverName(
        q['remarks'],
        host,
        port,
      ),
      type: 'VLESS',
      host: host,
      port: port,
      outbound: outbound,
    );
  }

  Server? _parseVmess(String raw) {
    final encoded =
        raw.substring('vmess://'.length);

    final normalized =
        base64.normalize(encoded);

    final jsonText =
        utf8.decode(
      base64Decode(normalized),
    );

    final map =
        jsonDecode(jsonText);

    if (map is! Map) return null;

    final host =
        map['add']?.toString() ?? '';

    final port =
        int.tryParse(
              map['port']?.toString() ?? '',
            ) ??
            443;

    final uuid =
        map['id']?.toString() ?? '';

    if (host.isEmpty ||
        uuid.isEmpty) {
      return null;
    }

    final security =
        map['tls']?.toString().toLowerCase();

    final tls = <String, dynamic>{
      'enabled':
          security == 'tls',
    };

    final sni =
        map['sni']?.toString();

    if (sni != null &&
        sni.isNotEmpty) {
      tls['server_name'] = sni;
    }

    if (map['fp'] != null) {
      tls['utls'] = {
        'enabled': true,
        'fingerprint':
            map['fp'].toString(),
      };
    }

    final outbound =
        <String, dynamic>{
      'type': 'vmess',
      'tag': 'proxy',
      'server': host,
      'server_port': port,
      'uuid': uuid,
      'security':
          map['scy']?.toString() ?? 'auto',
      'tls': tls,
    };

    final network =
        map['net']?.toString();

    if (network == 'ws') {
      outbound['transport'] = {
        'type': 'ws',
        'path':
            map['path']?.toString() ?? '/',
        if (map['host'] != null)
          'headers': {
            'Host':
                map['host'].toString(),
          },
      };
    } else if (network == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        'service_name':
            map['path']?.toString() ?? '',
      };
    } else if (network == 'httpupgrade') {
      outbound['transport'] = {
        'type': 'httpupgrade',
        'path':
            map['path']?.toString() ?? '/',
        if (map['host'] != null)
          'host':
              map['host'].toString(),
      };
    }

    return Server(
      raw: raw,
      name: _serverName(
        map['ps']?.toString(),
        host,
        port,
      ),
      type: 'VMess',
      host: host,
      port: port,
      outbound: outbound,
    );
  }

  Server? _parseTrojan(String raw) {
    final uri = Uri.parse(raw);

    final password =
        uri.userInfo;

    final host =
        uri.host;

    final port =
        uri.port;

    if (password.isEmpty ||
        host.isEmpty ||
        port <= 0) {
      return null;
    }

    final q = uri.queryParameters;

    final tls = <String, dynamic>{
      'enabled': true,
    };

    if (q['sni'] != null) {
      tls['server_name'] = q['sni'];
    }

    if (q['fp'] != null) {
      tls['utls'] = {
        'enabled': true,
        'fingerprint': q['fp'],
      };
    }

    final outbound =
        <String, dynamic>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': host,
      'server_port': port,
      'password': password,
      'tls': tls,
    };

    _applyTransport(
      outbound,
      q,
    );

    return Server(
      raw: raw,
      name: _serverName(
        q['remarks'],
        host,
        port,
      ),
      type: 'Trojan',
      host: host,
      port: port,
      outbound: outbound,
    );
  }

  Server? _parseShadowsocks(String raw) {
    final uri = Uri.parse(raw);

    String userInfo = uri.userInfo;

    if (userInfo.isEmpty) {
      final afterScheme =
          raw.substring('ss://'.length);

      final hashIndex =
          afterScheme.indexOf('#');

      final withoutName =
          hashIndex >= 0
              ? afterScheme.substring(
                  0,
                  hashIndex,
                )
              : afterScheme;

      try {
        final decoded =
            utf8.decode(
          base64Decode(
            base64.normalize(
              withoutName,
            ),
          ),
        );

        userInfo = decoded;
      } catch (_) {}
    }

    if (userInfo.isEmpty) {
      return null;
    }

    final separator =
        userInfo.indexOf(':');

    if (separator <= 0) {
      return null;
    }

    final method =
        userInfo.substring(0, separator);

    final password =
        userInfo.substring(
      separator + 1,
    );

    final host = uri.host;

    final port = uri.port;

    if (host.isEmpty ||
        port <= 0) {
      return null;
    }

    return Server(
      raw: raw,
      name: _serverName(
        _decodeFragment(uri.fragment),
        host,
        port,
      ),
      type: 'Shadowsocks',
      host: host,
      port: port,
      outbound: {
        'type': 'shadowsocks',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'method': method,
        'password': password,
      },
    );
  }

  Server? _parseHysteria2(String raw) {
    final uri = Uri.parse(raw);

    final password =
        uri.userInfo;

    final host =
        uri.host;

    final port =
        uri.port;

    if (password.isEmpty ||
        host.isEmpty ||
        port <= 0) {
      return null;
    }

    final q = uri.queryParameters;

    final tls = <String, dynamic>{
      'enabled': true,
    };

    if (q['sni'] != null) {
      tls['server_name'] = q['sni'];
    }

    if (q['insecure'] == '1' ||
        q['allowInsecure'] == '1') {
      tls['insecure'] = true;
    }

    return Server(
      raw: raw,
      name: _serverName(
        q['remarks'] ??
            _decodeFragment(uri.fragment),
        host,
        port,
      ),
      type: 'Hysteria2',
      host: host,
      port: port,
      outbound: {
        'type': 'hysteria2',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'password': password,
        'tls': tls,
      },
    );
  }

  Server? _parseTuic(String raw) {
    final uri = Uri.parse(raw);

    final userInfo =
        uri.userInfo;

    final separator =
        userInfo.indexOf(':');

    if (separator <= 0) {
      return null;
    }

    final uuid =
        userInfo.substring(0, separator);

    final password =
        userInfo.substring(
      separator + 1,
    );

    final host =
        uri.host;

    final port =
        uri.port;

    if (uuid.isEmpty ||
        password.isEmpty ||
        host.isEmpty ||
        port <= 0) {
      return null;
    }

    final q = uri.queryParameters;

    final tls = <String, dynamic>{
      'enabled': true,
    };

    if (q['sni'] != null) {
      tls['server_name'] = q['sni'];
    }

    return Server(
      raw: raw,
      name: _serverName(
        q['remarks'] ??
            _decodeFragment(uri.fragment),
        host,
        port,
      ),
      type: 'TUIC',
      host: host,
      port: port,
      outbound: {
        'type': 'tuic',
        'tag': 'proxy',
        'server': host,
        'server_port': port,
        'uuid': uuid,
        'password': password,
        'congestion_control':
            q['congestion_control'] ??
                'bbr',
        'tls': tls,
      },
    );
  }

  void _applyTransport(
    Map<String, dynamic> outbound,
    Map<String, String> q,
  ) {
    final network =
        q['type'] ??
            q['network'] ??
            'tcp';

    switch (network) {
      case 'ws':
      case 'websocket':
        outbound['transport'] = {
          'type': 'ws',
          'path': q['path'] ?? '/',
          if (q['host'] != null)
            'headers': {
              'Host': q['host'],
            },
        };
        break;

      case 'grpc':
        outbound['transport'] = {
          'type': 'grpc',
          'service_name':
              q['serviceName'] ??
                  q['service_name'] ??
                  '',
        };
        break;

      case 'httpupgrade':
      case 'http-upgrade':
        outbound['transport'] = {
          'type': 'httpupgrade',
          'path': q['path'] ?? '/',
          if (q['host'] != null)
            'host': q['host'],
        };
        break;

      case 'http':
      case 'h2':
        outbound['transport'] = {
          'type': 'http',
          'path': q['path'] ?? '/',
          if (q['host'] != null)
            'host': [
              q['host']!,
            ],
        };
        break;
    }
  }

  String _serverName(
    String? preferred,
    String host,
    int port,
  ) {
    final name =
        preferred?.trim() ?? '';

    if (name.isNotEmpty) {
      return _decodeFragment(name);
    }

    return '$host:$port';
  }

  String _decodeFragment(String value) {
    if (value.isEmpty) return value;

    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  List<Server> _deduplicateServers(
    List<Server> input,
  ) {
    final result = <Server>[];
    final seen = <String>{};

    for (final server in input) {
      final key =
          '${server.type}|${server.host}|${server.port}|${server.name}';

      if (seen.add(key)) {
        result.add(server);
      }
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // PING
  // ---------------------------------------------------------------------------

  Future<void> testAll({
    bool silent = true,
  }) async {
    if (servers.isEmpty) return;

    if (mounted) {
      setState(() {
        testing = true;
      });
    }

    await Future.wait(
      List.generate(
        servers.length,
        (index) async {
          final server = servers[index];

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

            stopwatch.stop();

            socket.destroy();

            if (!mounted) return;

            setState(() {
              if (index < servers.length &&
                  servers[index].host ==
                      server.host &&
                  servers[index].port ==
                      server.port) {
                servers[index].ping =
                    stopwatch.elapsedMilliseconds;
              }
            });
          } catch (_) {
            if (!mounted) return;

            setState(() {
              if (index < servers.length) {
                servers[index].ping = null;
              }
            });
          }
        },
      ),
    );

    if (!mounted) return;

    setState(() {
      testing = false;
    });

    await _saveServers();
  }

  // ---------------------------------------------------------------------------
  // SING-BOX CONFIG
  // ---------------------------------------------------------------------------

  Map<String, dynamic> buildConfig() {
    final outbounds = <Map<String, dynamic>>[];

    for (int i = 0; i < servers.length; i++) {
      final original =
          Map<String, dynamic>.from(
        servers[i].outbound,
      );

      original['tag'] = 'proxy-$i';

      outbounds.add(original);
    }

    if (outbounds.isEmpty) {
      throw StateError(
        'هیچ سروری وجود ندارد.',
      );
    }

    String finalOutbound;

    if (autoSelect &&
        outbounds.length > 1) {
      finalOutbound = 'auto';

      outbounds.add({
        'type': 'urltest',
        'tag': 'auto',
        'outbounds': [
          for (int i = 0;
              i < servers.length;
              i++)
            'proxy-$i',
        ],
        'url':
            'https://www.gstatic.com/generate_204',
        'interval': '3m',
        'tolerance': 50,
        'idle_timeout': '30m',
      });
    } else {
      final index =
          min(
            selectedServer,
            outbounds.length - 1,
          );

      finalOutbound =
          'proxy-$index';
    }

    return {
      'log': {
        'level': 'warn',
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

      'outbounds': [
        ...outbounds,
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
  }

  // ---------------------------------------------------------------------------
  // VPN
  // ---------------------------------------------------------------------------

  Future<void> connect() async {
    if (connecting) return;

    if (servers.isEmpty) {
      _showMessage(
        'اول Subscription را دریافت کن.',
      );
      return;
    }

    setState(() {
      connecting = true;
      stateText = 'در حال اتصال...';
      lastFault = '';
    });

    try {
      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw StateError(
          'اجازه VPN داده نشد.',
        );
      }

      final config =
          jsonEncode(buildConfig());

      await vpn.checkConfig(config);

      await vpn.connect(
        SessionOptions(
          config: config,
          networkMode: NetworkMode.vpn,
          notification: const NotificationConfig(
            title: 'Light speed 🔥',
            showTrafficStats: true,
            showStopButton: true,
            stopButtonLabel: 'قطع اتصال',
          ),
        ),
      );

      if (!mounted) return;

      setState(() {
        connected = true;
        connecting = false;
        connectedAt = DateTime.now();
        stateText = 'متصل';
        sessionUpload = 0;
        sessionDownload = 0;
      });

      _startConnectionTimer();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        connected = false;
        connecting = false;
        stateText = 'اتصال ناموفق';
        lastFault = e.toString();
      });

      _showMessage(
        'اتصال ناموفق بود:\n$e',
      );
    }
  }

  Future<void> disconnect() async {
    try {
      await vpn.disconnect();
    } catch (_) {}

    connectionTimer?.cancel();

    if (!mounted) return;

    setState(() {
      connected = false;
      connecting = false;
      connectedAt = null;
      uploadSpeed = 0;
      downloadSpeed = 0;
      stateText = 'قطع';
    });
  }

  void _startConnectionTimer() {
    connectionTimer?.cancel();

    connectionTimer =
        Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;

        if (connectedAt == null) return;

        setState(() {});
      },
    );
  }

  // ---------------------------------------------------------------------------
  // UI HELPERS
  // ---------------------------------------------------------------------------

  String size(int? bytes) {
    if (bytes == null) {
      return 'نامشخص';
    }

    if (bytes < 1024) {
      return '$bytes B';
    }

    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }

    if (bytes < 1024 * 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }

    return '${(bytes / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(2)} TB';
  }

  String speed(int bitsPerSecond) {
    if (bitsPerSecond <= 0) {
      return '0 B/s';
    }

    final bytes =
        bitsPerSecond / 8;

    if (bytes < 1024) {
      return '${bytes.toStringAsFixed(0)} B/s';
    }

    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB/s';
    }

    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }

    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB/s';
  }

  String remainingTime() {
    final expire =
        subscription.expire;

    if (expire == null ||
        expire <= 0) {
      return 'نامشخص';
    }

    final expiry =
        DateTime.fromMillisecondsSinceEpoch(
      expire * 1000,
    );

    final diff =
        expiry.difference(
      DateTime.now(),
    );

    if (diff.isNegative) {
      return 'منقضی شده';
    }

    final days =
        diff.inDays;

    final hours =
        diff.inHours % 24;

    if (days > 0) {
      return '$days روز و $hours ساعت';
    }

    final minutes =
        diff.inMinutes % 60;

    return '$hours ساعت و $minutes دقیقه';
  }

  String connectionDuration() {
    if (connectedAt == null) {
      return '00:00:00';
    }

    final diff =
        DateTime.now()
            .difference(connectedAt!);

    final h =
        diff.inHours
            .toString()
            .padLeft(2, '0');

    final m =
        (diff.inMinutes % 60)
            .toString()
            .padLeft(2, '0');

    final s =
        (diff.inSeconds % 60)
            .toString()
            .padLeft(2, '0');

    return '$h:$m:$s';
  }

  double usagePercent() {
    final total =
        subscription.total;

    final used =
        subscription.used;

    if (total == null ||
        used == null ||
        total <= 0) {
      return 0;
    }

    return min(
      1,
      max(
        0,
        used / total,
      ),
    );
  }

  void _showMessage(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            text,
            textDirection: TextDirection.rtl,
          ),
          behavior:
              SnackBarBehavior.floating,
        ),
      );
  }

  Widget _card({
    required Widget child,
    EdgeInsets padding =
        const EdgeInsets.all(18),
  }) {
    return Card(
      margin:
          const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }

  Widget _stat(
    String title,
    String value,
    IconData icon,
  ) {
    return Expanded(
      child: Container(
        padding:
            const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF101C2D),
          borderRadius:
              BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 21,
              color:
                  const Color(0xFF00D4FF),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              maxLines: 1,
              overflow:
                  TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // HOME PAGE
  // ---------------------------------------------------------------------------

  Widget _homePage() {
    final used =
        subscription.used;

    final total =
        subscription.total;

    final remaining =
        subscription.remaining;

    return RefreshIndicator(
      onRefresh: () =>
          loadSubscription(),
      child: ListView(
        padding:
            const EdgeInsets.fromLTRB(
          16,
          16,
          16,
          100,
        ),
        children: [
          _header(),

          const SizedBox(height: 12),

          _subscriptionCard(
            used: used,
            total: total,
            remaining: remaining,
          ),

          _trafficCard(),

          _connectionCard(),

          _quickStats(),

          if (lastFault.isNotEmpty)
            _errorCard(),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            borderRadius:
                BorderRadius.circular(16),
            gradient:
                const LinearGradient(
              colors: [
                Color(0xFF00D4FF),
                Color(0xFF0066FF),
              ],
            ),
          ),
          child: const Icon(
            Icons.bolt_rounded,
            color: Colors.white,
            size: 30,
          ),
        ),

        const SizedBox(width: 12),

        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'Light speed 🔥',
                style: TextStyle(
                  fontSize: 23,
                  fontWeight:
                      FontWeight.w800,
                ),
              ),
              Text(
                subscriptionTitle,
                maxLines: 1,
                overflow:
                    TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white60,
                ),
              ),
            ],
          ),
        ),

        IconButton(
          onPressed:
              loading
                  ? null
                  : () => loadSubscription(),
          icon: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child:
                      CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                )
              : const Icon(
                  Icons.refresh_rounded,
                ),
        ),
      ],
    );
  }

  Widget _subscriptionCard({
    required int? used,
    required int? total,
    required int? remaining,
  }) {
    return _card(
      child: Column(
        children: [
          Row(
            children: [
              const Icon(
                Icons.cloud_rounded,
                color:
                    Color(0xFF00D4FF),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'اطلاعات Subscription',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
              if (testing)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child:
                      CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                ),
            ],
          ),

          const SizedBox(height: 18),

          Row(
            children: [
              _stat(
                'کل حجم',
                size(total),
                Icons.data_usage_rounded,
              ),
              const SizedBox(width: 10),
              _stat(
                'مصرف',
                size(used),
                Icons.pie_chart_rounded,
              ),
              const SizedBox(width: 10),
              _stat(
                'باقی‌مانده',
                size(remaining),
                Icons.data_saver_on_rounded,
              ),
            ],
          ),

          const SizedBox(height: 18),

          ClipRRect(
            borderRadius:
                BorderRadius.circular(20),
            child:
                LinearProgressIndicator(
              minHeight: 8,
              value: usagePercent(),
              backgroundColor:
                  Colors.white10,
            ),
          ),

          const SizedBox(height: 14),

          Row(
            children: [
              Expanded(
                child: _infoLine(
                  Icons.upload_rounded,
                  'آپلود اشتراک',
                  size(
                    subscription.upload,
                  ),
                ),
              ),
              Expanded(
                child: _infoLine(
                  Icons.download_rounded,
                  'دانلود اشتراک',
                  size(
                    subscription.download,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          _infoLine(
            Icons.timer_outlined,
            'زمان باقی‌مانده',
            remainingTime(),
          ),

          const SizedBox(height: 8),

          Align(
            alignment:
                Alignment.centerLeft,
            child: Text(
              stateText,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoLine(
    IconData icon,
    String title,
    String value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        vertical: 5,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color:
                const Color(0xFF00D4FF),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 12,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _trafficCard() {
    return _card(
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          const Text(
            'ترافیک لحظه‌ای VPN',
            style: TextStyle(
              fontSize: 17,
              fontWeight:
                  FontWeight.bold,
            ),
          ),

          const SizedBox(height: 14),

          Row(
            children: [
              _stat(
                'دانلود',
                speed(downloadSpeed),
                Icons.download_rounded,
              ),
              const SizedBox(width: 10),
              _stat(
                'آپلود',
                speed(uploadSpeed),
                Icons.upload_rounded,
              ),
            ],
          ),

          const SizedBox(height: 14),

          Row(
            children: [
              Expanded(
                child: _infoLine(
                  Icons.download_done_rounded,
                  'دانلود این جلسه',
                  size(sessionDownload),
                ),
              ),
              Expanded(
                child: _infoLine(
                  Icons.upload_file_rounded,
                  'آپلود این جلسه',
                  size(sessionUpload),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _connectionCard() {
    return _card(
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 13,
                height: 13,
                decoration:
                    BoxDecoration(
                  shape:
                      BoxShape.circle,
                  color: connected
                      ? Colors.greenAccent
                      : Colors.redAccent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  connected
                      ? 'اتصال فعال است'
                      : 'اتصال برقرار نیست',
                  style:
                      const TextStyle(
                    fontSize: 17,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
              if (connected)
                Text(
                  connectionDuration(),
                  style:
                      const TextStyle(
                    color:
                        Colors.white60,
                  ),
                ),
            ],
          ),

          const SizedBox(height: 18),

          SizedBox(
            width: double.infinity,
            height: 58,
            child: FilledButton.icon(
              onPressed:
                  connecting
                      ? null
                      : connected
                          ? disconnect
                          : connect,
              icon: connecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child:
                          CircularProgressIndicator(
                        strokeWidth: 2,
                        color:
                            Colors.white,
                      ),
                    )
                  : Icon(
                      connected
                          ? Icons
                              .power_settings_new_rounded
                          : Icons
                              .bolt_rounded,
                    ),
              label: Text(
                connecting
                    ? 'در حال اتصال...'
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickStats() {
    return Row(
      children: [
        Expanded(
          child: _smallBox(
            Icons.dns_rounded,
            'سرورها',
            '${servers.length}',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _smallBox(
            Icons.flash_on_rounded,
            'انتخاب',
            autoSelect
                ? 'خودکار'
                : 'دستی',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _smallBox(
            Icons.sync_rounded,
            'آپدیت',
            '۱۵ دقیقه',
          ),
        ),
      ],
    );
  }

  Widget _smallBox(
    IconData icon,
    String title,
    String value,
  ) {
    return Container(
      padding:
          const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1422),
        borderRadius:
            BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color:
                const Color(0xFF00D4FF),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorCard() {
    return _card(
      child: Row(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.orangeAccent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              lastFault,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SERVERS PAGE
  // ---------------------------------------------------------------------------

  Widget _serversPage() {
    return Column(
      children: [
        Padding(
          padding:
              const EdgeInsets.fromLTRB(
            16,
            16,
            16,
            8,
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'سرورها',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                onPressed:
                    testing
                        ? null
                        : () => testAll(
                              silent: false,
                            ),
                icon: testing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(
                        Icons.speed_rounded,
                      ),
              ),
            ],
          ),
        ),

        Expanded(
          child: servers.isEmpty
              ? _emptyServers()
              : ListView.builder(
                  padding:
                      const EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    100,
                  ),
                  itemCount:
                      servers.length,
                  itemBuilder:
                      (context, index) {
                    return _serverTile(
                      index,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _emptyServers() {
    return Center(
      child: Padding(
        padding:
            const EdgeInsets.all(30),
        child: Column(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.dns_outlined,
              size: 70,
              color: Colors.white24,
            ),
            const SizedBox(height: 18),
            const Text(
              'هنوز سروری دریافت نشده',
              style: TextStyle(
                fontSize: 18,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'لینک Subscription را وارد کن و بروزرسانی را بزن.',
              textAlign:
                  TextAlign.center,
              style: TextStyle(
                color: Colors.white54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _serverTile(int index) {
    final server =
        servers[index];

    final selected =
        !autoSelect &&
            selectedServer == index;

    return Card(
      margin:
          const EdgeInsets.only(
        bottom: 10,
      ),
      child: InkWell(
        borderRadius:
            BorderRadius.circular(22),
        onTap: () {
          setState(() {
            selectedServer = index;
            autoSelect = false;
          });
        },
        child: Padding(
          padding:
              const EdgeInsets.all(15),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration:
                    BoxDecoration(
                  color: selected
                      ? const Color(
                          0xFF00D4FF,
                        ).withValues(
                          alpha: .15,
                        )
                      : Colors.white
                          .withValues(
                          alpha: .05,
                        ),
                  borderRadius:
                      BorderRadius.circular(
                    15,
                  ),
                ),
                child: Icon(
                  Icons.dns_rounded,
                  color: selected
                      ? const Color(
                          0xFF00D4FF,
                        )
                      : Colors.white54,
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      maxLines: 1,
                      overflow:
                          TextOverflow.ellipsis,
                      style:
                          const TextStyle(
                        fontWeight:
                            FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(
                      height: 5,
                    ),
                    Text(
                      '${server.type} • ${server.host}:${server.port}',
                      maxLines: 1,
                      overflow:
                          TextOverflow.ellipsis,
                      style:
                          const TextStyle(
                        color:
                            Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              _pingWidget(
                server.ping,
              ),

              const SizedBox(width: 8),

              if (selected)
                const Icon(
                  Icons.check_circle_rounded,
                  color:
                      Color(0xFF00D4FF),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pingWidget(int? ping) {
    if (ping == null) {
      return const Text(
        '—',
        style: TextStyle(
          color: Colors.white38,
        ),
      );
    }

    return Text(
      '$ping ms',
      style: TextStyle(
        fontSize: 12,
        fontWeight:
            FontWeight.bold,
        color: ping < 100
            ? Colors.greenAccent
            : ping < 250
                ? Colors.orangeAccent
                : Colors.redAccent,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SETTINGS
  // ---------------------------------------------------------------------------

  Widget _settingsPage() {
    return ListView(
      padding:
          const EdgeInsets.fromLTRB(
        16,
        16,
        16,
        100,
      ),
      children: [
        const Text(
          'تنظیمات',
          style: TextStyle(
            fontSize: 24,
            fontWeight:
                FontWeight.bold,
          ),
        ),

        const SizedBox(height: 16),

        _card(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'Subscription',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              const SizedBox(height: 12),

              TextField(
                controller:
                    urlController,
                textDirection:
                    TextDirection.ltr,
                decoration:
                    InputDecoration(
                  hintText:
                      'https://...',
                  filled: true,
                  fillColor:
                      Colors.black26,
                  border:
                      OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(
                      16,
                    ),
                    borderSide:
                        BorderSide.none,
                  ),
                ),
              ),

              const SizedBox(height: 12),

              SizedBox(
                width:
                    double.infinity,
                height: 52,
                child:
                    FilledButton.icon(
                  onPressed:
                      loading
                          ? null
                          : () =>
                              loadSubscription(),
                  icon: const Icon(
                    Icons.sync_rounded,
                  ),
                  label: const Text(
                    'بروزرسانی Subscription',
                  ),
                ),
              ),
            ],
          ),
        ),

        _card(
          child: Column(
            children: [
              SwitchListTile(
                contentPadding:
                    EdgeInsets.zero,
                value: autoSelect,
                onChanged:
                    connected
                        ? null
                        : (value) {
                            setState(() {
                              autoSelect =
                                  value;
                            });
                          },
                title: const Text(
                  'انتخاب خودکار سریع‌ترین سرور',
                ),
                subtitle:
                    const Text(
                  'sing-box با URLTest بهترین مسیر را انتخاب می‌کند.',
                  style: TextStyle(
                    color:
                        Colors.white54,
                  ),
                ),
              ),
            ],
          ),
        ),

        _card(
          child: Column(
            children: [
              _settingRow(
                Icons.dns_rounded,
                'تعداد سرورها',
                '${servers.length}',
              ),
              _settingRow(
                Icons.sync_rounded,
                'بروزرسانی خودکار',
                'هر ۱۵ دقیقه',
              ),
              _settingRow(
                Icons.cloud_download_rounded,
                'دانلود اشتراک',
                size(
                  subscription.download,
                ),
              ),
              _settingRow(
                Icons.cloud_upload_rounded,
                'آپلود اشتراک',
                size(
                  subscription.upload,
                ),
              ),
              _settingRow(
                Icons.data_usage_rounded,
                'مصرف اشتراک',
                size(
                  subscription.used,
                ),
              ),
              _settingRow(
                Icons.event_rounded,
                'زمان باقی‌مانده',
                remainingTime(),
              ),
            ],
          ),
        ),

        if (supportUrl != null &&
            supportUrl!.isNotEmpty)
          _card(
            child: ListTile(
              contentPadding:
                  EdgeInsets.zero,
              leading: const Icon(
                Icons.support_agent_rounded,
              ),
              title: const Text(
                'پشتیبانی Subscription',
              ),
              subtitle: Text(
                supportUrl!,
                maxLines: 1,
                overflow:
                    TextOverflow.ellipsis,
              ),
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
            size: 21,
            color:
                const Color(0xFF00D4FF),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TRAFFIC PAGE
  // ---------------------------------------------------------------------------

  Widget _trafficPage() {
    final used =
        subscription.used;

    final total =
        subscription.total;

    final remaining =
        subscription.remaining;

    return ListView(
      padding:
          const EdgeInsets.fromLTRB(
        16,
        16,
        16,
        100,
      ),
      children: [
        const Text(
          'مصرف و ترافیک',
          style: TextStyle(
            fontSize: 24,
            fontWeight:
                FontWeight.bold,
          ),
        ),

        const SizedBox(height: 16),

        _card(
          child: Column(
            children: [
              const Text(
                'مصرف Subscription',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              const SizedBox(height: 20),

              Row(
                children: [
                  _stat(
                    'کل',
                    size(total),
                    Icons.data_usage,
                  ),
                  const SizedBox(width: 10),
                  _stat(
                    'مصرف',
                    size(used),
                    Icons.pie_chart,
                  ),
                  const SizedBox(width: 10),
                  _stat(
                    'باقی',
                    size(remaining),
                    Icons.storage_rounded,
                  ),
                ],
              ),

              const SizedBox(height: 20),

              _infoLine(
                Icons.upload,
                'آپلود حساب',
                size(
                  subscription.upload,
                ),
              ),

              _infoLine(
                Icons.download,
                'دانلود حساب',
                size(
                  subscription.download,
                ),
              ),

              _infoLine(
                Icons.timer,
                'انقضا',
                remainingTime(),
              ),
            ],
          ),
        ),

        _card(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'جلسه فعلی VPN',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              const SizedBox(height: 16),

              _infoLine(
                Icons.download_done,
                'دانلود',
                size(
                  sessionDownload,
                ),
              ),

              _infoLine(
                Icons.upload_file,
                'آپلود',
                size(
                  sessionUpload,
                ),
              ),

              _infoLine(
                Icons.download_rounded,
                'سرعت دانلود',
                speed(
                  downloadSpeed,
                ),
              ),

              _infoLine(
                Icons.upload_rounded,
                'سرعت آپلود',
                speed(
                  uploadSpeed,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final pages = [
      _homePage(),
      _serversPage(),
      _trafficPage(),
      _settingsPage(),
    ];

    return Scaffold(
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
        backgroundColor:
            const Color(0xFF08111E),
        indicatorColor:
            const Color(0xFF00D4FF)
                .withValues(
          alpha: .18,
        ),
        destinations: const [
          NavigationDestination(
            icon: Icon(
              Icons.home_outlined,
            ),
            selectedIcon: Icon(
              Icons.home_rounded,
            ),
            label: 'خانه',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.dns_outlined,
            ),
            selectedIcon: Icon(
              Icons.dns_rounded,
            ),
            label: 'سرورها',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.data_usage_outlined,
            ),
            selectedIcon: Icon(
              Icons.data_usage_rounded,
            ),
            label: 'ترافیک',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.settings_outlined,
            ),
            selectedIcon: Icon(
              Icons.settings_rounded,
            ),
            label: 'تنظیمات',
          ),
        ],
      ),
    );
  }
}
