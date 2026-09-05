import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      debugShowCheckedModeBanner: false,
      title: 'Light speed',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF070910),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class Config {
  final String raw;
  final String type;
  final String address;
  final int? port;
  final String name;
  int? ping;

  Config({
    required this.raw,
    required this.type,
    required this.address,
    required this.port,
    this.name = '',
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

  int? get used {
    if (upload == null || download == null) return null;
    return upload! + download!;
  }

  int? get remaining {
    if (total == null || used == null) return null;
    final result = total! - used!;
    return result < 0 ? 0 : result;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController urlController = TextEditingController();

  List<Config> configs = [];
  SubscriptionInfo? subscriptionInfo;

  bool loading = false;
  bool testing = false;

  String message = 'لینک سابسکریپشن را وارد کنید';

  Timer? countdownTimer;

  @override
  void initState() {
    super.initState();
    loadSavedUrl();

    countdownTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) {
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  @override
  void dispose() {
    countdownTimer?.cancel();
    urlController.dispose();
    super.dispose();
  }

  Future<void> loadSavedUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('subscription_url');

    if (saved != null && saved.isNotEmpty) {
      urlController.text = saved;
    }
  }

  Future<void> loadSubscription() async {
    final input = urlController.text.trim();

    if (input.isEmpty) {
      setState(() {
        message = 'لطفاً لینک سابسکریپشن را وارد کنید';
      });
      return;
    }

    final uri = Uri.tryParse(input);

    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() {
        message = 'لینک وارد شده معتبر نیست';
      });
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();

    setState(() {
      loading = true;
      configs = [];
      subscriptionInfo = null;
      message = 'در حال دریافت سابسکریپشن...';
    });

    try {
      final response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'LightSpeed/1.0',
          'Accept': '*/*',
          'Cache-Control': 'no-cache',
        },
      ).timeout(const Duration(seconds: 25));

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw Exception(
          'HTTP ${response.statusCode}',
        );
      }

      final info = parseSubscriptionInfo(response.headers);

      final decoded = decodeSubscription(response.body);

      final extracted = extractConfigs(decoded);

      final result = <Config>[];
      final seen = <String>{};

      for (final line in extracted) {
        final config = parseConfig(line);

        if (config == null) continue;

        final key = config.raw;

        if (seen.contains(key)) continue;

        seen.add(key);
        result.add(config);
      }

      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(
        'subscription_url',
        input,
      );

      if (!mounted) return;

      setState(() {
        subscriptionInfo = info;
        configs = result;
        loading = false;

        if (result.isEmpty) {
          message =
              'سابسکریپشن دریافت شد، اما کانفیگی پیدا نشد';
        } else {
          message =
              '${result.length} سرور پیدا شد';
        }
      });
    } on SocketException {
      setState(() {
        loading = false;
        message =
            'اتصال به سرور برقرار نشد';
      });
    } on TimeoutException {
      setState(() {
        loading = false;
        message =
            'زمان دریافت سابسکریپشن تمام شد';
      });
    } on HandshakeException {
      setState(() {
        loading = false;
        message =
            'خطای SSL در اتصال به سرور';
      });
    } catch (e) {
      setState(() {
        loading = false;
        message = 'خطا در دریافت سابسکریپشن';
      });
    }
  }

  SubscriptionInfo? parseSubscriptionInfo(
    Map<String, String> headers,
  ) {
    String? raw;

    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() ==
          'subscription-userinfo') {
        raw = entry.value;
        break;
      }
    }

    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    int? read(String key) {
      final match = RegExp(
        '$key\\s*=\\s*(\\d+)',
        caseSensitive: false,
      ).firstMatch(raw!);

      if (match == null) return null;

      return int.tryParse(match.group(1)!);
    }

    return SubscriptionInfo(
      upload: read('upload'),
      download: read('download'),
      total: read('total'),
      expire: read('expire'),
    );
  }

  String decodeSubscription(String body) {
    var text = body
        .replaceAll('\uFEFF', '')
        .trim();

    if (extractConfigs(text).isNotEmpty) {
      return text;
    }

    for (int i = 0; i < 4; i++) {
      final decoded = decodeBase64(text);

      if (decoded == null ||
          decoded.trim().isEmpty) {
        break;
      }

      text = decoded
          .replaceAll('\uFEFF', '')
          .trim();

      if (extractConfigs(text).isNotEmpty) {
        return text;
      }
    }

    return text;
  }

  String? decodeBase64(String input) {
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

  List<String> extractConfigs(String text) {
    final result = <String>[];

    final regex = RegExp(
      r'(vless|vmess|trojan|ss|ssr|hysteria2?|hy2?|hy)://[^\s"<>]+',
      caseSensitive: false,
    );

    for (final match in regex.allMatches(text)) {
      var value = match.group(0)!.trim();

      while (
          value.endsWith(',') ||
          value.endsWith('}') ||
          value.endsWith(']') ||
          value.endsWith("'")) {
        value =
            value.substring(0, value.length - 1);
      }

      result.add(value);
    }

    return result;
  }

  Config? parseConfig(String value) {
    var raw = value
        .replaceAll('"', '')
        .replaceAll("'", '')
        .trim();

    final uri = Uri.tryParse(raw);

    if (uri == null) return null;

    final scheme = uri.scheme.toLowerCase();

    const supported = {
      'vless',
      'vmess',
      'trojan',
      'ss',
      'ssr',
      'hysteria',
      'hysteria2',
      'hy2',
      'hy',
    };

    if (!supported.contains(scheme)) {
      return null;
    }

    if (scheme == 'vmess') {
      final vmess = parseVmess(raw);

      if (vmess != null) {
        return vmess;
      }
    }

    final address = uri.host;

    if (address.isEmpty) {
      return null;
    }

    String name = '';

    final fragment = uri.fragment;

    if (fragment.isNotEmpty) {
      name = Uri.decodeComponent(fragment);
    }

    return Config(
      raw: raw,
      type: scheme.toUpperCase(),
      address: address,
      port: uri.hasPort ? uri.port : null,
      name: name,
    );
  }

  Config? parseVmess(String raw) {
    try {
      final encoded =
          raw.substring('vmess://'.length);

      final decoded = decodeBase64(encoded);

      if (decoded == null) return null;

      final data =
          jsonDecode(decoded);

      if (data is! Map) return null;

      final address =
          (data['add'] ?? '').toString();

      final portValue =
          int.tryParse(
        (data['port'] ?? '').toString(),
      );

      final name =
          (data['ps'] ?? '').toString();

      if (address.isEmpty) return null;

      return Config(
        raw: raw,
        type: 'VMESS',
        address: address,
        port: portValue,
        name: name,
      );
    } catch (_) {
      return null;
    }
  }

  Future<int?> testServer(
    Config config,
  ) async {
    if (config.address.isEmpty ||
        config.port == null) {
      return null;
    }

    final stopwatch = Stopwatch()..start();

    try {
      final socket =
          await Socket.connect(
        config.address,
        config.port!,
        timeout:
            const Duration(seconds: 3),
      );

      stopwatch.stop();

      socket.destroy();

      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  Future<void> testAllServers() async {
    if (configs.isEmpty) {
      setState(() {
        message =
            'ابتدا سابسکریپشن را دریافت کنید';
      });
      return;
    }

    setState(() {
      testing = true;
      message =
          'در حال تست سرعت سرورها...';
    });

    const batchSize = 8;

    for (int i = 0;
        i < configs.length;
        i += batchSize) {
      final end =
          (i + batchSize < configs.length)
              ? i + batchSize
              : configs.length;

      final batch =
          configs.sublist(i, end);

      await Future.wait(
        batch.map(
          (config) async {
            config.ping =
                await testServer(config);
          },
        ),
      );

      if (mounted) {
        setState(() {});
      }
    }

    configs.sort((a, b) {
      if (a.ping == null &&
          b.ping == null) {
        return 0;
      }

      if (a.ping == null) return 1;

      if (b.ping == null) return -1;

      return a.ping!
          .compareTo(b.ping!);
    });

    if (!mounted) return;

    setState(() {
      testing = false;

      final best = getBestServer();

      if (best == null) {
        message =
            'هیچ سروری پاسخ نداد';
      } else {
        message =
            'سریع‌ترین سرور: ${best.ping} ms';
      }
    });
  }

  Config? getBestServer() {
    final available = configs
        .where((config) =>
            config.ping != null)
        .toList();

    if (available.isEmpty) {
      return null;
    }

    available.sort(
      (a, b) =>
          a.ping!.compareTo(b.ping!),
    );

    return available.first;
  }

  String formatBytes(int? bytes) {
    if (bytes == null) {
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
          '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }

    if (bytes <
        1024 *
            1024 *
            1024 *
            1024) {
      return
          '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }

    return
        '${(bytes / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(1)} TB';
  }

  String formatExpire(int? expire) {
    if (expire == null ||
        expire <= 0) {
      return 'نامشخص';
    }

    final date =
        DateTime.fromMillisecondsSinceEpoch(
      expire * 1000,
    ).toLocal();

    return '${date.year}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.day.toString().padLeft(2, '0')}';
  }

  String remainingTime(int? expire) {
    if (expire == null ||
        expire <= 0) {
      return 'نامشخص';
    }

    final expiration =
        DateTime.fromMillisecondsSinceEpoch(
      expire * 1000,
    );

    final now = DateTime.now();

    if (expiration.isBefore(now)) {
      return 'منقضی شده';
    }

    final difference =
        expiration.difference(now);

    final days = difference.inDays;
    final hours =
        difference.inHours % 24;
    final minutes =
        difference.inMinutes % 60;

    if (days > 0) {
      return '$days روز و $hours ساعت';
    }

    if (hours > 0) {
      return '$hours ساعت و $minutes دقیقه';
    }

    return '$minutes دقیقه';
  }

  double usagePercent() {
    final info = subscriptionInfo;

    if (info == null ||
        info.total == null ||
        info.total! <= 0 ||
        info.used == null) {
      return 0;
    }

    final value =
        info.used! / info.total!;

    return value.clamp(0.0, 1.0);
  }

  Color pingColor(int? ping) {
    if (ping == null) {
      return Colors.grey;
    }

    if (ping < 100) {
      return Colors.greenAccent;
    }

    if (ping < 200) {
      return Colors.orangeAccent;
    }

    return Colors.redAccent;
  }

  Widget card({
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF111522),
        borderRadius:
            BorderRadius.circular(24),
        border: Border.all(
          color:
              Colors.white.withOpacity(0.07),
        ),
      ),
      child: child,
    );
  }

  Widget titleRow(
    String title,
    IconData icon,
  ) {
    return Row(
      children: [
        Container(
          padding:
              const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: const Color(
              0xFF7C4DFF,
            ).withOpacity(0.14),
            borderRadius:
                BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            color:
                const Color(0xFFB388FF),
            size: 20,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight:
                FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget buildHeader() {
    return Row(
      children: [
        Container(
          width: 55,
          height: 55,
          decoration: BoxDecoration(
            gradient:
                const LinearGradient(
              colors: [
                Color(0xFF7C4DFF),
                Color(0xFF536DFE),
              ],
            ),
            borderRadius:
                BorderRadius.circular(17),
          ),
          child: const Icon(
            Icons.bolt_rounded,
            color: Colors.white,
            size: 34,
          ),
        ),
        const SizedBox(width: 14),
        const Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Text(
              'Light speed 🔥',
              style: TextStyle(
                fontSize: 24,
                fontWeight:
                    FontWeight.w800,
              ),
            ),
            Text(
              'سریع • امن • قدرتمند',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget buildSubscriptionInput() {
    return card(
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          titleRow(
            'Subscription',
            Icons.link_rounded,
          ),
          const SizedBox(height: 15),
          TextField(
            controller: urlController,
            keyboardType:
                TextInputType.url,
            decoration:
                InputDecoration(
              hintText:
                  'لینک سابسکریپشن',
              prefixIcon:
                  const Icon(
                Icons.language,
              ),
              filled: true,
              fillColor:
                  const Color(
                      0xFF080A12),
              border:
                  OutlineInputBorder(
                borderRadius:
                    BorderRadius.circular(
                        16),
                borderSide:
                    BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: loading
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
                      Icons.download_rounded,
                    ),
              label: Text(
                loading
                    ? 'در حال دریافت...'
                    : 'دریافت سابسکریپشن',
              ),
              style:
                  ElevatedButton.styleFrom(
                backgroundColor:
                    const Color(
                        0xFF7C4DFF),
                foregroundColor:
                    Colors.white,
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(
                          16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildConnection() {
    final best =
        getBestServer();

    return Container(
      padding:
          const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient:
            const LinearGradient(
          colors: [
            Color(0xFF1B1433),
            Color(0xFF10131F),
          ],
        ),
        borderRadius:
            BorderRadius.circular(28),
      ),
      child: Column(
        children: [
          const Text(
            'وضعیت اتصال',
            style: TextStyle(
              color: Colors.white54,
            ),
          ),
          const SizedBox(height: 15),
          Container(
            width: 85,
            height: 85,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(
                0xFF7C4DFF,
              ).withOpacity(0.12),
              border: Border.all(
                color: const Color(
                  0xFF7C4DFF,
                ).withOpacity(0.4),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.power_settings_new_rounded,
              color:
                  Color(0xFFB388FF),
              size: 42,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'متصل نیست',
            style: TextStyle(
              fontSize: 21,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            best == null
                ? 'سروری انتخاب نشده'
                : 'بهترین Ping: ${best.ping} ms',
            style: const TextStyle(
              color: Colors.white54,
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: best == null
                  ? null
                  : () {
                      ScaffoldMessenger
                          .of(context)
                          .showSnackBar(
                        const SnackBar(
                          content: Text(
                            'اتصال واقعی VPN هنوز فعال نشده است',
                          ),
                        ),
                      );
                    },
              icon: const Icon(
                Icons.bolt_rounded,
              ),
              label: const Text(
                'اتصال سریع',
                style: TextStyle(
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              style:
                  ElevatedButton.styleFrom(
                backgroundColor:
                    const Color(
                        0xFF7C4DFF),
                foregroundColor:
                    Colors.white,
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(
                          16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget statBox(
    String title,
    String value,
    IconData icon,
  ) {
    return Expanded(
      child: Container(
        padding:
            const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color:
              const Color(0xFF080A12),
          borderRadius:
              BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color:
                  const Color(0xFFB388FF),
              size: 21,
            ),
            const SizedBox(height: 7),
            Text(
              title,
              style:
                  const TextStyle(
                color: Colors.white54,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              textAlign:
                  TextAlign.center,
              style:
                  const TextStyle(
                fontSize: 12,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildSubscriptionInfo() {
    final info =
        subscriptionInfo;

    if (info == null) {
      return card(
        child: Column(
          children: [
            titleRow(
              'اطلاعات اشتراک',
              Icons.data_usage_rounded,
            ),
            const SizedBox(height: 18),
            const Text(
              'اطلاعات حجم و زمان هنوز دریافت نشده است',
              textAlign:
                  TextAlign.center,
              style: TextStyle(
                color: Colors.white54,
              ),
            ),
          ],
        ),
      );
    }

    final percent =
        usagePercent();

    return card(
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          titleRow(
            'اطلاعات اشتراک',
            Icons.data_usage_rounded,
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'حجم باقی‌مانده',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatBytes(
                        info.remaining,
                      ),
                      style:
                          const TextStyle(
                        fontSize: 24,
                        fontWeight:
                            FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment:
                    CrossAxisAlignment.end,
                children: [
                  const Text(
                    'حجم کل',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatBytes(
                      info.total,
                    ),
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius:
                BorderRadius.circular(20),
            child:
                LinearProgressIndicator(
              value: percent,
              minHeight: 10,
              backgroundColor:
                  Colors.white10,
              valueColor:
                  const AlwaysStoppedAnimation(
                Color(0xFF7C4DFF),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            '${(percent * 100).toStringAsFixed(1)}٪ مصرف شده',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              statBox(
                'مصرف شده',
                formatBytes(info.used),
                Icons.pie_chart_rounded,
              ),
              const SizedBox(width: 8),
              statBox(
                'آپلود',
                formatBytes(info.upload),
                Icons.upload_rounded,
              ),
              const SizedBox(width: 8),
              statBox(
                'دانلود',
                formatBytes(info.download),
                Icons.download_rounded,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              statBox(
                'زمان باقی‌مانده',
                remainingTime(
                  info.expire,
                ),
                Icons.timer_rounded,
              ),
              const SizedBox(width: 8),
              statBox(
                'تاریخ انقضا',
                formatExpire(
                  info.expire,
                ),
                Icons.event_rounded,
              ),
              const SizedBox(width: 8),
              statBox(
                'تعداد سرور',
                '${configs.length}',
                Icons.dns_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildServers() {
    if (configs.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        titleRow(
          'همه سرورها',
          Icons.public_rounded,
        ),
        const SizedBox(height: 13),
        ...configs.asMap().entries.map(
          (entry) {
            final config =
                entry.value;

            final best =
                entry.key == 0 &&
                    config.ping != null;

            return Container(
              margin:
                  const EdgeInsets.only(
                      bottom: 9),
              decoration:
                  BoxDecoration(
                color: const Color(
                    0xFF111522),
                borderRadius:
                    BorderRadius.circular(
                        19),
                border: Border.all(
                  color: best
                      ? const Color(
                          0xFF7C4DFF)
                      : Colors.white
                          .withOpacity(
                              0.05),
                ),
              ),
              child: ListTile(
                contentPadding:
                    const EdgeInsets
                        .symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration:
                      BoxDecoration(
                    color: pingColor(
                      config.ping,
                    ).withOpacity(
                      0.12,
                    ),
                    borderRadius:
                        BorderRadius
                            .circular(14),
                  ),
                  child: Icon(
                    Icons.dns_rounded,
                    color: pingColor(
                      config.ping,
                    ),
                  ),
                ),
                title: Text(
                  config.name.isNotEmpty
                      ? config.name
                      : '${config.type} • ${config.address}',
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
                  style:
                      const TextStyle(
                    fontSize: 13,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  '${config.type}  •  ${config.address}:${config.port ?? '-'}',
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
                  style:
                      const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                  ),
                ),
                trailing: Column(
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  crossAxisAlignment:
                      CrossAxisAlignment.end,
                  children: [
                    Text(
                      config.ping == null
                          ? 'تست نشده'
                          : '${config.ping} ms',
                      style:
                          TextStyle(
                        color:
                            pingColor(
                          config.ping,
                        ),
                        fontWeight:
                            FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    if (best)
                      const Text(
                        'سریع‌ترین',
                        style:
                            TextStyle(
                          color:
                              Colors.amber,
                          fontSize: 9,
                        ),
                      ),
                  ],
                ),
                onTap: () {
                  Clipboard.setData(
                    ClipboardData(
                      text: config.raw,
                    ),
                  );

                  ScaffoldMessenger
                      .of(context)
                      .showSnackBar(
                    const SnackBar(
                      content: Text(
                        'کانفیگ کپی شد',
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection:
          TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding:
                const EdgeInsets.fromLTRB(
              18,
              18,
              18,
              35,
            ),
            children: [
              buildHeader(),

              const SizedBox(height: 22),

              buildSubscriptionInput(),

              const SizedBox(height: 12),

              Container(
                padding:
                    const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color:
                      const Color(0xFF111522),
                  borderRadius:
                      BorderRadius.circular(
                          15),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color:
                          Colors.white54,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        message,
                        style:
                            const TextStyle(
                          color:
                              Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              buildConnection(),

              const SizedBox(height: 14),

              buildSubscriptionInfo(),

              const SizedBox(height: 20),

              if (configs.isNotEmpty)
                SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: testing
                        ? null
                        : testAllServers,
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
                    label: Text(
                      testing
                          ? 'در حال تست...'
                          : 'تست سرعت همه سرورها',
                    ),
                    style:
                        OutlinedButton.styleFrom(
                      foregroundColor:
                          const Color(
                              0xFFB388FF),
                      side: BorderSide(
                        color: const Color(
                          0xFF7C4DFF,
                        ).withOpacity(0.5),
                      ),
                      shape:
                          RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(
                                16),
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 22),

              buildServers(),
            ],
          ),
        ),
      ),
    );
  }
}
