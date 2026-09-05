import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vless/flutter_vless.dart';
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
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF070812),
        cardTheme: CardThemeData(
          color: const Color(0xFF111322),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
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
    if (total <= 0) return 0;
    final value = total - used;
    return value < 0 ? 0 : value;
  }

  double get progress {
    if (total <= 0) return 0;
    return (used / total).clamp(0.0, 1.0);
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

  VlessStatus vpnStatus = VlessStatus();

  List<ServerItem> servers = [];

  SubscriptionInfo subscription = const SubscriptionInfo();

  Timer? timer;

  bool loading = false;
  bool testing = false;
  bool initialized = false;

  String message = 'آدرس اشتراک را وارد کنید';

  String? selectedServerName;

  DateTime? expireDate;

  @override
  void initState() {
    super.initState();

    flutterVless = FlutterVless(
      onStatusChanged: (status) {
        if (!mounted) return;

        setState(() {
          vpnStatus = status;
        });
      },
    );

    _initialize();

    timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) {
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  Future<void> _initialize() async {
    try {
      await flutterVless.initializeVless(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
        providerBundleIdentifier: 'com.light.speed',
        groupIdentifier: 'group.com.light.speed',
      );

      initialized = true;

      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('subscription_url');

      if (saved != null && saved.isNotEmpty) {
        urlController.text = saved;
      }

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      message = 'خطا در آماده‌سازی VPN: $e';

      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    urlController.dispose();
    super.dispose();
  }

  bool get isConnected {
    return vpnStatus.connectionState == VlessConnectionState.connected;
  }

  bool get isConnecting {
    return vpnStatus.connectionState == VlessConnectionState.connecting ||
        vpnStatus.connectionState == VlessConnectionState.disconnecting;
  }

  Future<void> loadSubscription() async {
    final url = urlController.text.trim();

    if (url.isEmpty) {
      _showMessage('ابتدا لینک Subscription را وارد کنید');
      return;
    }

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      _showMessage('لینک باید با http:// یا https:// شروع شود');
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();

    setState(() {
      loading = true;
      message = 'در حال دریافت Subscription...';
      servers = [];
      selectedServerName = null;
    });

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: const {
          'User-Agent': 'LightSpeed/1.0',
          'Accept': '*/*',
          'Cache-Control': 'no-cache',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'HTTP ${response.statusCode}',
        );
      }

      final info = _parseSubscriptionInfo(response.headers, response.body);

      final decoded = _decodeSubscription(response.body);

      final parsed = FlutterVless.parseMany(decoded);

      final List<ServerItem> result = [];

      for (var i = 0; i < parsed.length; i++) {
        final profile = parsed[i];

        final name = profile.remark.trim().isEmpty
            ? 'Server ${i + 1}'
            : profile.remark.trim();

        result.add(
          ServerItem(
            profile: profile,
            name: name,
          ),
        );
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'subscription_url',
        url,
      );

      final expire = info.expire > 0
          ? DateTime.fromMillisecondsSinceEpoch(
              info.expire * 1000,
            )
          : null;

      if (!mounted) return;

      setState(() {
        subscription = info;
        expireDate = expire;
        servers = result;
        loading = false;
        message = result.isEmpty
            ? 'هیچ کانفیگ قابل پشتیبانی پیدا نشد'
            : '${result.length} سرور دریافت شد';
      });

      if (result.isNotEmpty) {
        await testAllServers();
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        message = 'خطا در دریافت Subscription';
      });

      _showMessage(
        'دریافت اشتراک ناموفق بود:\n$e',
      );
    }
  }

  SubscriptionInfo _parseSubscriptionInfo(
    Map<String, String> headers,
    String body,
  ) {
    String? value;

    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'subscription-userinfo') {
        value = entry.value;
        break;
      }
    }

    value ??= _findUserInfo(body);

    if (value == null || value.isEmpty) {
      return const SubscriptionInfo();
    }

    int readNumber(String key) {
      final match = RegExp(
        '$key\\s*=\\s*(\\d+)',
        caseSensitive: false,
      ).firstMatch(value!);

      return int.tryParse(match?.group(1) ?? '') ?? 0;
    }

    return SubscriptionInfo(
      upload: readNumber('upload'),
      download: readNumber('download'),
      total: readNumber('total'),
      expire: readNumber('expire'),
    );
  }

  String? _findUserInfo(String text) {
    final match = RegExp(
      r'(?:subscription-userinfo|upload)\s*[:=][^\r\n]+',
      caseSensitive: false,
    ).firstMatch(text);

    return match?.group(0);
  }

  String _decodeSubscription(String source) {
    var current = source.trim();

    for (var i = 0; i < 8; i++) {
      final decoded = _tryBase64(current);

      if (decoded == null) {
        break;
      }

      final clean = decoded.trim();

      if (clean.isEmpty || clean == current) {
        break;
      }

      if (_containsKnownConfig(clean)) {
        return clean;
      }

      current = clean;
    }

    return current;
  }

  String? _tryBase64(String input) {
    try {
      var value = input
          .replaceAll(RegExp(r'\s+'), '')
          .replaceAll('-', '+')
          .replaceAll('_', '/');

      while (value.length % 4 != 0) {
        value += '=';
      }

      final bytes = base64Decode(value);
      return utf8.decode(
        bytes,
        allowMalformed: true,
      );
    } catch (_) {
      return null;
    }
  }

  bool _containsKnownConfig(String value) {
    return RegExp(
      r'(vless|vmess|trojan|ss|ssr|hysteria2|hy2)://',
      caseSensitive: false,
    ).hasMatch(value);
  }

  Future<void> testAllServers() async {
    if (servers.isEmpty || testing) return;

    setState(() {
      testing = true;
      message = 'در حال تست سرعت سرورها...';
    });

    for (final server in servers) {
      if (!mounted) return;

      setState(() {
        server.testing = true;
      });

      try {
        final delay = await flutterVless.getServerDelay(
          config: server.profile.getFullConfiguration(),
        );

        server.ping = delay;
      } catch (_) {
        server.ping = null;
      }

      if (mounted) {
        setState(() {
          server.testing = false;
        });
      }
    }

    servers.sort(
      (a, b) {
        final ap = a.ping ?? 999999;
        final bp = b.ping ?? 999999;
        return ap.compareTo(bp);
      },
    );

    if (servers.isNotEmpty) {
      selectedServerName = servers.first.name;
    }

    if (mounted) {
      setState(() {
        testing = false;
        message = 'تست سرورها تمام شد';
      });
    }
  }

  ServerItem? get bestServer {
    final available = servers
        .where((server) => server.ping != null)
        .toList();

    if (available.isEmpty) {
      return servers.isEmpty ? null : servers.first;
    }

    available.sort(
      (a, b) => a.ping!.compareTo(b.ping!),
    );

    return available.first;
  }

  Future<void> connectVpn() async {
    if (!initialized) {
      _showMessage('VPN هنوز آماده نشده است');
      return;
    }

    if (servers.isEmpty) {
      _showMessage('ابتدا Subscription را دریافت کنید');
      return;
    }

    final server = bestServer;

    if (server == null) {
      _showMessage('سروری برای اتصال وجود ندارد');
      return;
    }

    try {
      setState(() {
        message = 'در حال اتصال به ${server.name}...';
        selectedServerName = server.name;
      });

      final permission = await flutterVless.requestPermission();

      if (!permission) {
        _showMessage('مجوز VPN داده نشد');
        return;
      }

      await flutterVless.startVless(
        remark: server.name,
        config: server.profile.getFullConfiguration(),
        proxyOnly: false,
        notificationDisconnectButtonName: 'قطع اتصال',
      );
    } catch (e) {
      _showMessage(
        'اتصال VPN ناموفق بود:\n$e',
      );
    }
  }

  Future<void> disconnectVpn() async {
    try {
      await flutterVless.stopVless();

      if (mounted) {
        setState(() {
          message = 'VPN قطع شد';
        });
      }
    } catch (e) {
      _showMessage(
        'خطا در قطع VPN:\n$e',
      );
    }
  }

  Future<void> connectBestServer() async {
    if (servers.isEmpty) {
      await loadSubscription();
      return;
    }

    await connectVpn();
  }

  void _showMessage(String text) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';

    const units = [
      'B',
      'KB',
      'MB',
      'GB',
      'TB',
    ];

    double value = bytes.toDouble();
    var index = 0;

    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index++;
    }

    if (value >= 100) {
      return '${value.toStringAsFixed(0)} ${units[index]}';
    }

    if (value >= 10) {
      return '${value.toStringAsFixed(1)} ${units[index]}';
    }

    return '${value.toStringAsFixed(2)} ${units[index]}';
  }

  String formatDate(DateTime? date) {
    if (date == null) return 'نامشخص';

    final y = date.year.toString();
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');

    return '$y/$m/$d';
  }

  String remainingTime() {
    if (expireDate == null) {
      return 'نامشخص';
    }

    final difference = expireDate!.difference(DateTime.now());

    if (difference.isNegative) {
      return 'منقضی شده';
    }

    final days = difference.inDays;
    final hours = difference.inHours % 24;
    final minutes = difference.inMinutes % 60;

    if (days > 0) {
      return '$days روز و $hours ساعت';
    }

    if (hours > 0) {
      return '$hours ساعت و $minutes دقیقه';
    }

    return '$minutes دقیقه';
  }

  Color pingColor(int? ping) {
    if (ping == null) return Colors.grey;

    if (ping < 100) {
      return Colors.greenAccent;
    }

    if (ping < 200) {
      return Colors.orangeAccent;
    }

    return Colors.redAccent;
  }

  String statusText() {
    switch (vpnStatus.connectionState) {
      case VlessConnectionState.connected:
        return 'متصل';
      case VlessConnectionState.connecting:
        return 'در حال اتصال';
      case VlessConnectionState.disconnecting:
        return 'در حال قطع اتصال';
      case VlessConnectionState.disconnected:
        return 'قطع';
      default:
        return 'آماده';
    }
  }

  Widget infoTile(
    String title,
    String value,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF181A2A),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: Colors.deepPurpleAccent,
            size: 25,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSubscriptionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.data_usage,
                  color: Colors.deepPurpleAccent,
                ),
                SizedBox(width: 8),
                Text(
                  'اطلاعات اشتراک',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: infoTile(
                    'حجم کل',
                    formatBytes(subscription.total),
                    Icons.storage_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: infoTile(
                    'باقی‌مانده',
                    formatBytes(subscription.remaining),
                    Icons.data_saver_on,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: infoTile(
                    'مصرف شده',
                    formatBytes(subscription.used),
                    Icons.bar_chart,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: infoTile(
                    'دانلود',
                    formatBytes(subscription.download),
                    Icons.download,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: infoTile(
                    'آپلود',
                    formatBytes(subscription.upload),
                    Icons.upload,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: infoTile(
                    'سرورها',
                    '${servers.length}',
                    Icons.dns,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: LinearProgressIndicator(
                minHeight: 9,
                value: subscription.progress,
              ),
            ),

            const SizedBox(height: 8),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'مصرف: ${formatBytes(subscription.used)}',
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                  ),
                ),
                Text(
                  'باقی: ${formatBytes(subscription.remaining)}',
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF181A2A),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('تاریخ انقضا'),
                      Text(
                        formatDate(expireDate),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('زمان باقی‌مانده'),
                      Text(
                        remainingTime(),
                        style: TextStyle(
                          color: expireDate != null &&
                                  expireDate!
                                      .difference(DateTime.now())
                                      .isNegative
                              ? Colors.redAccent
                              : Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildConnectionCard() {
    final server = bestServer;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 190,
                  height: 190,
                  child: CircularProgressIndicator(
                    value: isConnected ? null : 0,
                    strokeWidth: 8,
                    color: isConnected
                        ? Colors.greenAccent
                        : Colors.deepPurpleAccent,
                    backgroundColor:
                        Colors.white10,
                  ),
                ),
                Column(
                  children: [
                    Icon(
                      isConnected
                          ? Icons.shield
                          : Icons.power_settings_new,
                      size: 52,
                      color: isConnected
                          ? Colors.greenAccent
                          : Colors.white70,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      statusText(),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 18),

            Text(
              selectedServerName ??
                  server?.name ??
                  'هیچ سروری انتخاب نشده',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 6),

            Text(
              server?.ping != null
                  ? 'Ping: ${server!.ping} ms'
                  : 'Ping: -',
              style: TextStyle(
                color: pingColor(server?.ping),
              ),
            ),

            const SizedBox(height: 18),

            SizedBox(
              width: double.infinity,
              height: 55,
              child: FilledButton.icon(
                onPressed: isConnecting
                    ? null
                    : isConnected
                        ? disconnectVpn
                        : connectBestServer,
                icon: Icon(
                  isConnected
                      ? Icons.stop_circle
                      : Icons.flash_on,
                ),
                label: Text(
                  isConnected
                      ? 'قطع اتصال'
                      : 'اتصال به سریع‌ترین سرور',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildServerList() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment:
                  MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'سرورها',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  onPressed: testing
                      ? null
                      : testAllServers,
                  icon: const Icon(Icons.speed),
                  tooltip: 'تست سرعت',
                ),
              ],
            ),

            const SizedBox(height: 10),

            if (servers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                  child: Text(
                    'هنوز سروری دریافت نشده است',
                    style: TextStyle(
                      color: Colors.white54,
                    ),
                  ),
                ),
              ),

            ...servers.asMap().entries.map(
              (entry) {
                final index = entry.key;
                final server = entry.value;

                return Container(
                  margin: const EdgeInsets.only(
                    bottom: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF181A2A),
                    borderRadius:
                        BorderRadius.circular(15),
                    border: Border.all(
                      color: selectedServerName ==
                              server.name
                          ? Colors.deepPurpleAccent
                          : Colors.transparent,
                    ),
                  ),
                  child: ListTile(
                    onTap: () {
                      setState(() {
                        selectedServerName =
                            server.name;
                      });
                    },
                    leading: CircleAvatar(
                      backgroundColor:
                          Colors.deepPurple.withValues(
                        alpha: 0.25,
                      ),
                      child: Text(
                        '${index + 1}',
                      ),
                    ),
                    title: Text(
                      server.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      server.testing
                          ? 'در حال تست...'
                          : server.ping == null
                              ? 'تست نشده'
                              : '${server.ping} ms',
                      style: TextStyle(
                        color: pingColor(server.ping),
                      ),
                    ),
                    trailing: server.testing
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child:
                                CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : server.ping != null
                            ? Icon(
                                Icons.circle,
                                size: 12,
                                color: pingColor(
                                  server.ping,
                                ),
                              )
                            : const Icon(
                                Icons.chevron_left,
                              ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Light speed 🔥',
            style: TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: loadSubscription,
            child: ListView(
              padding: const EdgeInsets.all(14),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        TextField(
                          controller: urlController,
                          keyboardType:
                              TextInputType.url,
                          textDirection:
                              TextDirection.ltr,
                          decoration:
                              InputDecoration(
                            labelText:
                                'لینک Subscription',
                            hintText:
                                'https://...',
                            prefixIcon: const Icon(
                              Icons.link,
                            ),
                            suffixIcon: IconButton(
                              onPressed: () {
                                urlController.clear();
                              },
                              icon: const Icon(
                                Icons.clear,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton.icon(
                            onPressed:
                                loading
                                    ? null
                                    : loadSubscription,
                            icon: loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child:
                                        CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.cloud_download,
                                  ),
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

                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111322),
                    borderRadius:
                        BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isConnected
                            ? Icons.check_circle
                            : Icons.info_outline,
                        color: isConnected
                            ? Colors.greenAccent
                            : Colors.deepPurpleAccent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(message),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                buildConnectionCard(),

                const SizedBox(height: 12),

                buildSubscriptionCard(),

                const SizedBox(height: 12),

                buildServerList(),

                const SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
