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
