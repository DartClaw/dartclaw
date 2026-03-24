import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _kid = 'kid-1';
const _jwkResponse =
    '{"keys":[{"kty":"RSA","kid":"kid-1","use":"sig","alg":"RS256",'
    '"n":"qFxkNfusfX5waaKbgl3PQYDzqAgiwKQthMnGHSPVrB4axj-ycHl21RaGu-frDjn0Ww0B-_4gwi8s5l-T2uAPWkJsmhDOZ-aVDs0jQW-gxOpYiLY5s1Q__f3ByUGcwCS-e6vmxMtdLx1VcjXIRfTJCz30UPCE_ph_-YgroURQ-8thQx5RCVlgyXzObca-aDN17TxAJlgWSYGdWtygCcGM5SYiM_7Cj1LGpCKAfxruUL3eJcya8iKIJBlVhrBiwL3ZEfgdDrvUpdyMDF4OGoGM6LO9Hd-9T45IweR0ELvMwolPllUe-81S-6K4ekqw1mvgJ8-YEe5SgLwaRUThBRpx2Q",'
    '"e":"AQAB"}]}';
const _privateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCoXGQ1+6x9fnBp
opuCXc9BgPOoCCLApC2EycYdI9WsHhrGP7JweXbVFoa75+sOOfRbDQH7/iDCLyzm
X5Pa4A9aQmyaEM5n5pUOzSNBb6DE6liItjmzVD/9/cHJQZzAJL57q+bEy10vHVVy
NchF9MkLPfRQ8IT+mH/5iCuhRFD7y2FDHlEJWWDJfM5txr5oM3XtPEAmWBZJgZ1a
3KAJwYzlJiIz/sKPUsakIoB/Gu5Qvd4lzJryIogkGVWGsGLAvdkR+B0Ou9Sl3IwM
Xg4agYzos70d371PjkjB5HQQu8zCiU+WVR77zVL7orh6SrDWa+Anz5gR7lKAvBpF
ROEFGnHZAgMBAAECggEACXdwdwyYrVG/tmDbR6BIuBEtIiSa96QDnzTNO/Q43n2u
2bjZKrPZt6+Vkdk/gURG9husIeQvKVwHtUhoguUYV+XmP190i6kOdo+YTOSe8JOQ
uNcuNWQmWPy8ublDvBYU09Vdm3En4y9OD6bwhOZ3q3cnVqm/gKVIhNpgQagauZ2l
lMETW9X3hnibeSNmJ1zbjbIERESOPWSV19c7FRUawbKQwurPyrJTFgum/f6hni9k
MfnytUzZx9W3eo13sQUO0B7QQmlubS1Jh/KhuNS0I2JsCCghsLK6oys5AL+sNeu2
NCiCppkjH66IelEJTnwiKrQcIlWgplzt4z8LDlUBgQKBgQDXMY7jbC6tfyQsWv9W
BKolFwM1D0IvdNwTuPxC8EWEy/cGUUCUPQ1zpWZmJYN7BvC3keh87CzJWDr1Cmha
DCQjWkJasvlB3pMcz3FKCPPHYSPYq189dec7Afk8y9w251cNHc0hHy5eE3iRWBuw
Cu+YOfcur5r2yhAqQPYBscMFqQKBgQDISV6DS4QVj6s83z2OrwzmOup5daXPWmPf
DUXvc+wrMeSsfY215KNDi/y1S2BRQqUttShcCyGlLvgPL5bdzuC4e+vrifrJVxyB
1v/2eOWVujyjLIiRk7xbojHs3iYIGDJ1nEJTX3MAPkNKS9SUCWxB5X1Yv+tcjEES
8s5mWcxIsQKBgDjEEfVcLFQIHfq1ZnXCdT+jem0cwVDTetqZCbJ+v1fwlhFMjcSM
9mdzUjfP3YcupYFHNBUAGDBk3eiV/kECwuWwgaB7ZdVCaXxIHJJzGhuWPGaDjnQg
Dgc61gx7mnPBQu1q1xnNp+WZLUzp+SPPPrThVZszJ6XCV9FNoZeA1PlBAoGBALVv
yZ+1BDWoDZ66OQCN0WirTIe1LPzXTIvecVFHOVW0AAzGPF7ffYsOQGJXoyxZ7Fqo
tqQTLWp/TxYqrUfIRki5cfHQ8A/+ywNQKlY0FP77VD0ZdaozJDn6h7GlWNySVvu2
D1uJpxs8TCb85NkqZBiZ9WA1k9gl8jlhHdsYU/gxAoGABOnBxb5gOW2cswiGC1SE
5uzZdOQAfmbUOPbM/6LIcqv30uoTQvp5ogMBKcl8loYbnmpt1/SYwRxBbsJJisPA
ziYQGAGUXYeBjycSuJriTb3YSZ8ZUnnCQ1SZ8YOWYxO1DSzIOQV0Q3L02cnHEMfs
/enQZOL5KRzXzPNF0PPnyQs=
-----END PRIVATE KEY-----
''';
const _certificatePem = '''
-----BEGIN CERTIFICATE-----
MIIDFzCCAf+gAwIBAgIUX6Hj0pjyfJHZTy+olEpLAGJwhCMwDQYJKoZIhvcNAQEL
BQAwGzEZMBcGA1UEAwwQZ29vZ2xlLWNoYXQtdGVzdDAeFw0yNjAzMDkyMzMxMjVa
Fw0yNzAzMDkyMzMxMjVaMBsxGTAXBgNVBAMMEGdvb2dsZS1jaGF0LXRlc3QwggEi
MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCoXGQ1+6x9fnBpopuCXc9BgPOo
CCLApC2EycYdI9WsHhrGP7JweXbVFoa75+sOOfRbDQH7/iDCLyzmX5Pa4A9aQmya
EM5n5pUOzSNBb6DE6liItjmzVD/9/cHJQZzAJL57q+bEy10vHVVyNchF9MkLPfRQ
8IT+mH/5iCuhRFD7y2FDHlEJWWDJfM5txr5oM3XtPEAmWBZJgZ1a3KAJwYzlJiIz
/sKPUsakIoB/Gu5Qvd4lzJryIogkGVWGsGLAvdkR+B0Ou9Sl3IwMXg4agYzos70d
371PjkjB5HQQu8zCiU+WVR77zVL7orh6SrDWa+Anz5gR7lKAvBpFROEFGnHZAgMB
AAGjUzBRMB0GA1UdDgQWBBS/S5IIGoZTJjG+IPGf8xKfmEyrzDAfBgNVHSMEGDAW
gBS/S5IIGoZTJjG+IPGf8xKfmEyrzDAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3
DQEBCwUAA4IBAQB0wLo2x4AitwPSc1jqea3B1oLN22RpETxvb0y8wCrLcTqzVQJC
1lqGMkGpgcRmApJwxG+4AIhJWOjjI2SAm6bMfjLmy0/xVrGesHH6/wYvxwq4uPVZ
TOenVQyQVUhQI8+b5cNXPHux4MVPAyYdwx2W+UcEAt8XW+rgE8zmrwfJ9LeD9yKJ
WG5F8ye5ntuR/ClgvCNDAsYDzg7lONDa/YUR1McEzfgHIIwJYcOjzPFrnrggm7AC
dkHJEoGnugkZqukjBgiXoddbL5CYEKdGe2vRhRAeVfQBVBuIDdy8WYyPQbIaLhGd
3tZkIU2sG84iAkbqlaotl8DYlu85Qe9t52QL
-----END CERTIFICATE-----
''';
const _otherPrivateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDZaYKn/TzNmQUH
CslL0gX9mZS6xTJ1dkMy8pk5G0aoXPbAwAC34E9IKzhSmNICGIKjQb46am8Dqf9m
T+c4+nEWzyDYYbPJFuUoH9aP4hbduv4JAdD4hONUwKHERizvLy430XyhkD1UrruX
8KADrE1T+JIV60aKxt8ZxKvxEkR/DX7XRhQV5d4Axb/asolN8hbcemiT0fyDzXfn
yv/XXoRHlXothGNRn9gCfMV7CLC8o7xZJrCsW2V0u+dsJrDhQtZ3d5ddo3ijDldk
57ZgK+Vth60VwwV5dTui0HR8nBixZXqWGyVp0BBFFEzJJzP+QsG86lHwQyz5Lugg
nEV921JFAgMBAAECggEAUr7sgmFIdfuqRS7exCOwMf/08kzBUqFrHAXnOSvfbY7M
PzoUS+dsZUxFyHHvY+rONbJ84yDFFcDqupboqu/ugL7eglxVH9C98NKFSAfFqihU
LTtqvFtfZk9WgiwvR+1OCuKJK7iJDyTdswta62r1l2MAvqToGUNtgBIxWrQYK75U
ekdkgJUi8OngnsBObLmfLN2Nvy1KrXscLLDaWMYECJ+xTCvPZrQzku3bLsO4uecd
dLWcZoWa2ewXWmeMOCOumUXeFdphYX7BfZWluyB5Kunrl0QMSW2eYfc2hAYqZVqY
AiGjiNEU60uHhKPjSSoyD5l4gPY4mP86uz+UJDtNlQKBgQD0U6kl3+uoRv8KjFhv
RQswEQnMx27zfO/3zzhtBpv3GgWUtY4lxqT03kS9sysXzaiaHchlKvux51gkm2t5
FAWBbxLOzE94HFKQnEZEew+FlYZBySzE61H4Re75fvnMRAgHOhIBLVjFJ5nXAn9H
xpUxnwokKUAaBi82rB/Fvw28owKBgQDjzKix0j3J+uD6ID/gfND63WnznWPt/s+G
cNkIBv+RwlfZRu64wo93uTAN+TPoVcVEiLPO98haeymYcWVGr9YAwA1tkKK9jxOE
uZfljjgCvZDtVaSYQEfSxG6wivGZer+lqct7gvA9c2DgFSLRQ+gyCMIoRZKkmuuJ
5R0bYah79wKBgQC52DEfaBXeqDIzGdHiwUfjRfKIW2KfvvbhLjQjahWUfaylEvyO
62xp/e+XxAMRVhPbNrBJk8pj5i77mWTEcmBFtfE+b9Y67IA5E0W3rUt/Nt8qhxWQ
q9Zr3PYLvXPQ1iatKJStZIrTXG3+SB38wKaXWfviyaXCpdWf5ok8ZzjRtQKBgHCX
TynUyEV0go4eMnQ6PPBBT4ThXerb7qZ8UEjvbJIWhGUX8hXP1ClQlrfRXB6RhhcB
mh3JynUuOrjmEzCE6Dkms3xb6JPYi8UmFjWXvYddOqyTj+7Qlq9N94e6pP8+9Epl
SfWaGjPFOzSGPddAwRs5yP0upfRFvfVCEMjf0+6xAoGBAO89PQn7Ejpy6UrOnrv9
vRfvrjv9sjbFVIgDLPm/m9SsqOuOY4HH853gYm6CkeS/Kp7Laazk5UL/zjpMO9sH
8HxUmxN9JyAc00jKg+W1dYjC6FwJGKQeh21D70oPlSbrifGXTgMYjMqhfzVkYdc7
XuvEp37vMYPgdk+bNV5iOQUi
-----END PRIVATE KEY-----
''';

void main() {
  group('GoogleJwtVerifier.verify', () {
    test('valid JWT with correct claims returns true', () async {
      final verifier = _buildVerifier();
      final token = _signToken(audience: 'https://example.com/integrations/googlechat');

      final valid = await verifier.verify('Bearer $token');

      expect(valid, isTrue);
    });

    test('missing Authorization header returns false', () async {
      final verifier = _buildVerifier();
      expect(await verifier.verify(null), isFalse);
    });

    test('non-Bearer header returns false', () async {
      final verifier = _buildVerifier();
      expect(await verifier.verify('Basic abc'), isFalse);
    });

    test('expired JWT returns false', () async {
      final verifier = _buildVerifier();
      final token = _signToken(
        audience: 'https://example.com/integrations/googlechat',
        expiresAt: DateTime.utc(2025, 3, 9, 12),
      );
      expect(await verifier.verify('Bearer $token'), isFalse);
    });

    test('wrong issuer returns false', () async {
      final verifier = _buildVerifier();
      final token = _signToken(audience: 'https://example.com/integrations/googlechat', issuer: 'wrong@example.com');
      expect(await verifier.verify('Bearer $token'), isFalse);
    });

    test('OIDC token with accounts.google.com issuer returns true', () async {
      final verifier = _buildVerifier();
      final token = _signToken(
        audience: 'https://example.com/integrations/googlechat',
        issuer: GoogleJwtVerifier.oidcIssuer,
        email: null,
        emailVerified: null,
      );
      expect(await verifier.verify('Bearer $token'), isTrue);
    });

    test('wrong audience returns false', () async {
      final verifier = _buildVerifier();
      final token = _signToken(audience: 'https://wrong.example.com/webhook');
      expect(await verifier.verify('Bearer $token'), isFalse);
    });

    test('unknown kid returns false', () async {
      final verifier = _buildVerifier();
      final token = _signToken(audience: 'https://example.com/integrations/googlechat', kid: 'missing-kid');
      expect(await verifier.verify('Bearer $token'), isFalse);
    });

    test('invalid signature returns false', () async {
      final verifier = _buildVerifier();
      final token = _signToken(
        audience: 'https://example.com/integrations/googlechat',
        privateKeyPem: _otherPrivateKeyPem,
      );
      expect(await verifier.verify('Bearer $token'), isFalse);
    });
  });

  group('GoogleJwtVerifier certificate caching', () {
    test('caches certs for TTL duration', () async {
      var now = DateTime.utc(2026, 3, 10, 0, 0, 0);
      var requests = 0;
      final verifier = _buildVerifier(
        cacheTtl: const Duration(minutes: 10),
        now: () => now,
        httpClient: MockClient((request) async {
          requests++;
          return http.Response(jsonEncode({_kid: _certificatePem}), 200);
        }),
      );
      final token = _signToken(audience: 'https://example.com/integrations/googlechat');

      expect(await verifier.verify('Bearer $token'), isTrue);
      now = now.add(const Duration(minutes: 5));
      expect(await verifier.verify('Bearer $token'), isTrue);
      expect(requests, 1);
    });

    test('refreshes certs after TTL expires', () async {
      var now = DateTime.utc(2026, 3, 10, 0, 0, 0);
      var requests = 0;
      final verifier = _buildVerifier(
        cacheTtl: const Duration(minutes: 10),
        now: () => now,
        httpClient: MockClient((request) async {
          requests++;
          return http.Response(jsonEncode({_kid: _certificatePem}), 200);
        }),
      );
      final token = _signToken(audience: 'https://example.com/integrations/googlechat');

      expect(await verifier.verify('Bearer $token'), isTrue);
      now = now.add(const Duration(minutes: 11));
      expect(await verifier.verify('Bearer $token'), isTrue);
      expect(requests, 2);
    });

    test('invalidateCache clears cache', () async {
      var requests = 0;
      final verifier = _buildVerifier(
        httpClient: MockClient((request) async {
          requests++;
          return http.Response(jsonEncode({_kid: _certificatePem}), 200);
        }),
      );
      final token = _signToken(audience: 'https://example.com/integrations/googlechat');

      expect(await verifier.verify('Bearer $token'), isTrue);
      verifier.invalidateCache();
      expect(await verifier.verify('Bearer $token'), isTrue);
      expect(requests, 2);
    });
  });

  group('GoogleJwtVerifier audience modes', () {
    test('app-url mode fetches certs from oauth certs endpoint', () async {
      Uri? requestedUrl;
      final verifier = _buildVerifier(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
        httpClient: MockClient((request) async {
          requestedUrl = request.url;
          return http.Response(jsonEncode({_kid: _certificatePem}), 200);
        }),
      );

      final token = _signToken(audience: 'https://example.com/integrations/googlechat');

      expect(await verifier.verify('Bearer $token'), isTrue);
      expect(requestedUrl, GoogleJwtVerifier.googleCertsUrl);
    });

    test('app-url mode validates against URL', () async {
      final verifier = _buildVerifier(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
      );
      final token = _signToken(audience: 'https://example.com/integrations/googlechat');
      expect(await verifier.verify('Bearer $token'), isTrue);
    });

    test('app-url mode requires Google Chat email claim', () async {
      final verifier = _buildVerifier(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
      );
      final token = _signToken(audience: 'https://example.com/integrations/googlechat', email: 'wrong@example.com');

      expect(await verifier.verify('Bearer $token'), isFalse);
    });

    test('app-url mode requires email_verified claim', () async {
      final verifier = _buildVerifier(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
      );
      final token = _signToken(audience: 'https://example.com/integrations/googlechat', emailVerified: false);

      expect(await verifier.verify('Bearer $token'), isFalse);
    });

    test('project-number mode does not require OIDC email claims', () async {
      final verifier = _buildVerifier(
        audience: const GoogleChatAudienceConfig(mode: GoogleChatAudienceMode.projectNumber, value: '123456789'),
      );
      final token = _signToken(audience: '123456789', email: null, emailVerified: null);
      expect(await verifier.verify('Bearer $token'), isTrue);
    });

    test('OIDC token in app-url mode skips email claim check', () async {
      final verifier = _buildVerifier(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
      );
      final token = _signToken(
        audience: 'https://example.com/integrations/googlechat',
        issuer: GoogleJwtVerifier.oidcIssuer,
        email: null,
        emailVerified: null,
      );
      expect(await verifier.verify('Bearer $token'), isTrue);
    });

    test('OIDC token fetches certs from v3 endpoint and parses JWK', () async {
      Uri? requestedUrl;
      final verifier = _buildVerifier(
        httpClient: MockClient((request) async {
          requestedUrl = request.url;
          // v3 endpoint returns JWK format, not PEM
          return http.Response(_jwkResponse, 200);
        }),
      );
      final token = _signToken(
        audience: 'https://example.com/integrations/googlechat',
        issuer: GoogleJwtVerifier.oidcIssuer,
        email: null,
        emailVerified: null,
      );

      expect(await verifier.verify('Bearer $token'), isTrue);
      expect(requestedUrl, GoogleJwtVerifier.googleOidcCertsUrl);
    });

    test('project-number mode fetches certs from chat service account metadata endpoint', () async {
      Uri? requestedUrl;
      final verifier = _buildVerifier(
        audience: const GoogleChatAudienceConfig(mode: GoogleChatAudienceMode.projectNumber, value: '123456789'),
        httpClient: MockClient((request) async {
          requestedUrl = request.url;
          return http.Response(jsonEncode({_kid: _certificatePem}), 200);
        }),
      );

      final token = _signToken(audience: '123456789', email: null, emailVerified: null);

      expect(await verifier.verify('Bearer $token'), isTrue);
      expect(requestedUrl, GoogleJwtVerifier.chatServiceAccountCertsUrl);
    });
  });
}

GoogleJwtVerifier _buildVerifier({
  GoogleChatAudienceConfig? audience,
  http.Client? httpClient,
  Duration cacheTtl = const Duration(minutes: 10),
  DateTime Function()? now,
}) {
  return GoogleJwtVerifier(
    audience:
        audience ??
        const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
    httpClient:
        httpClient ??
        MockClient((request) async {
          // Return JWK for v3 (OIDC), PEM for v1/service-account endpoints
          if (request.url == GoogleJwtVerifier.googleOidcCertsUrl) {
            return http.Response(_jwkResponse, 200);
          }
          return http.Response(jsonEncode({_kid: _certificatePem}), 200);
        }),
    cacheTtl: cacheTtl,
    now: now ?? () => DateTime.utc(2026, 3, 10, 0, 0, 0),
  );
}

String _signToken({
  required String audience,
  String issuer = GoogleJwtVerifier.expectedIssuer,
  String kid = _kid,
  String privateKeyPem = _privateKeyPem,
  DateTime? expiresAt,
  String? email = GoogleJwtVerifier.expectedIssuer,
  bool? emailVerified = true,
}) {
  final exp = (expiresAt ?? DateTime.utc(2027, 3, 10, 1, 0, 0)).millisecondsSinceEpoch ~/ 1000;
  final claims = <String, Object>{'iss': issuer, 'aud': audience, 'exp': exp};
  if (email != null) {
    claims['email'] = email;
  }
  if (emailVerified != null) {
    claims['email_verified'] = emailVerified;
  }
  final jwt = JWT(claims, header: {'kid': kid});
  return jwt.sign(RSAPrivateKey(privateKeyPem), algorithm: JWTAlgorithm.RS256);
}
