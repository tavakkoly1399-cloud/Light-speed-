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
    this.ping,
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final urlController = TextEditingController();

  List<Config> configs = [];

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

    if (saved != null) {
      urlController.text = saved;
    }
  }

  Future<void> loadSubscription() async {
    final url = urlController.text.trim();

    if (url.isEmpty) {
      setState(() {
        message = 'لینک Subscription وارد نشده است';
      });
      return;
    }

    setState(() {
      loading = true;
      configs.clear();
      message = 'در حال دریافت کانفیگ‌ها...';
    });

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'LightSpeed/1.0',
        },
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

      setState(() {
        configs = result;
        loading = false;
        message = '${configs.length} کانفیگ پیدا شد';
      });
    } catch (e) {
      setState(() {
        loading = false;
        message = 'دریافت Subscription ناموفق بود';
      });
    }
  }

  List<String> decodeSubscription(String body) {
    final direct = body
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
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
      var normalized =
          body.replaceAll(RegExp(r'\s+'), '');

      normalized +=
          '=' * ((4 - normalized.length % 4) % 4);

      final decoded = utf8.decode(
        base64.decode(normalized),
        allowMalformed: true,
      );

      return decoded
          .split(RegExp(r'\r?\n'))
          .map((e) => e.trim())
          .where(
            (e) =>
                e.isNotEmpty &&
                e.contains('://'),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Config? parseConfig(String value) {
    try {
      final uri = Uri.parse(value);

      final scheme = uri.scheme.toLowerCase();

      const supported = [
        'vless',
        'vmess',
        'trojan',
        'ss',
        'ssr',
        'hysteria',
        'hysteria2',
        'hy2',
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

  Future<int?> testServer(
    String host,
    int port,
  ) async {
    final stopwatch = Stopwatch()..start();

    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );

      stopwatch.stop();

      socket.destroy();

      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  Future<void> testAllServers() async {
    if (configs.isEmpty) return;

    setState(() {
      testing = true;
      message = 'در حال بررسی سرورها...';
    });

    for (final config in configs) {
      if (config.port == null) {
        continue;
      }

      final result = await testServer(
        config.address,
        config.port!,
      );

      if (!mounted) return;

      setState(() {
        config.ping = result;
      });
    }

    configs.sort((a, b) {
      if (a.ping == null && b.ping == null) {
        return 0;
      }

      if (a.ping == null) {
        return 1;
      }

      if (b.ping == null) {
        return -1;
      }

      return a.ping!.compareTo(
        b.ping!,
      );
    });

    setState(() {
      testing = false;
      message = 'سرورها بر اساس Ping مرتب شدند';
    });
  }

  Config? getBestServer() {
    final valid = configs
        .where((config) => config.ping != null)
        .toList();

    if (valid.isEmpty) {
      return null;
    }

    valid.sort(
      (a, b) =>
          a.ping!.compareTo(b.ping!),
    );

    return valid.first;
  }

  Future<void> copyConfig(Config config) async {
    await Clipboard.setData(
      ClipboardData(text: config.raw),
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('کانفیگ کپی شد'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final best = getBestServer();

    return Scaffold(
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
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'Subscription URL',
                  hintText: 'https://...',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.link),
                ),
                keyboardType:
                    TextInputType.url,
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: loading
                          ? null
                          : loadSubscription,
                      icon: const Icon(
                        Icons.download,
                      ),
                      label: const Text(
                        'دریافت',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          configs.isEmpty ||
                                  testing
                              ? null
                              : testAllServers,
                      icon: const Icon(
                        Icons.speed,
                      ),
                      label: const Text(
                        'تست Ping',
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Align(
                alignment:
                    Alignment.centerRight,
                child: Text(message),
              ),

              const SizedBox(height: 8),

              if (best != null)
                Card(
                  child: ListTile(
                    leading: const Icon(
                      Icons.flash_on,
                    ),
                    title: const Text(
                      'بهترین سرور',
                    ),
                    subtitle: Text(
                      '${best.address}:${best.port}'
                      '  •  ${best.ping} ms',
                    ),
                  ),
                ),

              const SizedBox(height: 8),

              Expanded(
                child: configs.isEmpty
                    ? const Center(
                        child: Text(
                          'هنوز کانفیگی دریافت نشده',
                        ),
                      )
                    : ListView.builder(
                        itemCount:
                            configs.length,
                        itemBuilder:
                            (context, index) {
                          final config =
                              configs[index];

                          return Card(
                            child: ListTile(
                              leading: const Icon(
                                Icons.cloud,
                              ),
                              title: Text(
                                '${config.type} ${index + 1}',
                              ),
                              subtitle: Text(
                                '${config.address}:${config.port ?? '-'}'
                                '\nPing: '
                                '${config.ping == null ? '---' : '${config.ping} ms'}',
                              ),
                              isThreeLine: true,
                              trailing:
                                  IconButton(
                                icon:
                                    const Icon(
                                  Icons.copy,
                                ),
                                onPressed: () =>
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
