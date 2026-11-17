class SqlUtils {
  /// Builds an INSERT ... ON CONFLICT DO UPDATE query.
  ///
  /// [table]: The table name.
  /// [columns]: List of all column names to insert.
  /// [conflictColumns]: List of columns in the ON CONFLICT clause (primary key(s)).
  /// [excludedUpdates]: List of columns that should NOT be updated on conflict (e.g. initial creation time, or the PK itself).
  ///
  /// Returns the SQL string.
  static String buildUpsertQuery({
    required String table,
    required List<String> columns,
    required List<String> conflictColumns,
    List<String> excludedUpdates = const [],
  }) {
    // Validate inputs
    if (columns.isEmpty) throw ArgumentError('Columns cannot be empty');
    if (conflictColumns.isEmpty) {
      throw ArgumentError('Conflict columns cannot be empty');
    }

    final colsStr = columns.join(', ');
    final placeholders = List.filled(columns.length, '?').join(', ');

    final conflictTarget = conflictColumns.join(', ');

    // Calculate which columns to update
    // We update everything that is in [columns] but NOT in [conflictColumns] and NOT in [excludedUpdates]
    final updates = columns
        .where(
          (c) => !conflictColumns.contains(c) && !excludedUpdates.contains(c),
        )
        .map((c) => '$c = EXCLUDED.$c')
        .toList();

    // Always ensure we reset soft delete flags on upsert
    updates.add('is_deleted = 0');
    updates.add('deleted_at = NULL');

    final updateStr = updates.join(', ');

    return 'INSERT INTO $table ($colsStr) VALUES ($placeholders) ON CONFLICT ($conflictTarget) DO UPDATE SET $updateStr';
  }

  /// Builds a Bulk INSERT ... ON CONFLICT DO UPDATE query.
  static String buildBulkUpsertQuery({
    required String table,
    required List<String> columns,
    required List<String> conflictColumns,
    required int rowCount,
    List<String>? columnCasts,
    List<String> excludedUpdates = const [],
  }) {
    if (columns.isEmpty) throw ArgumentError('Columns cannot be empty');
    if (conflictColumns.isEmpty) {
      throw ArgumentError('Conflict columns cannot be empty');
    }
    if (rowCount < 1) throw ArgumentError('Row count must be at least 1');
    if (columnCasts != null && columnCasts.length != columns.length) {
      throw ArgumentError('columnCasts length must match columns length');
    }

    final colsStr = columns.join(', ');

    // Generate placeholders with casts if provided (e.g. "?::text")
    final placeholderList = <String>[];
    for (var i = 0; i < columns.length; i++) {
      final cast = columnCasts != null && columnCasts[i].isNotEmpty
          ? '::${columnCasts[i]}'
          : '';
      placeholderList.add('?$cast');
    }
    final singleRowPlaceholders = '(${placeholderList.join(', ')})';

    final allPlaceholders = List.filled(
      rowCount,
      singleRowPlaceholders,
    ).join(', ');

    final conflictTarget = conflictColumns.join(', ');
    final updates = columns
        .where(
          (c) => !conflictColumns.contains(c) && !excludedUpdates.contains(c),
        )
        .map((c) => '$c = EXCLUDED.$c')
        .toList();

    updates.add('is_deleted = 0');
    updates.add('deleted_at = NULL');

    final updateStr = updates.join(', ');

    return 'INSERT INTO $table ($colsStr) VALUES $allPlaceholders ON CONFLICT ($conflictTarget) DO UPDATE SET $updateStr';
  }
}
