use super::{Graph, NodeId};

/// Transforms an arbitrary graph into a constant-degree graph (degree <= 3)
/// by replacing high-degree nodes with cycles.
pub struct ConstantDegreeTransformer;

impl ConstantDegreeTransformer {
    pub fn transform(input_graph: &Graph) -> Graph {
        let mut new_graph = Graph::new();
        let n = input_graph.num_nodes();

        let mut incoming_edges: Vec<Vec<(usize, i64)>> = vec![Vec::new(); n];
        for (u, edges) in input_graph.adj.iter().enumerate() {
            for edge in edges {
                incoming_edges[edge.target].push((u, edge.weight));
            }
        }

        // Node mapping: original_u -> List of (new_node_id, is_outgoing_slot, original_edge_weight_if_any)
        // Actually we need to know for each original edge, which new node corresponds to it.
        // Let's store: mapping[u] -> Vec<usize> of new node indices in the cycle.

        // Cycle Construction:
        // For node u with degree d:
        // Create d virtual nodes: v_0, ..., v_{d-1}.
        // Edges: (v_i, v_{(i+1)%d}) with weight 0.
        // We assign slots 0..out_degree-1 to outgoing edges.
        // We assign slots out_degree..d-1 to incoming edges.

        let mut node_cycles: Vec<Vec<usize>> = vec![Vec::new(); n];

        // 1. Create Nodes & Cycles
        for u in 0..n {
            let out_degree = input_graph.adj[u].len();
            let in_degree = incoming_edges[u].len();
            let total_degree = out_degree + in_degree;

            // If degree is 0, we still need one node to represent the task?
            // Yes, to be safe.
            let count = if total_degree == 0 { 1 } else { total_degree };

            for i in 0..count {
                // Determine if this specific sub-node is for incoming or outgoing or neutral
                // Naming convention: u_sub_i
                let new_id =
                    new_graph.add_node(NodeId(format!("{}_sub{}", input_graph.nodes[u].0, i)));
                node_cycles[u].push(new_id);

                // Add cycle edges (0-weight)
                if i > 0 {
                    let prev = node_cycles[u][i - 1];
                    new_graph.add_edge(prev, new_id, 0);
                }
            }
            // Complete cycle
            if count > 1 {
                let last = node_cycles[u][count - 1];
                let first = node_cycles[u][0];
                new_graph.add_edge(last, first, 0);
            }
        }

        // 2. Wiring Original Edges
        // For each edge u->v with weight w:
        // Find a free outgoing slot on u's cycle.
        // Find a free incoming slot on v's cycle.
        // Add edge u_slot -> v_slot with weight w.

        // Tracking usage
        let mut u_out_next = vec![0; n];
        let mut v_in_next = vec![0; n];

        for u in 0..n {
            for edge in &input_graph.adj[u] {
                let v = edge.target;

                // Get source node from u's cycle
                let u_slot_idx = u_out_next[u];
                let source_node = node_cycles[u][u_slot_idx];
                u_out_next[u] += 1;

                // Get target node from v's cycle
                // Incoming slots start after outgoing slots?
                // Or simply we allocated enough nodes, and we use the second part.
                // v has input_graph.adj[v].len() outgoing edges.
                let v_out_degree = input_graph.adj[v].len();
                let v_slot_idx = v_out_degree + v_in_next[v];
                let target_node = node_cycles[v][v_slot_idx];
                v_in_next[v] += 1;

                new_graph.add_edge(source_node, target_node, edge.weight);
            }
        }

        new_graph
    }
}
