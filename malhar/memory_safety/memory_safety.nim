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

proc freeBookKeeping(x:BookKeeping)=
    # TODO: may be make sure no record is valid anymore.. to be sure..
    c_free(x.records)
    c_free(x.recordPointers)

proc getRecordIndex(x:BookKeeping, record_pointer:pointer, record_payload:Natural):tuple[flag:bool, record_idx:int] =
    # given a record pointer, get its index in the records array!
    # NOTE: flag must be checked if a valid record was found in the first place.

    doAssert not isNil(record_pointer)
    for i in 0..<64:
        let to_check = x.recordPointers[i]
        if isNil(to_check):
            continue
        if to_check == record_pointer and (record_payload == x.records[i].payload):
            result.flag = true
            result.record_idx = i
            return result
    
    result.flag = false
    result.record_idx = -1
    return result

proc checkValidReference(x:BookKeeping, record_pointer:pointer, reference_id:uint8, record_payload:Natural):tuple[flag:bool, record_idx:int] {.inline.} =
    # Returns the (valid) record index in book-keeping, if exists. otherwise flag would be false, indicating invalid/dead reference!

    var (flag, record_idx) = x.getRecordIndex(record_pointer, record_payload)
    if flag == false:
        result.flag = false
        result.record_idx = -1
        return result

    var cond_1 = (x.records[record_idx].references[reference_id.Natural].status == live)
    var cond_2  = (x.records[record_idx].payload == record_payload)
    if cond_1 == true and cond_2 == false:
        echo "\t[INFO]: This should be rare, it means same record-pointer exists in book-keeping, but different payload. This points to a scenario where a reference was removed during reallocation, and just deallocated memory-space was given to a new Data-structure! Calling debugInvalidation(info) should help!"
    
    if cond_1 and cond_2:
        result.flag = true
        result.record_idx = record_idx
    else:
        result.flag = false
        result.record_idx = -1
    return result

proc isValidReference*(x:BookKeeping, record_pointer:pointer, reference_id:uint8, record_payload:Natural):bool =
    let (flag, record_idx) = x.checkValidReference(record_pointer, reference_id, record_payload)
    return flag

template getLiveCountImpl(record_pointer_t:ptr Record):Natural=
    # Counts the number of live references to this record!
    var ref_counter_t:Natural = 0
    for i in 0..<64: # SIMD opportunity.. (supposed to be called during decRefCount.. we check all the references slots even never filled to not save more meta-data. But called rarely so ok!)
        ref_counter_t += (record_pointer_t.references[i].status == live).Natural
    ref_counter_t
