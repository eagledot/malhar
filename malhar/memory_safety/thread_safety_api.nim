# Minimal API to check memory corruption during a concurrent environment.
# For now: (try to) prove that `no concurrent access` to a shared byte is being done from different threads!
import system/ansi_c
import ./bit_array_simple

type
    ThreadMetaData* = object
        readMismatchArray:BitArray
        writeArray:BitArray
        threadIds*:ptr UncheckedArray[int] # corresponding thread-id which will do a read/write. 
proc `=copy`(a:var ThreadMetaData, b:ThreadMetaData){.error.}

proc initThreadSafetyMetaData*(n_indices:Natural):ThreadMetaData=
    # NOTE: n_indices, generally represent the actual number of `bytes`, not the `logical` elements.
    result.readMismatchArray = initBitArray(n_indices)
    result.writeArray = initBitArray(n_indices)
    result.threadIds = cast[ptr UncheckedArray[int]](c_malloc((n_indices * sizeof(int)).csize_t)) 
    for i in 0..<n_indices:
        result.thread_ids[i] = -1
