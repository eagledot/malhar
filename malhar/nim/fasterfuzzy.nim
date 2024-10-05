import strutils
import std/algorithm

import nimpy
import nimpy / [raw_buffers, py_types]

import tlsh_python_module

# create a mapping to speed up hex to string conversion during initialization. default toHex is too slow??
var hex2str:array[256, string]
for i in 0..<256:
    hex2str[i] = toHex[uint8](uint8(i))

proc myCmp(x, y: tuple[ix:int32, score:int32]): int =
    cmp(x.score, y.score)

proc compare_fast(
    stored_hashes:PyObject,     # a sequence/array of stored fuzzy hashes.
    query_hash:string,          # fuzzy hash for current query/string/word.
    unigram:string,             # [ascii character should be single byte (should be a uint8 right.)
    indices_scores:PyObject,    # [int32, int32] packed array.
    threshold_score:int = 120,   # keeping it higher would result in matching more keys. (but may not make sense ...)
    hash_size:int = 35 + 1      # fixed. (35 + 1 single byte unigram)
    ){.exportpy.}=

    # buffer protocol to consume data.
    var
        hash_buf:RawPyBuffer
    stored_hashes.getBuffer(hash_buf, PyBUF_SIMPLE or PyBUF_ND)  # we just want to read data!
    var hash_arr = cast[ptr UncheckedArray[uint8]](hash_buf.buf)

    assert hash_buf.len mod hash_size == 0
    let n_hashes = hash_buf.len div hash_size

    # should be faster, may be later able to use multithreading too, i guess !!!!
    # TODO: this size would be good enough for most of cases..
    let temp_seq_length = 10_000     # to hold (index, score) int32 pairs.  (with threshold )              
    var temp_seq = newSeq[tuple[ix:int32, score:int32]](temp_seq_length)
    var temp_count = 0

    for i in 0..<n_hashes:
        var stored_hash:string        
        var stored_unigram = $chr(hash_arr[(i*hash_size) + hash_size - 1])

        if stored_unigram.toLower() == unigram.toLower():

            for j in 0..<hash_size-1:
                stored_hash = stored_hash & hex2str[int(hash_arr[i*hash_size + j])]    # direct look-up.

            var score = compare_tlsh_hash(stored_hash, query_hash)  # by default, lower the score better match it would be. 
            if score <= threshold_score:
                temp_seq[temp_count] = (ix:int32(i), score:threshold_score.int32 - score.int32,)  # we reverse the score, now higher better it would be !
                inc temp_count
                if temp_count >= temp_seq_length:
                    break
    
    var
        indices_scores_buffer:RawPyBuffer
    indices_scores.getBuffer(indices_scores_buffer, PyBuf_WRITABLE)  # expecting this to be a writable buffer.
    
    # have to sort it..
    let sorted_seq = sorted(temp_seq[0..<temp_count], cmp = myCmp, order = Descending)

    let arr_size = indices_scores_buffer.len div (2 * int(indices_scores_buffer.itemsize))
    
    var arr = cast[ptr UncheckedArray[int32]](indices_scores_buffer.buf)
    for i in 0..<min(arr_size, len(sorted_seq)):
        arr[2*i] = sorted_seq[i].ix
        arr[2*i+1] = sorted_seq[i].score
    
    # very rare case, should not happend, top_k should be near 1000..
    let remaining = max(arr_size - temp_count, 0)
    for i in arr_size-remaining..<arr_size:
        arr[2*i] = -1'i32
        arr[2*i+1] = 0'i32
    
    # decrease the reference count.
    hash_buf.release()
    indices_scores_buffer.release()