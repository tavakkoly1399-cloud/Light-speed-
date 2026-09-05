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
      title: 'Light speed 🔥',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
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
  int? ping;

  Config({
    required this.raw,
    required this.type,
    required this.address,
    this.port,
  });
}

class SubscriptionInfo {
  int? upload;
  int? download;
  int? total;
  int? expire;

  int get used => (upload ?? 0) + (download ?? 0);

  int? get remaining {
    if (total == null || total! <= 0) return null;
    return total! - used < 0 ? 0 : total! - used;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final urlController = TextEditingController();

  List<Config> configs = [];
  SubscriptionInfo? subscriptionInfo;

  bool loading = false;
  bool testing = false;

  String message = 'لینک Subscription را وارد کن';

  @override
  void initState() {
    super.initState();
    loadSavedUrl();
  }

  Future<void> loadSavedUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('subscription_url');

    if (saved != null && saved.isNotEmpty) {
      urlController.text = saved;
    }
  }

  // ==========================================================
  // دریافت Subscription
  // ==========================================================

  Future<void> loadSubscription() async {
    final url = urlController.text.trim();

    if (url.isEmpty) {
      setState(() {
        message = 'لینک Subscription وارد نشده است';
      });
      return;
    }

    Uri uri;

    try {
      uri = Uri.parse(url);

      if (!uri.hasScheme ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw const FormatException(
          'لینک باید با http یا https باشد',
        );
      }
    } catch (e) {
      setState(() {
        message = 'لینک نامعتبر است: $e';
      });
      return;
    }

    setState(() {
      loading = true;
      configs.clear();
      subscriptionInfo = null;
      message = 'در حال دریافت Subscription...';
    });

    try {
      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'LightSpeed/1.0',
          'Accept': '*/*',
          'Cache-Control': 'no-cache',
        },
      ).timeout(
        const Duration(seconds: 20),
      );

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw Exception(
          'HTTP ${response.statusCode}',
        );
      }

      // اطلاعات حجم و تاریخ از Header
      final info = parseSubscriptionInfo(
        response.headers,
      );

      // محتوای Subscription
      final body = utf8.decode(
        response.bodyBytes,
        allowMalformed: true,
      );

      final lines = decodeSubscription(body);

      final result = <Config>[];

      for (final line in lines) {
        final config = parseConfig(line);

        if (config != null) {
          result.add(config);
        }
      }

      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(
        'subscription_url',
        url,
      );

      if (!mounted) return;

      setState(() {
        configs = result;
        subscriptionInfo = info;
        loading = false;

        if (result.isEmpty) {
          message =
              'هیچ کانفیگی پیدا نشد. پاسخ سرور را بررسی کنید.';
        } else {
          message =
              '${result.length} سرور پیدا شد';
        }
      });
    } on SocketException catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        message =
            'خطای اتصال: ${e.message}';
      });
    } on FormatException catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        message =
            'خطای فرمت: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        message =
            'خطا: ${e.toString()}';
      });
    }
  }

  // ==========================================================
  // Subscription-Userinfo
  // ==========================================================

  SubscriptionInfo? parseSubscriptionInfo(
    Map<String, String> headers,
  ) {
    String? userInfo;

    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() ==
          'subscription-userinfo') {
        userInfo = entry.value;
        break;
      }
    }

    if (userInfo == null ||
        userInfo.trim().isEmpty) {
      return null;
    }

    final info = SubscriptionInfo();

    final parts = userInfo.split(';');

    for (final part in parts) {
      final item = part.trim();

      if (!item.contains('=')) {
        continue;
      }

      final index = item.indexOf('=');

      final key = item
          .substring(0, index)
          .trim()
          .toLowerCase();

      final value = item
          .substring(index + 1)
          .trim();

      final number = int.tryParse(value);

      if (number == null) {
        continue;
      }

      switch (key) {
        case 'upload':
          info.upload = number;
          break;

        case 'download':
          info.download = number;
          break;

        case 'total':
          info.total = number;
          break;

        case 'expire':
          info.expire = number;
          break;
      }
    }

    return info;
  }

  // ==========================================================
  // Decode Subscription
  // ==========================================================

  List<String> decodeSubscription(String body) {
    final cleaned = body
        .replaceFirst('\uFEFF', '')
        .trim();

    if (cleaned.isEmpty) {
      return [];
    }

    // اول: کانفیگ خام
    final direct = extractConfigs(cleaned);

    if (direct.isNotEmpty) {
      return direct;
    }

    // دوم: Base64
    final decoded = decodeBase64(cleaned);

    if (decoded != null) {
      final result = extractConfigs(decoded);

      if (result.isNotEmpty) {
        return result;
      }

      // Base64 دوبل
      final second = decodeBase64(decoded);

      if (second != null) {
        final secondResult =
            extractConfigs(second);

        if (secondResult.isNotEmpty) {
          return secondResult;
        }
      }
    }

    return [];
  }

  // ==========================================================
  // استخراج همه کانفیگ‌ها
  // ==========================================================

  List<String> extractConfigs(String text) {
    final result = <String>[];

    final lines =
        text.split(RegExp(r'\r?\n'));

    const prefixes = [
      'vless://',
      'vmess://',
      'trojan://',
      'ss://',
      'ssr://',
      'hysteria://',
      'hysteria2://',
      'hy2://',
      'hy://',
    ];

    for (var line in lines) {
      var value = line.trim();

      if (value.isEmpty) continue;

      value = value.replaceAll('"', '');
      value = value.replaceAll("'", '');

      final lower = value.toLowerCase();

      for (final prefix in prefixes) {
        if (lower.startsWith(prefix)) {
          result.add(value);
          break;
        }
      }
    }

    return result;
  }

  // ==========================================================
  // Base64
  // ==========================================================

  String? decodeBase64(String input) {
    try {
      var value = input.trim();

      value = value.replaceAll(
        RegExp(r'\s+'),
        '',
      );

      // URL Safe Base64
      value = value.replaceAll('-', '+');
      value = value.replaceAll('_', '/');

      final remainder = value.length % 4;

      if (remainder != 0) {
        value += '=' * (4 - remainder);
      }

      final bytes = base64.decode(value);

      return utf8.decode(
        bytes,
        allowMalformed: true,
      );
    } catch (_) {
      return null;
    }
  }

  // ==========================================================
  // تشخیص کانفیگ
  // ==========================================================

  Config? parseConfig(String value) {
    try {
      final uri = Uri.parse(value);

      final scheme =
          uri.scheme.toLowerCase();

      const supported = [
        'vless',
        'vmess',
        'trojan',
        'ss',
        'ssr',
        'hysteria',
        'hysteria2',
        'hy2',
        'hy',
      ];

      if (!supported.contains(scheme)) {
        return null;
      }

      return Config(
        raw: value,
        type: scheme.toUpperCase(),
        address: uri.host,
        port: uri.hasPort ? uri.port : null,
      );
    } catch (_) {
      return null;
    }
  }

  // ==========================================================
  // Ping
  // ==========================================================

  Future<int?> testServer(
    String host,
    int port,
  ) async {
    final stopwatch = Stopwatch()..start();

    Socket? socket;

    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(
          seconds: 3,
        ),
      );

      stopwatch.stop();

      socket.destroy();

      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      socket?.destroy();
      return null;
    }
  }

  // ==========================================================
  // تست همه سرورها
  // ==========================================================

  Future<void> testAllServers() async {
    if (configs.isEmpty) return;

    setState(() {
      testing = true;
      message =
          'در حال تست همه سرورها...';
    });

    for (final config in configs) {
      if (config.port == null ||
          config.address.isEmpty) {
        continue;
      }

      final ping = await testServer(
        config.address,
        config.port!,
      );

      if (!mounted) return;

      setState(() {
        config.ping = ping;
      });
    }

    configs.sort((a, b) {
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

    if (!mounted) return;

    setState(() {
      testing = false;
      message =
          'تست تمام شد؛ سریع‌ترین سرور اول لیست است';
    });
  }

  // ==========================================================
  // سریع‌ترین
  // ==========================================================

  Config? getBestServer() {
    final valid = configs
        .where(
          (e) => e.ping != null,
        )
        .toList();

    if (valid.isEmpty) return null;

    valid.sort(
      (a, b) =>
          a.ping!.compareTo(
            b.ping!,
          ),
    );

    return valid.first;
  }

  // ==========================================================
  // حجم
  // ==========================================================

  String formatBytes(int? bytes) {
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
        1024 * 1024 * 1024) {
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

  // ==========================================================
  // تاریخ
  // ==========================================================

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
        '${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  String remainingDays(int? expire) {
    if (expire == null ||
        expire <= 0) {
      return 'نامشخص';
    }

    final date =
        DateTime.fromMillisecondsSinceEpoch(
      expire * 1000,
    );

    final days =
        date.difference(DateTime.now()).inDays;

    if (days < 0) {
      return 'منقضی شده';
    }

    return '$days روز';
  }

  // ==========================================================
  // کارت اطلاعات اشتراک
  // ==========================================================

  Widget buildSubscriptionCard() {
    final info = subscriptionInfo;

    if (info == null) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.account_balance_wallet,
                ),
                SizedBox(width: 8),
                Text(
                  '📊 اطلاعات اشتراک',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            if (info.total != null)
              infoRow(
                'حجم کل',
                formatBytes(
                  info.total,
                ),
                Icons.storage,
              ),

            infoRow(
              'مصرف‌شده',
              formatBytes(
                info.used,
              ),
              Icons.data_usage,
            ),

            if (info.remaining != null)
              infoRow(
                'باقی‌مانده',
                formatBytes(
                  info.remaining,
                ),
                Icons.data_saver_on,
              ),

            if (info.upload != null)
              infoRow(
                'آپلود',
                formatBytes(
                  info.upload,
                ),
                Icons.upload,
              ),

            if (info.download != null)
              infoRow(
                'دانلود',
                formatBytes(
                  info.download,
                ),
                Icons.download,
              ),

            if (info.expire != null)
              infoRow(
                'تاریخ انقضا',
                formatExpire(
                  info.expire,
                ),
                Icons.event,
              ),

            if (info.expire != null)
              infoRow(
                'زمان باقی‌مانده',
                remainingDays(
                  info.expire,
                ),
                Icons.timer,
              ),

            infoRow(
              'تعداد سرورها',
              '${configs.length}',
              Icons.cloud,
            ),
          ],
        ),
      ),
    );
  }

  Widget infoRow(
    String title,
    String value,
    IconData icon,
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
            size: 19,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title),
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

  // ==========================================================
  // Copy
  // ==========================================================

  Future<void> copyConfig(
    Config config,
  ) async {
    await Clipboard.setData(
      ClipboardData(
        text: config.raw,
      ),
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(
      const SnackBar(
        content:
            Text('کانفیگ کپی شد'),
      ),
    );
  }

  // ==========================================================
  // UI
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    final best = getBestServer();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Light speed 🔥',
          style: TextStyle(
            fontWeight:
                FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),

      body: SafeArea(
        child: Padding(
          padding:
              const EdgeInsets.all(16),

          child: Column(
            children: [
              TextField(
                controller:
                    urlController,
                decoration:
                    const InputDecoration(
                  labelText:
                      'Subscription URL',
                  hintText:
                      'https://...',
                  border:
                      OutlineInputBorder(),
                  prefixIcon:
                      Icon(Icons.link),
                ),
                keyboardType:
                    TextInputType.url,
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child:
                        FilledButton.icon(
                      onPressed:
                          loading
                              ? null
                              : loadSubscription,
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
                                  Icons.download,
                                ),
                      label:
                          const Text(
                        'دریافت',
                      ),
                    ),
                  ),

                  const SizedBox(width: 8),

                  Expanded(
                    child:
                        FilledButton.icon(
                      onPressed:
                          configs.isEmpty ||
                                  testing
                              ? null
                              : testAllServers,
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
                ],
              ),

              const SizedBox(height: 10),

              Align(
                alignment:
                    Alignment.centerRight,
                child: Text(
                  message,
                ),
              ),

              const SizedBox(height: 8),

              // اطلاعات حجم و تاریخ
              buildSubscriptionCard(),

              // سریع‌ترین سرور
              if (best != null)
                Card(
                  child: ListTile(
                    leading:
                        const Icon(
                      Icons.flash_on,
                    ),
                    title:
                        const Text(
                      '⚡ سریع‌ترین سرور',
                      style: TextStyle(
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    subtitle:
                        Text(
                      '${best.address}:${best.port}'
                      ' • ${best.ping} ms',
                    ),
                  ),
                ),

              const SizedBox(height: 8),

              // لیست همه سرورها
              Expanded(
                child: configs.isEmpty
                    ? const Center(
                        child: Text(
                          'هنوز سروری دریافت نشده',
                        ),
                      )
                    : ListView.builder(
                        itemCount:
                            configs.length,
                        itemBuilder:
                            (context, index) {
                          final config =
                              configs[index];

                          final isBest =
                              best == config;

                          return Card(
                            child:
                                ListTile(
                              leading:
                                  Icon(
                                isBest
                                    ? Icons
                                        .flash_on
                                    : Icons
                                        .cloud,
                              ),

                              title:
                                  Row(
                                children: [
                                  Expanded(
                                    child:
                                        Text(
                                      '${config.type} ${index + 1}',
                                    ),
                                  ),

                                  if (isBest)
                                    const Text(
                                      '⚡',
                                      style:
                                          TextStyle(
                                        fontSize:
                                            20,
                                      ),
                                    ),
                                ],
                              ),

                              subtitle:
                                  Text(
                                '${config.address}:${config.port ?? '-'}'
                                '\nPing: '
                                '${config.ping == null ? '---' : '${config.ping} ms'}',
                              ),

                              isThreeLine:
                                  true,

                              trailing:
                                  IconButton(
                                icon:
                                    const Icon(
                                  Icons.copy,
                                ),
                                onPressed:
                                    () =>
                                        copyConfig(
                                  config,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    urlController.dispose();
    super.dispose();
  }
}
