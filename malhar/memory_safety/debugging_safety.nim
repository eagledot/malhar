type
    prisonReason* {.size:sizeof(uint8).} = enum
        # Reasons if a reference was invalid/dead, out of sync with stack. 
        
        PreemptiveDeallocation     # user forcing to release memory pre-emptively (aka without scope exit).
        ReleasedDuringAssignment   # var b = a, b = c, then b has to remove older reference first !
        MovedToThreadByUser  # moving to a different Thread by user!
        ReallocationHappenedInThisThread # realloc routine responsible.
        ReallocationHappenedInOtherThread # realloc routine responsible.
