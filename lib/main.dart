import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LightSpeedApp());
}

// ============================================================
// COLORS
// ============================================================

const Color bgColor = Color(0xFF050A12);
const Color cardColor = Color(0xFF0B1220);
const Color cardColor2 = Color(0xFF101A2C);
const Color cyanColor = Color(0xFF00E5FF);
const Color greenColor = Color(0xFF00E676);
const Color purpleColor = Color(0xFF8B5CF6);
const Color redColor = Color(0xFFFF4D67);
const Color textColor = Color(0xFFF5F7FA);
const Color mutedColor = Color(0xFF8D99AA);

// ============================================================
// APP
// ============================================================

class LightSpeedApp extends StatelessWidget {
  const LightSpeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Light speed 🔥',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: bgColor,
        fontFamily: 'sans',
        colorScheme: ColorScheme.fromSeed(
          seedColor: cyanColor,
          brightness: Brightness.dark,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// ============================================================
// MODELS
// ============================================================

class ServerConfig {
  final String name;
  final String protocol;
  final String host;
  final int port;
  final String rawUrl;
  final String? country;
  int? ping;
  bool testing;

  ServerConfig({
    required this.name,
    required this.protocol,
    required this.host,
    required this.port,
    required this.rawUrl,
    this.country,
    this.ping,
    this.testing = false,
  });
}

class SubscriptionInfo {
  int upload = 0;
  int download = 0;
  int total = 0;
  int expire = 0;

  int get used => upload + download;

  int get remaining {
    if (total <= 0) return 0;

    final value = total - used;

    if (value < 0) return 0;
    return value;
  }

  double get usagePercent {
    if (total <= 0) return 0;

    final percent = used / total;

    if (percent > 1) return 1;
    if (percent < 0) return 0;

    return percent;
  }

  DateTime? get expiryDate {
    if (expire <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(expire * 1000);
  }
}

// ============================================================
// SERVICE
// ============================================================

class SubscriptionService {
  static Future<SubscriptionResult> fetch(String url) async {
    final response = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'LightSpeed/1.0',
        'Accept': '*/*',
      },
    ).timeout(const Duration(seconds: 20));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final metadata = parseUserInfo(
      response.headers['subscription-userinfo'],
    );

    final configs = decodeSubscription(response.body);

    if (configs.isEmpty) {
      throw Exception('هیچ سروری در Subscription پیدا نشد');
    }

    return SubscriptionResult(
      configs: configs,
      info: metadata,
    );
  }

  static SubscriptionInfo? parseUserInfo(String? header) {
    if (header == null || header.trim().isEmpty) {
      return null;
    }

    final info = SubscriptionInfo();

    final parts = header.split(';');

    for (final part in parts) {
      final p = part.trim().split('=');

      if (p.length != 2) continue;

      final key = p[0].trim().toLowerCase();
      final value = int.tryParse(p[1].trim()) ?? 0;

      switch (key) {
        case 'upload':
          info.upload = value;
          break;

        case 'download':
          info.download = value;
          break;

        case 'total':
          info.total = value;
          break;

        case 'expire':
          info.expire = value;
          break;
      }
    }

    return info;
  }

  static List<String> decodeSubscription(String body) {
    String text = body.trim();

    if (text.isEmpty) {
      return [];
    }

    // Direct subscription
    final direct = extractLines(text);

    if (direct.isNotEmpty) {
      return direct;
    }

    // Base64
    final decoded = tryDecodeBase64(text);

    if (decoded != null) {
      return extractLines(decoded);
    }

    return [];
  }

  static List<String> extractLines(String text) {
    final lines = text
        .replaceAll('\r', '\n')
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final result = <String>[];

    for (final line in lines) {
      final lower = line.toLowerCase();

      if (lower.startsWith('vless://') ||
          lower.startsWith('vmess://') ||
          lower.startsWith('trojan://') ||
          lower.startsWith('ss://') ||
          lower.startsWith('ssr://') ||
          lower.startsWith('hysteria://') ||
          lower.startsWith('hysteria2://') ||
          lower.startsWith('hy2://')) {
        result.add(line);
      }
    }

    return result;
  }

  static String? tryDecodeBase64(String value) {
    try {
      String normalized = value.trim();

      normalized = normalized.replaceAll('\n', '');
      normalized = normalized.replaceAll('\r', '');

      normalized = normalized.replaceAll('-', '+');
      normalized = normalized.replaceAll('_', '/');

      while (normalized.length % 4 != 0) {
        normalized += '=';
      }

      final bytes = base64Decode(normalized);

      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  static ServerConfig? parseConfig(String url) {
    try {
      final uri = Uri.parse(url);

      final scheme = uri.scheme.toLowerCase();

      switch (scheme) {
        case 'vless':
          return _parseVless(uri, url);

        case 'vmess':
          return _parseVmess(url);

        case 'trojan':
          return _parseTrojan(uri, url);

        case 'ss':
          return _parseShadowsocks(uri, url);

        case 'ssr':
          return _parseSimple(uri, url, 'SSR');

        case 'hysteria':
          return _parseSimple(uri, url, 'Hysteria');

        case 'hysteria2':
        case 'hy2':
          return _parseSimple(uri, url, 'Hysteria2');

        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  static ServerConfig? _parseVless(Uri uri, String raw) {
    if (uri.host.isEmpty || uri.port == 0) {
      return null;
    }

    String name = uri.fragment;

    if (name.isEmpty) {
      name = uri.host;
    }

    return ServerConfig(
      name: Uri.decodeComponent(name),
      protocol: 'VLESS',
      host: uri.host,
      port: uri.port,
      rawUrl: raw,
    );
  }

  static ServerConfig? _parseTrojan(Uri uri, String raw) {
    if (uri.host.isEmpty || uri.port == 0) {
      return null;
    }

    String name = uri.fragment;

    if (name.isEmpty) {
      name = uri.host;
    }

    return ServerConfig(
      name: Uri.decodeComponent(name),
      protocol: 'Trojan',
      host: uri.host,
      port: uri.port,
      rawUrl: raw,
    );
  }

  static ServerConfig? _parseSimple(
    Uri uri,
    String raw,
    String protocol,
  ) {
    if (uri.host.isEmpty || uri.port == 0) {
      return null;
    }

    String name = uri.fragment;

    if (name.isEmpty) {
      name = uri.host;
    }

    return ServerConfig(
      name: Uri.decodeComponent(name),
      protocol: protocol,
      host: uri.host,
      port: uri.port,
      rawUrl: raw,
    );
  }

  static ServerConfig? _parseShadowsocks(Uri uri, String raw) {
    if (uri.host.isEmpty || uri.port == 0) {
      return null;
    }

    String name = uri.fragment;

    if (name.isEmpty) {
      name = uri.host;
    }

    return ServerConfig(
      name: Uri.decodeComponent(name),
      protocol: 'Shadowsocks',
      host: uri.host,
      port: uri.port,
      rawUrl: raw,
    );
  }

  static ServerConfig? _parseVmess(String raw) {
    try {
      final encoded = raw.substring('vmess://'.length);

      String normalized = encoded.replaceAll('-', '+').replaceAll('_', '/');

      while (normalized.length % 4 != 0) {
        normalized += '=';
      }

      final decoded = utf8.decode(base64Decode(normalized));

      final data = jsonDecode(decoded);

      final host = data['add']?.toString() ?? '';
      final port = int.tryParse(data['port']?.toString() ?? '') ?? 0;

      if (host.isEmpty || port == 0) {
        return null;
      }

      final name = data['ps']?.toString().isNotEmpty == true
          ? data['ps'].toString()
          : host;

      return ServerConfig(
        name: name,
        protocol: 'VMess',
        host: host,
        port: port,
        rawUrl: raw,
      );
    } catch (_) {
      return null;
    }
  }
}

class SubscriptionResult {
  final List<ServerConfig> configs;
  final SubscriptionInfo? info;

  SubscriptionResult({
    required this.configs,
    required this.info,
  });
}

// ============================================================
// MAIN SCREEN
// ============================================================

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int currentIndex = 0;

  final TextEditingController subscriptionController =
      TextEditingController();

  List<ServerConfig> servers = [];

  SubscriptionInfo? subscriptionInfo;

  ServerConfig? selectedServer;

  bool loading = false;
  bool testingAll = false;
  bool connected = false;
  bool autoRefresh = true;
  bool autoFastest = true;

  String statusMessage = 'آماده اتصال';

  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();
    loadSavedData();

    refreshTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) {
        if (autoRefresh) {
          loadSubscription(silent: true);
        }
      },
    );
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    subscriptionController.dispose();
    super.dispose();
  }

  // ==========================================================
  // STORAGE
  // ==========================================================

  Future<void> loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();

    final savedUrl = prefs.getString('subscription_url');

    if (savedUrl != null && savedUrl.isNotEmpty) {
      subscriptionController.text = savedUrl;

      await loadSubscription(silent: true);
    }
  }

  Future<void> saveUrl() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'subscription_url',
      subscriptionController.text.trim(),
    );
  }

  // ==========================================================
  // SUBSCRIPTION
  // ==========================================================

  Future<void> loadSubscription({
    bool silent = false,
  }) async {
    final url = subscriptionController.text.trim();

    if (url.isEmpty) {
      if (!silent) {
        showMessage('لینک Subscription را وارد کنید');
      }
      return;
    }

    if (!silent) {
      setState(() {
        loading = true;
        statusMessage = 'در حال دریافت سرورها...';
      });
    }

    try {
      final result = await SubscriptionService.fetch(url);

      final parsed = <ServerConfig>[];

      for (final raw in result.configs) {
        final config = SubscriptionService.parseConfig(raw);

        if (config != null) {
          parsed.add(config);
        }
      }

      if (parsed.isEmpty) {
        throw Exception('کانفیگ قابل شناسایی نیست');
      }

      setState(() {
        servers = parsed;
        subscriptionInfo = result.info;

        if (selectedServer != null) {
          final matching = parsed.where(
            (server) => server.rawUrl == selectedServer!.rawUrl,
          );

          if (matching.isNotEmpty) {
            selectedServer = matching.first;
          } else {
            selectedServer = parsed.first;
          }
        } else {
          selectedServer = parsed.first;
        }

        loading = false;
        statusMessage = '${parsed.length} سرور دریافت شد';
      });

      await saveUrl();

      if (!silent) {
        showMessage('${parsed.length} سرور با موفقیت دریافت شد');
      }

      if (autoFastest && servers.length > 1) {
        await testAllServers(autoSelect: true);
      }
    } catch (e) {
      setState(() {
        loading = false;
        statusMessage = 'دریافت Subscription ناموفق بود';
      });

      if (!silent) {
        showMessage(
          'خطا در دریافت Subscription',
          error: true,
        );
      }
    }
  }

  // ==========================================================
  // PING
  // ==========================================================

  Future<int?> testServer(ServerConfig server) async {
    final stopwatch = Stopwatch()..start();

    try {
      final socket = await Socket.connect(
        server.host,
        server.port,
        timeout: const Duration(seconds: 3),
      );

      stopwatch.stop();

      socket.destroy();

      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  Future<void> testSingleServer(ServerConfig server) async {
    setState(() {
      server.testing = true;
    });

    final ping = await testServer(server);

    setState(() {
      server.ping = ping;
      server.testing = false;
    });
  }

  Future<void> testAllServers({
    bool autoSelect = false,
  }) async {
    if (servers.isEmpty) {
      showMessage('ابتدا Subscription را دریافت کنید');
      return;
    }

    setState(() {
      testingAll = true;

      for (final server in servers) {
        server.testing = true;
      }
    });

    for (final server in servers) {
      final ping = await testServer(server);

      if (!mounted) return;

      setState(() {
        server.ping = ping;
        server.testing = false;
      });
    }

    servers.sort((a, b) {
      if (a.ping == null && b.ping == null) return 0;
      if (a.ping == null) return 1;
      if (b.ping == null) return -1;

      return a.ping!.compareTo(b.ping!);
    });

    if (autoSelect && servers.isNotEmpty) {
      final fastest = servers.firstWhere(
        (server) => server.ping != null,
        orElse: () => servers.first,
      );

      setState(() {
        selectedServer = fastest;
      });
    }

    setState(() {
      testingAll = false;
    });

    if (autoSelect) {
      showMessage('سریع‌ترین سرور انتخاب شد');
    }
  }

  // ==========================================================
  // CONNECT
  // ==========================================================

  Future<void> connectFastest() async {
    if (servers.isEmpty) {
      showMessage('ابتدا Subscription را دریافت کنید');
      return;
    }

    setState(() {
      statusMessage = 'در حال انتخاب سریع‌ترین سرور...';
    });

    await testAllServers(autoSelect: true);

    if (!mounted) return;

    final server = selectedServer;

    if (server == null) {
      showMessage(
        'سرور مناسبی پیدا نشد',
        error: true,
      );
      return;
    }

    // فعلاً فقط انتخاب سرور انجام می‌شود.
    // اتصال واقعی VPN باید در مرحله sing-box اضافه شود.

    setState(() {
      connected = false;
      statusMessage = 'سرور آماده اتصال: ${server.name}';
    });

    showMessage(
      'سریع‌ترین سرور انتخاب شد: ${server.name}',
    );
  }

  void disconnect() {
    setState(() {
      connected = false;
      statusMessage = 'اتصال قطع شد';
    });
  }

  // ==========================================================
  // HELPERS
  // ==========================================================

  void showMessage(
    String message, {
    bool error = false,
  }) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          textDirection: TextDirection.rtl,
        ),
        backgroundColor: error ? redColor : cardColor2,
        behavior: SnackBarBehavior.floating,
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
    int index = 0;

    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index++;
    }

    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[index]}';
  }

  String formatExpiry() {
    final date = subscriptionInfo?.expiryDate;

    if (date == null) {
      return 'نامشخص';
    }

    return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
  }

  String remainingDays() {
    final date = subscriptionInfo?.expiryDate;

    if (date == null) {
      return 'نامشخص';
    }

    final difference = date.difference(DateTime.now()).inDays;

    if (difference < 0) {
      return 'منقضی شده';
    }

    return '$difference روز';
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: IndexedStack(
            index: currentIndex,
            children: [
              buildHome(),
              buildServers(),
              buildTraffic(),
              buildSubscription(),
              buildSettings(),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          backgroundColor: cardColor,
          indicatorColor: cyanColor.withOpacity(.15),
          selectedIndex: currentIndex,
          onDestinationSelected: (index) {
            setState(() {
              currentIndex = index;
            });
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'خانه',
            ),
            NavigationDestination(
              icon: Icon(Icons.dns_outlined),
              selectedIcon: Icon(Icons.dns),
              label: 'سرورها',
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart),
              label: 'مصرف',
            ),
            NavigationDestination(
              icon: Icon(Icons.link_outlined),
              selectedIcon: Icon(Icons.link),
              label: 'اشتراک',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'تنظیمات',
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // HOME
  // ==========================================================

  Widget buildHome() {
    return RefreshIndicator(
      onRefresh: () => loadSubscription(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 30),
        children: [
          buildHeader(),

          const SizedBox(height: 25),

          Center(
            child: GestureDetector(
              onTap: connected
                  ? disconnect
                  : connectFastest,
              child: Container(
                width: 210,
                height: 210,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [
                      cyanColor,
                      purpleColor,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: cyanColor.withOpacity(.25),
                      blurRadius: 50,
                      spreadRadius: 8,
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(8),
                child: Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: bgColor,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          connected
                              ? Icons.power
                              : Icons.bolt,
                          size: 55,
                          color: connected
                              ? greenColor
                              : cyanColor,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          connected
                              ? 'متصل'
                              : 'اتصال',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          connected
                              ? 'قطع اتصال'
                              : 'سریع‌ترین سرور',
                          style: const TextStyle(
                            color: mutedColor,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 25),

          Center(
            child: Text(
              statusMessage,
              style: const TextStyle(
                color: mutedColor,
              ),
            ),
          ),

          const SizedBox(height: 20),

          if (selectedServer != null)
            buildSelectedServer(),

          const SizedBox(height: 15),

          buildTrafficSummary(),

          const SizedBox(height: 15),

          Row(
            children: [
              Expanded(
                child: buildInfoCard(
                  icon: Icons.event,
                  title: 'انقضا',
                  value: formatExpiry(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: buildInfoCard(
                  icon: Icons.timer_outlined,
                  title: 'زمان باقی‌مانده',
                  value: remainingDays(),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          OutlinedButton.icon(
            onPressed: loading
                ? null
                : () => loadSubscription(),
            icon: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.refresh),
            label: const Text('به‌روزرسانی Subscription'),
          ),
        ],
      ),
    );
  }

  Widget buildHeader() {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            gradient: const LinearGradient(
              colors: [
                cyanColor,
                purpleColor,
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
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Light speed 🔥',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'VPN Manager',
                style: TextStyle(
                  color: mutedColor,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () {
            setState(() {
              currentIndex = 4;
            });
          },
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );
  }

  Widget buildSelectedServer() {
    final server = selectedServer!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: cyanColor.withOpacity(.18),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: cyanColor.withOpacity(.1),
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Icon(
              Icons.public,
              color: cyanColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  server.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${server.protocol} • ${server.host}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: mutedColor,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          pingWidget(server.ping),
        ],
      ),
    );
  }

  Widget buildTrafficSummary() {
    final info = subscriptionInfo;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(
                Icons.data_usage,
                color: cyanColor,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'حجم باقی‌مانده',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                info == null
                    ? 'نامشخص'
                    : formatBytes(info.remaining),
                style: const TextStyle(
                  color: cyanColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: info?.usagePercent ?? 0,
              backgroundColor: Colors.white.withOpacity(.07),
              valueColor: const AlwaysStoppedAnimation(
                cyanColor,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'مصرف: ${info == null ? 'نامشخص' : formatBytes(info.used)}',
                style: const TextStyle(
                  color: mutedColor,
                  fontSize: 12,
                ),
              ),
              Text(
                'کل: ${info == null ? 'نامشخص' : formatBytes(info.total)}',
                style: const TextStyle(
                  color: mutedColor,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildInfoCard({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: purpleColor,
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              color: mutedColor,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // SERVERS
  // ==========================================================

  Widget buildServers() {
    return Column(
      children: [
        buildPageHeader(
          'سرورها',
          'مدیریت و انتخاب سرور',
        ),
        Expanded(
          child: servers.isEmpty
              ? buildEmptyState(
                  icon: Icons.dns_outlined,
                  title: 'سروری وجود ندارد',
                  subtitle:
                      'ابتدا Subscription خود را دریافت کنید',
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: servers.length,
                  itemBuilder: (context, index) {
                    return buildServerCard(
                      servers[index],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget buildServerCard(ServerConfig server) {
    final selected =
        selectedServer?.rawUrl == server.rawUrl;

    return GestureDetector(
      onTap: () {
        setState(() {
          selectedServer = server;
        });
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: selected
              ? cyanColor.withOpacity(.08)
              : cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? cyanColor.withOpacity(.5)
                : Colors.white.withOpacity(.05),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: purpleColor.withOpacity(.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.public,
                color: purpleColor,
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
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      protocolChip(server.protocol),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${server.host}:${server.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: mutedColor,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              children: [
                pingWidget(server.ping),
                const SizedBox(height: 5),
                InkWell(
                  onTap: () => testSingleServer(server),
                  child: const Icon(
                    Icons.speed,
                    size: 20,
                    color: cyanColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget protocolChip(String protocol) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 7,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: cyanColor.withOpacity(.08),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        protocol,
        style: const TextStyle(
          color: cyanColor,
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget pingWidget(int? ping) {
    if (ping == null) {
      return const Text(
        '--',
        style: TextStyle(
          color: mutedColor,
          fontSize: 12,
        ),
      );
    }

    Color color;

    if (ping < 100) {
      color = greenColor;
    } else if (ping < 200) {
      color = cyanColor;
    } else if (ping < 400) {
      color = Colors.orange;
    } else {
      color = redColor;
    }

    return Text(
      '$ping ms',
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.bold,
        fontSize: 12,
      ),
    );
  }

  // ==========================================================
  // TRAFFIC
  // ==========================================================

  Widget buildTraffic() {
    final info = subscriptionInfo;

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        buildPageHeader(
          'مصرف اینترنت',
          'آمار Subscription',
        ),

        const SizedBox(height: 15),

        Row(
          children: [
            Expanded(
              child: buildTrafficCard(
                Icons.download,
                'دانلود',
                info == null
                    ? 'نامشخص'
                    : formatBytes(info.download),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: buildTrafficCard(
                Icons.upload,
                'آپلود',
                info == null
                    ? 'نامشخص'
                    : formatBytes(info.upload),
              ),
            ),
          ],
        ),

        const SizedBox(height: 15),

        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.pie_chart_outline,
                    color: purpleColor,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'وضعیت حجم',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 25),
              SizedBox(
                width: 170,
                height: 170,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 170,
                      height: 170,
                      child: CircularProgressIndicator(
                        strokeWidth: 14,
                        value: info?.usagePercent ?? 0,
                        backgroundColor:
                            Colors.white.withOpacity(.06),
                        valueColor:
                            const AlwaysStoppedAnimation(
                          cyanColor,
                        ),
                      ),
                    ),
                    Column(
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      children: [
                        Text(
                          info == null
                              ? '--'
                              : '${(info.usagePercent * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(
                          'مصرف شده',
                          style: TextStyle(
                            color: mutedColor,
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

        const SizedBox(height: 15),

        buildInfoCard(
          icon: Icons.storage,
          title: 'کل حجم',
          value: info == null
              ? 'نامشخص'
              : formatBytes(info.total),
        ),
      ],
    );
  }

  Widget buildTrafficCard(
    IconData icon,
    String title,
    String value,
  ) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: cyanColor,
          ),
          const SizedBox(height: 15),
          Text(
            title,
            style: const TextStyle(
              color: mutedColor,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // SUBSCRIPTION
  // ==========================================================

  Widget buildSubscription() {
    final info = subscriptionInfo;

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        buildPageHeader(
          'Subscription',
          'مدیریت اشتراک',
        ),

        const SizedBox(height: 15),

        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'لینک Subscription',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: subscriptionController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText:
                      'https://example.com/sub/...',
                  filled: true,
                  fillColor: bgColor,
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(15),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(
                    Icons.link,
                    color: cyanColor,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: loading
                      ? null
                      : () => loadSubscription(),
                  icon: loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child:
                              CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.download),
                  label: const Text(
                    'دریافت و به‌روزرسانی',
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 15),

        buildInfoCard(
          icon: Icons.cloud_download,
          title: 'حجم کل',
          value: info == null
              ? 'نامشخص'
              : formatBytes(info.total),
        ),

        const SizedBox(height: 12),

        buildInfoCard(
          icon: Icons.data_usage,
          title: 'حجم مصرف شده',
          value: info == null
              ? 'نامشخص'
              : formatBytes(info.used),
        ),

        const SizedBox(height: 12),

        buildInfoCard(
          icon: Icons.data_saver_on,
          title: 'حجم باقی‌مانده',
          value: info == null
              ? 'نامشخص'
              : formatBytes(info.remaining),
        ),

        const SizedBox(height: 12),

        buildInfoCard(
          icon: Icons.calendar_month,
          title: 'تاریخ انقضا',
          value: formatExpiry(),
        ),

        const SizedBox(height: 12),

        buildInfoCard(
          icon: Icons.timer,
          title: 'زمان باقی‌مانده',
          value: remainingDays(),
        ),

        const SizedBox(height: 20),

        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'به‌روزرسانی خودکار',
                ),
                subtitle: const Text(
                  'هر ۱۵ دقیقه Subscription بررسی شود',
                  style: TextStyle(
                    color: mutedColor,
                    fontSize: 11,
                  ),
                ),
                value: autoRefresh,
                onChanged: (value) {
                  setState(() {
                    autoRefresh = value;
                  });
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==========================================================
  // SETTINGS
  // ==========================================================

  Widget buildSettings() {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        buildPageHeader(
          'تنظیمات',
          'تنظیمات Light speed',
        ),

        const SizedBox(height: 15),

        buildSettingsCard(
          title: 'اتصال',
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'انتخاب سریع‌ترین سرور',
              ),
              subtitle: const Text(
                'قبل از اتصال Ping سرورها بررسی شود',
                style: TextStyle(
                  color: mutedColor,
                  fontSize: 11,
                ),
              ),
              value: autoFastest,
              onChanged: (value) {
                setState(() {
                  autoFastest = value;
                });
              },
            ),
          ],
        ),

        const SizedBox(height: 15),

        buildSettingsCard(
          title: 'Subscription',
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'به‌روزرسانی خودکار',
              ),
              subtitle: const Text(
                'هر ۱۵ دقیقه Subscription دریافت شود',
                style: TextStyle(
                  color: mutedColor,
                  fontSize: 11,
                ),
              ),
              value: autoRefresh,
              onChanged: (value) {
                setState(() {
                  autoRefresh = value;
                });
              },
            ),
          ],
        ),

        const SizedBox(height: 15),

        buildSettingsCard(
          title: 'ابزارها',
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.speed,
                color: cyanColor,
              ),
              title: const Text(
                'تست همه سرورها',
              ),
              subtitle: const Text(
                'بررسی Ping همه کانفیگ‌ها',
                style: TextStyle(
                  color: mutedColor,
                  fontSize: 11,
                ),
              ),
              trailing: testingAll
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child:
                          CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(
                      Icons.chevron_left,
                    ),
              onTap: testingAll
                  ? null
                  : () => testAllServers(),
            ),
          ],
        ),

        const SizedBox(height: 25),

        Center(
          child: Column(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.circular(18),
                  gradient: const LinearGradient(
                    colors: [
                      cyanColor,
                      purpleColor,
                    ],
                  ),
                ),
                child: const Icon(
                  Icons.bolt,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Light speed 🔥',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Version 1.0.0',
                style: TextStyle(
                  color: mutedColor,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildSettingsCard({
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        18,
        12,
        18,
        8,
      ),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: cyanColor,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          ...children,
        ],
      ),
    );
  }

  // ==========================================================
  // PAGE HEADER
  // ==========================================================

  Widget buildPageHeader(
    String title,
    String subtitle,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        4,
        10,
        4,
        0,
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subtitle,
            style: const TextStyle(
              color: mutedColor,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // EMPTY
  // ==========================================================

  Widget buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 70,
              color: mutedColor,
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: mutedColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
