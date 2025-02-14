import std/json
import jsony
import nimpy
import std/random
import strutils
import std/tables
import std/sets
import times

import invertedDb

var db:InvertedDB # to be initialized.. (TODO: allow multiple instances can return an id, to differentiate!)
var initialized = false
proc initDB(capacity:Natural = 1_000_000, top_k:Natural = 10_000) {.exportpy.}=
    if initialized:
        echo "Already initialized. For now only 1 instance is possible!" 
        return
       
    db = init(capacity = capacity, top_k = top_k) # move, should not given an `sink` error, as db is uninitalized!
    initialized = true

proc append(document_id:int, tokens:openArray[string]):int  {.exportpy.}=
    # Inputs:
        # tokens: generally from a tokenizer. (all possible tokens generated from a document, paragraph)
    # Returns:
        # err_code:int ( negative generally if some error, for now when try to append more than capacity, TODO: allow reallocate)
    
    doAssert initialized == true, "Please initialize the db first!" # I think nim allows us to check for non initialized values, right . by some flag use it!
    doAssert document_id >= int(low(uint32)) and document_id < int(high(uint32)), "Supposed to be uint32 value! " # or let nimpy marshal it ?
    
    let err_code = db.append(
        document_id = uint32(document_id),
        tokens = tokens)
    return err_code

proc query(query_json:string, prefix_match:bool = false, threshold:int = 150, num_threads:int = 1, top_k:int = -1):string {.exportpy.} =  # we can return a dict mapping 'tokens/suggestions` to all the corresponding document ids they appear in!
    # NOTE: query_json is json encoded, seq[seq[string]], to make it easier to pass from python!
    # Inputs:
        # query_json/query: for "hellp world" it could be -> [ ["hell", "p", "hellp"], ["world"]], actual user spelling is always appended in the last. 

        # top_k: int, should be part of an server or another abstraction, underlying library returns all possible results, whatever may be the cost for now! 
    # Returns:
        # json encoded mapping from "suggestions" to `doc-ids`, for each of the user query
        # something like this:
        #   user_query    | suggestions    | doc - ids
        #   `hellp`       | ["hello", "p"] | [[1,2], [7]]

    # parse json to get a seq[seq[string]]
    let query_node = parseJson(query_json)
    doAssert query_node.kind == JArray
    var query = newSeq[seq[string]](len(query_node))
    for i in 0..<len(query_node):
        doAssert query_node[i].kind == JArray
        for token in query_node[i]:
            query[i].add(token.getStr())
    
    # each element is tuple containing document id and corresponding matched tokens!
    let id_tokens_array = db.query(
                tokens = query,
                prefix_match = prefix_match,
                threshold = threshold,
                num_threads = num_threads,
                top_k = top_k
                )
    result = id_tokens_array.toJson() 
    return result

proc get_count():int {.exportpy.} =
    return int(db.counter)

proc get_token(idx:int):string {.exportpy.} = 
    return db.get_token(idx)

proc get_stats():string {.exportpy.} = 
    return db.get_stats()