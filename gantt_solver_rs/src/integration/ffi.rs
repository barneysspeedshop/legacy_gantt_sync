use prost::Message;
use std::slice;

pub mod generated {
    include!(concat!(env!("OUT_DIR"), "/gantt_protocol.rs"));
}
use generated::{SolverRequest, SolverResponse};

/// Returns an encoded response owned by the caller; release it with `free_buffer`.
///
/// # Safety
/// `proto_input` must reference `input_length` readable bytes, and `output_length`
/// must reference writable, aligned storage for an `i32`. Both must remain valid
/// for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn solve_critical_path(
    proto_input: *const u8,
    input_length: i32,
    output_length: *mut i32,
) -> *mut u8 {
    if proto_input.is_null() || output_length.is_null() || input_length < 0 {
        return std::ptr::null_mut();
    }

    let input_slice = unsafe { slice::from_raw_parts(proto_input, input_length as usize) };

    let resp = match SolverRequest::decode(input_slice) {
        Ok(_) => SolverResponse {
            success: false,
            error_message: "Scheduling is experimental and not implemented".to_owned(),
            ..SolverResponse::default()
        },
        Err(e) => SolverResponse {
            success: false,
            error_message: format!("Failed to parse SolverRequest: {}", e),
            ..SolverResponse::default()
        },
    };

    let mut out_buf = Vec::new();
    resp.encode(&mut out_buf).unwrap();

    let mut out_buf = out_buf.into_boxed_slice();
    let ptr = out_buf.as_mut_ptr();
    unsafe {
        *output_length = out_buf.len() as i32;
    }
    std::mem::forget(out_buf);
    ptr
}

/// Releases a response allocated by `solve_critical_path`.
///
/// # Safety
/// A non-null `ptr` must be a live allocation returned by `solve_critical_path`,
/// and `length` must equal its reported length. The allocation must be freed once.
#[no_mangle]
pub unsafe extern "C" fn free_buffer(ptr: *mut u8, length: i32) {
    if ptr.is_null() || length <= 0 {
        return;
    }
    unsafe {
        let _ = Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, length as usize));
    }
}
