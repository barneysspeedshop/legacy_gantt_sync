pub mod transform;
pub mod weights;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NodeId(pub String);

impl fmt::Display for NodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

use std::fmt;

#[derive(Debug, Clone)]
pub struct Edge {
    pub target: usize, // Index into the graph's node vector
    pub weight: i64,
}

#[derive(Debug, Clone, Default)]
pub struct Graph {
    /// Maps internal index -> Original external ID (if applicable, or internal ID)
    pub nodes: Vec<NodeId>,
    /// Adjacency list: adj[u] contains all edges starting from u
    pub adj: Vec<Vec<Edge>>,
}

impl Graph {
    pub fn new() -> Self {
        Self {
            nodes: Vec::new(),
            adj: Vec::new(),
        }
    }

    pub fn add_node(&mut self, id: NodeId) -> usize {
        let idx = self.nodes.len();
        self.nodes.push(id);
        self.adj.push(Vec::new());
        idx
    }

    pub fn add_edge(&mut self, from: usize, to: usize, weight: i64) {
        if from < self.adj.len() && to < self.adj.len() {
            self.adj[from].push(Edge { target: to, weight });
        }
    }

    pub fn num_nodes(&self) -> usize {
        self.nodes.len()
    }
}
