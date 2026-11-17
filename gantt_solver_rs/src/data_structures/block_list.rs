use std::collections::LinkedList;

/// A Block in the BlockList.
/// Contains a list of elements.
#[derive(Debug, Clone)]
pub struct Block<T> {
    pub elements: Vec<T>,
    // Optional: caching min/max if needed by BoundaryTree locally,
    // but BoundaryTree usually manages this mapping.
}

impl<T> Default for Block<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Block<T> {
    pub fn new() -> Self {
        Self {
            elements: Vec::new(),
        }
    }

    pub fn len(&self) -> usize {
        self.elements.len()
    }

    pub fn is_empty(&self) -> bool {
        self.elements.is_empty()
    }
}

/// BlockList implementation.
/// Conceptually a linked list of Blocks.
/// But standard LinkedList in Rust is doubly linked.
/// To support "Block-Based Linked List", we can wrap a LinkedList<Block<T>>.
pub struct BlockList<T> {
    pub blocks: LinkedList<Block<T>>,
    pub all_elements_count: usize,
    pub delta: usize, // Max block size
}

impl<T: Ord + Clone> BlockList<T> {
    pub fn new(delta: usize) -> Self {
        Self {
            blocks: LinkedList::new(),
            all_elements_count: 0,
            delta,
        }
    }

    /// Appends an element to the last block.
    /// If the last block is full (>= delta), it splits or creates a new one?
    /// Lemma 3.3 says "linked list containing at most delta elements".
    /// Usually we append to the tail. If tail is full, we might split it or just start a new block.
    /// For "Sorted" property maintenance, insertion is specific.
    /// BMSSP uses BlockList for B_1 and B_2 sequences.
    /// B_1 (Prepend/Batch) and B_2 (Insert).
    /// If just prepending/appending, we fill the current block until delta, then new block.
    pub fn push_back(&mut self, item: T) {
        if self.blocks.is_empty() {
            self.blocks.push_back(Block::new());
        }

        let last_block = self.blocks.back_mut().unwrap();
        if last_block.len() < self.delta {
            last_block.elements.push(item);
            self.all_elements_count += 1;
        } else {
            // Block is full.
            // For simple unsorted lists (like maybe B_1?), we just add a new block.
            // But if we need to maintain some sorted property or if this is the "frontier",
            // splitting at median is for when we *insert* into a sorted block and it overflows.
            // If this is just a sequence, we push a new block.
            let mut new_block = Block::new();
            new_block.elements.push(item);
            self.blocks.push_back(new_block);
            self.all_elements_count += 1;
        }
    }

    /// Insert item while maintaining order (for B_2).
    /// This requires finding the right block (via BoundaryTree usually) and inserting.
    /// Then checking for split.
    /// Since BlockList itself might not own the Tree, this method might just take a block reference/cursor?
    /// But `LinkedList` cursors are experimental in Rust.
    ///
    /// Alternative: Store blocks in a Vec or robust custom pointer structure if standard LinkedList is too limiting.
    /// Given the "Real-time" requirement and "Memory Efficiency", `Vec<Block>` might be better due to cache locality,
    /// but splicing blocks in the middle is O(N_blocks).
    /// However, N_blocks is likely small relative to N (N/delta).
    ///
    /// Let's stick to `LinkedList` for O(1) block splicing if we need to move blocks around.
    /// But accessing "the block containing value X" requires the BoundaryTree.
    ///
    /// For this generic `BlockList`, let's implement the "Split" logic on a specific block.
    /// We can't easy reference a block inside LinkedList from outside.
    ///
    /// Refactoring: Maybe `BlockList` IS the high level structure that manages B1/B2?
    /// Let's define `BlockList` as just the storage.
    pub fn split_block(&mut self, _block_idx: usize) {
        // Splitting a specific block is hard with LinkedList without cursor.
        // If we use `Vec<Block>`, splitting is `insert` of a block -> O(CountBlocks).
        // If Blocks are large (delta), CountBlocks is small.
        // O(N/delta) might be acceptable for "Real-Time" if delta is large.
    }
}

// For V1 MVP, let's use Vec<Vec<T>> (Vec of Blocks) to keep it simple and safe.
// LinkedList is notoriously unergonomic in Rust.
#[derive(Debug, Clone)]
pub struct VecBlockList<T> {
    pub blocks: Vec<Vec<T>>,
    pub delta: usize,
}

impl<T: Ord + Clone> VecBlockList<T> {
    pub fn new(delta: usize) -> Self {
        Self {
            blocks: Vec::new(),
            delta,
        }
    }

    pub fn insert_ordered(&mut self, item: T) {
        // 1. Find block (linear scan or via external index hints).
        // For now, linear scan is O(num_blocks).
        // We iterate to find the first block where max > item, or just append if none.

        let mut target_idx = self.blocks.len();
        for (i, block) in self.blocks.iter().enumerate() {
            if let Some(last) = block.last() {
                if item < *last {
                    target_idx = i;
                    break;
                }
            }
        }

        if target_idx == self.blocks.len() {
            // Append to last block or new
            if let Some(last_block) = self.blocks.last_mut() {
                if last_block.len() < self.delta {
                    last_block.push(item);
                    // Maintain order inside block?
                    // If we want total order, yes.
                    // But strictly, BMSSP says blocks are "sequences".
                    // B2 is "standard inserts", implying sorted.
                    last_block.sort(); // naive for now
                } else {
                    let new_block = vec![item];
                    self.blocks.push(new_block);
                }
            } else {
                self.blocks.push(vec![item]);
            }
        } else {
            // Insert into target_block
            self.blocks[target_idx].push(item);
            self.blocks[target_idx].sort();

            // Check split
            if self.blocks[target_idx].len() > self.delta {
                // Split at median
                let mid = self.blocks[target_idx].len() / 2;
                let new_vec = self.blocks[target_idx].split_off(mid);
                self.blocks.insert(target_idx + 1, new_vec);
            }
        }
    }

    /// Prepend items to the start of the list.
    /// Used for Batch Prepend operations where we know these items are smaller than current min.
    pub fn batch_prepend(&mut self, mut items: Vec<T>) {
        if items.is_empty() {
            return;
        }

        // Sorting items to ensure they form a valid sequence?
        // Usually batch prepend implies we are adding a sorted chunk.
        items.sort();

        // Just insert as a new block at the beginning?
        // Lemma 3.3 says we maintain blocks of size delta.
        // If items > delta, split them.

        // Simple implementation:
        // Create full blocks from items.
        // Prepend them to self.blocks.

        let mut chunks: Vec<Vec<T>> = items.chunks(self.delta).map(|c| c.to_vec()).collect();
        // Reverse to prepend in correct order (if we prepend one by one)
        // But we want the smallest items first.
        // chunks[0, 1] -> prepend 1 then 0.

        while let Some(chunk) = chunks.pop() {
            self.blocks.insert(0, chunk);
        }
    }
}
