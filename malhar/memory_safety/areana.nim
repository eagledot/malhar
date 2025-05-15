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