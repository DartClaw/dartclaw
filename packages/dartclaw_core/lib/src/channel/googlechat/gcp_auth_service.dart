import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

class GcpAuthService {
  final String _clientEmail;
  final String _privateKey;
  final List<String> scopes;
  final http.Client? httpClient;

  GcpAuthService({required String serviceAccountJson, required List<String> scopes, http.Client? httpClient})
    : this._parsed(
        parsedServiceAccount: _parseServiceAccount(serviceAccountJson),
        scopes: scopes,
        httpClient: httpClient,
      );

  GcpAuthService._parsed({
    required _ParsedServiceAccount parsedServiceAccount,
    required this.scopes,
    required this.httpClient,
  }) : _clientEmail = parsedServiceAccount.clientEmail,
       _privateKey = parsedServiceAccount.privateKey;

  Future<AutoRefreshingAuthClient> initialize() async {
    try {
      final credentials = ServiceAccountCredentials(
        _clientEmail,
        ClientId.serviceAccount('service-account'),
        _privateKey,
      );
      return clientViaServiceAccount(credentials, scopes, baseClient: httpClient);
    } catch (error) {
      throw StateError('Failed to initialize GCP auth client: $error');
    }
  }

  static String? resolveCredentialJson({String? configValue, Map<String, String>? env}) {
    final environment = env ?? Platform.environment;
    final normalized = configValue?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      if (normalized.startsWith('{')) {
        return normalized;
      }
      final fromConfigPath = _readFileIfExists(normalized);
      if (fromConfigPath != null) {
        return fromConfigPath;
      }
    }

    final envPath = environment['GOOGLE_APPLICATION_CREDENTIALS']?.trim();
    if (envPath == null || envPath.isEmpty) {
      return null;
    }
    return _readFileIfExists(envPath);
  }

  static Future<String?> resolveCredentialJsonAsync({
    String? configValue,
    Map<String, String>? env,
    Future<String?> Function(String path)? fileReader,
  }) async {
    final environment = env ?? Platform.environment;
    final normalized = configValue?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      if (normalized.startsWith('{')) {
        return normalized;
      }
      final fromConfigPath = fileReader != null ? await fileReader(normalized) : _readFileIfExists(normalized);
      if (fromConfigPath != null) {
        return fromConfigPath;
      }
    }

    final envPath = environment['GOOGLE_APPLICATION_CREDENTIALS']?.trim();
    if (envPath == null || envPath.isEmpty) {
      return null;
    }
    return fileReader != null ? await fileReader(envPath) : _readFileIfExists(envPath);
  }

  static String? _readFileIfExists(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    return file.readAsStringSync();
  }

  static _ParsedServiceAccount _parseServiceAccount(String serviceAccountJson) {
    try {
      final decoded = jsonDecode(serviceAccountJson);
      if (decoded is! Map) {
        throw const FormatException('Service account JSON must decode to an object');
      }

      final type = decoded['type'];
      if (type != 'service_account') {
        throw ArgumentError('The given credentials are not of type service_account (was: $type).');
      }

      String readRequiredField(String name) {
        final value = decoded[name];
        if (value is! String || value.trim().isEmpty) {
          throw ArgumentError('The given credentials do not contain the required field: $name.');
        }
        return value.trim();
      }

      return _ParsedServiceAccount(
        clientEmail: readRequiredField('client_email'),
        privateKey: readRequiredField('private_key'),
      );
    } catch (error) {
      throw StateError('Failed to parse GCP service account credentials: $error');
    }
  }
}

class _ParsedServiceAccount {
  final String clientEmail;
  final String privateKey;

  const _ParsedServiceAccount({required this.clientEmail, required this.privateKey});
}
