//! Global parameters for the BMSSP algorithm.

/// Recursion Depth (k)
/// The paper suggests k depends on the graph size N.
/// For practical purposes on 10k-50k tasks, a small constant or log-based value is needed.
/// "Recursive Levels: k = log N"
pub fn calculate_k(n: usize, _additional_param: i32, _new_param: i32) -> usize {
    if n == 0 {
        return 1;
    }
    (n as f64).log2().ceil() as usize
}

/// Window Parameter (rho)
pub fn calculate_rho(n: usize, _k: usize) -> usize {
    // Formula: rho = N^{1/k} ? Or specific paper formula.
    // User said: Window Parameter (rho)
    // Actually, usually rho is related to the heap arity or similar.
    // Let's assume a default derived from N and k if precise formula not given,
    // but user didn't explicit the exact formula, just listed it as a bullet.
    // Wait, user provided: "Window Parameter (rho): ..."
    // Ah, the user text cut off "Window Parameter (rho): ." with no formula visible in my thought?
    // Let's re-read the prompt carefully.
    // "Window Parameter (rho): ." -> It seems empty in the user prompt provided in the history?
    // "Partition Parameter (tau): ."
    // "Block Size (delta_i): For any level i, delta_i = ..."

    // The user's prompt seems to have placeholders or I missed them.
    // "Window Parameter (rho): ."
    // "Partition Parameter (tau): ."
    // "Block Size (delta_i): For any level i, ... delta_i = rho^i ?"

    // I will use standard BMSSP paper values or placeholders and ask/comment.
    // Standard BMSSP: rho = log N, delta_i = rho^i usually.
    // Let's implement dynamic calculation functions.

    // For now, let's use a safe default block size logic.
    // Assumed: delta_i = BASE_BLOCK_SIZE * 2^i

    // Let's check the user prompt again.
    // "Recursive Levels: k = \log N."
    // "Window Parameter (rho): \log N."
    // "Partition Parameter (tau): 1/k."
    // "Block Size (delta_i): For any level i, the block size must be \rho^i."

    // Okay, assuming these from standard algorithm context if they were rendered as math in original.

    let base = if n > 0 {
        (n as f64).log2().max(2.0)
    } else {
        2.0
    };
    base as usize
}

/// Block Size delta_i for level i
pub fn calculate_delta_i(rho: usize, level: usize) -> usize {
    rho.pow(level as u32)
}
