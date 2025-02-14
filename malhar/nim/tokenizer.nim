import std/tables
import std/options
import std/base64
import std/os
import std/json       # takes higher RAM , Ok implementation, can notice difference by using `-d:useMalloc` !
import std/unicode
import streams
import std/algorithm
import times

import jsony         # better than standard json implm
import nimpy

# used while returning `tokens` so as to be decodable by Json parser!
import strutils
const WhitespaceMine* = {' '}  # nothing with `\`, as leading to invalid control character error in json decoding!
const PrintableCharsMine* = Letters + Digits + PunctuationChars + WhitespaceMine
const invalid = AllChars - PrintableCharsMine        # we skip those in case some bytes happen to be as `tokens` after tokenization results! 

type
    TokenInfo = object
        rank:int
        token_bytes:string  # base64 encoded.
        token_string:Option[string] # use isSome / isNone, routines to be sure.. of some assumptions, before accessing value.

proc load_tekken_json(path:string):seq[TokenInfo]=
    # We process the `tekken.json` from NemoMistral, and return the VOCAB only.
    # A better description/experimentation could be found in python code  (preprocessing.py ).
    # Only if python code works, we do sufficient coding in Nim, to speed up some bottleneck portion!
    doAssert os.existsFile(path)

    let f = open(path, fmRead)
    var raw_data = f.readAll()
    var json_data = fromJson(raw_data)

    doAssert json_data.kind == JObject

    # NOTE: that we can directly convert json to a type using `to` or something... but ok for me this logic!
    let vocab_node = json_data["vocab"]
    doAssert vocab_node.kind == JArray
    for temp_node in vocab_node:
        var x:TokenInfo
        x.rank = temp_node["rank"].getInt()
        x.token_bytes = temp_node["token_bytes"].getStr()
        if temp_node["token_str"].kind == JNull:
            x.token_string = none(string)
        else:
            x.token_string = some(temp_node["token_str"].getStr())
        result.add(x)

    return result

proc reload_mergeable_ranks(
    vocab:openArray[TokenInfo],
    max_vocab:int = -1             # -1 to indicate all.
):Table[string, int]=
    # ported from python code i wrote in `preprocessing.py`, visit that for more details!

    # generate a mapping/dictionary from the byte pairs, to rank.
    var vocab_length = len(vocab)
    if max_vocab != -1:
        doAssert max_vocab >= len(vocab), "Expected custom vocab size to be greater than original vocabulary"
        vocab_length = max_vocab
    
    for i in 0..<vocab_length:
        assert vocab[i].rank == i

        let merge = decode(vocab[i].token_bytes)
        
        doAssert i >= 256 or len(merge) == 1, "upto 255 ascii or null!" 

        # original (file in ordered, so best rank is assigned to all 4 variations!)
        if not (merge in result):
            result[merge] = vocab[i].rank
            result[merge.toLower()] = vocab[i].rank
            result[merge.strip()] = vocab[i].rank  # strip whitespace
            result[merge.toLower().strip()] = vocab[i].rank  # strip whitespace


    return result


# ------------- Byte Pairs (storing start and end indice in the original string)  ------------------
type
    BytePairObj = object
        start_ix:int
        end_ix:int
        valid:bool   # in case to ignore this pair during merging.
proc `copy`(a:var BytePairObj, b: BytePairObj) {.error.}
proc len(x:BytePairObj):int=
    result = x.end_ix - x.start_ix + 1

proc simple_merge(
    content:string,
    merge_pairs:Table[string, int],       # (pair, rank!)
    ):string=
    # NOTE: it actually returns the sequence of "tokens", we further serialize it (to json), to easier to send to python side, which deserialize it!

    # Tokenize the content(string), into `tokens`, using the `merge_pairs` collected during training.
    # It just keeps merging byte pairs, until all possible pairs are merged.
    # (sorted based on the rank, if in an iteration more than one possible `merge` candidates are available)
    
    let n_pairs = len(content)
    var byte_pairs = newSeq[BytePairObj](n_pairs)
    for i in 0..<n_pairs:
        byte_pairs[i] = BytePairObj(start_ix:i, end_ix:i, valid:true)
    
    while true:
        # two consecutive valid pairs.. we need , so we can check for merging!
        var j_1 = 0
        var j_2 = 0 + 1

        # to keep track which of the two elements are selected for merging. (based on rank)
        var
            merge_1 = j_1
            merge_2 = j_2
            best_rank = high(int)

    
        while j2 < n_pairs:

            doAssert byte_pairs[j_1].valid
            if byte_pairs[j_2].valid == false:
                j_2 += 1
            else:
                let
                    s_ix = byte_pairs[j_1].start_ix
                    e_ix = byte_pairs[j_2].end_ix
                
                let substr{.cursor.} = content[s_ix..e_ix]
                if substr in merge_pairs:
                    # if this rank represent lowest rank upto this point, then update merge_1 and merge_2, so as to later know which byte_pairs to merge finally!
                    let curr_rank = merge_pairs[substr]
                    if curr_rank < best_rank:
                        merge_1 = j_1
                        merge_2 = j_2
                        best_rank = curr_rank
                
                j_1 = j_2
                j_2 = j_1 + 1
        
        if best_rank < high(int):
            # it means we found the next mergable pair!
            # update the slice indices..
            assert merge_2 > merge_1, "sanity check!!"
            byte_pairs[merge_2].valid = false # i.e this has been merged with merge_1
            byte_pairs[merge_1].end_ix = byte_pairs[merge_2].end_ix  # increment the consecutive substring!
        else:
            break # nothing left to merge!

    # just collect bytes/strings merged
    var some_result:seq[string]
    for pair in byte_pairs:
        if pair.valid:
            let 
                s_ix = pair.start_ix
                e_ix = pair.end_ix 
            let temp = content[s_ix..e_ix]

            
            # following checks helps to prevent including bytes/(invalid utf8) pairs  to prevent errors during json decoding.!
            # Note: it can happen due to tokenizer limited vocabulary, (we break into bytes, but some bytes are never merged, hence leading to invalid utf8 errors!)
            if len(temp) == 1 and temp.find(invalid) != -1:  # it prevent unprintable chars/codes to be included which may lead to Jsondecoding errors on python side!
                continue
            if validateUtf8(temp) == -1: # NOTE: it is possible to merge "those individual bytes" to UTF8 valid strings...  but LATER TODO..
                some_result.add(temp)
            
    let json_result = some_result.toJson()  # on python side, we deserialize it to get corresponding tokens!
    return json_result


#------------------------------------------------------------------------------------- ------ 
#                          Tokenizers (to be used from python side)
# Uses the `tekken.json` from Nemo mistral model , for details see `preprocessing.py python code
# init the tokenizer first
# then just call tokenize(string_content) (calling from python side has overhead in nano seconds!)
#-----------------------------------------------------------------------------------------

type
    TokenizerNemoMistral = object
        merge_pairs:Table[string, int]

proc `=copy`(a:var TokenizerNemoMistral, b: TokenizerNemoMistral){.error.}

var tokenizer = default(TokenizerNemoMistral)
var initialized:bool = false
proc initTokenizer*(path:string) {.exportpy}= 
    if initialized == false:
        let vocab = load_tekken_json(path)
        tokenizer.merge_pairs = reload_mergeable_ranks(vocab)
        initialized = true
    else:
        echo "Already initialized..."

proc tokenize*(
        content:string):string {.exportpy.} =
    return simple_merge(content, tokenizer.merge_pairs)

# ------------------------------------------------------------------------------------------------------------
