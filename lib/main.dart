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
  final FlutterVlessURL? profile;
  int? ping;

  Config({
    required this.raw,
    required this.type,
    required this.address,
    this.port,
    this.profile,
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

  late final FlutterVless flutterVless;

  List<Config> configs = [];

  bool loading = false;
  bool testing = false;

  String message = 'لینک Subscription را وارد کن';

  VlessStatus? vpnStatus;

  @override
  void initState() {
    super.initState();

    flutterVless = FlutterVless(
      onStatusChanged: (status) {
        if (!mounted) return;

        setState(() {
          vpnStatus = status;

          if (status.connectionState ==
              VlessConnectionState.connected) {
            message = 'VPN متصل است';
          } else if (status.connectionState ==
              VlessConnectionState.connecting) {
            message = 'در حال اتصال به VPN...';
          } else if (status.connectionState ==
              VlessConnectionState.disconnecting) {
            message = 'در حال قطع VPN...';
          } else {
            message = 'VPN قطع است';
          }
        });
      },
    );

    initializeVpn();
    loadSavedUrl();
  }

  Future<void> initializeVpn() async {
    try {
      await flutterVless.initializeVless(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
        providerBundleIdentifier: 'com.example.light_speed',
        groupIdentifier: 'group.com.example.light_speed',
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        message = 'راه‌اندازی VPN ناموفق بود';
      });
    }
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

      if (!mounted) return;

      setState(() {
        configs = result;
        loading = false;
        message = '${configs.length} کانفیگ پیدا شد';
      });

      await testAllServers();
    } catch (e) {
      if (!mounted) return;

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

    var current = body.trim();

    for (var i = 0; i < 5; i++) {
      try {
        var normalized =
            current.replaceAll(RegExp(r'\s+'), '');

        normalized +=
            '=' * ((4 - normalized.length % 4) % 4);

        final decoded = utf8.decode(
          base64.decode(normalized),
          allowMalformed: true,
        );

        if (decoded.trim() == current.trim()) {
          break;
        }

        current = decoded.trim();

        final result = current
            .split(RegExp(r'\r?\n'))
            .map((e) => e.trim())
            .where(
              (e) =>
                  e.isNotEmpty &&
                  e.contains('://'),
            )
            .toList();

        if (result.isNotEmpty) {
          return result;
        }
      } catch (_) {
        break;
      }
    }

    return [];
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
        'hysteria',
        'hysteria2',
        'hy2',
      ];

      if (!supported.contains(scheme)) {
        return null;
      }

      FlutterVlessURL? profile;

      try {
        profile = FlutterVless.parse(value);
      } catch (_) {
        profile = null;
      }

      return Config(
        raw: value,
        type: scheme.toUpperCase(),
        address: uri.host,
        port: uri.hasPort ? uri.port : null,
        profile: profile,
      );
    } catch (_) {
      return null;
    }
  }

  Future<int?> testServer(
    Config config,
  ) async {
    final profile = config.profile;

    if (profile == null) {
      return null;
    }

    try {
      final delay = await flutterVless
          .getServerDelay(
            config: profile.getFullConfiguration(),
          )
          .timeout(
            const Duration(seconds: 10),
          );

      return delay > 0 ? delay : null;
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
      final result = await testServer(config);

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

    if (!mounted) return;

    setState(() {
      testing = false;
      message = 'سرورها بر اساس Ping مرتب شدند';
    });
  }

  Config? getBestServer() {
    final valid = configs
        .where(
          (config) =>
              config.ping != null &&
              config.profile != null,
        )
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

  Future<void> connectVpn() async {
    final best = getBestServer();

    if (best == null ||
        best.profile == null) {
      setState(() {
        message =
            'ابتدا Subscription را دریافت و سرورها را تست کن';
      });
      return;
    }

    try {
      setState(() {
        message = 'در حال درخواست اجازه VPN...';
      });

      final permission =
          await flutterVless.requestPermission();

      if (!permission) {
        if (!mounted) return;

        setState(() {
          message = 'اجازه VPN داده نشد';
        });

        return;
      }

      if (!mounted) return;

      setState(() {
        message =
            'در حال اتصال به ${best.address}...';
      });

      await flutterVless.startVless(
        remark: '${best.type} ${best.address}',
        config: best.profile!.getFullConfiguration(),
        proxyOnly: false,
        notificationDisconnectButtonName:
            'DISCONNECT',
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        message = 'اتصال VPN ناموفق بود';
      });
    }
  }

  Future<void> disconnectVpn() async {
    try {
      await flutterVless.stopVless();

      if (!mounted) return;

      setState(() {
        message = 'VPN قطع شد';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        message = 'قطع VPN ناموفق بود';
      });
    }
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

    final connected =
        vpnStatus?.connectionState ==
            VlessConnectionState.connected;

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

              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: configs.isEmpty
                      ? null
                      : connected
                          ? disconnectVpn
                          : connectVpn,
                  icon: Icon(
                    connected
                        ? Icons.stop
                        : Icons.power_settings_new,
                  ),
                  label: Text(
                    connected
                        ? 'قطع VPN'
                        : 'اتصال VPN',
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
