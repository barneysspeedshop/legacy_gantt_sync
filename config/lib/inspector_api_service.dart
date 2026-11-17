import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

class InspectorApiService {
  final ApiService apiService;

  InspectorApiService(this.apiService);

  SharedPreferences get _prefs => apiService.prefs;

  String get baseUrl =>
      _prefs.getString('inspector_url') ?? 'http://127.0.0.1:8787';

  String? get localToken => apiService.localInspectorToken;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${apiService.accessToken}',
    'X-Local-Inspector-Token': localToken ?? '',
  };

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String> queryParameters = const {},
  }) async {
    final uri = Uri.parse('$baseUrl/api/local/v1$path').replace(
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
    );
    final response = await http.get(uri, headers: _headers);
    final body = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Inspector request failed (${response.statusCode}): ${body is Map ? body['error'] ?? response.body : response.body}',
      );
    }
    return Map<String, dynamic>.from(body as Map);
  }

  Future<List<Map<String, dynamic>>> getTables() async {
    final response = await get('/tables');
    return _mapList(response['data']);
  }

  Future<List<Map<String, dynamic>>> getSchema() async {
    final response = await get('/schema');
    return _mapList(response['data']);
  }

  Future<Map<String, dynamic>> getRows(
    String tableKey, {
    String? tenantId,
    String? search,
    bool includeDeleted = true,
    int limit = 100,
    int offset = 0,
  }) {
    final parts = tableKey.split('.');
    if (parts.length != 2) throw ArgumentError('Invalid table key: $tableKey');
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      'includeDeleted': '$includeDeleted',
    };
    if (tenantId != null && tenantId.isNotEmpty) query['tenantId'] = tenantId;
    if (search != null && search.isNotEmpty) query['search'] = search;
    return get('/tables/${parts[0]}/${parts[1]}', queryParameters: query);
  }

  static List<Map<String, dynamic>> _mapList(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }
}
