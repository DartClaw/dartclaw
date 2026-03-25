import 'package:meta/meta.dart';

enum CanvasPermission {
  view,
  interact;

  static CanvasPermission? fromName(String? raw) {
    if (raw == null) return null;
    final normalized = raw.trim().toLowerCase();
    return switch (normalized) {
      'view' => CanvasPermission.view,
      'interact' => CanvasPermission.interact,
      _ => null,
    };
  }
}

@immutable
class CanvasShareToken {
  final String token;
  final String sessionKey;
  final CanvasPermission permission;
  final DateTime expiresAt;
  final String? label;

  const CanvasShareToken({
    required this.token,
    required this.sessionKey,
    required this.permission,
    required this.expiresAt,
    this.label,
  });

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  CanvasShareToken copyWith({
    String? token,
    String? sessionKey,
    CanvasPermission? permission,
    DateTime? expiresAt,
    String? label,
    bool clearLabel = false,
  }) {
    return CanvasShareToken(
      token: token ?? this.token,
      sessionKey: sessionKey ?? this.sessionKey,
      permission: permission ?? this.permission,
      expiresAt: expiresAt ?? this.expiresAt,
      label: clearLabel ? null : (label ?? this.label),
    );
  }

  Map<String, dynamic> toJson() => {
    'token': token,
    'sessionKey': sessionKey,
    'permission': permission.name,
    'expiresAt': expiresAt.toIso8601String(),
    if (label != null) 'label': label,
  };

  factory CanvasShareToken.fromJson(Map<String, dynamic> json) {
    final permission = CanvasPermission.fromName(json['permission'] as String?);
    if (permission == null) {
      throw FormatException('Invalid canvas token permission: ${json['permission']}');
    }
    final expiresAtRaw = json['expiresAt'] as String?;
    final expiresAt = expiresAtRaw == null ? null : DateTime.tryParse(expiresAtRaw);
    if (expiresAt == null) {
      throw const FormatException('Invalid canvas token expiresAt');
    }
    final token = json['token'] as String?;
    final sessionKey = json['sessionKey'] as String?;
    if (token == null || token.isEmpty || sessionKey == null || sessionKey.isEmpty) {
      throw const FormatException('Invalid canvas token payload');
    }
    return CanvasShareToken(
      token: token,
      sessionKey: sessionKey,
      permission: permission,
      expiresAt: expiresAt,
      label: json['label'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasShareToken &&
          runtimeType == other.runtimeType &&
          token == other.token &&
          sessionKey == other.sessionKey &&
          permission == other.permission &&
          expiresAt == other.expiresAt &&
          label == other.label;

  @override
  int get hashCode => Object.hash(token, sessionKey, permission, expiresAt, label);

  @override
  String toString() {
    final masked = token.length > 4 ? '...${token.substring(token.length - 4)}' : '***';
    return 'CanvasShareToken(token: $masked, sessionKey: $sessionKey, permission: ${permission.name}, '
        'expiresAt: $expiresAt, label: $label)';
  }
}

@immutable
class CanvasState {
  final String? currentHtml;
  final bool visible;
  final List<CanvasShareToken> activeTokens;

  const CanvasState({this.currentHtml, this.visible = false, this.activeTokens = const []});

  bool get hasContent => currentHtml != null && currentHtml!.trim().isNotEmpty;

  CanvasState copyWith({
    String? currentHtml,
    bool clearCurrentHtml = false,
    bool? visible,
    List<CanvasShareToken>? activeTokens,
  }) {
    return CanvasState(
      currentHtml: clearCurrentHtml ? null : (currentHtml ?? this.currentHtml),
      visible: visible ?? this.visible,
      activeTokens: activeTokens ?? this.activeTokens,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasState &&
          runtimeType == other.runtimeType &&
          currentHtml == other.currentHtml &&
          visible == other.visible &&
          _listEquals(activeTokens, other.activeTokens);

  @override
  int get hashCode => Object.hash(currentHtml, visible, Object.hashAll(activeTokens));

  @override
  String toString() =>
      'CanvasState(currentHtml: ${currentHtml != null ? '<set>' : '<null>'}, visible: $visible, '
      'activeTokens: ${activeTokens.length})';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
