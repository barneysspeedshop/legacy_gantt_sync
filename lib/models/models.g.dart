// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Subscribe _$SubscribeFromJson(Map<String, dynamic> json) => _Subscribe(
  type: json['type'] as String,
  channel: json['channel'] as String,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$SubscribeToJson(_Subscribe instance) =>
    <String, dynamic>{
      'type': instance.type,
      'channel': instance.channel,
      'runtimeType': instance.$type,
    };

_Operation _$OperationFromJson(Map<String, dynamic> json) => _Operation(
  type: json['type'] as String,
  data: json['data'] as Map<String, dynamic>,
  timestamp: (json['timestamp'] as num).toInt(),
  actorId: json['actorId'] as String?,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$OperationToJson(_Operation instance) =>
    <String, dynamic>{
      'type': instance.type,
      'data': instance.data,
      'timestamp': instance.timestamp,
      'actorId': instance.actorId,
      'runtimeType': instance.$type,
    };

_Error _$ErrorFromJson(Map<String, dynamic> json) => _Error(
  type: json['type'] as String? ?? 'error',
  error: json['error'] as String,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$ErrorToJson(_Error instance) => <String, dynamic>{
  'type': instance.type,
  'error': instance.error,
  'runtimeType': instance.$type,
};
