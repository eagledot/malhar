# Module to implement Bookkeeping code for memory safety.
import system/ansi_c   # c_malloc, c_free 

# a reference status.
type
    ReferenceStatus {.size:sizeof(uint8).} = enum
        dead # 0
        live # 1

# id by default would be from [0-64) based on the index.
type
    Reference = object
        status:ReferenceStatus
        # since only can writer, write , if written writerCount would not match. (during each read this can be checked)
        writerCount:int = -1  # it can be used to check if memory has been manipulated in-directly.
        expectMutation:bool = false  # by default, all references expect underlying memory to be frozen, at the time of their creation.
        threadId:int

# A record represents a Memory allocation by the allocator. We intend to keep necessary meta-data for each such record to enable memory-safety!
type
    Record = object  # combination of base pointer and reference id is unique enough !
        size:Natural
        payload:Natural  # to distinguish b/w record pointers, since those could be reused. want to prove that some reference/stack-data may not refer to `re-assigned record-pointer` during `alloc to ds1 - dealloc from ds1 -alloc to ds2`. rare but could happen. Using extra payload can prevent it! 
        ownerRefId:int = -1  # -1 means, no writer, other wise ix in [0-63] indicating which reference is a writer!                          
        writerCount:int = 0  # to maintain the number of times this record/memory has been manipulated!
        references:array[64, Reference]  # each record is allowed upto 64 live reference for now!

type
    BookKeeping* = object
        capacity:int    # possible capacity!
        # synced.. bases pointer mapping to records
        recordPointers:ptr UncheckedArray[pointer]
        records:ptr UncheckedArray[Record]

proc `=copy`(dst: var BookKeeping, src: BookKeeping){.error.}
# proc `=sink`(dst: var BookKeeping, src: BookKeeping){.error.}


proc initBookKeeping*(size:Natural = 1024):BookKeeping=
    # size: i.e initially can keep track of size number of active allocations at any point of time during execution of programme!
    result = default(BookKeeping)
    result.recordPointers = cast[ptr UncheckedArray[pointer]](c_malloc((size * sizeof(pointer)).csize_t))
    result.records = cast[ptr UncheckedArray[Record]](c_malloc((size * sizeof(Record)).csize_t))
    result.capacity = size

    # default initialization!
    for i in 0..<size:
        result.recordPointers[i] = nil  # nil would mean a record is not present yet!
    for i in 0..<size:
        result.records[i] = default(Record)
