class PubSubMessage {
  final String type;
  final String channelName;
  final String payload;

  const PubSubMessage({
    required this.type,
    required this.channelName,
    required this.payload,
  });

  /// Factory to parse from raw Redis list [type, channel, payload]
  factory PubSubMessage.fromList(List<dynamic> list) {
    if (list.length < 3) {
      throw const FormatException('Invalid PubSub message format');
    }
    return PubSubMessage(
      type: list[0]?.toString() ?? '',
      channelName: list[1]?.toString() ?? '',
      payload: list[2]?.toString() ?? '',
    );
  }
}
