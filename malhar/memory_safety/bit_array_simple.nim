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

proc initBitArray*(n_indices:Natural):BitArray =
    let n_words = ((n_indices - 1) div sizeof(BitArrayScalar)) + 1
    
    let capacity_in_bytes = (n_words * sizeof(BitArrayScalar)) div 8
    result.n_indices = n_indices
    result.data = cast[ptr UncheckedArray[BitArrayScalar]](c_malloc(capacity_in_bytes.csize_t))
    result.capacity_in_bytes = capacity_in_bytes

    # zeroing..
    c_memset(result.data, 0, capacity_in_bytes.csize_t) # fill 0 at for each of the byte.
    return result

proc resetBitArray*(x:var BitArray)=
    doAssert not isNil(x.data)
    # zeroing..
    c_memset(x.data, 0, x.capacity_in_bytes.csize_t) # fill 0 at for each of the byte.

proc set*(x:var BitArray, idx:Natural)=
    doAssert idx < x.n_indices
    let word_idx = getWordIdx(x.data, idx)
    let rem = getWordRem(x.data, idx)
    x.data[word_idx] = x.data[word_idx] or (1.BitArrayScalar shl rem)
    