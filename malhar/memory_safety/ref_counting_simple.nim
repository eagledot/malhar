# Enough reference counting for production use.
# Main use is to `free` resources automatically(correctly).
# Alternative would be to inject `free` or `deallocRecord` manually, but with non-trivial codebases it would not play well, but users would be allowed to bypass this (with the risk of memory being freed at wrong time! or leakage)

type
    RecordPayload = uint32  # an ever increasing counter!
type
        RefCount* = tuple
            record_pointer:pointer
            record_payload:RecordPayload
            ref_count:uint32   

const MAX_LIVE_RECORDS_COUNT = 1024 # at one time it can support this number of allocations/records!
var ref_count_arr*:array[MAX_LIVE_RECORDS_COUNT, RefCount] # put it on the stack.
var record_counter:RecordPayload = 1

proc has_record*(record_pointer:pointer, record_payload:RecordPayload):tuple[flag:bool, record_idx:int] =
    doAssert not isNil(record_pointer), "not expected, right!"
    var found_ix:int = -1
    for i in 0..<MAX_LIVE_RECORDS_COUNT:
        # find the corresponding slot
        if ref_count_arr[i].record_pointer == record_pointer and record_payload == ref_count_arr[i].record_payload:
            found_ix = i
            break
    result = (found_ix >= 0, found_ix)
    return result

proc add_record*(record_pointer:pointer):RecordPayload=
    # add a new ref count  pair after making sure no duplicate record pointer already exists!
    var found_ix:int = -1
    var flag:bool = true
    for i in 0..<MAX_LIVE_RECORDS_COUNT:
        if isNil(ref_count_arr[i].record_pointer):
            if flag:
                found_ix = i
                flag = false
        else:
            # cannot exist two same record pointers at same time!
            assert ref_count_arr[i].record_pointer != record_pointer

    doAssert found_ix >= 0
    ref_count_arr[found_ix] = (record_pointer:record_pointer, record_payload: record_counter, ref_count:1)
    result = record_counter
    inc record_counter
    return result

proc remove_record*(record_pointer:pointer, record_payload:RecordPayload)=
    # Forcefully removing a record. useful for cases like reallocation.
    # but generally called after all memory safety checks have been passed.
    let (flag, found_ix) = has_record(record_pointer, record_payload)
    doAssert flag == true, "NOTE if you are doing, manual deallocation it is tricky for now to support that.. error may happen, try without manual deallocation first!"    
    # reset this entry.
    ref_count_arr[found_ix] = (record_pointer:nil, record_payload:0, ref_count:0)

proc inc_ref_count*(record_pointer:pointer, record_payload:RecordPayload)=
    echo fgYellow("\t[Info]: Ref counting incremented!")
    # It makes sure a valid record_pointer, if memory safety checks pass.. then it must pass too.
    # shouldn't be possible to pass a weird record pointer, if reference counting logic is sound.
    let (flag, found_ix) = has_record(record_pointer,record_payload)
    doAssert flag == true
    inc ref_count_arr[found_ix].ref_count

proc dec_ref_count*(record_pointer:pointer, record_payload:RecordPayload):Natural = 
    # It makes sure a valid record_pointer, if memory safety checks pass.. then it must pass too.
    # shouldn't be possible to pass a weird record pointer, if reference counting logic is sound.
    when defined(debug):
        echo fgYellow("\t[Info]: Ref counting decremented!")
    let (flag, found_ix) = has_record(record_pointer, record_payload)
    doAssert flag == true
    doAssert ref_count_arr[found_ix].ref_count >= 1
    dec ref_count_arr[found_ix].ref_count
    let temp = ref_count_arr[found_ix].ref_count
    return temp