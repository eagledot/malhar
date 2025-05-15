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