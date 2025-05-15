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