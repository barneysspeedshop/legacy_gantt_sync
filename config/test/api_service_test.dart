import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:config/api_service.dart';

class NetworkHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'login keeps session tokens in memory and logout clears credentials',
    () => HttpOverrides.runWithHttpOverrides(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/auth/login');
        expect(jsonDecode(await utf8.decoder.bind(request).join()), {
          'username': 'operator',
          'password': 'test-only-password',
        });
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'accessToken': 'test-only-access-token',
            'refreshToken': 'test-only-refresh-token',
          }),
        );
        await request.response.close();
      });
      final api = ApiService('http://127.0.0.1:${server.port}', prefs);
      expect(await api.login('operator', 'test-only-password'), isTrue);
      expect(api.accessToken, 'test-only-access-token');
      expect(prefs.getKeys(), isEmpty);
      expect(ApiService(api.baseUrl, prefs).accessToken, isNull);
      api.localInspectorToken = 'test-only-inspector-token';
      await api.logout();
      expect(api.accessToken, isNull);
      expect(api.localInspectorToken, isNull);
      expect(prefs.getKeys(), isEmpty);
    }, NetworkHttpOverrides()),
  );
}
