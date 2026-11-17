use std::collections::BTreeMap;

/// Boundary Tree implementation using Rust's BTreeMap (which is a B-Tree, meeting self-balancing requirements).
/// Maps the "Max" element of a block to the Block index (or ID).
/// Used to find which block potentially contains a value or to find the smallest blocks.
pub struct BoundaryTree<K: Ord + Clone> {
    // Map max_key -> block_index
    // We might need to store more info.
    // In BMSSP, we need to "Pull smallest N values".
    // This implies efficient access to the first blocks.
    pub index: BTreeMap<K, usize>,
}

impl<K: Ord + Clone> Default for BoundaryTree<K> {
    fn default() -> Self {
        Self::new()
    }
}

impl<K: Ord + Clone> BoundaryTree<K> {
    pub fn new() -> Self {
        Self {
            index: BTreeMap::new(),
        }
    }

    pub fn update(&mut self, max_key: K, block_idx: usize) {
        self.index.insert(max_key, block_idx);
    }

    pub fn remove(&mut self, max_key: &K) {
        self.index.remove(max_key);
    }

    // Find the block that might contain `key`.
    // We want the smallest boundary >= key.
    pub fn find_block_for(&self, key: &K) -> Option<usize> {
        // BTreeMap range:
        self.index.range(key..).next().map(|(_, &idx)| idx)
    }
}
