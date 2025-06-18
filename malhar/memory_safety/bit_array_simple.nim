# Bit array implementation. (being used to check/uncheck the presence of an index).

import system/ansi_c   # c_malloc, c_free 

type
    BitArrayScalar = uint # or int

type
    BitArray* = object
        n_indices*:Natural # 1 bit for each index.
        capacity_in_bytes:Natural  # in bytes. (given n_indices.. we calculate capacity in bytes)
        data:ptr UncheckedArray[BitArrayScalar]

proc `=copy`(a:var BitArray, b:BitArray) {.error.}  # only sink should be needed!

proc freeBitArray*(x:var BitArray)=
    # release underlying memory/resources if any back to the OS.
    doAssert not isNil(x.data)
    c_free(x.data)
    x.data = nil