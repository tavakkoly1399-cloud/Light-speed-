import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const LightSpeedApp());
}

class LightSpeedApp extends StatelessWidget {
  const LightSpeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Light speed 🔥',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
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

  int? get used {
    if (upload == null || download == null) {
      return null;
    }
    return upload! + download!;
  }

  int? get remaining {
    if (total == null || used == null) {
      return null;
    }

    final value = total! - used!;
    return value < 0 ? 0 : value;
  }
}

class ServerItem {
  final FlutterVlessURL profile;
  final String name;
  int? ping;
  bool testing;

  ServerItem({
    required this.profile,
    required this.name,
    this.ping,
    this.testing = false,
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController urlController = TextEditingController();

  late final FlutterVless flutterVless;

  List<ServerItem> servers = [];

  SubscriptionInfo? subscriptionInfo;

  VlessStatus? vpnStatus;

  bool loading = false;
  bool testingServers = false;

  String statusText = 'قطع';
  String? errorText;

  @override
  void initState() {
    super.initState();

    flutterVless = FlutterVless(
      onStatusChanged: (status) {
        if (!mounted) {
          return;
        }

        setState(() {
          vpnStatus = status;

          if (status.connectionState == VlessConnectionState.connected) {
            statusText = 'متصل';
          } else if (status.connectionState ==
              VlessConnectionState.connecting) {
            statusText = 'در حال اتصال...';
          } else if (status.connectionState ==
              VlessConnectionState.disconnecting) {
            statusText = 'در حال قطع...';
          } else {
            statusText = 'قطع';
          }
        });
      },
    );

    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await flutterVless.initializeVless(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
        providerBundleIdentifier: 'com.example.light_speed',
        groupIdentifier: 'group.com.example.light_speed',
      );

      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString('subscription_url');

      if (savedUrl != null && savedUrl.isNotEmpty) {
        urlController.text = savedUrl;
      }
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        errorText = 'خطا در راه‌اندازی VPN:\n$e';
      });
    }
  }

  @override
  void dispose() {
    urlController.dispose();
    super.dispose();
  }

  Future<void> _loadSubscription() async {
    final url = urlController.text.trim();

    if (url.isEmpty) {
      _showMessage('لینک اشتراک را وارد کنید.');
      return;
    }

    Uri? uri;

    try {
      uri = Uri.parse(url);

      if (!uri.hasScheme ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw const FormatException();
      }
    } catch (_) {
      _showMessage('لینک اشتراک معتبر نیست.');
      return;
    }

    setState(() {
      loading = true;
      errorText = null;
      servers = [];
      subscriptionInfo = null;
    });

    try {
      final response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'Light-speed',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'سرور اشتراک پاسخ نامعتبر داد: ${response.statusCode}',
        );
      }

      final info = _parseSubscriptionUserinfo(
        response.headers['subscription-userinfo'],
      );

      final body = _decodeSubscription(response.body);

      if (body.trim().isEmpty) {
        throw Exception('محتوای اشتراک خالی است.');
      }

      final profiles = FlutterVless.parseMany(body);

      if (profiles.isEmpty) {
        throw Exception(
          'هیچ سرور پشتیبانی‌شده‌ای در اشتراک پیدا نشد.',
        );
      }

      final loadedServers = <ServerItem>[];

      for (var i = 0; i < profiles.length; i++) {
        final profile = profiles[i];

        final remark = profile.remark.trim().isEmpty
            ? 'Server ${i + 1}'
            : profile.remark.trim();

        loadedServers.add(
          ServerItem(
            profile: profile,
            name: remark,
          ),
        );
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('subscription_url', url);

      if (!mounted) {
        return;
      }

      setState(() {
        subscriptionInfo = info;
        servers = loadedServers;
        loading = false;
      });

      _showMessage(
        '${loadedServers.length} سرور پیدا شد.',
      );

      await _testAllServers();
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        loading = false;
        errorText = 'خطا در دریافت اشتراک:\n$e';
      });

      _showMessage('دریافت اشتراک ناموفق بود.');
    }
  }

  SubscriptionInfo? _parseSubscriptionUserinfo(String? header) {
    if (header == null || header.trim().isEmpty) {
      return null;
    }

    int? getValue(String key) {
      final regex = RegExp(
        '$key=([0-9]+)',
        caseSensitive: false,
      );

      final match = regex.firstMatch(header);

      if (match == null) {
        return null;
      }

      return int.tryParse(match.group(1)!);
    }

    return SubscriptionInfo(
      upload: getValue('upload'),
      download: getValue('download'),
      total: getValue('total'),
      expire: getValue('expire'),
    );
  }

  String _decodeSubscription(String input) {
    var value = input.trim();

    for (var i = 0; i < 5; i++) {
      final decoded = _tryBase64Decode(value);

      if (decoded == null) {
        break;
      }

      if (decoded.trim() == value.trim()) {
        break;
      }

      value = decoded.trim();
    }

    return value;
  }

  String? _tryBase64Decode(String input) {
    var value = input.trim();

    if (value.isEmpty) {
      return null;
    }

    value = value.replaceAll('\n', '').replaceAll('\r', '');

    final missing = value.length % 4;

    if (missing != 0) {
      value += '=' * (4 - missing);
    }

    try {
      final bytes = base64Decode(value);
      final decoded = utf8.decode(bytes);

      if (!_looksLikeSubscription(decoded)) {
        return null;
      }

      return decoded;
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeSubscription(String value) {
    final lower = value.toLowerCase();

    return lower.contains('vless://') ||
        lower.contains('vmess://') ||
        lower.contains('trojan://') ||
        lower.contains('ss://') ||
        lower.contains('hysteria2://') ||
        lower.contains('hy2://') ||
        lower.contains('{') ||
        lower.contains('proxies:');
  }

  Future<void> _testAllServers() async {
    if (servers.isEmpty) {
      return;
    }

    setState(() {
      testingServers = true;

      for (final server in servers) {
        server.testing = true;
        server.ping = null;
      }
    });

    for (final server in servers) {
      try {
        final stopwatch = Stopwatch()..start();

        final delay = await flutterVless
            .getServerDelay(
              config: server.profile.getFullConfiguration(),
            )
            .timeout(const Duration(seconds: 10));

        stopwatch.stop();

        if (!mounted) {
          return;
        }

        setState(() {
          server.ping = delay > 0 ? delay : stopwatch.elapsedMilliseconds;
          server.testing = false;
        });
      } catch (_) {
        if (!mounted) {
          return;
        }

        setState(() {
          server.ping = null;
          server.testing = false;
        });
      }
    }

    if (!mounted) {
      return;
    }

    servers.sort((a, b) {
      if (a.ping == null && b.ping == null) {
        return 0;
      }

      if (a.ping == null) {
        return 1;
      }

      if (b.ping == null) {
        return -1;
      }

      return a.ping!.compareTo(b.ping!);
    });

    setState(() {
      testingServers = false;
    });
  }

  ServerItem? get bestServer {
    for (final server in servers) {
      if (server.ping != null) {
        return server;
      }
    }

    return servers.isNotEmpty ? servers.first : null;
  }

  Future<void> _connect() async {
    if (servers.isEmpty) {
      _showMessage('ابتدا اشتراک را دریافت کنید.');
      return;
    }

    if (vpnStatus?.connectionState == VlessConnectionState.connected) {
      await _disconnect();
      return;
    }

    final server = bestServer;

    if (server == null) {
      _showMessage('هیچ سروری برای اتصال وجود ندارد.');
      return;
    }

    try {
      setState(() {
        statusText = 'در حال اتصال...';
        errorText = null;
      });

      final permission = await flutterVless.requestPermission();

      if (!permission) {
        if (!mounted) {
          return;
        }

        setState(() {
          statusText = 'قطع';
          errorText = 'اجازه VPN داده نشد.';
        });

        _showMessage('برای اتصال باید اجازه VPN را تأیید کنید.');
        return;
      }

      await flutterVless.startVless(
        remark: server.name,
        config: server.profile.getFullConfiguration(),
        proxyOnly: false,
        notificationDisconnectButtonName: 'DISCONNECT',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        statusText = 'قطع';
        errorText = 'خطا در اتصال:\n$e';
      });

      _showMessage('اتصال انجام نشد.');
    }
  }

  Future<void> _disconnect() async {
    try {
      await flutterVless.stopVless();

      if (!mounted) {
        return;
      }

      setState(() {
        statusText = 'قطع';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        errorText = 'خطا در قطع اتصال:\n$e';
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            textDirection: TextDirection.rtl,
          ),
        ),
      );
  }

  String _formatBytes(int? bytes) {
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
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} GB';
    }

    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} TB';
  }

  String _formatExpire(int? expire) {
    if (expire == null || expire == 0) {
      return 'نامشخص';
    }

    final date = DateTime.fromMillisecondsSinceEpoch(
      expire * 1000,
      isUtc: true,
    ).toLocal();

    return '${date.year}/${date.month.toString().padLeft(2, '0')}/'
        '${date.day.toString().padLeft(2, '0')}';
  }

  String _remainingTime(int? expire) {
    if (expire == null || expire == 0) {
      return 'نامشخص';
    }

    final expiry = DateTime.fromMillisecondsSinceEpoch(
      expire * 1000,
    );

    final difference = expiry.difference(DateTime.now());

    if (difference.isNegative) {
      return 'منقضی شده';
    }

    final days = difference.inDays;
    final hours = difference.inHours % 24;

    if (days > 0) {
      return '$days روز و $hours ساعت';
    }

    final minutes = difference.inMinutes % 60;

    if (hours > 0) {
      return '$hours ساعت و $minutes دقیقه';
    }

    return '$minutes دقیقه';
  }

  String _pingText(ServerItem server) {
    if (server.testing) {
      return 'در حال تست';
    }

    if (server.ping == null) {
      return 'ناموفق';
    }

    return '${server.ping} ms';
  }

  Widget _infoCard({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    title,
                    textDirection: TextDirection.rtl,
                    style: const TextStyle(
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    textDirection: TextDirection.rtl,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
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

  Widget _buildSubscriptionInfo() {
    final info = subscriptionInfo;

    if (info == null) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _infoCard(
                title: 'حجم کل',
                value: _formatBytes(info.total),
                icon: Icons.storage,
              ),
            ),
            Expanded(
              child: _infoCard(
                title: 'مصرف شده',
                value: _formatBytes(info.used),
                icon: Icons.data_usage,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _infoCard(
                title: 'باقی‌مانده',
                value: _formatBytes(info.remaining),
                icon: Icons.download,
              ),
            ),
            Expanded(
              child: _infoCard(
                title: 'آپلود',
                value: _formatBytes(info.upload),
                icon: Icons.upload,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _infoCard(
                title: 'دانلود',
                value: _formatBytes(info.download),
                icon: Icons.download_for_offline,
              ),
            ),
            Expanded(
              child: _infoCard(
                title: 'انقضا',
                value: _formatExpire(info.expire),
                icon: Icons.event,
              ),
            ),
          ],
        ),
        _infoCard(
          title: 'زمان باقی‌مانده',
          value: _remainingTime(info.expire),
          icon: Icons.timer,
        ),
      ],
    );
  }

  Widget _buildServerList() {
    if (servers.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Center(
            child: Text(
              'هنوز سروری دریافت نشده است.',
              textDirection: TextDirection.rtl,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'سرورها (${servers.length})',
                textDirection: TextDirection.rtl,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            IconButton(
              onPressed: testingServers ? null : _testAllServers,
              icon: const Icon(Icons.speed),
              tooltip: 'تست سرورها',
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...servers.asMap().entries.map(
          (entry) {
            final index = entry.key;
            final server = entry.value;
            final isBest = identical(server, bestServer);

            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: Text('${index + 1}'),
                ),
                title: Text(
                  server.name,
                  textDirection: TextDirection.rtl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  isBest ? 'بهترین سرور' : 'سرور اشتراک',
                  textDirection: TextDirection.rtl,
                ),
                trailing: Text(
                  _pingText(server),
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isBest ? null : null,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected =
        vpnStatus?.connectionState == VlessConnectionState.connected;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Light speed 🔥'),
          centerTitle: true,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            'لینک اشتراک',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: urlController,
                          keyboardType: TextInputType.url,
                          textDirection: TextDirection.ltr,
                          decoration: const InputDecoration(
                            hintText: 'https://...',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.link),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: loading ? null : _loadSubscription,
                            icon: loading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh),
                            label: Text(
                              loading
                                  ? 'در حال دریافت...'
                                  : 'دریافت اشتراک',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        Icon(
                          connected
                              ? Icons.vpn_lock
                              : Icons.vpn_lock_outlined,
                          size: 60,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          statusText,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: _connect,
                            icon: Icon(
                              connected
                                  ? Icons.stop_circle
                                  : Icons.power_settings_new,
                            ),
                            label: Text(
                              connected ? 'قطع VPN' : 'اتصال به بهترین سرور',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        errorText!,
                        textDirection: TextDirection.rtl,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                _buildSubscriptionInfo(),
                const SizedBox(height: 12),
                _buildServerList(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
