type
    prisonReason* {.size:sizeof(uint8).} = enum
        # Reasons if a reference was invalid/dead, out of sync with stack. 

        PreemptiveDeallocation     # user forcing to release memory pre-emptively (aka without scope exit).
        ReleasedDuringAssignment   # var b = a, b = c, then b has to remove older reference first !
        MovedToThreadByUser  # moving to a different Thread by user!
        ReallocationHappenedInThisThread # realloc routine responsible.
        ReallocationHappenedInOtherThread # realloc routine responsible.

type
    PrisonRecord = object
        record_pointer:pointer
        reference_id:uint8
        record_payload:Natural     # payload associated to distinguish record_pointers, as they could be reused!
        reason:prisonReason

# append only..
type
    Prison = object
        len:Natural = 0
        capacity:Natural = 0
        records:ptr UncheckedArray[PrisonRecord]

proc `=copy`(a: var Prison, b:Prison){.error.}
proc `=sink`(a: var Prison, b:Prison){.error.}

proc initPrison*(size:Natural = 2048):Prison=
    result.capacity = size
    result.len = 0
    result.records = cast[ptr UncheckedArray[PrisonRecord]](c_malloc((sizeof(PrisonRecord) * size).csize_t))
    return result

proc findRecord(x:Prison, record_pointer:pointer, reference_id:uint8, record_payload:Natural):tuple[flag:bool, reason:prisonReason]=
    var found_ix = -1

    # we scan all, find the latest reason for incarceration!
    for i in 0..<x.len:
        if x.records[i].record_pointer == record_pointer and  x.records[i].record_payload == record_payload and (x.records[i].reference_id == reference_id):
            found_ix = i
    if found_ix >= 0:
        doAssert x.records[found_ix].reason != ReleasedDuringAssignment # it is kind of a dummy reason, cannot be reason a read/write is prevented!
        return (true, x.records[found_ix].reason)
    else:
        return (false, ReleasedDuringAssignment)

proc sendToPrison*(p: var Prison, record_pointer:pointer, reference_id:uint8, record_payload:Natural, reason:prisonReason)=
    p.records[p.len].record_pointer = record_pointer
    p.records[p.len].reference_id = reference_id
    p.records[p.len].record_payload = record_payload
    inc p.len

proc debugValidation(x: Prison, record_pointer:pointer, reference_id:uint8, record_payload:Natural)=
    # in case reference was valid!
    # like proving this is a fresh reference.

    let (found, reason) = x.findRecord(record_pointer, reference_id, record_payload)    
    if found == true:
        quit("[INFO]: Validation failed, Must not have happened.. bug somewhere!")
    echo "[INFO]: Stack data is Fresh, no-signs for staleness!"