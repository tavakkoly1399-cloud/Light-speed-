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
      title: 'Light speed',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF05070D),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
        fontFamily: 'sans',
      ),
      home: const HomePage(),
    );
  }
}

enum ServerSelectionMode {
  auto,
  manual,
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

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver {
  final TextEditingController url = TextEditingController();

  final List<Server> servers = [];

  StreamSubscription? stateSub;
  StreamSubscription? trafficSub;
  StreamSubscription? faultSub;
  StreamSubscription? networkQualitySub;
  StreamSubscription? stunSub;

  Timer? timer;

  int page = 0;

  bool loading = false;
  bool testing = false;
  bool connected = false;
  bool connecting = false;

  bool networkTestRunning = false;
  bool stunTestRunning = false;

  String stateText = 'آماده اتصال';

  String download = '0 Mbps';
  String upload = '0 Mbps';

  String testDownload = '0 Mbps';
  String testUpload = '0 Mbps';
  String testPing = '—';

  String stunLatency = '—';
  String externalIp = '—';
  String natType = '—';

  int downloadTotalBytes = 0;
  int uploadTotalBytes = 0;

  int? totalBytes;
  int? usedBytes;
  int? uploadBytes;
  int? downloadBytes;
  int? expireAt;

  double downloadCapacityBps = 0;
  double uploadCapacityBps = 0;

  int? idleLatencyMs;
  int? downloadRpm;
  int? uploadRpm;

  Server? selectedServer;

  ServerSelectionMode selectionMode =
      ServerSelectionMode.auto;

  String? lastUpdate;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _listenVpn();
    loadSaved();

    timer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => loadSubscription(silent: true),
    );
  }

  // ============================================================
  // APP LIFECYCLE
  // ============================================================

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (state == AppLifecycleState.resumed) {
      _syncVpnState();
    }
  }

  Future<void> _syncVpnState() async {
    try {
      final current = await vpn.getServiceState();

      if (!mounted) return;

      final text = current.toString().toLowerCase();

      setState(() {
        if (text.contains('started') ||
            text.contains('running') ||
            text.contains('connected')) {
          connected = true;
          connecting = false;
          stateText = 'VPN متصل است';
        } else if (text.contains('stopped') ||
            text.contains('disconnected')) {
          connected = false;
          connecting = false;
          stateText = 'VPN متوقف است';
        }
      });
    } catch (e) {
      debugPrint('getServiceState: $e');
    }
  }

  // ============================================================
  // VPN EVENTS
  // ============================================================

  void _listenVpn() {
    stateSub = vpn.serviceStateStream.listen(
      (state) {
        if (!mounted) return;

        final text = state.toString();
        final low = text.toLowerCase();

        debugPrint('VPN STATE: $text');

        setState(() {
          stateText = _prettyState(text);

          if (low.contains('started') ||
              low.contains('running') ||
              low.contains('connected')) {
            connected = true;
            connecting = false;
          }

          if (low.contains('stopped') ||
              low.contains('disconnected')) {
            connected = false;
            connecting = false;

            download = '0 Mbps';
            upload = '0 Mbps';
          }

          if (low.contains('starting')) {
            connecting = true;
          }

          if (low.contains('stopping')) {
            connecting = true;
          }
        });
      },
      onError: (Object error) {
        debugPrint(
          'VPN state stream error: $error',
        );
      },
    );

    trafficSub = vpn.trafficStatsStream.listen(
      (stats) {
        if (!mounted) return;

        try {
          setState(() {
            download =
                speed(stats.downlinkBps);
            upload =
                speed(stats.uplinkBps);

            downloadTotalBytes =
                stats.downlinkTotalBytes;

            uploadTotalBytes =
                stats.uplinkTotalBytes;
          });
        } catch (e) {
          debugPrint(
            'Traffic stats error: $e',
          );
        }
      },
      onError: (Object error) {
        debugPrint(
          'Traffic stream error: $error',
        );
      },
    );

    faultSub = vpn.faultStream.listen(
      (error) {
        if (!mounted) return;

        final message = error.toString();

        debugPrint(
          'SINGBOX FAULT: $message',
        );

        setState(() {
          stateText = 'خطای VPN';
          connected = false;
          connecting = false;
        });

        snack(
          'خطای sing-box:\n$message',
        );
      },
      onError: (Object error) {
        debugPrint(
          'Fault stream error: $error',
        );
      },
    );

    networkQualitySub =
        vpn.networkQualityProgressStream.listen(
      (progress) {
        if (!mounted) return;

        try {
          setState(() {
            networkTestRunning =
                progress.isRunning;

            downloadCapacityBps =
                progress.downloadCapacityBps
                    .toDouble();

            uploadCapacityBps =
                progress.uploadCapacityBps
                    .toDouble();

            idleLatencyMs =
                progress.idleLatencyMs;

            downloadRpm =
                progress.downloadRPM;

            uploadRpm =
                progress.uploadRPM;

            testDownload =
                speed(
              progress.downloadCapacityBps,
            );

            testUpload =
                speed(
              progress.uploadCapacityBps,
            );

            if (progress.idleLatencyMs > 0) {
              testPing =
                  '${progress.idleLatencyMs} ms';
            }
          });
        } catch (e) {
          debugPrint(
            'Network quality error: $e',
          );
        }
      },
      onError: (Object error) {
        debugPrint(
          'Network quality stream error: $error',
        );

        if (!mounted) return;

        setState(() {
          networkTestRunning = false;
        });
      },
    );

    stunSub = vpn.stunProgressStream.listen(
      (progress) {
        if (!mounted) return;

        try {
          setState(() {
            stunTestRunning =
                progress.isRunning;

            if (progress.latencyMs > 0) {
              stunLatency =
                  '${progress.latencyMs} ms';
            }

            if (progress.externalIp != null &&
                progress.externalIp
                    .toString()
                    .isNotEmpty) {
              externalIp =
                  progress.externalIp.toString();
            }

            if (progress.natType != null &&
                progress.natType
                    .toString()
                    .isNotEmpty) {
              natType =
                  progress.natType.toString();
            }
          });
        } catch (e) {
          debugPrint(
            'STUN error: $e',
          );
        }
      },
      onError: (Object error) {
        debugPrint(
          'STUN stream error: $error',
        );

        if (!mounted) return;

        setState(() {
          stunTestRunning = false;
        });
      },
    );
  }

  // ============================================================
  // SAVED DATA
  // ============================================================

  Future<void> loadSaved() async {
    try {
      final prefs =
          await SharedPreferences.getInstance();

      final saved =
          prefs.getString(
        'subscription_url',
      );

      final savedMode =
          prefs.getString(
        'selection_mode',
      );

      final savedServer =
          prefs.getString(
        'selected_server_raw',
      );

      final savedLastUpdate =
          prefs.getString(
        'last_update',
      );

      if (savedMode == 'manual') {
        selectionMode =
            ServerSelectionMode.manual;
      } else {
        selectionMode =
            ServerSelectionMode.auto;
      }

      lastUpdate = savedLastUpdate;

      if (saved != null &&
          saved.isNotEmpty) {
        url.text = saved;

        await loadSubscription(
          silent: true,
          restoreSelectedRaw: savedServer,
        );
      }

      await _syncVpnState();
    } catch (e) {
      debugPrint(
        'loadSaved: $e',
      );
    }
  }

  Future<void> saveSelectionMode() async {
    final prefs =
        await SharedPreferences.getInstance();

    await prefs.setString(
      'selection_mode',
      selectionMode ==
              ServerSelectionMode.manual
          ? 'manual'
          : 'auto',
    );
  }

  Future<void> saveSelectedServer() async {
    final prefs =
        await SharedPreferences.getInstance();

    if (selectedServer == null) {
      await prefs.remove(
        'selected_server_raw',
      );
      return;
    }

    await prefs.setString(
      'selected_server_raw',
      selectedServer!.raw,
    );
  }

  // ============================================================
  // SUBSCRIPTION
  // ============================================================

  Future<void> addSubscription() async {
    final controller =
        TextEditingController(
      text: url.text,
    );

    final result =
        await showDialog<String>(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection:
              TextDirection.rtl,
          child: AlertDialog(
            backgroundColor:
                const Color(0xFF101522),
            title: const Text(
              'افزودن Subscription',
            ),
            content: TextField(
              controller: controller,
              autofocus: true,
              textDirection:
                  TextDirection.ltr,
              keyboardType:
                  TextInputType.url,
              decoration:
                  const InputDecoration(
                hintText:
                    'https://example.com/sub...',
                border:
                    OutlineInputBorder(),
                prefixIcon:
                    Icon(Icons.link),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(
                    context,
                  );
                },
                child: const Text(
                  'لغو',
                ),
              ),
              FilledButton(
                onPressed: () {
                  final value =
                      controller.text.trim();

                  if (value.isEmpty) {
                    return;
                  }

                  Navigator.pop(
                    context,
                    value,
                  );
                },
                child: const Text(
                  'افزودن',
                ),
              ),
            ],
          ),
        );
      },
    );

    controller.dispose();

    if (result == null ||
        result.trim().isEmpty) {
      return;
    }

    url.text = result.trim();

    await loadSubscription();
  }

  Future<void> loadSubscription({
    bool silent = false,
    String? restoreSelectedRaw,
  }) async {
    final subscription =
        url.text.trim();

    if (subscription.isEmpty) {
      if (!silent && mounted) {
        snack(
          'ابتدا Subscription را اضافه کن',
        );
      }
      return;
    }

    Uri uri;

    try {
      uri = Uri.parse(
        subscription,
      );

      if (!uri.hasScheme ||
          uri.host.isEmpty) {
        throw Exception(
          'آدرس Subscription معتبر نیست',
        );
      }
    } catch (e) {
      if (!silent && mounted) {
        snack(
          'آدرس Subscription نامعتبر است',
        );
      }
      return;
    }

    if (mounted) {
      setState(() {
        loading = true;

        if (!silent) {
          stateText =
              'در حال دریافت سرورها...';
        }
      });
    }

    try {
      final response = await http
          .get(
            uri,
            headers: const {
              'User-Agent':
                  'LightSpeed/6.0',
              'Accept': '*/*',
              'Cache-Control':
                  'no-cache',
              'Pragma': 'no-cache',
            },
          )
          .timeout(
            const Duration(
              seconds: 60,
            ),
          );

      debugPrint(
        'SUB HTTP: ${response.statusCode}',
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

      final lines =
          decodeSubscription(body);

      final result = <Server>[];

      for (final line in lines) {
        final server =
            parseServer(line);

        if (server != null) {
          result.add(server);
        }
      }

      if (result.isEmpty) {
        throw Exception(
          'هیچ کانفیگ معتبری پیدا نشد',
        );
      }

      final prefs =
          await SharedPreferences
              .getInstance();

      await prefs.setString(
        'subscription_url',
        subscription,
      );

      final updateTime =
          DateTime.now()
              .toLocal()
              .toIso8601String();

      await prefs.setString(
        'last_update',
        updateTime,
      );

      Server? restored;

      final rawToRestore =
          restoreSelectedRaw ??
              prefs.getString(
                'selected_server_raw',
              );

      if (rawToRestore != null) {
        for (final server in result) {
          if (server.raw ==
              rawToRestore) {
            restored = server;
            break;
          }
        }
      }

      if (!mounted) return;

      setState(() {
        servers
          ..clear()
          ..addAll(result);

        selectedServer = restored;

        lastUpdate =
            updateTime;

        loading = false;

        stateText =
            '${servers.length} سرور دریافت شد';
      });

      await saveSelectedServer();

      if (!silent) {
        snack(
          '${servers.length} سرور دریافت شد',
        );
      }

      if (selectionMode ==
              ServerSelectionMode.auto &&
          !silent) {
        await testAll(
          silent: true,
        );

        final best =
            fastest();

        if (mounted &&
            best != null) {
          setState(() {
            selectedServer =
                best;
          });

          await saveSelectedServer();
        }
      }
    } catch (e) {
      debugPrint(
        'SUB ERROR: $e',
      );

      if (!mounted) return;

      setState(() {
        loading = false;
        stateText =
            'خطا در دریافت Subscription';
      });

      if (!silent) {
        snack(
          'دریافت Subscription ناموفق بود:\n$e',
        );
      }
    }
  }

  String? responseHeader(
    Map<String, String> headers,
    String wanted,
  ) {
    final target =
        wanted.toLowerCase();

    for (final entry
        in headers.entries) {
      if (entry.key.toLowerCase() ==
          target) {
        return entry.value;
      }
    }

    return null;
  }

  // ============================================================
  // USER INFO
  // ============================================================

  void _readUserInfo(String? raw) {
    if (raw == null ||
        raw.trim().isEmpty) {
      return;
    }

    final values = <String, int>{};

    for (final item
        in raw.split(';')) {
      final index =
          item.indexOf('=');

      if (index <= 0) continue;

      final key = item
          .substring(0, index)
          .trim()
          .toLowerCase();

      final value =
          int.tryParse(
        item
            .substring(index + 1)
            .trim(),
      );

      if (value == null) continue;

      if (key == 'upload') {
        values['upload'] = value;
      }

      if (key == 'download') {
        values['download'] =
            value;
      }

      if (key == 'total' ||
          key == 'transfer_enable') {
        values['total'] =
            value;
      }

      if (key == 'expire' ||
          key == 'expired_at') {
        values['expire'] =
            value;
      }
    }

    if (!mounted) return;

    setState(() {
      if (values.containsKey('total')) {
        totalBytes =
            values['total'];
      }

      if (values.containsKey('upload')) {
        uploadBytes =
            values['upload'];
      }

      if (values.containsKey('download')) {
        downloadBytes =
            values['download'];
      }

      if (values.containsKey('upload') ||
          values.containsKey('download')) {
        usedBytes =
            (uploadBytes ?? 0) +
                (downloadBytes ?? 0);
      }

      if (values.containsKey('expire')) {
        expireAt =
            values['expire'];
      }
    });
  }

  // ============================================================
  // SUB DECODER
  // ============================================================

  List<String> decodeSubscription(
    String body,
  ) {
    final direct = body
        .split(
          RegExp(r'\r?\n'),
        )
        .map(
          (e) => e.trim(),
        )
        .where(
          (e) =>
              e.isNotEmpty &&
              e.contains('://'),
        )
        .toList();

    if (direct.isNotEmpty) {
      return direct;
    }

    try {
      var encoded =
          body.trim();

      encoded = encoded
          .replaceAll(
            RegExp(r'\s+'),
            '',
          )
          .replaceAll(
            '-',
            '+',
          )
          .replaceAll(
            '_',
            '/',
          );

      encoded +=
          '=' *
              ((4 -
                      encoded.length %
                          4) %
                  4);

      final decoded =
          utf8.decode(
        base64.decode(
          encoded,
        ),
        allowMalformed: true,
      );

      return decoded
          .split(
            RegExp(r'\r?\n'),
          )
          .map(
            (e) => e.trim(),
          )
          .where(
            (e) =>
                e.isNotEmpty &&
                e.contains('://'),
          )
          .toList();
    } catch (e) {
      debugPrint(
        'Subscription decode error: $e',
      );

      return [];
    }
  }

  // ============================================================
  // SERVER PARSER
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

      if (![
        'vless',
        'trojan',
        'ss',
        'shadowsocks',
        'hysteria2',
        'hy2',
        'tuic',
      ].contains(scheme)) {
        return null;
      }

      if (uri.host.isEmpty ||
          !uri.hasPort) {
        return null;
      }

      final name =
          Uri.decodeComponent(
        uri.fragment.isEmpty
            ? '${scheme.toUpperCase()} ${uri.host}'
            : uri.fragment,
      );

      late Map<String, dynamic>
          outbound;

      switch (scheme) {
        case 'vless':
          outbound =
              vless(uri);
          break;

        case 'trojan':
          outbound =
              trojan(uri);
          break;

        case 'ss':
        case 'shadowsocks':
          outbound =
              shadowsocks(
                    uri,
                    raw,
                  ) ??
                  {};
          break;

        case 'hysteria2':
        case 'hy2':
          outbound =
              hysteria2(uri);
          break;

        case 'tuic':
          outbound =
              tuic(uri);
          break;

        default:
          return null;
      }

      if (outbound.isEmpty) {
        return null;
      }

      return Server(
        raw: raw,
        name: name,
        type:
            scheme.toUpperCase(),
        host: uri.host,
        port: uri.port,
        outbound: outbound,
      );
    } catch (e) {
      debugPrint(
        'parseServer: $e',
      );

      return null;
    }
  }

  // ============================================================
  // VMESS
  // ============================================================

  Server? parseVmess(
    String raw,
  ) {
    try {
      var encoded =
          raw.substring(
        raw.indexOf('://') + 3,
      );

      encoded = encoded
          .replaceAll(
            '-',
            '+',
          )
          .replaceAll(
            '_',
            '/',
          );

      encoded +=
          '=' *
              ((4 -
                      encoded.length %
                          4) %
                  4);

      final decoded =
          utf8.decode(
        base64.decode(
          encoded,
        ),
        allowMalformed: true,
      );

      final map =
          json.decode(
                decoded,
              )
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
          '${map['tls'] ?? ''}'
              .toLowerCase();

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
    } catch (e) {
      debugPrint(
        'VMess parse error: $e',
      );

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
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'uuid': uri.userInfo,
    };

    final flow =
        p['flow'] ?? '';

    if (flow.isNotEmpty) {
      outbound['flow'] =
          flow;
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

      final fp =
          p['fp'] ?? '';

      if (fp.isNotEmpty) {
        tls['utls'] = {
          'enabled': true,
          'fingerprint': fp,
        };
      }

      if (security ==
              'reality' &&
          (p['pbk'] ?? '')
              .isNotEmpty) {
        tls['reality'] = {
          'enabled': true,
          'public_key':
              p['pbk'],
          if ((p['sid'] ?? '')
              .isNotEmpty)
            'short_id':
                p['sid'],
        };
      }

      outbound['tls'] =
          tls;
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
  // TROJAN
  // ============================================================

  Map<String, dynamic> trojan(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': uri.host,
      'server_port': uri.port,
      'password':
          uri.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            p['sni'] ??
                p['host'] ??
                uri.host,
      },
    };

    if (p['allowInsecure'] ==
            '1' ||
        p['allow_insecure'] ==
            '1' ||
        p['insecure'] == '1') {
      (outbound['tls']
              as Map<String, dynamic>)[
          'insecure'] = true;
    }

    addTransport(
      outbound,
      p['type'] ?? 'tcp',
      p['path'] ?? '',
      p['host'] ?? '',
    );

    return outbound;
  }

  // ============================================================
  // SHADOWSOCKS
  // ============================================================

  Map<String, dynamic>?
      shadowsocks(
    Uri uri,
    String raw,
  ) {
    try {
      var user =
          uri.userInfo;

      if (user.isEmpty) {
        var encoded =
            raw.substring(
          raw.indexOf('://') + 3,
        ).split('#').first;

        encoded = encoded
            .replaceAll(
              '-',
              '+',
            )
            .replaceAll(
              '_',
              '/',
            );

        encoded +=
            '=' *
                ((4 -
                        encoded.length %
                            4) %
                    4);

        user = utf8.decode(
          base64.decode(
            encoded,
          ),
          allowMalformed:
              true,
        );
      }

      final separator =
          user.indexOf(':');

      if (separator <= 0) {
        return null;
      }

      return {
        'type':
            'shadowsocks',
        'tag': 'proxy',
        'server': uri.host,
        'server_port':
            uri.port,
        'method':
            Uri.decodeComponent(
          user.substring(
            0,
            separator,
          ),
        ),
        'password':
            Uri.decodeComponent(
          user.substring(
            separator + 1,
          ),
        ),
      };
    } catch (e) {
      debugPrint(
        'Shadowsocks parse error: $e',
      );

      return null;
    }
  }

  // ============================================================
  // HYSTERIA 2
  // ============================================================

  Map<String, dynamic> hysteria2(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type':
          'hysteria2',
      'tag': 'proxy',
      'server': uri.host,
      'server_port':
          uri.port,
      'password':
          uri.userInfo,
      'tls': {
        'enabled': true,
        'server_name':
            p['sni'] ??
                p['peer'] ??
                uri.host,
      },
    };

    if (p['insecure'] ==
        '1') {
      (outbound['tls']
              as Map<String, dynamic>)[
          'insecure'] = true;
    }

    return outbound;
  }

  // ============================================================
  // TUIC
  // ============================================================

  Map<String, dynamic> tuic(
    Uri uri,
  ) {
    final p =
        uri.queryParameters;

    final outbound =
        <String, dynamic>{
      'type': 'tuic',
      'tag': 'proxy',
      'server': uri.host,
      'server_port':
          uri.port,
      'uuid':
          uri.userInfo,
      'password':
          p['password'] ?? '',
      'congestion_control':
          p['congestion_control'] ??
              'cubic',
      'udp_relay_mode':
          p['udp_relay_mode'] ??
              'native',
      'zero_rtt_handshake':
          false,
      'tls': {
        'enabled': true,
        'server_name':
            p['sni'] ??
                p['peer'] ??
                uri.host,
      },
    };

    if (p['insecure'] ==
        '1') {
      (outbound['tls']
              as Map<String, dynamic>)[
          'insecure'] = true;
    }

    return outbound;
  }

  // ============================================================
  // TRANSPORT
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
        'path': path.isEmpty
            ? '/'
            : path,
        if (host.isNotEmpty)
          'headers': {
            'Host': host,
          },
      };

      return;
    }

    if (n == 'grpc') {
      outbound['transport'] = {
        'type': 'grpc',
        'service_name':
            path,
      };

      return;
    }

    if (n ==
        'httpupgrade') {
      outbound['transport'] = {
        'type':
            'httpupgrade',
        'path': path.isEmpty
            ? '/'
            : path,
        if (host.isNotEmpty)
          'host': host,
      };

      return;
    }

    if (n == 'h2' ||
        n == 'http') {
      outbound['transport'] = {
        'type': 'http',
        'path': path.isEmpty
            ? '/'
            : path,
        if (host.isNotEmpty)
          'host': [host],
      };
    }
  }

  // ============================================================
  // SING-BOX CONFIG
  // ============================================================

  String makeConfig(
    Server server,
  ) {
    final proxy =
        Map<String, dynamic>.from(
      server.outbound,
    );

    proxy['tag'] =
        'proxy';

    final config =
        <String, dynamic>{
      'log': {
        'level': 'info',
      },
      'dns': {
        'servers': [
          {
            'type': 'https',
            'tag':
                'dns-remote',
            'server':
                '1.1.1.1',
            'server_port':
                443,
            'path':
                '/dns-query',
            'tls': {
              'enabled': true,
              'server_name':
                  'cloudflare-dns.com',
            },
          },
          {
            'type': 'local',
            'tag':
                'dns-local',
          },
        ],
        'final':
            'dns-remote',
        'strategy':
            'ipv4_only',
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': [
            '172.19.0.1/30',
          ],
          'mtu': 1400,
          'auto_route':
              true,
          'stack':
              'system',
        },
      ],
      'outbounds': [
        proxy,
        {
          'type':
              'direct',
          'tag':
              'direct',
        },
        {
          'type':
              'block',
          'tag':
              'block',
        },
      ],
      'route': {
        'rules': [
          {
            'protocol': 'dns',
            'action':
                'hijack-dns',
          },
          {
            'port': 53,
            'action':
                'hijack-dns',
          },
          {
            'ip_is_private':
                true,
            'outbound':
                'direct',
          },
        ],
        'final':
            'proxy',
      },
    };

    return jsonEncode(
      config,
    );
  }

  // ============================================================
  // PING ALL
  // ============================================================

  Future<void> testAll({
    bool silent = false,
  }) async {
    if (servers.isEmpty) {
      return;
    }

    if (testing) {
      return;
    }

    if (mounted) {
      setState(() {
        testing = true;

        if (!silent) {
          stateText =
              'در حال تست سرورها...';
        }
      });
    }

    await Future.wait(
      servers.map(
        (server) async {
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

            server.ping =
                stopwatch
                    .elapsedMilliseconds;
          } catch (_) {
            server.ping = null;
          }
        },
      ),
    );

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
  // FASTEST
  // ============================================================

  Server? fastest() {
    final good =
        servers.where(
      (s) => s.ping != null,
    ).toList();

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

  // ============================================================
  // MANUAL SERVER
  // ============================================================

  Future<void> selectManualServer(
    Server server,
  ) async {
    if (connected ||
        connecting) {
      snack(
        'ابتدا VPN را قطع کن',
      );
      return;
    }

    setState(() {
      selectionMode =
          ServerSelectionMode.manual;

      selectedServer =
          server;

      stateText =
          'سرور انتخاب شد: ${server.name}';
    });

    await saveSelectionMode();
    await saveSelectedServer();

    snack(
      'سرور ${server.name} انتخاب شد',
    );
  }

  Future<void> selectAutoMode() async {
    if (connected ||
        connecting) {
      snack(
        'ابتدا VPN را قطع کن',
      );
      return;
    }

    setState(() {
      selectionMode =
          ServerSelectionMode.auto;

      stateText =
          'در حال پیدا کردن سریع‌ترین سرور...';
    });

    await saveSelectionMode();

    if (servers.isEmpty) {
      return;
    }

    await testAll(
      silent: true,
    );

    final best =
        fastest();

    if (mounted) {
      setState(() {
        selectedServer =
            best;
        stateText = best == null
            ? 'سرور قابل دسترس پیدا نشد'
            : 'سریع‌ترین سرور: ${best.name}';
      });
    }

    await saveSelectedServer();

    if (best != null) {
      snack(
        'سریع‌ترین سرور: ${best.name} • ${best.ping} ms',
      );
    }
  }

  // ============================================================
  // CONNECT
  // ============================================================

  Future<void> connect() async {
    if (servers.isEmpty) {
      snack(
        'ابتدا Subscription را اضافه کن',
      );
      return;
    }

    if (connected ||
        connecting) {
      return;
    }

    setState(() {
      connecting = true;
      stateText =
          'در حال آماده‌سازی VPN...';
    });

    try {
      Server? selected;

      if (selectionMode ==
              ServerSelectionMode.manual &&
          selectedServer != null) {
        selected =
            selectedServer;
      } else {
        setState(() {
          stateText =
              'در حال تست سریع‌ترین سرور...';
        });

        await testAll(
          silent: true,
        );

        selected =
            fastest();

        selected ??=
            servers.first;

        if (mounted) {
          setState(() {
            selectedServer =
                selected;
          });
        }

        await saveSelectedServer();
      }

      if (selected == null) {
        throw Exception(
          'سروری برای اتصال وجود ندارد',
        );
      }

      debugPrint(
        'SELECTED SERVER: '
        '${selected.name} '
        '${selected.type} '
        '${selected.host}:${selected.port}',
      );

      if (mounted) {
        setState(() {
          stateText =
              'سرور: ${selected!.name}';
        });
      }

      final permission =
          await vpn.requestVPNPermission();

      if (!permission) {
        throw Exception(
          'مجوز VPN داده نشد',
        );
      }

      final config =
          makeConfig(selected);

      if (mounted) {
        setState(() {
          stateText =
              'در حال بررسی کانفیگ...';
        });
      }

      await vpn.checkConfig(
        config,
      );

      if (mounted) {
        setState(() {
          stateText =
              'در حال اتصال به سرور...';
        });
      }

      await vpn.connect(
        SessionOptions(
          config: config,
          networkMode:
              NetworkMode.vpn,
          notification:
              NotificationConfig(
            title:
                'Light speed',
            showTrafficStats:
                true,
            showStopButton:
                true,
            stopButtonLabel:
                'قطع اتصال',
          ),
        ),
      );

      if (!mounted) {
        return;
      }

      /*
       * connect() موفق شده است.
       * وضعیت نهایی توسط serviceStateStream
       * نیز بررسی می‌شود.
       */
      setState(() {
        connected = true;
        connecting = false;
        stateText =
            'متصل • ${selected!.name}';
      });

      snack(
        'VPN با موفقیت متصل شد',
      );
    } catch (e, stack) {
      debugPrint(
        'CONNECT ERROR: $e',
      );

      debugPrint(
        'CONNECT STACK:\n$stack',
      );

      try {
        await vpn.disconnect();
      } catch (_) {}

      if (!mounted) return;

      setState(() {
        connected = false;
        connecting = false;
        stateText =
            'اتصال ناموفق';
      });

      snack(
        'خطای VPN:\n$e',
      );
    }
  }

  // ============================================================
  // DISCONNECT
  // ============================================================

  Future<void> disconnect() async {
    if (connecting) {
      return;
    }

    try {
      await vpn.disconnect();
    } catch (e) {
      debugPrint(
        'Disconnect error: $e',
      );
    }

    if (!mounted) return;

    setState(() {
      connected = false;
      connecting = false;

      stateText =
          'اتصال قطع شد';

      download =
          '0 Mbps';
      upload =
          '0 Mbps';

      downloadTotalBytes =
          0;
      uploadTotalBytes =
          0;
    });
  }

  // ============================================================
  // REAL NETWORK SPEED TEST
  // ============================================================

  Future<void> startSpeedTest() async {
    if (networkTestRunning) {
      return;
    }

    try {
      setState(() {
        networkTestRunning =
            true;
        testDownload =
            'در حال تست...';
        testUpload =
            'در حال تست...';
        testPing =
            'در حال تست...';
      });

      await vpn.startNetworkQualityTest();
    } catch (e) {
      debugPrint(
        'Speed test error: $e',
      );

      if (!mounted) return;

      setState(() {
        networkTestRunning =
            false;
      });

      snack(
        'تست سرعت ناموفق بود:\n$e',
      );
    }
  }

  Future<void> stopSpeedTest() async {
    try {
      await vpn.stopNetworkQualityTest();
    } catch (e) {
      debugPrint(
        'Stop speed test: $e',
      );
    }

    if (!mounted) return;

    setState(() {
      networkTestRunning =
          false;
    });
  }

  // ============================================================
  // STUN TEST
  // ============================================================

  Future<void> startStunTest() async {
    if (stunTestRunning) {
      return;
    }

    try {
      setState(() {
        stunTestRunning =
            true;
        stunLatency =
            'در حال تست...';
        externalIp =
            'در حال تست...';
        natType =
            'در حال تست...';
      });

      await vpn.startStunTest();
    } catch (e) {
      debugPrint(
        'STUN test error: $e',
      );

      if (!mounted) return;

      setState(() {
        stunTestRunning =
            false;
      });

      snack(
        'تست STUN ناموفق بود:\n$e',
      );
    }
  }

  Future<void> stopStunTest() async {
    try {
      await vpn.stopStunTest();
    } catch (e) {
      debugPrint(
        'Stop STUN: $e',
      );
    }

    if (!mounted) return;

    setState(() {
      stunTestRunning =
          false;
    });
  }

  // ============================================================
  // SPEED FORMAT
  // ============================================================

  String speed(dynamic bps) {
    final value =
        bps is num
            ? bps.toDouble()
            : 0.0;

    if (value <= 0) {
      return '0 Mbps';
    }

    if (value >= 1000000000) {
      return
          '${(value / 1000000000).toStringAsFixed(2)} Gbps';
    }

    if (value >= 1000000) {
      return
          '${(value / 1000000).toStringAsFixed(2)} Mbps';
    }

    if (value >= 1000) {
      return
          '${(value / 1000).toStringAsFixed(1)} Kbps';
    }

    return
        '${value.toStringAsFixed(0)} bps';
  }

  // ============================================================
  // SIZE
  // ============================================================

  String size(int? bytes) {
    if (bytes == null) {
      return 'نامشخص';
    }

    if (bytes == 0) {
      return '0 B';
    }

    if (bytes < 1024 * 1024) {
      return
          '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    if (bytes <
        1024 *
            1024 *
            1024) {
      return
          '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    return
        '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  // ============================================================
  // DATE
  // ============================================================

  String _dateFromUnix(
    int timestamp,
  ) {
    try {
      final milliseconds =
          timestamp >
                  20000000000
              ? timestamp
              : timestamp * 1000;

      final date =
          DateTime
              .fromMillisecondsSinceEpoch(
        milliseconds,
      );

      return
          '${date.year}/'
          '${date.month.toString().padLeft(2, '0')}/'
          '${date.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return 'نامشخص';
    }
  }

  // ============================================================
  // STATE
  // ============================================================

  String _prettyState(
    String value,
  ) {
    final low =
        value.toLowerCase();

    if (low.contains('started') ||
        low.contains('running') ||
        low.contains('connected')) {
      return 'VPN متصل است';
    }

    if (low.contains(
        'starting')) {
      return 'در حال اتصال...';
    }

    if (low.contains(
        'stopping')) {
      return 'در حال قطع اتصال...';
    }

    if (low.contains(
          'stopped',
        ) ||
        low.contains(
          'disconnected',
        )) {
      return 'VPN متوقف است';
    }

    return value;
  }

  // ============================================================
  // SNACK
  // ============================================================

  void snack(
    String text,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(text),
        duration:
            const Duration(
          seconds: 4,
        ),
        behavior:
            SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(
            16,
          ),
        ),
      ),
    );
  }

  // ============================================================
  // GRADIENT
  // ============================================================

  LinearGradient get mainGradient {
    return const LinearGradient(
      begin:
          Alignment.topLeft,
      end:
          Alignment.bottomRight,
      colors: [
        Color(0xFF00E5FF),
        Color(0xFF7C4DFF),
      ],
    );
  }

  // ============================================================
  // CARD
  // ============================================================

  Widget card(
    Widget child, {
    EdgeInsetsGeometry? padding,
  }) {
    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 12,
      ),
      padding:
          padding ??
              const EdgeInsets.all(
                16,
              ),
      decoration:
          BoxDecoration(
        color:
            const Color(
          0xFF0D121D,
        ),
        borderRadius:
            BorderRadius.circular(
          22,
        ),
        border:
            Border.all(
          color:
              Colors.white.withValues(
            alpha: .06,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color:
                Colors.black.withValues(
              alpha: .18,
            ),
            blurRadius: 18,
            offset:
                const Offset(
              0,
              8,
            ),
          ),
        ],
      ),
      child: child,
    );
  }

  // ============================================================
  // HEADER
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
            width: 48,
            height: 48,
            decoration:
                BoxDecoration(
              shape:
                  BoxShape.circle,
              gradient:
                  mainGradient,
              boxShadow: [
                BoxShadow(
                  color:
                      const Color(
                    0xFF7C4DFF,
                  ).withValues(
                    alpha: .3,
                  ),
                  blurRadius: 18,
                ),
              ],
            ),
            child:
                const Icon(
              Icons.bolt,
              color:
                  Colors.white,
              size: 27,
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
                  fontSize: 23,
                  fontWeight:
                      FontWeight.w900,
                ),
              ),
              const SizedBox(
                height: 2,
              ),
              Text(
                subtitle,
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ============================================================
  // BUILD
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
          height: 72,
          selectedIndex: page,
          backgroundColor:
              const Color(
            0xFF090D15,
          ),
          indicatorColor:
              const Color(
            0xFF34216B,
          ),
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
                  Icon(
                Icons.home,
              ),
              label: 'خانه',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.dns_outlined,
              ),
              selectedIcon:
                  Icon(
                Icons.dns,
              ),
              label: 'سرورها',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.bar_chart_outlined,
              ),
              selectedIcon:
                  Icon(
                Icons.bar_chart,
              ),
              label: 'ترافیک',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.link_outlined,
              ),
              selectedIcon:
                  Icon(
                Icons.link,
              ),
              label: 'اشتراک',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.settings_outlined,
              ),
              selectedIcon:
                  Icon(
                Icons.settings,
              ),
              label: 'تنظیمات',
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // HOME
  // ============================================================

  Widget _home() {
    final best =
        fastest();

    final displayServer =
        selectionMode ==
                ServerSelectionMode
                    .manual
            ? selectedServer
            : selectedServer ??
                best;

    final percent =
        totalBytes == null ||
                totalBytes! <= 0
            ? 0.0
            : ((usedBytes ??
                        0) /
                    totalBytes!)
                .clamp(
                  0.0,
                  1.0,
                );

    return ListView(
      padding:
          const EdgeInsets.fromLTRB(
        18,
        18,
        18,
        24,
      ),
      children: [
        header(
          'Light speed',
          'VPN واقعی با sing-box',
        ),

        const SizedBox(
          height: 4,
        ),

        _connectionHero(),

        const SizedBox(
          height: 18,
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
              fontWeight:
                  FontWeight.w600,
            ),
          ),
        ),

        const SizedBox(
          height: 18,
        ),

        _modeSelector(),

        const SizedBox(
          height: 10,
        ),

        _selectedServerCard(
          displayServer,
        ),

        const SizedBox(
          height: 4,
        ),

        Row(
          children: [
            Expanded(
              child:
                  _statCard(
                icon:
                    Icons.download_rounded,
                title:
                    'دانلود',
                value:
                    download,
                iconColor:
                    const Color(
                  0xFF00E5FF,
                ),
              ),
            ),
            const SizedBox(
              width: 10,
            ),
            Expanded(
              child:
                  _statCard(
                icon:
                    Icons.upload_rounded,
                title:
                    'آپلود',
                value:
                    upload,
                iconColor:
                    const Color(
                  0xFF9C6CFF,
                ),
              ),
            ),
          ],
        ),

        card(
          Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration:
                        BoxDecoration(
                      borderRadius:
                          BorderRadius
                              .circular(
                        14,
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
                      Icons.data_usage,
                      color:
                          Color(
                        0xFF9C6CFF,
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 12,
                  ),
                  const Expanded(
                    child:
                        Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children: [
                        Text(
                          'حجم اشتراک',
                          style:
                              TextStyle(
                            fontWeight:
                                FontWeight
                                    .bold,
                          ),
                        ),
                        SizedBox(
                          height: 3,
                        ),
                        Text(
                          'مصرف اینترنت',
                          style:
                              TextStyle(
                            color:
                                Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    size(
                      totalBytes,
                    ),
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 14,
              ),
              ClipRRect(
                borderRadius:
                    BorderRadius.circular(
                  20,
                ),
                child:
                    LinearProgressIndicator(
                  value:
                      percent,
                  minHeight:
                      8,
                  backgroundColor:
                      Colors.white
                          .withValues(
                    alpha: .06,
                  ),
                ),
              ),
              const SizedBox(
                height: 10,
              ),
              Row(
                children: [
                  const Text(
                    'مصرف شده',
                    style:
                        TextStyle(
                      color:
                          Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    size(
                      usedBytes,
                    ),
                    style:
                        const TextStyle(
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ============================================================
  // CONNECTION HERO
  // ============================================================

  Widget _connectionHero() {
    return Center(
      child: GestureDetector(
        onTap:
            connecting
                ? null
                : connected
                    ? disconnect
                    : connect,
        child: Container(
          width: 225,
          height: 225,
          decoration:
              BoxDecoration(
            shape:
                BoxShape.circle,
            gradient:
                connected
                    ? const LinearGradient(
                        colors: [
                          Color(
                            0xFF00E676,
                          ),
                          Color(
                            0xFF00B8D4,
                          ),
                        ],
                      )
                    : mainGradient,
            boxShadow: [
              BoxShadow(
                color:
                    (connected
                            ? const Color(
                                0xFF00E676,
                              )
                            : const Color(
                                0xFF7C4DFF,
                              ))
                        .withValues(
                  alpha: .30,
                ),
                blurRadius:
                    45,
                spreadRadius:
                    8,
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: 199,
              height: 199,
              decoration:
                  const BoxDecoration(
                shape:
                    BoxShape.circle,
                color:
                    Color(
                  0xFF080C14,
                ),
              ),
              child: Center(
                child:
                    connecting
                        ? Column(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .center,
                            children: [
                              const SizedBox(
                                width:
                                    42,
                                height:
                                    42,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth:
                                      3,
                                ),
                              ),
                              const SizedBox(
                                height:
                                    14,
                              ),
                              const Text(
                                'در حال اتصال',
                                style:
                                    TextStyle(
                                  fontWeight:
                                      FontWeight
                                          .bold,
                                ),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .center,
                            children: [
                              Icon(
                                Icons
                                    .power_settings_new,
                                size:
                                    58,
                                color:
                                    connected
                                        ? const Color(
                                            0xFF00E676,
                                          )
                                        : const Color(
                                            0xFF9C6CFF,
                                          ),
                              ),
                              const SizedBox(
                                height:
                                    10,
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
                                          .w800,
                                ),
                              ),
                              const SizedBox(
                                height:
                                    4,
                              ),
                              Text(
                                connected
                                    ? 'VPN فعال است'
                                    : 'برای اتصال لمس کنید',
                                style:
                                    const TextStyle(
                                  color:
                                      Colors
                                          .white54,
                                  fontSize:
                                      11,
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

  // ============================================================
  // MODE SELECTOR
  // ============================================================

  Widget _modeSelector() {
    return card(
      Row(
        children: [
          Expanded(
            child:
                _modeButton(
              icon:
                  Icons.auto_awesome,
              title:
                  'خودکار',
              subtitle:
                  'سریع‌ترین سرور',
              active:
                  selectionMode ==
                      ServerSelectionMode
                          .auto,
              onTap:
                  selectAutoMode,
            ),
          ),
          const SizedBox(
            width: 10,
          ),
          Expanded(
            child:
                _modeButton(
              icon:
                  Icons.touch_app,
              title:
                  'دستی',
              subtitle:
                  'انتخاب سرور',
              active:
                  selectionMode ==
                      ServerSelectionMode
                          .manual,
              onTap: () {
                setState(() {
                  page = 1;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeButton({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius:
          BorderRadius.circular(
        18,
      ),
      child:
          AnimatedContainer(
        duration:
            const Duration(
          milliseconds: 200,
        ),
        padding:
            const EdgeInsets.all(
          13,
        ),
        decoration:
            BoxDecoration(
          borderRadius:
              BorderRadius.circular(
            18,
          ),
          gradient:
              active
                  ? mainGradient
                  : null,
          color:
              active
                  ? null
                  : const Color(
                      0xFF151B28,
                    ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color:
                  active
                      ? Colors.white
                      : Colors.white60,
            ),
            const SizedBox(
              width: 8,
            ),
            Expanded(
              child:
                  Column(
                crossAxisAlignment:
                    CrossAxisAlignment
                        .start,
                children: [
                  Text(
                    title,
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  Text(
                    subtitle,
                    style:
                        TextStyle(
                      color:
                          active
                              ? Colors.white70
                              : Colors.white38,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // SELECTED SERVER
  // ============================================================

  Widget _selectedServerCard(
    Server? server,
  ) {
    return card(
      InkWell(
        onTap: () {
          setState(() {
            page = 1;
          });
        },
        borderRadius:
            BorderRadius.circular(
          18,
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration:
                  BoxDecoration(
                borderRadius:
                    BorderRadius.circular(
                  15,
                ),
                gradient:
                    mainGradient,
              ),
              child:
                  const Icon(
                Icons.public,
                color:
                    Colors.white,
              ),
            ),
            const SizedBox(
              width: 12,
            ),
            Expanded(
              child:
                  Column(
                crossAxisAlignment:
                    CrossAxisAlignment
                        .start,
                children: [
                  Text(
                    selectionMode ==
                            ServerSelectionMode
                                .auto
                        ? 'سرور سریع‌ترین'
                        : 'سرور انتخاب‌شده',
                    style:
                        const TextStyle(
                      color:
                          Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(
                    height: 4,
                  ),
                  Text(
                    server?.name ??
                        'هنوز سروری انتخاب نشده',
                    maxLines: 1,
                    overflow:
                        TextOverflow
                            .ellipsis,
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  if (server != null)
                    Text(
                      '${server.type} • ${server.host}',
                      maxLines: 1,
                      overflow:
                          TextOverflow
                              .ellipsis,
                      style:
                          const TextStyle(
                        color:
                            Colors.white38,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
            if (server?.ping != null)
              Column(
                children: [
                  Text(
                    '${server!.ping}',
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'ms',
                    style:
                        TextStyle(
                      color:
                          Colors.white38,
                      fontSize: 10,
                    ),
                  ),
                ],
              )
            else
              const Icon(
                Icons.chevron_left,
                color:
                    Colors.white38,
              ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // STAT CARD
  // ============================================================

  Widget _statCard({
    required IconData icon,
    required String title,
    required String value,
    required Color iconColor,
  }) {
    return card(
      Column(
        crossAxisAlignment:
            CrossAxisAlignment
                .start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color:
                    iconColor,
                size: 20,
              ),
              const SizedBox(
                width: 6,
              ),
              Text(
                title,
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(
            height: 9,
          ),
          Text(
            value,
            style:
                const TextStyle(
              fontSize: 17,
              fontWeight:
                  FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // SERVERS PAGE
  // ============================================================

  Widget _servers() {
    return ListView(
      padding:
          const EdgeInsets.fromLTRB(
        18,
        18,
        18,
        
