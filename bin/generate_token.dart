import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    print('Usage: dart bin/generate_token.dart <user_id>');
    exit(1);
  }

  final userId = args[0];
  final secret = Platform.environment['JWT_SECRET'];

  if (secret == null) {
    print('Error: JWT_SECRET environment variable is not set.');
    exit(1);
  }

  final jwt = JWT({'sub': userId, 'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000});

  final token = jwt.sign(SecretKey(secret));

  print('Token for user $userId:');
  print(token);
}
