import 'dart:io';

import 'package:yaml/yaml.dart';

import '../sip/sip_config.dart';

class AuthConfig {
  AuthConfig({
    required this.appId,
    required this.appSecret,
    required this.tokenTtl,
    required this.renewTtl,
  });

  final String appId;
  final String appSecret;
  final Duration tokenTtl;
  final Duration renewTtl;
}

class AsteriskConfig {
  AsteriskConfig({
    required this.ariUrl,
    required this.ariUser,
    required this.ariPassword,
    required this.wsSipUrl,
    required this.sipDomain,
  });

  final String ariUrl;
  final String ariUser;
  final String ariPassword;
  final String wsSipUrl;
  final String sipDomain;
}

class TlsConfig {
  const TlsConfig({
    this.enabled = true,
    this.autoGenerate = true,
    this.hstsMaxAge = 15552000, // 180 days
    this.hstsIncludeSubdomains = true,
  });

  final bool enabled;
  final bool autoGenerate;
  final int hstsMaxAge;
  final bool hstsIncludeSubdomains;

  String get hstsHeader {
    final buf = StringBuffer('max-age=$hstsMaxAge');
    if (hstsIncludeSubdomains) buf.write('; includeSubDomains');
    return buf.toString();
  }
}

class LogsConfig {
  const LogsConfig({this.format = 'json'});
  final String format; // 'json' | 'text'
  bool get isJson => format == 'json';
}

class MetricsConfig {
  const MetricsConfig({this.enabled = true, this.path = '/metrics'});
  final bool enabled;
  final String path;
}

/// SASL ANONYMOUS (RFC 4505) guest access. When [enabled], the XMPP
/// stream advertises the ANONYMOUS mechanism and mints an ephemeral JID
/// on [host] (falls back to the server domain when null).
class AnonymousConfig {
  const AnonymousConfig({this.enabled = false, this.host});
  final bool enabled;
  final String? host;
}

/// XEP-0363 HTTP File Upload. [maxFileSizeBytes] is advertised in the
/// upload service's disco#info data form and enforced on slot requests.
class HttpUploadConfig {
  const HttpUploadConfig({
    this.enabled = true,
    this.maxFileSizeBytes = 10485760, // 10 MiB
  });
  final bool enabled;
  final int maxFileSizeBytes;
}

class Config {
  Config({
    required this.host,
    required this.port,
    required this.publicHost,
    required this.tlsCertPath,
    required this.tlsKeyPath,
    required this.dbPath,
    required this.fileStorePath,
    required this.avatarStorePath,
    required this.auth,
    required this.asterisk,
    this.tls = const TlsConfig(),
    this.logs = const LogsConfig(),
    this.metrics = const MetricsConfig(),
    this.anonymous = const AnonymousConfig(),
    this.httpUpload = const HttpUploadConfig(),
    this.sip = SipConfig.disabled,
  });

  final String host;
  final int port;
  final String publicHost;
  final String tlsCertPath;
  final String tlsKeyPath;
  final String dbPath;
  final String fileStorePath;
  final String avatarStorePath;
  final AuthConfig auth;
  final AsteriskConfig asterisk;
  final TlsConfig tls;
  final LogsConfig logs;
  final MetricsConfig metrics;
  final AnonymousConfig anonymous;
  final HttpUploadConfig httpUpload;
  final SipConfig sip;

  /// XMPP domain the server presents to clients.
  String get xmppDomain => publicHost;

  /// Absolute base URL clients use to reach this server over HTTP(S).
  /// Used to build XEP-0363 PUT/GET slot URLs.
  String get publicBaseUrl {
    final scheme = tls.enabled ? 'https' : 'http';
    return '$scheme://$publicHost:$port';
  }

  static Future<Config> load(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('Config file not found: $path');
    }
    final raw = loadYaml(await file.readAsString()) as YamlMap;
    final auth = raw['auth'] as YamlMap;
    final ast = raw['asterisk'] as YamlMap;
    final tlsMap = raw['tls'] as YamlMap?;
    final logsMap = raw['logs'] as YamlMap?;
    final metricsMap = raw['metrics'] as YamlMap?;
    final anonMap = raw['anonymous'] as YamlMap?;
    final uploadMap = raw['httpUpload'] as YamlMap?;
    final sipMap = raw['sip'] as YamlMap?;
    return Config(
      host: raw['host'] as String,
      port: raw['port'] as int,
      publicHost: raw['publicHost'] as String,
      tlsCertPath: raw['tlsCertPath'] as String,
      tlsKeyPath: raw['tlsKeyPath'] as String,
      dbPath: raw['dbPath'] as String,
      fileStorePath: raw['fileStorePath'] as String,
      avatarStorePath: raw['avatarStorePath'] as String,
      auth: AuthConfig(
        appId: auth['appId'] as String,
        appSecret: auth['appSecret'] as String,
        tokenTtl: Duration(seconds: auth['tokenTtlSeconds'] as int),
        renewTtl: Duration(seconds: auth['renewTtlSeconds'] as int),
      ),
      asterisk: AsteriskConfig(
        ariUrl: ast['ariUrl'] as String,
        ariUser: ast['ariUser'] as String,
        ariPassword: ast['ariPassword'] as String,
        wsSipUrl: ast['wsSipUrl'] as String,
        sipDomain: ast['sipDomain'] as String,
      ),
      tls: tlsMap == null
          ? const TlsConfig()
          : TlsConfig(
              enabled: tlsMap['enabled'] as bool? ?? true,
              autoGenerate: tlsMap['autoGenerate'] as bool? ?? true,
              hstsMaxAge: tlsMap['hstsMaxAge'] as int? ?? 15552000,
              hstsIncludeSubdomains:
                  tlsMap['hstsIncludeSubdomains'] as bool? ?? true,
            ),
      logs: logsMap == null
          ? const LogsConfig()
          : LogsConfig(format: logsMap['format'] as String? ?? 'json'),
      metrics: metricsMap == null
          ? const MetricsConfig()
          : MetricsConfig(
              enabled: metricsMap['enabled'] as bool? ?? true,
              path: metricsMap['path'] as String? ?? '/metrics',
            ),
      anonymous: anonMap == null
          ? const AnonymousConfig()
          : AnonymousConfig(
              enabled: anonMap['enabled'] as bool? ?? false,
              host: anonMap['host'] as String?,
            ),
      httpUpload: uploadMap == null
          ? const HttpUploadConfig()
          : HttpUploadConfig(
              enabled: uploadMap['enabled'] as bool? ?? true,
              maxFileSizeBytes:
                  uploadMap['maxFileSizeBytes'] as int? ?? 10485760,
            ),
      sip: sipMap == null ? SipConfig.disabled : _parseSip(sipMap),
    );
  }
}

SipConfig _parseSip(YamlMap m) {
  final bind = m['bind'] as YamlMap?;
  final outbound = m['outboundProxy'] as YamlMap?;
  final anchor = m['mediaAnchor'] as YamlMap?;
  final rawDids = m['dids'] as YamlMap?;
  final dids = <String, String>{};
  if (rawDids != null) {
    for (final e in rawDids.entries) {
      dids[e.key.toString()] = e.value.toString();
    }
  }
  return SipConfig(
    enabled: m['enabled'] as bool? ?? false,
    domain: m['domain'] as String? ?? 'sip.invalid',
    bindAddress: bind?['address'] as String? ?? '0.0.0.0',
    bindPort: bind?['port'] as int? ?? 5060,
    outboundProxyHost: outbound?['host'] as String? ?? '127.0.0.1',
    outboundProxyPort: outbound?['port'] as int? ?? 5060,
    localContactUri:
        m['localContactUri'] as String? ?? 'sip:b2bua@127.0.0.1:5060',
    b2buaFromUri: m['b2buaFromUri'] as String? ?? 'sip:rainbow-stub@localhost',
    mediaAnchor: anchor == null
        ? null
        : MediaAnchorConfig(
            baseUri: anchor['baseUri'] as String,
            authToken: anchor['authToken'] as String?,
          ),
    dids: dids,
    inboundRingTimeout: Duration(
      seconds: m['inboundRingTimeoutSeconds'] as int? ?? 45,
    ),
  );
}
