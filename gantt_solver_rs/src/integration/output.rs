use serde::Serialize;
use std::collections::HashMap;

#[derive(Serialize)]
pub struct CriticalPathResult {
    pub project_id: String,
    pub tasks: HashMap<String, TaskUpdate>,
    pub merkle_root: String,
}

#[derive(Serialize)]
pub struct TaskUpdate {
    pub start: i64,
    pub end: i64,
    pub input_start_delay: i64, // slack/float
    pub is_critical: bool,
}

impl CriticalPathResult {
    pub fn new(project_id: String, merkle_root: String) -> Self {
        Self {
            project_id,
            tasks: HashMap::new(),
            merkle_root,
        }
    }
}
