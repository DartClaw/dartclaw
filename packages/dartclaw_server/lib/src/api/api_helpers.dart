import 'dart:convert';

import 'package:shelf/shelf.dart';

Response jsonResponse(int status, Object body) {
  return Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json; charset=utf-8'});
}

Response errorResponse(int status, String code, String message, [Map<String, dynamic>? details]) {
  final error = <String, dynamic>{'code': code, 'message': message};
  if (details != null) error['details'] = details;
  return jsonResponse(status, {'error': error});
}
