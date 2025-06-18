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

template getWordIdx(array_t: ptr UncheckedArray[BitArrayScalar], idx_t:Natural):Natural =
    # Get the `WORD` where this idx_t would belong to.
    # For example for a 64 bit system, 64th index would be in 2nd word. 
    (idx_t div (sizeof(BitArrayScalar) * 8))

template getWordRem(array_t: ptr UncheckedArray[BitArrayScalar], idx_t:Natural):Natural =
    # to get the `bit` for a `word`, corresponding to given index.
    # for example: 64th index, would mean 0't bit. combined with word, 1 word and 0'th bit to look for!
    (idx_t mod (sizeof(BitArrayScalar) * 8))