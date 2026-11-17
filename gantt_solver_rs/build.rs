fn main() {
    prost_build::Config::new()
        .boxed(".gantt_protocol.ProtocolMessage.payload.single_operation")
        .compile_protos(
            &["../legacy_gantt_protocol/proto/gantt_protocol.proto"],
            &["../legacy_gantt_protocol/proto"],
        )
        .unwrap();
}
