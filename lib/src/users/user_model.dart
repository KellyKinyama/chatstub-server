import 'dart:convert';

/// Domain model for a Rainbow user. Serialized to the exact JSON shape
/// the native `react-native-rainbow-module` SDK expects (subset).
class User {
  User({
    required this.id,
    required this.loginEmail,
    this.firstName,
    this.lastName,
    this.nickName,
    this.title,
    this.jobTitle,
    this.companyId,
    this.language = 'en',
    this.isActive = true,
    this.isInitialized = true,
    this.emailVerified = true,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String loginEmail;
  final String? firstName;
  final String? lastName;
  final String? nickName;
  final String? title;
  final String? jobTitle;
  final String? companyId;
  final String language;
  final bool isActive;
  final bool isInitialized;
  final bool emailVerified;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get displayName {
    final f = firstName?.trim() ?? '';
    final l = lastName?.trim() ?? '';
    final joined = '$f $l'.trim();
    return joined.isEmpty ? loginEmail : joined;
  }

  Map<String, dynamic> toRainbowJson({
    Map<String, dynamic>? presence,
    bool hasAvatar = false,
  }) => {
    'id': id,
    'loginEmail': loginEmail,
    'firstName': firstName,
    'lastName': lastName,
    'nickName': nickName,
    'displayName': displayName,
    'title': title,
    'jobTitle': jobTitle,
    'companyId': companyId,
    'language': language,
    'isActive': isActive,
    'isInitialized': isInitialized,
    'emailVerified': emailVerified,
    'creationDate': createdAt.toUtc().toIso8601String(),
    'lastUpdateDate': updatedAt.toUtc().toIso8601String(),
    // Fields the SDK reads defensively — return empty defaults.
    'emails': const <Map<String, dynamic>>[],
    'phoneNumbers': const <Map<String, dynamic>>[],
    'roles': const ['user'],
    'adminType': 'undefined',
    'accountType': 'free',
    'presence': presence ?? const {'show': 'offline', 'status': null},
    'lastAvatarUpdateDate': hasAvatar
        ? updatedAt.toUtc().toIso8601String()
        : null,
  };

  @override
  String toString() => jsonEncode(toRainbowJson());
}
