use crate::graph::Graph;
use std::cmp::Ordering;
use std::collections::BinaryHeap;

#[derive(Eq, PartialEq)]
struct State {
    cost: i64,
    node: usize,
}

impl Ord for State {
    fn cmp(&self, other: &Self) -> Ordering {
        // Reverse ordering for Min-Heap
        other.cost.cmp(&self.cost)
    }
}

impl PartialOrd for State {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// "Mini-Dijkstra" for small sets or base case.
pub fn run_dijkstra(graph: &Graph, sources: &[usize]) -> Vec<i64> {
    let mut dist = vec![i64::MAX; graph.num_nodes()];
    let mut heap = BinaryHeap::new();

    for &s in sources {
        dist[s] = 0;
        heap.push(State { cost: 0, node: s });
    }

    while let Some(State { cost, node }) = heap.pop() {
        if cost > dist[node] {
            continue;
        }

        for edge in &graph.adj[node] {
            let next = State {
                cost: cost + edge.weight,
                node: edge.target,
            };

            if next.cost < dist[next.node] {
                dist[next.node] = next.cost;
                heap.push(next);
            }
        }
    }

    dist
}
