# Areana: a memory allocator inspired by arena allocator.

import system/ansi_c  # c_malloc, c_free!
import math

include ./memory_safety

# record-payload
var 
    record_counter = 1  # would be accessed under a lock (This will act a payload for book-keeping and user stack-data )

type
    Block = object
        n_records:Natural
        capacity:Natural 
        size:Natural  # current size (< capacity) for this block.
        memory:pointer
proc `=copy`(a:var Block, b:Block){.error.}
proc `=sink`(a:var Block, b:Block){.error.}

type
    ArenaAllocator = object
        # lock:Lock              # for all operations, making it thread-safe, yes contention would be there.. but if user is careful about allocations then better than malloc atleast?
        blocks:array[16, Block] # [1mb, 2mb, 4mb, ...]
        # book-keeping (optional/modular, to (try to) prevent memory-safety bugs!)
        bookkeeper*:BookKeeping

proc `=copy`(a:var ArenaAllocator, b: ArenaAllocator){.error.}
proc `=sink`(a:var ArenaAllocator, b: ArenaAllocator){.error.}

proc initAllocator*():ArenaAllocator =
    result = default(ArenaAllocator)
    result.bookkeeper = initBookKeeping(size = 1024)
    return result

template isBlockInitializedImpl(allocator_t:ArenaAllocator, block_ix_t:Natural):bool=
    not isNil(allocator_t.blocks[block_ix_t].memory)
template isBlockInitializedImpl(block_ptr_t:ptr Block):bool=
    not isNil(block_ptr_t.memory)

template getBlockAvailableMemoryImpl(allocator_t:ArenaAllocator, block_ix_t:Natural):Natural = 
    doAssert isBlockInitializedImpl(allocator_t, block_ix_t), "cannot be nil, not intialized yet??"
    allocator_t.blocks[block_ix_t].capacity - allocator_t.blocks[block_ix_t].size

proc isRightMostRecord(x:ArenaAllocator, block_idx:Natural, record_pointer:pointer, record_size:Natural):bool=
    # TODO: double check this logic!
    # NOTE: not supposed to be dependent on any bookkeeping api!
    return (cast[int](record_pointer)) + record_size == (cast[int](x.blocks[block_idx].memory)) + x.blocks[block_idx].size

proc freeBlock(allocator: var ArenaAllocator, block_idx:Natural)=
    # free this block to the os and reset block meta-data!
    let mem_to_free = allocator.blocks[block_idx].memory
    doAssert not isNil(mem_to_free)
    c_free(mem_to_free) # os/libC call!
    # reset state.
    reset(allocator.blocks[block_idx])
    assert isNil(allocator.blocks[block_idx].memory)

proc getStartingBlockIndex(n_bytes:Natural):Natural {.inline.} =
    # may be directly get index, as each block has a capacity of 2 of index ?
    
    let temp = ((n_bytes.float32 / (1024 * 1024).float32) + 0.1) # push at-boundaries allocation to a much larger block!
    for i in 0..<16:
        let cap = pow(2'f32, i.float32)  # TODO: use look-up table to replace pow routine/call..
        if cap >= temp:
            return i

proc allocateBlock(allocator: var ArenaAllocator, n_bytes:Natural, zeroin:bool):Natural =
    # allocate a new block, by finding first non-initialized block with enough capacity!
    var block_idx = getStartingBlockIndex(n_bytes)
    var was_found = false
    for i in block_idx..<16:
        if allocator.isBlockInitializedImpl(block_idx) == false:
            was_found = true
            block_idx = i
            break
    doAssert was_found == true
    
    ## initialize it. (each block has a fixed capacity, given its index)
    if block_idx >= 12:
        echo "[Warning] Too much memory for a single allocation???"
    let cap = pow(2, block_idx.float32).uint * (1024 * 1024) # since fixed 16, can replace pow with a look-table!
    allocator.blocks[block_idx].memory = c_malloc(cap.csize_t) # may crash if too much requested!
    allocator.blocks[block_idx].capacity = cap
    allocator.blocks[block_idx].size = 0
    if zeroin:
        c_memset(allocator.blocks[block_idx].memory, 0, cap.csize_t)

    return block_idx
