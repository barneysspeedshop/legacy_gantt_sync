use gantt_solver_rs::integration::ffi::{
    free_buffer,
    generated::{ProtocolDependency, ProtocolTask, SolverRequest, SolverResponse},
    solve_critical_path,
};
use prost::Message;

fn solve(bytes: &[u8]) -> SolverResponse {
    let mut length = 0;
    let output = unsafe { solve_critical_path(bytes.as_ptr(), bytes.len() as i32, &mut length) };
    assert!(!output.is_null());
    assert!(length > 0);
    let response = unsafe {
        SolverResponse::decode(std::slice::from_raw_parts(output, length as usize)).unwrap()
    };
    unsafe { free_buffer(output, length) };
    response
}

#[test]
fn rejects_dependency_scheduling_instead_of_reporting_unchanged_tasks_as_solved() {
    let request = SolverRequest {
        tasks: vec![
            ProtocolTask {
                id: "a".into(),
                start: "0".into(),
                end: "1000".into(),
                ..Default::default()
            },
            ProtocolTask {
                id: "b".into(),
                start: "0".into(),
                end: "1000".into(),
                ..Default::default()
            },
            ProtocolTask {
                id: "c".into(),
                start: "0".into(),
                end: "1000".into(),
                ..Default::default()
            },
        ],
        dependencies: vec![
            ProtocolDependency {
                predecessor_task_id: "a".into(),
                successor_task_id: "b".into(),
                r#type: "FS".into(),
                lag: 500,
                ..Default::default()
            },
            ProtocolDependency {
                predecessor_task_id: "b".into(),
                successor_task_id: "c".into(),
                r#type: "FS".into(),
                ..Default::default()
            },
        ],
        ..Default::default()
    };
    let response = solve(&request.encode_to_vec());
    assert!(!response.success);
    assert_eq!(
        response.error_message,
        "Scheduling is experimental and not implemented"
    );
    assert!(response.tasks.is_empty());
}

#[test]
fn rejects_empty_scheduling_requests_explicitly() {
    let response = solve(&SolverRequest::default().encode_to_vec());
    assert!(!response.success);
    assert_eq!(
        response.error_message,
        "Scheduling is experimental and not implemented"
    );
}

#[test]
fn malformed_protobuf_returns_a_decode_error() {
    let response = solve(&[0xff]);
    assert!(!response.success);
    assert!(response
        .error_message
        .starts_with("Failed to parse SolverRequest:"));
    assert!(response.tasks.is_empty());
}
