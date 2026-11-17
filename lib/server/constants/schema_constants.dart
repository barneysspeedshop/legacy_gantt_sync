class SchemaConstants {
  static const String tasksTable = '''
      CREATE TABLE IF NOT EXISTS tasks (
        id TEXT NOT NULL,
        tenant_id TEXT NOT NULL,
        name TEXT,
        gantt_type TEXT,
        start_date BIGINT,
        end_date BIGINT,
        parent_id TEXT,
        last_updated BIGINT,
        deleted_at BIGINT,
        color TEXT,
        text_color TEXT,
        uses_work_calendar BOOLEAN DEFAULT FALSE,
        completion FLOAT8 DEFAULT 0.0,
        resource_id TEXT,
        baseline_start BIGINT,
        baseline_end BIGINT,
        notes TEXT,
        PRIMARY KEY (tenant_id, id)
      )
    ''';

  static const String dependenciesTable = '''
      CREATE TABLE IF NOT EXISTS dependencies (
        predecessor_task_id TEXT NOT NULL,
        successor_task_id TEXT NOT NULL,
        tenant_id TEXT NOT NULL,
        dependency_type TEXT NOT NULL DEFAULT 'finishToStart',
        lag BIGINT,
        last_updated BIGINT,
        deleted_at BIGINT,
        PRIMARY KEY (tenant_id, predecessor_task_id, successor_task_id)
      )
    ''';

  static const String resourcesTable = '''
      CREATE TABLE IF NOT EXISTS resources (
        id TEXT NOT NULL,
        tenant_id TEXT NOT NULL,
        name TEXT,
        parent_id TEXT,
        gantt_type TEXT,
        is_expanded BOOLEAN NOT NULL DEFAULT TRUE,
        last_updated BIGINT,
        deleted_at BIGINT,
        sort_order FLOAT8,
        PRIMARY KEY (tenant_id, id)
      )
    ''';

  static String tenantPolicy(String tableName) =>
      '''
        CREATE POLICY tenant_isolation ON $tableName
        USING (tenant_id = current_setting('app.current_tenant')::text)
        WITH CHECK (tenant_id = current_setting('app.current_tenant')::text)
      ''';
}
