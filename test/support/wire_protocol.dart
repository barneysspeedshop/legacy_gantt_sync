import 'package:legacy_gantt_protocol/legacy_gantt_protocol.dart';

List<int> encodeMessage(Map<String, dynamic> message) =>
    ProtobufMapper.toProtobuf(message).writeToBuffer();

Map<String, dynamic> decodeMessage(Object message) =>
    ProtobufMapper.toJson(ProtocolMessage.fromBuffer(message as List<int>));
