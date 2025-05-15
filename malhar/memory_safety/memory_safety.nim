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


# ---------------------------------------------------------------------------------------
# Out of turn (indirect) references removal from book-keeping due to operations like `realloc`, `moving to a new Thread`, `pre-emptive deallocation`.
# This will make stack-data stale/corrupted.
# We can detect such corrupted data now, and plan to introduce nice debug messages when read or write is tried by such stack-data/stack-references!  
# --------------------------------------------------------------------------------------------
include ./debugging_safety
var prison* = initPrison() # global scope

proc removeReferenceForcefully*(x:var BookKeeping, 
    record_pointer:pointer, 
    reference_id:uint8, 
    record_payload:Natural,
    reason:prisonReason  # a reason has to be provided, for removing a reference forcefully!
    )=
    # remove an existing reference out-of-turn. For `realloc` like operations, we will need to prevent access to `reallocated memory` by some stale references/stack-data. 
    # NOTE: Error message during `proveReadAccess` and `proveWriteAccess` may not be useful, as it would just indicate `invalidAccess`. (probably enumerate the possibly reasons clearly!) 

    let (flag, record_idx) = x.checkValidReference(record_pointer, reference_id = reference_id, record_payload = record_payload)
    doAssert flag == true
    x.records[record_idx].references[reference_id.Natural].status = dead
    
    # send this record + payload to prison. so later we can debug!
    prison.sendToPrison(record_pointer, reference_id, record_payload, reason) # what is the reason , have to be provided!

# ------------------------------------------------------------------------------------------


proc addRecord(x:var BookKeeping, record_pointer:pointer, record_size:Natural, record_payload:Natural):uint8 = 
    # Add a new record (of allocation) in a given block_idx!

    var (flag, record_idx) = x.getRecordIndex(record_pointer, record_payload = record_payload)
    doAssert flag == false, "must not have been found, (valid) record_pointer + record_payload is supposed to be unique!"
    
    # find a slot to add this new record!
    var found = false
    record_idx = 0
    for i in 0..<64:
        if isNil(x.recordPointers[i]):
            record_idx = i
            found = true
            break
    doAssert found == true, "Not enough capacity?"

    x.recordPointers[record_idx] = record_pointer
    
    x.records[record_idx].payload = record_payload # basically a unique value each time a record is added, guarantees payload would be unique even if pointer can be repeated!
    x.records[record_idx].ownerRefId = -1   # by default starts as reader!
    x.records[record_idx].size = record_size
    x.records[record_idx].writerCount = 0   # fresh record, still to be written !
    
    x.records[record_idx].references[0] = default(Reference)
    x.records[record_idx].references[0].status = live # 0 will be foremost live reference by default on new record addition!
    x.records[record_idx].references[0].threadId = getThreadId() # corresponding threadId where it was created. some operations may force thread matching..
    x.records[record_idx].references[0].writerCount = 0     # new record, nothing has been written to it.

    return 0'u8 # return the reference assigned!

proc removeRecord(x:var BookKeeping, record_pointer:pointer, record_payload:Natural, now:bool = false, debugFile:string, debugLine:int)=
    # removes an existing Record. TODO: rename it to removeRecord! 
    let (flag, record_idx) = x.getRecordIndex(record_pointer, record_payload)
    if flag == false:
        echo "\t[FATAL]: Cannot remove a non-existent record: ", $(cast[int](record_pointer)), " Did you try to double free, or bad reference counting logic!"
    doAssert flag == true

    let live_count = getLiveCountImpl(addr x.records[record_idx])
    if now == true:

        # debugging/prison records!
        x.removeAllReferencesForcefully(
          record_pointer = record_pointer,
          record_payload = record_payload,
          reason = PreemptiveDeallocation  
        )  # pre-emptive deallocation, without scope exists. (later memoy safety will prevent all later access to this memory/record from stale references)      
    else:
        doAssert live_count == 0, "This must have been the last active (not dead) reference, but found: " & $live_count

    # For now no need to specifically set references to default.. setting record pointer to nil is enough!  
    x.recordPointers[record_idx] = nil 
    x.records[record_idx] = default(Record) # can do away with this, since record_pointer we set to nil. 
    echo "\t[INFO]: record invalidated for: ", $(cast[int](record_pointer))
