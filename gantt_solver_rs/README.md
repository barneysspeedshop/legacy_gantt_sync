# Gantt Solver RS (experimental)

This MIT-licensed Rust crate contains scheduling research and a Protobuf FFI boundary. **Schedule optimization is not implemented.** Valid `SolverRequest` messages return `success: false` and `Scheduling is experimental and not implemented`. The server returns the same explicit error for `OPTIMIZE_SCHEDULE` without changing tasks. Earlier versions echoed tasks and incorrectly reported success.

The graph, data-structure, Dijkstra, and BMSSP modules are experimental scaffolding. They are not connected to task/dependency scheduling through the FFI. No scheduling correctness or performance guarantee is claimed. Client-side chart interactions and visualization remain independent of this backend limitation.

## Build and check

Install Rust, Cargo, and the Protobuf compiler (`protoc`). The sibling `legacy_gantt_protocol` checkout supplies the canonical schema.

```bash
cargo test --locked
cargo build --release --locked
```

The contract tests exercise a non-empty dependency chain with lag, an empty request, and malformed Protobuf. They verify explicit rejection rather than successful optimization. Implementing scheduling requires separate tests for dependency semantics, constraints, cycles, and duration preservation before enabling it.

The Dart server loads `target/release/libgantt_solver_rs.so` on Linux or the equivalent platform library. Finish Rust compilation before starting the Dart build on constrained hosts.

## FFI contract

`solve_critical_path` accepts a pointer and byte length for an encoded `SolverRequest` and writes the byte length of an encoded `SolverResponse` through its third argument. Copy the response bytes, then call `free_buffer` with the returned pointer and length. These are binary Protobuf messages, not JSON or C strings.

```c
uint8_t* solve_critical_path(const uint8_t* input, int32_t input_length,
                           int32_t* output_length);
void free_buffer(uint8_t* output, int32_t output_length);
```

See [LICENSE](LICENSE).
