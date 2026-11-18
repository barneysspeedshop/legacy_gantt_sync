import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'api_service.dart';
import 'inspector_api_service.dart';
import 'models.dart';

class DatabaseInspectorScreen extends StatefulWidget {
  final ApiService apiService;

  const DatabaseInspectorScreen({super.key, required this.apiService});

  @override
  State<DatabaseInspectorScreen> createState() =>
      _DatabaseInspectorScreenState();
}

class _DatabaseInspectorScreenState extends State<DatabaseInspectorScreen> {
  late final InspectorApiService _inspector;
  late Future<_InspectorBootstrap> _bootstrapFuture;
  List<Map<String, dynamic>> _tableDefinitions = const [];
  String? _selectedTable;
  String? _selectedTenant;
  String _search = '';
  bool _includeDeleted = true;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _inspector = InspectorApiService(widget.apiService);
    _bootstrapFuture = _loadBootstrap();
  }

  Future<_InspectorBootstrap> _loadBootstrap() async {
    final results = await Future.wait([
      _inspector.getTables(),
      widget.apiService.getTenants(),
    ]);
    final tables = results[0] as List<Map<String, dynamic>>;
    final tenants = results[1] as List<Tenant>;
    _tableDefinitions = tables;
    if (_selectedTable == null && tables.isNotEmpty) {
      _selectedTable = tables.first['key']?.toString();
    }
    return _InspectorBootstrap(tables: tables, tenants: tenants);
  }

  Future<Map<String, dynamic>> _loadRows() {
    final table = _selectedTable;
    if (table == null) {
      return Future.value(<String, dynamic>{'data': [], 'meta': {}});
    }
    final definition = _tableDefinition;
    return _inspector.getRows(
      table,
      tenantId: definition?['tenantScoped'] == true ? _selectedTenant : null,
      search: _search,
      includeDeleted: _includeDeleted,
      offset: _offset,
    );
  }

  Map<String, dynamic>? get _tableDefinition {
    final table = _selectedTable;
    if (table == null) return null;
    for (final definition in _tableDefinitions) {
      if (definition['key'] == table) return definition;
    }
    return null;
  }

  void _selectTable(String? tableKey, List<Map<String, dynamic>> tables) {
    if (tableKey == null) return;
    final definition = tables.firstWhere((item) => item['key'] == tableKey);
    setState(() {
      _selectedTable = tableKey;
      _offset = 0;
      if (definition['tenantScoped'] != true) _selectedTenant = null;
    });
  }

  void _refresh() {
    setState(() {
      _offset = 0;
      _bootstrapFuture = _loadBootstrap();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Database Inspector'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<_InspectorBootstrap>(
        future: _bootstrapFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ErrorPanel(error: snapshot.error!);
          }
          final bootstrap = snapshot.data!;
          return _buildInspector(context, bootstrap);
        },
      ),
    );
  }

  Widget _buildInspector(BuildContext context, _InspectorBootstrap bootstrap) {
    final selectedDefinition = bootstrap.tables.firstWhere(
      (item) => item['key'] == _selectedTable,
      orElse: () => const <String, dynamic>{},
    );
    final tenantScoped = selectedDefinition['tenantScoped'] == true;
    if (tenantScoped &&
        _selectedTenant == null &&
        bootstrap.tenants.isNotEmpty) {
      _selectedTenant = bootstrap.tenants.first.id;
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 280,
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedTable,
                  decoration: const InputDecoration(labelText: 'Table'),
                  items: bootstrap.tables
                      .map(
                        (table) => DropdownMenuItem<String>(
                          value: table['key']?.toString(),
                          child: Text(table['key']?.toString() ?? ''),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => _selectTable(value, bootstrap.tables),
                ),
              ),
              if (tenantScoped)
                SizedBox(
                  width: 250,
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedTenant,
                    decoration: const InputDecoration(labelText: 'Tenant'),
                    items: bootstrap.tenants
                        .map(
                          (tenant) => DropdownMenuItem<String>(
                            value: tenant.id,
                            child: Text('${tenant.name} (${tenant.id})'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() {
                      _selectedTenant = value;
                      _offset = 0;
                    }),
                  ),
                ),
              SizedBox(
                width: 260,
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Search',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() {
                    _search = value;
                    _offset = 0;
                  }),
                ),
              ),
              FilterChip(
                label: const Text('Include tombstones'),
                selected: _includeDeleted,
                onSelected: (value) => setState(() {
                  _includeDeleted = value;
                  _offset = 0;
                }),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.schema),
                label: const Text('Schema'),
                onPressed: () => _showSchema(context),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tenantScoped && _selectedTenant == null
              ? const Center(child: Text('Select a tenant'))
              : FutureBuilder<Map<String, dynamic>>(
                  future: _loadRows(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return _ErrorPanel(error: snapshot.error!);
                    }
                    final body = snapshot.data!;
                    return _buildRows(context, body);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildRows(BuildContext context, Map<String, dynamic> body) {
    final rows = (body['data'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final meta = Map<String, dynamic>.from(body['meta'] as Map? ?? const {});
    final columns = <String>{};
    for (final row in rows) {
      columns.addAll(row.keys);
    }
    final orderedColumns = columns.toList()..sort();
    if (rows.isEmpty) {
      return Column(
        children: [
          const Expanded(child: Center(child: Text('No rows found'))),
          _pager(meta),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: DataTable(
                  columns: orderedColumns
                      .map((column) => DataColumn(label: Text(column)))
                      .toList(),
                  rows: rows
                      .map(
                        (row) => DataRow(
                          onSelectChanged: (_) => _showRow(context, row),
                          cells: orderedColumns
                              .map(
                                (column) => DataCell(
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 260,
                                    ),
                                    child: Text(
                                      _displayValue(row[column]),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
        ),
        _pager(meta),
      ],
    );
  }

  Widget _pager(Map<String, dynamic> meta) {
    final offset = meta['offset'] as int? ?? _offset;
    final limit = meta['limit'] as int? ?? 100;
    final total = meta['total'] as int? ?? 0;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text('$total rows'),
          const SizedBox(width: 16),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: offset == 0
                ? null
                : () => setState(() {
                    _offset = (offset - limit).clamp(0, total);
                  }),
          ),
          Text(
            '${total == 0 ? 0 : offset + 1}-${(offset + limit).clamp(0, total)}',
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: offset + limit >= total
                ? null
                : () => setState(() => _offset = offset + limit),
          ),
        ],
      ),
    );
  }

  Future<void> _showSchema(BuildContext context) async {
    try {
      final schema = await _inspector.getSchema();
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Live Schema'),
          content: SizedBox(
            width: 700,
            height: 500,
            child: ListView.builder(
              itemCount: schema.length,
              itemBuilder: (context, index) {
                final table = schema[index];
                return ExpansionTile(
                  title: Text('${table['schema']}.${table['table']}'),
                  subtitle: Text('RLS: ${table['rls'] ?? 'none'}'),
                  children: [
                    for (final column
                        in (table['columns'] as List? ?? const []))
                      ListTile(
                        dense: true,
                        title: Text(column['column_name']?.toString() ?? ''),
                        subtitle: Text(
                          '${column['data_type']} (${column['udt_name']})',
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Schema error: $error')));
    }
  }

  void _showRow(BuildContext context, Map<String, dynamic> row) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Row Details'),
        content: SingleChildScrollView(
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(row),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static String _displayValue(dynamic value) {
    if (value == null) return '';
    if (value is Map || value is List) return jsonEncode(value);
    return value.toString();
  }
}

class _InspectorBootstrap {
  final List<Map<String, dynamic>> tables;
  final List<Tenant> tenants;

  const _InspectorBootstrap({required this.tables, required this.tenants});
}

class _ErrorPanel extends StatelessWidget {
  final Object error;

  const _ErrorPanel({required this.error});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text('Error: $error'),
    ),
  );
}
