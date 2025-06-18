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
