class ProtocolConstants {
  // Channels
  static const String channelAdminUpdates = 'admin_updates';
  static const String channelTenantUsersPrefix = 'tenant_users_';

  // Operation Types
  static const String insertTask = 'INSERT_TASK';
  static const String updateTask = 'UPDATE_TASK';
  static const String deleteTask = 'DELETE_TASK';
  static const String insertDependency = 'INSERT_DEPENDENCY';
  static const String updateDependency = 'UPDATE_DEPENDENCY';
  static const String deleteDependency = 'DELETE_DEPENDENCY';
  static const String insertResource = 'INSERT_RESOURCE';
  static const String updateResource = 'UPDATE_RESOURCE';
  static const String deleteResource = 'DELETE_RESOURCE';
  static const String resetData = 'RESET_DATA';
  static const String optimizeSchedule = 'OPTIMIZE_SCHEDULE';
  static const String batchUpdate = 'BATCH_UPDATE';

  // Ephemeral Operations
  static const String cursorMove = 'CURSOR_MOVE';
  static const String ghostUpdate = 'GHOST_UPDATE';
  static const String presenceUpdate = 'PRESENCE_UPDATE';

  // Dependency Types
  static const String dependencyFinishToStart = 'finishToStart';
  static const String dependencyStartToStart = 'startToStart';
  static const String dependencyFinishToFinish = 'finishToFinish';
  static const String dependencyStartToFinish = 'startToFinish';
}
