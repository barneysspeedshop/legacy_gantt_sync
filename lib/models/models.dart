import 'package:freezed_annotation/freezed_annotation.dart';

part 'models.freezed.dart';
part 'models.g.dart';

@freezed
sealed class ProtocolMessage with _$ProtocolMessage {
  const factory ProtocolMessage.subscribe({
    required String type,
    required String channel,
    int? lastSyncedTimestamp,
  }) = _Subscribe;

  const factory ProtocolMessage.operation({
    required String type,
    required Map<String, dynamic> data,
    required int timestamp,
    String? actorId,
  }) = _Operation;

  const factory ProtocolMessage.error({
    @Default('error') String type,
    required String error,
  }) = _Error;

  factory ProtocolMessage.fromJson(Map<String, dynamic> json) =>
      _$ProtocolMessageFromJson(json);
}
