import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_singbox_client/flutter_singbox_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
        scaffoldBackgroundColor: const Color(0xFF050A12),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF19E6B5),
          brightness: Brightness.dark,
        ),
      ),
      home: const LightSpeedHome(),
    );
  }
}

class ServerConfig {
  final String name;
  final String type;
  final String address;
  final int port;
  final String raw;
  final Map<String, dynamic> outbound;

  int? ping;

  ServerConfig({
    required this.name,
    required this.type,
    required this.address,
    required this.port,
    required this.raw,
    required this.outbound,
    this.ping,
  });
}

class SubscriptionInfo {
  final int upload;
  final int download;
  final int total;
  final int expire;

  const SubscriptionInfo({
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire = 0,
  });

  int get used => upload + download;

  int get remaining {
    if (total <= used) return 0;
    return total - used;
  }

  double get progress {
    if (total <= 0) return 0;
    return (used / total).clamp(0.0, 1.0);
  }
}

class LightSpeedHome extends StatefulWidget {
  const LightSpeedHome({super.key});

  @override
  State<LightSpeedHome> createState() => _LightSpeedHomeState();
}

class _LightSpeedHomeState extends State<LightSpeedHome>
    with WidgetsBindingObserver {
  final SingboxClient _singbox = SingboxClient();

  final TextEditingController _subscriptionController =
      TextEditingController();

  final Color green = const Color(0xFF19E6B5);
  final Color purple = const Color(0xFF8B5CF6);
  final Color blue = const Color(0xFF3B82F6);
  final Color panel = const Color(0xFF0A1220);

  int _tab = 0;

  bool _initialized = false;
  bool _loading = false;
  bool _connecting = false;
  bool _connected = false;

  String _status = 'آماده اتصال';
  String? _error;

  List<ServerConfig> _servers = [];
  ServerConfig? _currentServer;

  SubscriptionInfo _subscription =
      const SubscriptionInfo();

  int _downloadBps = 0;
  int _uploadBps = 0;

  StreamSubscription? _stateSubscription;
  StreamSubscription? _trafficSubscription;
  StreamSubscription? _faultSubscription;

  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final savedUrl =
          prefs.getString('subscription_url');

      if (savedUrl != null) {
        _subscriptionController.text = savedUrl;
      }

      await _singbox.initialize();

      _initialized = true;

      _stateSubscription =
          _singbox.serviceStateStream.listen((state) {
        if (!mounted) return;

        final value =
            state.toString().toLowerCase();

        setState(() {
          if (value.contains('running') ||
              value.contains('connected') ||
              value.contains('started')) {
            _connected = true;
            _connecting = false;
            _status = 'متصل';
          }

          if (value.contains('stopped') ||
              value.contains('disconnected')) {
            _connected = false;
            _connecting = false;
            _status = 'قطع اتصال';
          }
        });
      });

      _trafficSubscription =
          _singbox.trafficStatsStream.listen((stats) {
        if (!mounted) return;

        setState(() {
          _downloadBps = stats.downlinkBps;
          _uploadBps = stats.uplinkBps;
        });
      });

      _faultSubscription =
          _singbox.faultStream.listen((fault) {
        if (!mounted) return;

        setState(() {
          _connected = false;
          _connecting = false;
          _status = 'خطا';
          _error = fault.toString();
        });

        _showMessage(
          'خطای VPN: ${fault.toString()}',
        );
      });

      if (_subscriptionController.text.trim().isNotEmpty) {
        await refreshSubscription(
          showMessage: false,
        );
      }

      _refreshTimer = Timer.periodic(
        const Duration(minutes: 15),
        (_) {
          if (!_connected &&
              _subscriptionController.text
                  .trim()
                  .isNotEmpty) {
            refreshSubscription(
              showMessage: false,
            );
          }
        },
      );

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error =
            'راه‌اندازی برنامه ناموفق بود:\n$e';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (state == AppLifecycleState.resumed &&
        _subscriptionController.text
            .trim()
            .isNotEmpty &&
        !_connected) {
      refreshSubscription(
        showMessage: false,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _refreshTimer?.cancel();

    _stateSubscription?.cancel();
    _trafficSubscription?.cancel();
    _faultSubscription?.cancel();

    _subscriptionController.dispose();

    super.dispose();
  }

  Future<void> refreshSubscription({
    bool showMessage = true,
  }) async {
    if (_loading) return;

    final url =
        _subscriptionController.text.trim();

    if (url.isEmpty) {
      _showMessage(
        'ابتدا لینک Subscription را وارد کنید.',
      );
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _status = 'در حال دریافت سرورها...';
    });

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Light-speed/1.0',
        },
      ).timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw Exception(
          'خطای سرور: HTTP ${response.statusCode}',
        );
      }

      _readSubscriptionInfo(
        response.headers['subscription-userinfo'],
      );

      final decoded =
          _decodeSubscription(response.body);

      final parsed =
          _parseSubscription(decoded);

      if (parsed.isEmpty) {
        throw Exception(
          'هیچ کانفیگ پشتیبانی‌شده‌ای پیدا نشد.',
        );
      }

      final prefs =
          await SharedPreferences.getInstance();

      await prefs.setString(
        'subscription_url',
        url,
      );

      if (!mounted) return;

      setState(() {
        _servers = parsed;

        if (_currentServer == null ||
            !_containsSameServer(
              _currentServer!,
              parsed,
            )) {
          _currentServer = parsed.first;
        }

        _status = 'Subscription به‌روز شد';
      });

      await _pingServers();

      if (mounted && showMessage) {
        _showMessage(
          '${_servers.length} سرور دریافت شد.',
        );
      }
    } catch (e) {
      if (!mounted) return;

      final message =
          e.toString().replaceFirst(
                'Exception: ',
                '',
              );

      setState(() {
        _error = message;
        _status = 'خطا در دریافت';
      });

      if (showMessage) {
        _showMessage(message);
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  bool _containsSameServer(
    ServerConfig server,
    List<ServerConfig> list,
  ) {
    return list.any(
      (x) =>
          x.address == server.address &&
          x.port == server.port &&
          x.type == server.type,
    );
  }

  void _readSubscriptionInfo(String? header) {
    if (header == null || header.isEmpty) {
      return;
    }

    final values = <String, int>{};

    for (final item in header.split(';')) {
      final parts = item.trim().split('=');

      if (parts.length != 2) continue;

      values[
          parts[0].trim().toLowerCase()] =
          int.tryParse(parts[1].trim()) ?? 0;
    }

    if (!mounted) return;

    setState(() {
      _subscription = SubscriptionInfo(
        upload: values['upload'] ?? 0,
        download: values['download'] ?? 0,
        total: values['total'] ?? 0,
        expire: values['expire'] ?? 0,
      );
    });
  }

  String _decodeSubscription(String body) {
    final text = body.trim();

    if (text.isEmpty) return '';

    if (text.contains('://')) {
      return text;
    }

    final candidates = <String>[
      text,
      text.replaceAll(RegExp(r'\s+'), ''),
    ];

    for (final candidate in candidates) {
      try {
        var value = candidate;

        value += '=' *
            ((4 - value.length % 4) % 4);

        final bytes =
            base64Url.decode(value);

        final decoded =
            utf8.decode(
          bytes,
          allowMalformed: true,
        );

        if (decoded.contains('://')) {
          return decoded;
        }
      } catch (_) {}

      try {
        var value =
            candidate
                .replaceAll('-', '+')
                .replaceAll('_', '/');

        value += '=' *
            ((4 - value.length % 4) % 4);

        final decoded =
            utf8.decode(
          base64.decode(value),
          allowMalformed: true,
        );

        if (decoded.contains('://')) {
          return decoded;
        }
      } catch (_) {}
    }

    return text;
  }

  List<ServerConfig> _parseSubscription(
    String text,
  ) {
    final result = <ServerConfig>[];

    for (final line
        in text.split(RegExp(r'\r?\n'))) {
      final value = line.trim();

      if (value.isEmpty ||
          value.startsWith('#')) {
        continue;
      }

      try {
        if (value.startsWith('vless://')) {
          result.add(_parseVless(value));
        } else if (value.startsWith('vmess://')) {
          result.add(_parseVmess(value));
        } else if (value.startsWith('trojan://')) {
          result.add(_parseTrojan(value));
        } else if (value.startsWith('ss://')) {
          result.add(
            _parseShadowsocks(value),
          );
        } else if (value.startsWith(
              'hysteria2://',
            ) ||
            value.startsWith('hy2://')) {
          result.add(
            _parseHysteria2(value),
          );
        }
      } catch (_) {}
    }

    return result;
  }

  ServerConfig _parseVless(String raw) {
    final uri = Uri.parse(raw);

    final query = uri.queryParameters;

    final type =
        query['type'] ??
            query['network'] ??
            'tcp';

    final outbound =
        <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': uri.host,
      'server_port':
          uri.hasPort ? uri.port : 443,
      'uuid': uri.userInfo,
    };

    _applyTls(
      outbound,
      query,
    );

    _applyTransport(
      outbound,
      query,
      type,
    );

    if (query['flow'] != null &&
        query['flow']!.isNotEmpty) {
      outbound['flow'] =
          query['flow'];
    }

    return ServerConfig(
      name: _displayName(
        query['name'] ??
            query['remarks'],
        uri.host,
      ),
      type: 'VLESS',
      address: uri.host,
      port: uri.hasPort
          ? uri.port
          : 443,
      raw: raw,
      outbound: outbound,
    );
  }

  ServerConfig _parseVmess(String raw) {
    final encoded =
        raw.substring('vmess://'.length);

    final decoded =
        _decodeBase64Json(encoded);

    if (decoded == null) {
      throw Exception('VMess نامعتبر');
    }

    final server =
        decoded['add']?.toString() ?? '';

    final port =
        int.tryParse(
              decoded['port']?.toString() ?? '',
            ) ??
            443;

    final uuid =
        decoded['id']?.toString() ?? '';

    final network =
        decoded['net']?.toString() ?? 'tcp';

    final outbound =
        <String, dynamic>{
      'type': 'vmess',
      'tag': 'proxy',
      'server': server,
      'server_port': port,
      'uuid': uuid,
      'security':
          decoded['scy']?.toString() ??
              'auto',
    };

    final tls =
        decoded['tls']?.toString();

    if (tls == 'tls') {
      final tlsConfig =
          <String, dynamic>{
        'enabled': true,
      };

      final sni =
          decoded['sni']?.toString() ??
              decoded['host']?.toString();

      if (sni != null &&
          sni.isNotEmpty) {
        tlsConfig['server_name'] = sni;
      }

      outbound['tls'] = tlsConfig;
    }

    _applyVmessTransport(
      outbound,
      decoded,
      network,
    );

    return ServerConfig(
      name: _displayName(
        decoded['ps']?.toString(),
        server,
      ),
      type: 'VMess',
      address: server,
      port: port,
      raw: raw,
      outbound: outbound,
    );
  }

  ServerConfig _parseTrojan(String raw) {
    final uri = Uri.parse(raw);

    final query = uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': uri.host,
      'server_port':
          uri.hasPort ? uri.port : 443,
      'password': uri.userInfo,
    };

    _applyTls(
      outbound,
      query,
    );

    final network =
        query['type'] ??
            query['network'] ??
            'tcp';

    _applyTransport(
      outbound,
      query,
      network,
    );

    return ServerConfig(
      name: _displayName(
        query['name'],
        uri.host,
      ),
      type: 'Trojan',
      address: uri.host,
      port:
          uri.hasPort ? uri.port : 443,
      raw: raw,
      outbound: outbound,
    );
  }

  ServerConfig _parseShadowsocks(
    String raw,
  ) {
    final uri = Uri.parse(raw);

    String userInfo;

    if (uri.userInfo.isNotEmpty) {
      userInfo = uri.userInfo;
    } else {
      final encoded =
          raw.substring('ss://'.length);

      final decoded =
          _decodeBase64String(
        encoded.split('#').first,
      );

      if (decoded == null) {
        throw Exception(
          'Shadowsocks نامعتبر',
        );
      }

      userInfo = decoded;
    }

    final separator =
        userInfo.indexOf('@');

    if (separator <= 0) {
      throw Exception(
        'فرمت Shadowsocks نامعتبر',
      );
    }

    final methodPassword =
        userInfo.substring(
      0,
      separator,
    );

    final hostPort =
        userInfo.substring(
      separator + 1,
    );

    final colon =
        methodPassword.indexOf(':');

    if (colon <= 0) {
      throw Exception(
        'روش Shadowsocks نامعتبر',
      );
    }

    final method =
        methodPassword.substring(
      0,
      colon,
    );

    final password =
        methodPassword.substring(
      colon + 1,
    );

    final hostParts =
        hostPort.split(':');

    final host =
        hostParts.first;

    final port =
        hostParts.length > 1
            ? int.tryParse(
                  hostParts.last,
                ) ??
                443
            : 443;

    final outbound =
        <String, dynamic>{
      'type': 'shadowsocks',
      'tag': 'proxy',
      'server': host,
      'server_port': port,
      'method': method,
      'password': password,
    };

    return ServerConfig(
      name: _displayName(
        uri.fragment.isEmpty
            ? null
            : Uri.decodeComponent(
                uri.fragment,
              ),
        host,
      ),
      type: 'Shadowsocks',
      address: host,
      port: port,
      raw: raw,
      outbound: outbound,
    );
  }

  ServerConfig _parseHysteria2(
    String raw,
  ) {
    final uri = Uri.parse(raw);

    final query = uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': uri.host,
      'server_port':
          uri.hasPort ? uri.port : 443,
      'password': uri.userInfo,
    };

    final tls =
        <String, dynamic>{
      'enabled': true,
    };

    final sni =
        query['sni'];

    if (sni != null &&
        sni.isNotEmpty) {
      tls['server_name'] = sni;
    }

    outbound['tls'] = tls;

    return ServerConfig(
      name: _displayName(
        query['name'],
        uri.host,
      ),
      type: 'Hysteria2',
      address: uri.host,
      port:
          uri.hasPort ? uri.port : 443,
      raw: raw,
      outbound: outbound,
    );
  }

  void _applyTls(
    Map<String, dynamic> outbound,
    Map<String, String> query,
  ) {
    final security =
        query['security'];

    if (security == null ||
        security == 'none' ||
        security == 'false') {
      return;
    }

    final tls =
        <String, dynamic>{
      'enabled': true,
    };

    final sni =
        query['sni'] ??
            query['host'];

    if (sni != null &&
        sni.isNotEmpty) {
      tls['server_name'] = sni;
    }

    final fingerprint =
        query['fp'];

    if (fingerprint != null &&
        fingerprint.isNotEmpty) {
      tls['utls'] = {
        'enabled': true,
        'fingerprint': fingerprint,
      };
    }

    final pbk =
        query['pbk'];

    final sid =
        query['sid'];

    if (security == 'reality' &&
        pbk != null &&
        pbk.isNotEmpty) {
      tls['reality'] = {
        'enabled': true,
        'public_key': pbk,
        if (sid != null && sid.isNotEmpty)
          'short_id': sid,
      };
    }

    outbound['tls'] = tls;
  }

  void _applyTransport(
    Map<String, dynamic> outbound,
    Map<String, String> query,
    String type,
  ) {
    if (type == 'ws' ||
        type == 'websocket') {
      final transport =
          <String, dynamic>{
        'type': 'ws',
      };

      final path =
          query['path'];

      if (path != null &&
          path.isNotEmpty) {
        transport['path'] = path;
      }

      final host =
          query['host'];

      if (host != null &&
          host.isNotEmpty) {
        transport['headers'] = {
          'Host': host,
        };
      }

      outbound['transport'] =
          transport;
    } else if (type == 'grpc') {
      final service =
          query['serviceName'] ??
              query['service_name'] ??
              '';

      outbound['transport'] = {
        'type': 'grpc',
        if (service.isNotEmpty)
          'service_name': service,
      };
    } else if (type == 'httpupgrade') {
      final transport =
          <String, dynamic>{
        'type': 'httpupgrade',
      };

      final path =
          query['path'];

      if (path != null &&
          path.isNotEmpty) {
        transport['path'] = path;
      }

      final host =
          query['host'];

      if (host != null &&
          host.isNotEmpty) {
        transport['headers'] = {
          'Host': host,
        };
      }

      outbound['transport'] =
          transport;
    }
  }

  void _applyVmessTransport(
    Map<String, dynamic> outbound,
    Map<String, dynamic> data,
    String network,
  ) {
    if (network == 'ws') {
      final transport =
          <String, dynamic>{
        'type': 'ws',
      };

      final path =
          data['path']?.toString();

      if (path != null &&
          path.isNotEmpty) {
        transport['path'] = path;
      }

      final host =
          data['host']?.toString();

      if (host != null &&
          host.isNotEmpty) {
        transport['headers'] = {
          'Host': host,
        };
      }

      outbound['transport'] =
          transport;
    } else if (network == 'grpc') {
      final service =
          data['path']?.toString() ??
              data['serviceName']?.toString() ??
              '';

      outbound['transport'] = {
        'type': 'grpc',
        if (service.isNotEmpty)
          'service_name': service,
      };
    } else if (network == 'httpupgrade') {
      outbound['transport'] = {
        'type': 'httpupgrade',
        if (data['path'] != null)
          'path':
              data['path'].toString(),
        if (data['host'] != null)
          'headers': {
            'Host':
                data['host'].toString(),
          },
      };
    }
  }

  String _displayName(
    String? value,
    String fallback,
  ) {
    if (value == null ||
        value.trim().isEmpty) {
      return fallback;
    }

    return value.trim();
  }

  Map<String, dynamic>?
      _decodeBase64Json(String value) {
    final decoded =
        _decodeBase64String(value);

    if (decoded == null) {
      return null;
    }

    try {
      final json =
          jsonDecode(decoded);

      if (json is Map<String, dynamic>) {
        return json;
      }
    } catch (_) {}

    return null;
  }

  String? _decodeBase64String(
    String value,
  ) {
    try {
      var text =
          value.replaceAll('-', '+')
              .replaceAll('_', '/');

      text += '=' *
          ((4 - text.length % 4) % 4);

      return utf8.decode(
        base64.decode(text),
        allowMalformed: true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _pingServers() async {
    if (_servers.isEmpty) return;

    final futures =
        _servers.map((server) async {
      final stopwatch =
          Stopwatch()..start();

      try {
        final socket =
            await Socket.connect(
          server.address,
          server.port,
          timeout:
              const Duration(seconds: 3),
        );

        await socket.close();

        stopwatch.stop();

        server.ping =
            stopwatch.elapsedMilliseconds;
      } catch (_) {
        server.ping = null;
      }
    });

    await Future.wait(futures);

    _servers.sort((a, b) {
      if (a.ping == null &&
          b.ping == null) {
        return 0;
      }

      if (a.ping == null) return 1;
      if (b.ping == null) return -1;

      return a.ping!.compareTo(
        b.ping!,
      );
    });

    if (mounted) {
      setState(() {
        if (_currentServer != null) {
          final match =
              _servers.where(
            (x) =>
                x.address ==
                    _currentServer!.address &&
                x.port ==
                    _currentServer!.port,
          );

          if (match.isNotEmpty) {
            _currentServer =
                match.first;
          }
        }
      });
    }
  }

  Future<void> _connect() async {
    if (!_initialized) {
      _showMessage(
        'VPN هنوز آماده نشده است.',
      );
      return;
    }

    if (_connected) {
      await _disconnect();
      return;
    }

    if (_servers.isEmpty) {
      await refreshSubscription();

      if (_servers.isEmpty) {
        return;
      }
    }

    final best =
        _servers.firstWhere(
      (server) => server.ping != null,
      orElse: () => _servers.first,
    );

    setState(() {
      _currentServer = best;
      _connecting = true;
      _status = 'در حال اتصال...';
      _error = null;
    });

    try {
      final permission =
          await _singbox.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'مجوز VPN توسط کاربر تأیید نشد.',
        );
      }

      final config =
          _buildSingboxConfig(best);

      await _singbox.checkConfig(
        config,
      );

      await _singbox.connect(
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
        _connected = true;
        _connecting = false;
        _status = 'متصل';
      });

      _showMessage(
        'اتصال VPN برقرار شد.',
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _connected = false;
        _connecting = false;
        _status = 'اتصال ناموفق';
        _error = e.toString();
      });

      _showMessage(
        'اتصال ناموفق:\n$e',
      );
    }
  }

  Future<void> _disconnect() async {
    try {
      await _singbox.disconnect();

      if (!mounted) return;

      setState(() {
        _connected = false;
        _connecting = false;
        _status = 'قطع اتصال';
        _downloadBps = 0;
        _uploadBps = 0;
      });

      _showMessage(
        'VPN قطع شد.',
      );
    } catch (e) {
      _showMessage(
        'خطا هنگام قطع اتصال: $e',
      );
    }
  }

  String _buildSingboxConfig(
    ServerConfig server,
  ) {
    final config =
        <String, dynamic>{
      'log': {
        'level': 'warn',
      },
      'dns': {
        'servers': [
          {
            'type': 'https',
            'tag': 'remote-dns',
            'server':
                '1.1.1.1',
            'server_port': 443,
            'path':
                '/dns-query',
            'detour': 'proxy',
          },
          {
            'type': 'local',
            'tag': 'local-dns',
          },
        ],
        'final':
            'remote-dns',
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
    };

    return jsonEncode(config);
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            textDirection:
                TextDirection.rtl,
          ),
          behavior:
              SnackBarBehavior.floating,
        ),
      );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return '0 B';
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

  String _formatSpeed(int bytes) {
    return '${_formatBytes(bytes)}/s';
  }

  String _formatDate(int timestamp) {
    if (timestamp <= 0) {
      return 'نامشخص';
    }

    final date =
        DateTime.fromMillisecondsSinceEpoch(
      timestamp * 1000,
    );

    return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
  }

  String _remaining(int timestamp) {
    if (timestamp <= 0) {
      return 'نامشخص';
    }

    final expire =
        DateTime.fromMillisecondsSinceEpoch(
      timestamp * 1000,
    );

    final diff =
        expire.difference(DateTime.now());

    if (diff.isNegative) {
      return 'منقضی شده';
    }

    final days = diff.inDays;
    final hours =
        diff.inHours.remainder(24);

    if (days > 0) {
      return '$days روز و $hours ساعت';
    }

    return '$hours ساعت';
  }

  Widget _glass({
    required Widget child,
    EdgeInsets padding =
        const EdgeInsets.all(16),
  }) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: panel,
        borderRadius:
            BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white
              .withValues(alpha: 0.07),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x3319E6B5),
            blurRadius: 30,
            spreadRadius: -12,
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _gradientText(
    String text,
    double size,
  ) {
    return ShaderMask(
      shaderCallback: (bounds) {
        return LinearGradient(
          colors: [
            green,
            blue,
            purple,
          ],
        ).createShader(bounds);
      },
      child: Text(
        text,
        style: TextStyle(
          fontSize: size,
          fontWeight:
              FontWeight.w900,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _speedCard(
    String title,
    String value,
    IconData icon,
  ) {
    return Expanded(
      child: _glass(
        padding:
            const EdgeInsets.all(14),
        child: Column(
          children: [
            Icon(
              icon,
              color: green,
              size: 22,
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                color: Colors.white
                    .withValues(
                  alpha: 0.55,
                ),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow:
                  TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight:
                    FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _connectButton() {
    return GestureDetector(
      onTap: _connecting
          ? null
          : _connect,
      child: Container(
        width: 220,
        height: 220,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(
            colors: [
              green,
              blue,
              purple,
              green,
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: green.withValues(
                alpha: 0.18,
              ),
              blurRadius: 55,
              spreadRadius: 8,
            ),
          ],
        ),
        padding:
            const EdgeInsets.all(7),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color:
                const Color(0xFF07101B),
            border: Border.all(
              color: Colors.white
                  .withValues(alpha: 0.05),
            ),
          ),
          child: Column(
            mainAxisAlignment:
                MainAxisAlignment.center,
            children: [
              Icon(
                _connected
                    ? Icons
                        .power_settings_new
                    : Icons.bolt,
                size: 55,
                color: _connected
                    ? green
                    : Colors.white,
              ),
              const SizedBox(height: 10),
              Text(
                _connecting
                    ? 'در حال اتصال'
                    : _connected
                        ? 'متصل'
                        : 'اتصال',
                style:
                    const TextStyle(
                  fontSize: 22,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _connected
                    ? 'VPN فعال است'
                    : 'برای اتصال لمس کنید',
                style:
                    TextStyle(
                  fontSize: 11,
                  color: Colors.white
                      .withValues(
                    alpha: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _serverSummary() {
    final server = _currentServer;

    return _glass(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration:
                BoxDecoration(
              shape: BoxShape.circle,
              color: green.withValues(
                alpha: 0.1,
              ),
            ),
            child: Icon(
              Icons.dns_rounded,
              color: green,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  'سرور فعلی',
                  style: TextStyle(
                    color: Colors.white
                        .withValues(
                      alpha: 0.5,
                    ),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  server?.name ??
                      'هیچ سروری انتخاب نشده',
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
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
          if (server?.ping != null)
            Text(
              '${server!.ping} ms',
              style:
                  TextStyle(
                color: green,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }

  Widget buildHomePage() {
    return RefreshIndicator(
      onRefresh: () =>
          refreshSubscription(),
      child: ListView(
        physics:
            const AlwaysScrollableScrollPhysics(),
        padding:
            const EdgeInsets.fromLTRB(
          18,
          18,
          18,
          30,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    _gradientText(
                      'LIGHT SPEED',
                      25,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'VPN سریع و امن',
                      style: TextStyle(
                        color: Colors.white
                            .withValues(
                          alpha: 0.45,
                        ),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 48,
                height: 48,
                decoration:
                    BoxDecoration(
                  borderRadius:
                      BorderRadius.circular(
                    16,
                  ),
                  color: const Color(
                    0xFF0D1726,
                  ),
                  border: Border.all(
                    color: green.withValues(
                      alpha: 0.25,
                    ),
                  ),
                ),
                child: Icon(
                  Icons.bolt,
                  color: green,
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          Center(
            child: _connectButton(),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              _status,
              style: TextStyle(
                color: _connected
                    ? green
                    : Colors.white
                        .withValues(
                        alpha: 0.65,
                      ),
                fontWeight:
                    FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 20),
          _serverSummary(),
          const SizedBox(height: 12),
          Row(
            children: [
              _speedCard(
                'دانلود',
                _formatSpeed(
                  _downloadBps,
                ),
                Icons
                    .arrow_downward_rounded,
              ),
              const SizedBox(width: 10),
              _speedCard(
                'آپلود',
                _formatSpeed(
                  _uploadBps,
                ),
                Icons
                    .arrow_upward_rounded,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _glass(
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.data_usage,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'حجم باقی‌مانده',
                        style:
                            TextStyle(
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ),
                    Text(
                      _subscription
                                  .total >
                              0
                          ? _formatBytes(
                              _subscription
                                  .remaining,
                            )
                          : 'نامشخص',
                      style:
                          TextStyle(
                        color: green,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius:
                      BorderRadius.circular(
                    20,
                  ),
                  child:
                      LinearProgressIndicator(
                    minHeight: 8,
                    value:
                        _subscription
                            .progress,
                    backgroundColor:
                        Colors.white
                            .withValues(
                      alpha: 0.06,
                    ),
                    valueColor:
                        AlwaysStoppedAnimation(
                      green,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'مصرف‌شده: ${_formatBytes(_subscription.used)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors
                              .white
                              .withValues(
                            alpha: 0.45,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      'کل: ${_subscription.total > 0 ? _formatBytes(_subscription.total) : 'نامشخص'}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors
                            .white
                            .withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _glass(
                  child: Column(
                    children: [
                      const Icon(
                        Icons
                            .calendar_month,
                        color:
                            Colors.white70,
                      ),
                      const SizedBox(
                        height: 8,
                      ),
                      Text(
                        'انقضا',
                        style:
                            TextStyle(
                          fontSize: 11,
                          color: Colors
                              .white
                              .withValues(
                            alpha: 0.45,
                          ),
                        ),
                      ),
                      const SizedBox(
                        height: 5,
                      ),
                      Text(
                        _formatDate(
                          _subscription
                              .expire,
                        ),
                        style:
                            const TextStyle(
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
                child: _glass(
                  child: Column(
                    children: [
                      const Icon(
                        Icons
                            .schedule_rounded,
                        color:
                            Colors.white70,
                      ),
                      const SizedBox(
                        height: 8,
                      ),
                      Text(
                        'زمان باقی‌مانده',
                        style:
                            TextStyle(
                          fontSize: 11,
                          color: Colors
                              .white
                              .withValues(
                            alpha: 0.45,
                          ),
                        ),
                      ),
                      const SizedBox(
                        height: 5,
                      ),
                      Text(
                        _remaining(
                          _subscription
                              .expire,
                        ),
                        style:
                            const TextStyle(
                          fontWeight:
                              FontWeight.bold,
                        ),
                        textAlign:
                            TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _glass(
              child: Row(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Colors.orange,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _error!,
                      style:
                          const TextStyle(
                        color:
                            Colors.orange,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget buildServersPage() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        _pageHeader(
          'سرورها',
          'انتخاب سریع‌ترین سرور',
          Icons.dns_rounded,
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Text(
                '${_servers.length} سرور',
                style:
                    TextStyle(
                  color: Colors.white
                      .withValues(
                    alpha: 0.5,
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: _loading
                  ? null
                  : () =>
                      refreshSubscription(),
              icon: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child:
                          CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(
                      Icons.refresh,
                    ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_servers.isEmpty)
          _emptyState(
            'هنوز سروری دریافت نشده',
            Icons.dns_outlined,
          ),
        ..._servers.map(
          (server) =>
              _serverTile(server),
        ),
      ],
    );
  }

  Widget _serverTile(
    ServerConfig server,
  ) {
    final selected =
        identical(
          server,
          _currentServer,
        );

    return GestureDetector(
      onTap: () {
        setState(() {
          _currentServer = server;
        });
      },
      child: Container(
        margin:
            const EdgeInsets.only(
          bottom: 10,
        ),
        padding:
            const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? green.withValues(
                  alpha: 0.08,
                )
              : panel,
          borderRadius:
              BorderRadius.circular(
            20,
          ),
          border: Border.all(
            color: selected
                ? green.withValues(
                    alpha: 0.45,
                  )
                : Colors.white
                    .withValues(
                    alpha: 0.06,
                  ),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration:
                  BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? green.withValues(
                        alpha: 0.12,
                      )
                    : Colors.white
                        .withValues(
                        alpha: 0.04,
                      ),
              ),
              child: Icon(
                selected
                    ? Icons.check
                    : Icons.public,
                color: selected
                    ? green
                    : Colors.white70,
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
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${server.type} • ${server.address}:${server.port}',
                    maxLines: 1,
                    overflow:
                        TextOverflow.ellipsis,
                    style:
                        TextStyle(
                      color: Colors.white
                          .withValues(
                        alpha: 0.4,
                      ),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _pingWidget(server),
          ],
        ),
      ),
    );
  }

  Widget _pingWidget(
    ServerConfig server,
  ) {
    if (server.ping == null) {
      return const Text(
        '--',
        style: TextStyle(
          color: Colors.white54,
        ),
      );
    }

    Color color;

    if (server.ping! < 100) {
      color = green;
    } else if (server.ping! < 200) {
      color = Colors.orange;
    } else {
      color = Colors.redAccent;
    }

    return Column(
      children: [
        Icon(
          Icons.network_check,
          size: 18,
          color: color,
        ),
        const SizedBox(height: 3),
        Text(
          '${server.ping} ms',
          style:
              TextStyle(
            color: color,
            fontSize: 11,
            fontWeight:
                FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget buildTrafficPage() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        _pageHeader(
          'ترافیک',
          'مصرف اینترنت VPN',
          Icons.bar_chart_rounded,
        ),
        const SizedBox(height: 20),
        _glass(
          padding:
              const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                'مصرف کل',
                style:
                    TextStyle(
                  color: Colors.white
                      .withValues(
                    alpha: 0.5,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _gradientText(
                _formatBytes(
                  _subscription.used,
                ),
                34,
              ),
              const SizedBox(height: 5),
              Text(
                _subscription.total > 0
                    ? 'از ${_formatBytes(_subscription.total)}'
                    : 'حجم کل نامشخص',
                style:
                    TextStyle(
                  color: Colors.white
                      .withValues(
                    alpha: 0.45,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            _trafficCard(
              'دانلود',
              _formatBytes(
                _subscription.download,
              ),
              Icons
                  .arrow_downward_rounded,
            ),
            const SizedBox(width: 10),
            _trafficCard(
              'آپلود',
              _formatBytes(
                _subscription.upload,
              ),
              Icons
                  .arrow_upward_rounded,
            ),
          ],
        ),
        const SizedBox(height: 14),
        _glass(
          child: Column(
            children: [
              _infoRow(
                'سرعت دانلود',
                _formatSpeed(
                  _downloadBps,
                ),
              ),
              const Divider(
                color: Colors.white10,
              ),
              _infoRow(
                'سرعت آپلود',
                _formatSpeed(
                  _uploadBps,
                ),
              ),
              const Divider(
                color: Colors.white10,
              ),
              _infoRow(
                'باقی‌مانده',
                _subscription.total > 0
                    ? _formatBytes(
                        _subscription
                            .remaining,
                      )
                    : 'نامشخص',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _trafficCard(
    String title,
    String value,
    IconData icon,
  ) {
    return Expanded(
      child: _glass(
        child: Column(
          children: [
            Icon(
              icon,
              color: green,
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: TextStyle(
                color: Colors.white
                    .withValues(
                  alpha: 0.5,
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              value,
              style:
                  const TextStyle(
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

  Widget buildSubscriptionPage() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        _pageHeader(
          'اشتراک',
          'مدیریت Subscription',
          Icons.link_rounded,
        ),
        const SizedBox(height: 20),
        _glass(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'لینک Subscription',
                style:
                    TextStyle(
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller:
                    _subscriptionController,
                maxLines: 3,
                decoration:
                    InputDecoration(
                  hintText:
                      'https://...',
                  filled: true,
                  fillColor:
                      Colors.black
                          .withValues(
                    alpha: 0.18,
                  ),
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
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _loading
                      ? null
                      : () =>
                          refreshSubscription(),
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child:
                              CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(
                          Icons.sync,
                        ),
                  label: Text(
                    _loading
                        ? 'در حال بروزرسانی...'
                        : 'بروزرسانی اشتراک',
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _glass(
          child: Column(
            children: [
              _infoRow(
                'حجم کل',
                _subscription.total > 0
                    ? _formatBytes(
                        _subscription.total,
                      )
                    : 'نامشخص',
              ),
              const Divider(
                color: Colors.white10,
              ),
              _infoRow(
                'مصرف',
                _formatBytes(
                  _subscription.used,
                ),
              ),
              const Divider(
                color: Colors.white10,
              ),
              _infoRow(
                'باقی‌مانده',
                _subscription.total > 0
                    ? _formatBytes(
                        _subscription
                            .remaining,
                      )
                    : 'نامشخص',
              ),
              const Divider(
                color: Colors.white10,
              ),
              _infoRow(
                'تاریخ انقضا',
                _formatDate(
                  _subscription.expire,
                ),
              ),
              const Divider(
                color: Colors.white10,
              ),
              _infoRow(
                'زمان باقی‌مانده',
                _remaining(
                  _subscription.expire,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildSettingsPage() {
    return ListView(
      padding:
          const EdgeInsets.all(18),
      children: [
        _pageHeader(
          'تنظیمات',
          'تنظیمات Light speed',
          Icons.settings_rounded,
        ),
        const SizedBox(height: 18),
        _glass(
          child: Column(
            children: [
              _settingTile(
                Icons.speed,
                'انتخاب خودکار سریع‌ترین سرور',
                'انتخاب بر اساس کمترین Ping',
                true,
              ),
              const Divider(
                color: Colors.white10,
              ),
              _settingTile(
                Icons.sync,
                'بروزرسانی خودکار',
                'هر ۱۵ دقیقه',
                true,
              ),
              const Divider(
                color: Colors.white10,
              ),
              _settingTile(
                Icons.shield_outlined,
                'حالت VPN',
                'TUN / Android VPN',
                true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _glass(
          child: Column(
            children: [
              const Icon(
                Icons.bolt,
                color: Color(0xFF19E6B5),
                size: 42,
              ),
              const SizedBox(height: 8),
              _gradientText(
                'LIGHT SPEED',
                20,
              ),
              const SizedBox(height: 5),
              Text(
                'نسخه 1.0.0',
                style:
                    TextStyle(
                  color: Colors.white
                      .withValues(
                    alpha: 0.45,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'VPN Client',
                style:
                    TextStyle(
                  color: Colors.white
                      .withValues(
                    alpha: 0.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _settingTile(
    IconData icon,
    String title,
    String subtitle,
    bool value,
  ) {
    return ListTile(
      contentPadding:
          EdgeInsets.zero,
      leading: Container(
        width: 44,
        height: 44,
        decoration:
            BoxDecoration(
          borderRadius:
              BorderRadius.circular(
            14,
          ),
          color: green.withValues(
            alpha: 0.08,
          ),
        ),
        child: Icon(
          icon,
          color: green,
        ),
      ),
      title: Text(
        title,
        style:
            const TextStyle(
          fontWeight:
              FontWeight.bold,
        ),
      ),
      subtitle: Text(
        subtitle,
        style:
            TextStyle(
          color: Colors.white
              .withValues(
            alpha: 0.4,
          ),
          fontSize: 11,
        ),
      ),
      trailing:
          Switch(
        value: value,
        onChanged: (_) {},
      ),
    );
  }

  Widget _pageHeader(
    String title,
    String subtitle,
    IconData icon,
  ) {
    return Row(
      children: [
        Container(
          width: 50,
          height: 50,
          decoration:
              BoxDecoration(
            borderRadius:
                BorderRadius.circular(
              16,
            ),
            gradient:
                LinearGradient(
              colors: [
                green.withValues(
                  alpha: 0.15,
                ),
                purple.withValues(
                  alpha: 0.15,
                ),
              ],
            ),
          ),
          child: Icon(
            icon,
            color: green,
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
                fontSize: 24,
                fontWeight:
                    FontWeight.w900,
              ),
            ),
            Text(
              subtitle,
              style:
                  TextStyle(
                color: Colors.white
                    .withValues(
                  alpha: 0.4,
                ),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ],
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
          Expanded(
            child: Text(
              title,
              style:
                  TextStyle(
                color: Colors.white
                    .withValues(
                  alpha: 0.55,
                ),
              ),
            ),
          ),
          Text(
            value,
            style:
                const TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(
    String text,
    IconData icon,
  ) {
    return Padding(
      padding:
          const EdgeInsets.only(
        top: 80,
      ),
      child: Column(
        children: [
          Icon(
            icon,
            size: 70,
            color: Colors.white24,
          ),
          const SizedBox(height: 14),
          Text(
            text,
            style:
                TextStyle(
              color: Colors.white
                  .withValues(
                alpha: 0.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomNavigation() {
    return NavigationBar(
      selectedIndex: _tab,
      backgroundColor:
          const Color(0xFF07101B),
      indicatorColor:
          green.withValues(
        alpha: 0.14,
      ),
      onDestinationSelected:
          (index) {
        setState(() {
          _tab = index;
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      buildHomePage(),
      buildServersPage(),
      buildTrafficPage(),
      buildSubscriptionPage(),
      buildSettingsPage(),
    ];

    return Directionality(
      textDirection:
          TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: IndexedStack(
            index: _tab,
            children: pages,
          ),
        ),
        bottomNavigationBar:
            _bottomNavigation(),
      ),
    );
  }
}
