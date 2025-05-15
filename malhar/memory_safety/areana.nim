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

proc allocate_from_block(allocator:var ArenaAllocator, block_idx:Natural, n_bytes:Natural):pointer=
    # allocate a new record from a (initialized) block.
    assert allocator.getBlockAvailableMemoryImpl(block_idx) >= (n_bytes)
    let block_ptr = addr allocator.blocks[block_idx]
    result = cast[pointer](cast[int](block_ptr.memory) + block_ptr.size)
    
    block_ptr.size += n_bytes # increment the bumpCounter!
    block_ptr.n_records += 1
    return result

proc getLargestBlockIdx(allocator: ArenaAllocator):Natural {.inline.} =
    # rather than storing meta-data, we can just scan!
    result = 0
    for i in 0..<16:
        # TODO: use 0 rather than nil, to speed up various computations..but later!
        if allocator.isBlockInitializedImpl(i): # branching can be removed... 
            result = i # if we use 0 in-place of Nil , then very (fast) simple calculation!
    assert allocator.isBlockInitializedImpl(result) == true, "Expected to be initialized..  if calling this routine"
    return result    

proc getBlocksCount(allocator: ArenaAllocator):Natural =
    result = 0
    for i in 0..<16: # TOdo: may be unroll!
        result += (allocator.isBlockInitializedImpl(i)).int
    return result

proc getBlockIndex(allocator:var ArenaAllocator, record_pointer:pointer, record_size:Natural, reference_id:uint8):Natural =
    # given user stored record info, we can find which block it belongs to!
    
    var block_idx = 0
    var found = false
    for i in 0..<16:
        if allocator.isBlockInitializedImpl(i):
            let x_0 = cast[int](record_pointer)
            let x_1 = cast[int](allocator.blocks[i].memory)
            let cap = cast[int](allocator.blocks[i].capacity)
            if x_0 >= x_1 and (x_0 + record_size) <= (x_1 + cap): # must reside inside a block!
                block_idx = i
                found = true
                break
    doAssert found == true, "must have been found!"
    return block_idx

proc deallocRecord*(allocator:var ArenaAllocator, record_pointer:pointer, record_size:Natural, reference_id:uint8, record_payload:Natural, now:bool = false,
    debugFile: string,
    debugLine: int,
    )=

    # ------- BookKeeping stuff -------------------------------
    allocator.bookkeeper.removeRecord(record_pointer, record_payload = record_payload, now = now, debugFile = debugFile, debugLine = debugLine)
    # ------------------------------------------------------------

    # --------------------------------------
    # Allocator Stuff 
    # ---------------------------------------
    
    let block_idx = allocator.getBlockIndex(
        record_pointer = record_pointer,
        record_size = record_size,
        reference_id = reference_id) # find the block_idx where this record belongs to!

    # free any other potential Block (every dealloc call is the opportunity..)
    let largest_block_idx = allocator.getLargestBlockIdx() # largest active block!
    for i in 0..<16:
        let block_ptr = addr allocator.blocks[i]
        if isBlockInitializedImpl(block_ptr): # some thing block_ptr 
            if block_ptr.n_records == 0 and (i != largest_block_idx) and (i != block_idx):
                allocator.freeBlock(i)
                echo "\t[INFO]: Returned to OS for block: ", i, " largest: ", block_idx

    if allocator.blocks[block_idx].n_records == 1: # last record which is being deactivated/removed!
        # this was the last record, this block can be returned to OS. (we return it if *is not* the larget Block. )
        if largest_block_idx != block_idx:
            allocator.freeBlock(block_idx)
        else:
            allocator.blocks[block_idx].size = 0 # just reduce the size, indicating full block is available!
    elif allocator.isRightMostRecord(block_idx, record_pointer = record_pointer, record_size = record_size):
        # else check if this was the most recent record?, if yes we can effectively just free that record only !
        allocator.blocks[block_idx].size -= record_size # decrement the bumpCOunter!
    else:
        discard
    
    allocator.blocks[block_idx].n_records -= 1

proc allocRecord*(allocator: var ArenaAllocator, n_bytes:Natural, zeroin:bool = false):tuple[record_pointer:pointer, record_size:Natural, reference_id:uint8, record_payload:Natural] =
    # Allocate a new Record.
    assert n_bytes > 0

    # -----------------------------------------------------
    #  Allocator stuff 
    # -------------------------------------------------------

    # finding the compatible block, first check if enough space available in an already allocated block!
    var block_idx = getStartingBlockIndex(n_bytes)
    var found_already_init = false
    for i in block_idx..<16:
        if allocator.isBlockInitializedImpl(block_idx) == false:
            continue
        if allocator.getBlockAvailableMemoryImpl(block_idx) >= n_bytes:
            found_already_init = true
            block_idx = i
            break

    if found_already_init == false:
        block_idx = allocator.allocateBlock(n_bytes, zeroin) # allocate a fresh (Arena) block
        echo "\t[INFO]: allocated From OS for block: ", block_idx

    let record_pointer = allocator.allocate_from_block(block_idx, n_bytes) # allocate from it!
    # ----------------------------------------------------------------------------

    result.record_pointer = record_pointer
    result.record_size = n_bytes
    result.reference_id = 0 # as a new records, so first reference is 0!
    result.record_payload = record_counter # even if a record pointer in re-used, we should be able to distinguish it!

    # ------------------------------------
    # -- BookKeeping stuff...
    # ----------------------------------------------
    result.reference_id = allocator.bookkeeper.addRecord(
            record_pointer = record_pointer,
            record_size = n_bytes,
            record_payload = record_counter)
    doAssert result.reference_id == 0, "Since new record, so foremost reference must be zero"
    # -----------------------------------------------------
    
    inc record_counter
    return result

