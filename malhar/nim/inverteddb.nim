
import std/sets
import strutils
import std/unicode
import std/algorithm
import std/editdistance
import std/tables
import std/times

import tlsh_python_module
when defined(windows):
    import std/winlean

# TODO: do so for tokens also, like token indices are positive right, so why not uint32/uint64 can save some space?
type DOC_ID_TYPE = uint32 # NOTE: keep it a positive number for now, if too much use uint64, but keep it positive!
type
    SetTest = object
        values:ptr UncheckedArray[DOC_ID_TYPE] = nil      # when compressed we can use uint16 values if within range..., otherwise uint32
        size:uint32  = 0        # current size/len
        capacity:uint32         # initial-size, it can be updated dynamically!
        
        # range info, in cases to speed up checking if a document-id is in this set for some cases, especially if doc-ids follow an order!
        min = low(DOC_ID_TYPE)  # 0
        max = low(DOC_ID_TYPE)  # 0
        

proc `=copy`(a:var SetTest, b:SetTest){.error.}
proc `=sink`(a:var SetTest, b:SetTest){.error.}

proc initSetTest(capacity:uint32 = 16):SetTest=
    result = default(SetTest)
    result.capacity = capacity 
    result.values = cast[ptr UncheckedArray[DOC_ID_TYPE]](alloc0(capacity.int * sizeof(DOC_ID_TYPE)))  # increment in size of 20 new values !
    result.size = 0
    return result

proc add(obj:var SetTest, value:uint32)=

    # NOTE: we use alloc, not allocShared, so this is supposed to be run in main thread!!
    doAssert not isNil(obj.values)

    # check if already available.. don't care if adds some latency.. (focus on memory!) (it is used for indexing only!)
    if (value >= obj.min) and (value <= obj.max):
        for i in obj.min..(obj.max):
            if value == i:
                return

    if obj.size == obj.capacity:
        var temp_realloc_arr = alloc0((obj.capacity.int + 8)*sizeof(DOC_ID_TYPE))     # capacity is incremented by just 8 units!
        copyMem(temp_realloc_arr, obj.values, obj.capacity.int * sizeof(DOC_ID_TYPE)) # copy to new destination array
        dealloc(obj.values)
        obj.values = cast[ptr UncheckedArray[DOC_ID_TYPE]](temp_realloc_arr)
        obj.capacity = obj.capacity + 8
    
    assert obj.capacity >= obj.size

    # update range info..
    obj.min = min(value, obj.min)
    obj.max = max(value, obj.max)

    obj.values[obj.size] = value
    obj.size += 1

proc compress(obj:var SetTest)=
    discard

proc decompress(obj:var SetTest)=
    discard

proc get_all(obj: SetTest):seq[DOC_ID_TYPE]=
    doAssert not isNil(obj.values),"not expected!"
    result = newSeq[DOC_ID_TYPE](obj.size)
    for i in 0..<obj.size:
        result[i] = obj.values[i]
    return result


#---------------------------------------------------------------------------------------------------------
# threadData type to pass arguments of this type to threads!
type ThreadData = tuple[
                    query_hash:ptr UncheckedArray[uint8],    # supposed to be read only.

                    # prefix matching!
                    query_token_byte:uint8,                   # first byte of token being queried (to check during prefix match!)
                    do_prefix_match:bool,

                    # following 3 are the original pointers allocated during initialization, we use offset and offset_topK to calculate corresponding pointers/address for each thread.
                    stored_hashes_arr:ptr UncheckedArray[uint8], # read only. (not supposed to be concurrent with write operations.)
                    token_prefixes_1:ptr UncheckedArray[uint8], # read only.  (single byte, match to implement prefix matching)
                    best_indices_arr:ptr UncheckedArray[int], # to track the indices matching/under threshold. (length = max_indices_count)
                    best_scores_arr:ptr UncheckedArray[int],   # score generated from comparison.  (length = max_indices_count)
                    
                    # a location 
                    indices_count_ptr:ptr int, # to store the number of matching-indices found by each thread, so we know the limit to search in best_indices/scores_arr
                    
                    work_size:Natural,  # number of hashes to process/compare with query_hash by each threads.                    
                    max_indices_count:Natural,         # maximum number of possible hash indices that could be collected during comparison/scanning.
                    
                    offset:int,        # indicates the starting index to use for stored_hashes.
                    offset_topK:int,   # indicates the offset in best_indices_arr, and best_scores aray, to start storing index of potential matches
                    threshold:Natural,
                    final_hash_size:Natural  # This should be inclusive of extra PAYLOAD size if any.(for now no payload.. just hash data)                   
                    ]

proc query_thread(data:ThreadData) {.thread.} = 
    # Each thread compares the query_hash, with each hash provided to it as Work Size.
    # if less than some threshold, it would store the index of the that hash. (NOTE: such index would be relative, we later can get the absolute by adding proper offsets).
    
    # destructure thread data.
    let threshold = data.threshold
    let count_stored_hashes = data.work_size # (how many hashes to compare)
    let final_hash_size = data.final_hash_size

    # using the corresponding offset, we find the address this thread would start from !
    let hashes_pointer = cast[int](data.stored_hashes_arr) +  (data.offset * data.final_hash_size)     # it would be incremented in `hash_size`
    let token_prefix_arr = cast[ptr UncheckedArray[uint8]](cast[int](data.token_prefixes_1) +  (data.offset * 1))  # each element is the original byte of token, corresponding to hash being compared!

    # indices_pointer will always have a set/unique  matching absoluted (token/hash) Indices
    let indices_pointer = cast[ptr UncheckedArray[int]](cast[int](data.best_indices_arr) + (data.offset_topK * sizeof(int)))
    let scores_pointer = cast[ptr UncheckedArray[int]](cast[int](data.best_scores_arr) +  (data.offset_topK * sizeof(int)))

    let do_prefix_match = data.do_prefix_match
    let query_token_byte = data.query_token_byte

    var count = 0
    var other_count = 0
    for i in 0..<count_stored_hashes:
        let temp = cast[ptr UncheckedArray[uint8]](hashes_pointer + i * final_hash_size)

        # implement prefix match.
        if do_prefix_match and query_token_byte != token_prefix_arr[i]:
            # NOTE: if user  knows first character is `h`, 
            continue

        let score = compare_tlsh_hash(data.query_hash, temp, leave_quartile_diff = true)  # leaving quartile differences.. seems to work better!
        if score <= threshold:

            if unlikely(count >= data.max_indices_count):
                let temp_index = count mod data.max_indices_count
                let already_stored_score = scores_pointer[temp_index] # cycle through ONLY AFTER once filled fully
                if (score < already_stored_score): # comparison would always be with valid values, as filled fully already..
                    indices_pointer[temp_index] = i + data.offset
                    scores_pointer[temp_index] = score
                    count += 1
            else:
                indices_pointer[count] = i + data.offset
                scores_pointer[count] = score
                count += 1
    
    data.indices_count_ptr[] = min(data.max_indices_count, count)

proc myComp(x,y:tuple[hash_idx:int, len_diff:int, score:int]):int = 
    # NOTE: sorting by length works, because we always have a cutoff on threshold.
    # so only good enough matches are collected before running `sorting`.

    if x.len_diff  <= 2 and y.len_diff <= 2 :
        # first score and then length..
        result = cmp(x.score, y.score)
        if result == 0:
            result = cmp(x.len_diff, y.len_diff)
    else:
        # first length and then score
        result = cmp(x.len_diff, y.len_diff) # minimum is better
        if result == 0:
            result = cmp(x.score, y.score)  # minimum is better


type
    InvertedDB* = object
        stored_hashes_arr:ptr UncheckedArray[uint8]  # ptr to stored hashes where each hash has `hash_size` uint8 values.
        best_indices_arr: ptr UncheckedArray[int] # this and following is updated by threads independently during each query.
        best_scores_arr: ptr UncheckedArray[int] 

        indices_count_arr: ptr UncheckedArray[int] # allocated an int for maximum threads.. so each thread can write to it the count of matching indices.  
        
        max_threads:int = 64
        capacity:Natural = 500_000    # 500k unique tokens. (could be overridden .. but to add logic!)  (used to allocate share memory during init)

        top_k:Natural = 2000            # at-max top 2000 results. (this would be difficult to improvise after init! )
        hash_size:Natural = 35          # donot change this until you know what you are doing!
        counter*:Natural = 0             # counting number of hashes stored so far. 

        # prefix, a poor man's dict/associative array/table/mapping. TODO: get a rough idea of latency  this adds ,since a table/dict is really quick.
        hash_prefixes_4: ptr UncheckedArray[uint8] # first 4 bytes are stored for each generated hash we scan this later during append to find if that has already exist. 
        token_prefixes_1: ptr UncheckedArray[uint8] # first bytes of a token being indexed, (to implement prefix matching, in case user quite sure of first character in spelling!) 
        
        document_ids_arr:seq[SetTest]  # length would be same as CAPACITY. it storeds documents ids pointed to by each hash.

        # store the actual token for a hash, helps in debugging, may even allow us to return possible correct spellings!
        tokens_original:seq[string] # corresponding token for a hash (index acts as key) 
        initialized:bool = false 

proc `=copy`(a:var InvertedDB, b:InvertedDB) {.error.}
# proc `=sink`(a:var InvertedDB, b:InvertedDB) {.error.}

proc init(db:var InvertedDB, capacity:Natural, top_k:Natural = 2_000)=
    db.capacity = capacity
    db.top_k = top_k

    db.stored_hashes_arr = cast[ptr UncheckedArray[uint8]](allocShared0(capacity * db.hash_size))
    db.hash_prefixes_4 = cast[ptr UncheckedArray[uint8]](allocShared0(capacity * 4))
    db.token_prefixes_1 = cast[ptr UncheckedArray[uint8]](allocShared0(capacity * 1))

    doAssert len(db.document_ids_arr) == 0
    for i in 0..<capacity:
        db.document_ids_arr.add(initSetTest())

    # each thread can write to it (wait-free) while comparing hashes
    db.best_indices_arr = cast[ptr UncheckedArray[int]](allocShared0(sizeof(int) * top_k))
    
    # fill with high enough values initial, so that logic works in query_thread.. (minimum of score is kept, we cycle through it top_k is overshoot!)
    db.best_scores_arr = cast[ptr UncheckedArray[int]](allocShared(sizeof(int) * top_k))
    for i in 0..<top_k:
        db.best_scores_arr[i] = int(high(int32))  # lower score is better one!

    db.indices_count_arr = cast[ptr UncheckedArray[int]](allocShared0(sizeof(int) * db.max_threads))

    # also store the corresponding original token for each hash!
    db.tokens_original = newSeq[string](capacity)
    db.initialized = true

proc init*(capacity:Natural = 1_000_000, top_k = 2000):InvertedDB = 
    result = default(InvertedDB)
    doAssert result.initialized == false
    init(result, capacity = capacity, top_k = top_k)

proc query_single(db:InvertedDB, query_hash:string, num_threads:Natural = 1, threshold:Natural = 150, prefix_match:bool = false, query_token_byte:uint8 = 0)=
    # NOTE: this itself is not thread SAFE.. i.e make sure control access to this routine FROM another module/library in a sequential manner.

    assert not isNil(db.stored_hashes_arr)
    assert num_threads <= db.max_threads - 1

    # note that dynamic thread creation has its cost.. but if work is enough... it almost amortizes!
    # var thr: array[0..<1, Thread[ThreadData]]
    var thr = newSeq[Thread[ThreadData]](num_threads)
    let total_hashes_stored = db.counter
    var work_size = newSeq[int](num_threads)
    for i in 0..<num_threads:
        work_size[i] = total_hashes_stored div num_threads
    for i in 0..<(total_hashes_stored mod num_threads):
        work_size[i] = work_size[i] + 1

    let query_hash = toUint8Hash(query_hash)  # generate uint8 sequence! (all threads share this to read only)
    assert len(query_hash) == db.hash_size

    for i in 0..<num_threads:
        var temp:ThreadData
        temp.query_hash = cast[ptr UncheckedArray[uint8]](addr(query_hash[0])) # NOTE: we can take this address..(i think threads:on allocated on shared heap, also scoping rules make sure valid!)
        # get corresponding offset into the stored_hashes array for this thread!
        temp.stored_hashes_arr = db.stored_hashes_arr  # using offset thread would know where to start 
        temp.token_prefixes_1  = db.token_prefixes_1
        
        # using offset top_k each thread would know where to start.
        temp.best_indices_arr =  db.best_indices_arr
        temp.best_scores_arr = db.best_scores_arr
        temp.indices_count_ptr = addr(db.indices_count_arr[i]) # store here the count!

        temp.threshold = threshold
        temp.work_size = work_size[i]
        temp.final_hash_size = db.hash_size

        let top_k_each_thread  = (db.top_k div num_threads) # NOTE: if update this logic, update `stride = (db.top_k div ..) ` in query too... 
        temp.max_indices_count = top_k_each_thread
        temp.offset = 0
        temp.offset_topK = 0
        for j in 0..<i:
            temp.offset += work_size[j]
            temp.offset_topK += top_k_each_thread 

        # prefix matching necessary args
        temp.do_prefix_match = prefix_match
        temp.query_token_byte = query_token_byte # only makes sense, if we are prefix matching

        createThread(thr[i], query_thread, temp)

    joinThreads(thr)  # on windows it doesn't clean up the resources/handles by default!'

    when defined(windows):
        # have to do this manually.. https://github.com/nim-lang/Nim/issues/23350
        for i in 0..<num_threads:
            discard closeHandle(cast[Handle](thr[i].sys))

proc augment_data(data:string):string = 
    # NOTE: this also assumes data is lowercased for now!!!!
    # We augment the content, with some template in order to generate a useful TLSH hash (which requires enough variation ) to fill 50% of buckets!

    # following code is just an attempt to augment the content without biasing it due to random template.
    # may be more elegant solution exists.. this has worked surprisingly well !

    const FREQUENCY = "etaonrishdlfcmugypwbvkjxzq" # english/ascii is enough, since template is also in english... (supposed to de-bias the template effect on `data`)
    doAssert len(FREQUENCY) == 26
    # can use a lookup table, reverse look-up to de-bias effect of template!
    var lookupTable:array[ord('a')..ord('z'), char]
    for i in 0..<26:
        lookupTable[ord(FREQUENCY[i])] = FREQUENCY[26-i-1]
    
    var random_template = "this is $1-$2-$3 destined to be a value, otherwise would not have enough variation to begin with in the first place."
    var counter:int = 0
    var new_data:string = ""
    while counter < len(data):
        let runeLen = data.runeLenAt(counter)
        if runeLen == 1:
            # it means ascii
            let ordinal_value = ord(data[counter])
            if ordinal_value >= 97 and ordinal_value <= 122:
                new_data = new_data & $(lookupTable[ord(data[counter])])
            else:
                new_data = new_data & $(data[counter])
        else:
            new_data = new_data & $(data[counter..<(counter + runeLen)])
        counter += runeLen

    # de-bias the effect of random template on new_data..
    counter = 0
    while counter < len(new_data):
        let runeLen = new_data.runeLenAt(counter)
        if runeLen == 1:
            # it means ascii.. template is ascii..
            let curr_str = $(new_data[counter])    
            if curr_str == "$" or curr_str == "-" or curr_str == "1" or curr_str == "2" or curr_str == "3":
                counter += runeLen
                continue
            
            random_template = random_template.replace(curr_str, "*")
        counter += runeLen
    
    return random_template % [new_data, new_data, new_data] # % formats the string

proc query*(db:InvertedDB, 
        tokens:openArray[seq[string]],  # should be renamed as `user keywords`, and no need for nesting!,each element should be user keyword!
        prefix_match:bool  = true,
        threshold:int = 120,           # since now we are leaving quartile differences, 120 is also good instead of 150!
        num_threads:int = 1,
        top_k:int = -1,         # just limit before returning, latency same, supposed to be helpful (for now just speed up python side json decoding for demo)!        
        ):tuple[
            doc_ids:seq[DOC_ID_TYPE],
            matched_tokens:seq[int], # To be parsed, for each doc_id, there would be `n_user_keyword` tokens, -1 would indicate nothing matched for a particular keyword!
            token_mapping:OrderedTableRef[int, string], # a mapping of unique tokens ids to corresponding strings!

            # extra debugging useful stuff.
            # parse this, for each user keyword, we return possible suggestions as tokens' absolute indices, use mapping to get corresponding string on python/(nim)server side. Library does just that!
            suggestions:seq[int],      # <suggestion_count_user_keyword_1>,<s1>,<s2>,.... <suggestion_count_user_keyword_2>,<s1>,<s2>...
            found:int,                # actual unique docs count, not TOP_K
        ]=

    doAssert db.initialized == true, "Database must be initialized first!"
    var final_hash_indices:seq[seq[int]] # each internal loop, produces the "best matching hash indices"
    let stride = (db.top_k div num_threads) # this is used to create offsets earlier.. so must be matched with what creation! 
    
    for i in 0..<len(tokens):  # each iteration is supposed to word/spelling user has entered! (in english a longer query is whitespace limited !)
        let user_query = tokens[i][len(tokens[i])-1] # assuming original user query is always appened in the last (followed by subwords !)
        var final_data:seq[tuple[hash_idx:int, len_diff:int, score:int]] # this collects stats for `current` user query. so that we can sort them before processing next user query.

        for token in tokens[i]:
            # echo "\tprocessing: ", token
            let token_augmented = augment_data(token)
            let (flag, token_hash) = generate_tlsh_hash(token_augmented)

            assert flag == true, "expected to be a valid hash!"
            db.query_single(
                query_hash = token_hash,
                num_threads = num_threads,
                threshold = threshold,
                prefix_match = prefix_match,
                query_token_byte = uint8(user_query[0])
            )

            # here we post-process for getting the `top possible correct spellings for user_query`.
            let user_query_len = len(user_query)
            
            var data = newSeq[tuple[hash_idx:int, len_diff:int, score:int]](db.top_k) # to be used for further sorting and stuff!
            var counter = 0
            for i in 0..<num_threads:
                let indices_count = db.indices_count_arr[i] # for this thread. (updated in the query_thread every time) so no need to reset !    
                for j in 0..<indices_count:
                    let 
                        hash_idx = db.best_indices_arr[i*stride + j]
                        score = db.best_scores_arr[i*stride + j]
                        stored_token{.cursor.} = db.tokens_original[hash_idx] # just want to read only..(no need to create a new string), if compiler cannot figure it out.
                        len_diff = abs(len(stored_token) - len(user_query))

                    # update data sequentially
                    data[j+counter] = (hash_idx: hash_idx,
                                        len_diff : len_diff, 
                                        score: score)
                
                counter += indices_count

            final_data.add(data[0..<counter]) # later sorted for after each of the subtokens for a user query are processed.

        final_data.sort(
            cmp = myComp,
            order = Ascending
        )

        var temp:seq[int] # best matching indices for this user query. (NOTE we limit this...)
        let limit = 120    
        var temp_set = initHashSet[int]() # limit is less so not so much latency is added, right!
        for i in 0..<len(final_data):
            let hash_idx = final_data[i].hash_idx
            if not (hash_idx in temp_set):
                temp.add(hash_idx)
                temp_set.incl(hash_idx)
            
            if len(temp_set) == limit:
                break

        final_hash_indices.add(temp) # keep best matching hash indices for this user spelling/keyword.
    
    # ------------------------------
    # a sequence of length equal to number of keywords from the user query/phrase!
    let n_user_keywords = len(final_hash_indices)
    let final_limit = 16     
    let unique_tokens_mapping = newOrderedTable[int, string](final_limit * n_user_keywords)

    # Allocate sufficient memory to hold the [document ids and corresponding matching tokens]
    var max_possible_documents:uint32 = 0
    var memory_idx = 0'u32       # index into some_memory,logical (doc_id and n_user_keywords number of matching tokens, -1 if not matched)
    for i in 0..<n_user_keywords:
        for hash_idx in final_hash_indices[i]:
            max_possible_documents += db.document_ids_arr[hash_idx].size
    
    var memory_doc_ids = newSeq[DOC_ID_TYPE](max_possible_documents.int)
    var memory_tokens = newSeq[int](max_possible_documents.int * (n_user_keywords))
    let some_ptr = cast[ptr UncheckedArray[int]](addr(memory_tokens[0]))
    for i in 0..<len(memory_tokens):
        some_ptr[i] = -1
    
    let id_2_memory = newOrderedTable[DOC_ID_TYPE, uint32](max_possible_documents.int)  # map the DOC_ID_TYPE into an `index/offset` of some PACKED MEMORY
    var suggestions = newSeq[int](final_limit * n_user_keywords + n_user_keywords) # first value is count for keyword 0, followed by absolute token indices, then count for keyword 1 and so on, if not match, count would be 0, parse at will! 
    var count_for_suggestions = 0     # index into the suggestions array, packed..

    for u_k_index in 0..<n_user_keywords:       # equals to number of user keywords!
        # -------------------------------------------------------------------------------
        # -------- One more sorting based on levenstein distance (higher precision!) ------
        # --------------------------------------------------------------------
        let user_query {.cursor.} = tokens[u_k_index][len(tokens[u_k_index])-1] # TODO: simplify it
        # for each keyword, we keep top limit only by running through levenshtien distance!
        let already_top = len(final_hash_indices[u_k_index])
        var temp_scores = newSeq[int](already_top)
        var temp_indices = newSeq[int](already_top) # [0 .. <already_top], relative, later use to get the absolute indices into the hash/tokens stored!
        for j in 0..<len(temp_scores):
            var temp_token {.cursor.} = db.tokens_original[final_hash_indices[u_k_index][j]]
            temp_scores[j] = editDistanceAscii(temp_token, user_query)
            temp_indices[j] = j

        proc myComp3(idx_1, idx_2:int):int = 
            return cmp(temp_scores[idx_1], temp_scores[idx_2])
        temp_indices.sort(myComp3,
            order = Ascending)
        # --------------------------------------------------------------------------------------------

        doAssert len(temp_indices) == len(final_hash_indices[u_k_index])

    # ----------------------------------------------------------------------------------
        var n_indices = min((len(temp_indices)), final_limit)  # only TOP-K (final limit) are kept!
        
        # update the suggestions array as discussed, first count, then tokens' indices for this keyword token
        suggestions[count_for_suggestions] = n_indices # how many suggestions for keyword ix, then we fill the indices for those tokens!
        count_for_suggestions += 1
        
        for ix in 0..<n_indices:
            # only one matching token for each user keyword for a document.. (best one!) 
            let absolute_hash_idx = final_hash_indices[u_k_index][temp_indices[ix]]

            # update the hash idx for suggestions too, this way we can know possible suggestions for each keyword, to display!
            suggestions[count_for_suggestions] = absolute_hash_idx
            count_for_suggestions += 1
 
            # save the original token too.
            unique_tokens_mapping[absolute_hash_idx] = db.tokens_original[absolute_hash_idx] # even if overwrite, ok

            let documents_ptr = db.document_ids_arr[absolute_hash_idx].values
            let documents_count = db.document_ids_arr[absolute_hash_idx].size

            for k in 0..<documents_count:
                let doc_id = documents_ptr[k]
                
                # NOTE: checking a key and writing key adds most of the latency! TODO in future! (may be bloom filter to speed up !)
                if not(doc_id in id_2_memory):
                    id_2_memory[doc_id] = memory_idx # map the doc_id into an index into some_memory, this takes the most time!
                    memory_idx += 1
                
                let offset = id_2_memory[doc_id]
                memory_doc_ids[offset] = doc_id

                let token_offset = offset.int * n_user_keywords + u_k_index
                let value = memory_tokens[token_offset]
                if value == -1: # if doc_id and i is repeated next time, then its value != -1, hence not updated. we keep the best/first one only!
                    memory_tokens[token_offset] = absolute_hash_idx

    let unique_docs_count = len(id_2_memory)
    
    # ------------------------------------------------------------------------------------------------------------------------
    #                Sorting based on the count (only if n_user_keywords > 1)
    # ---------------------------------------------------------------------------------
    var relative_indices = newSeq[int](unique_docs_count)
    for i in 0..<unique_docs_count:
        relative_indices[i] = i

    if n_user_keywords > 1:
        # Generate a count table!, only if more than one keyword, we need to sort based on the number of tokens matched 
        var count_table = newSeq[int](unique_docs_count)
        for i in 0..<unique_docs_count:
            var count:int = 0           # count for how many tokens have been matched for each doc!
            let token_offset = i*n_user_keywords
            for j in 0..<n_user_keywords:
                let matched_token = memory_tokens[token_offset + j]
                count += int(matched_token > -1)
            count_table[i] = count
        
        proc someComp(i,j:int):int =
            # NOTE: take care, i keep forgetting how cmp effects, idea is to preserve some order if alreay, double check if taking unexpected latency!
            if count_table[i] == count_table[j]:
                return cmp(i, j) # order intact, if i < j!
            else:
                return cmp(count_table[j], count_table[i])
        
        relative_indices.sort(someComp, order = Ascending)

    # limit if have to
    if top_k > 0:
        relative_indices = relative_indices[0..<min(len(relative_indices), top_k)]  # can i prevent copy here...! read only i guess!

    # ---------------------------------------------------
    # Final collection, can just shift the complexity, not get rid of it.. still quite fast, I am tired at this point!
    #--------------------------------------------------------
    var final_doc_ids = newSeq[DOC_ID_TYPE](len(relative_indices))
    var final_matching_tokens = newSeq[int](n_user_keywords * len(relative_indices))  # parse it at demand i guess!
    for i,ix in relative_indices:
        final_doc_ids[i] = memory_doc_ids[ix]
        for j in 0..<n_user_keywords:
            final_matching_tokens[i*n_user_keywords + j] = memory_tokens[ix * n_user_keywords + j]

    result.doc_ids =  final_doc_ids 
    result.matched_tokens =  final_matching_tokens
    result.token_mapping =  unique_tokens_mapping
    result.suggestions = suggestions
    result.found = unique_docs_count      # Note: actual found matches, not TOP_K. (so as to display client side... and get an idea!)
      
proc checkHashPresence(db:InvertedDB, token_hash:seq[uint8]):tuple[flag:bool, hash_idx:int] {.inline.} =
    # Rather than using a table/hashsets, we use a prefix array which has stored first 4 bytes, and can speed up scanning the presence of some hash.

    var flag = false
    let temp = cast[ptr UncheckedArray[uint8]](db.hash_prefixes_4)
    for i in 0..<db.counter:

        var sum_temp:bool = true
        for j in 0..<4: # opportunity for sse/simd, if compiler doesn't do it!
            sum_temp = sum_temp and (temp[i*4 + j] == token_hash[j])
        
        if sum_temp == true:
            # investigate further
            let stored_hash = cast[ptr UncheckedArray[uint8]](cast[int](db.stored_hashes_arr) +  i * (db.hash_size))
            for k in 4..<db.hash_size: # can start with 4 as 4 already matched!
                sum_temp = sum_temp and (token_hash[k] == stored_hash[k]) 
                if sum_temp == false:
                    break
            
            if sum_temp == true:
                return (flag:true, hash_idx:i)
            else:
                continue # try the rest of hashes
    
    return (flag:false, hash_idx: -1)

proc checkTokenPresence(db:InvertedDB, token:string):tuple[flag:bool, hash_idx:int] {.inline.} =
    var flag = false
    for i in 0..<db.counter:
        let temp_str {.cursor.} = db.tokens_original[i]
        if temp_str == token:
            return (flag: true, hash_idx:i)
    return (flag:false, hash_idx: -1) 

proc append*(db:var InvertedDB, document_id:uint32, tokens:openArray[string]):int=
    # This assumes all the tokens/keywords for given document_id are provided.
    for token in tokens:
        if len(token) == 0:
            continue

        if db.counter >= db.capacity:  # should never be greater as incremented in form of 1.
            echo "capacity reached "
            return -1
                
        let token_augmented = augment_data(token)
        let (flag, token_hash_hex) = generate_tlsh_hash(token_augmented)
        let token_hash_u8 =  toUint8Hash(token_hash_hex)  

        if flag == false:
            echo "[WARNING]: not enough variation for " & token & "  but shouldn't have happened!"
            continue
        
        let (hash_present, hash_idx) = db.checkHashPresence(token_hash_u8)
        if hash_present:
            db.document_ids_arr[hash_idx].add(document_id)  # just update the set containing document ids!
            continue

        assert len(token_hash_u8) == db.hash_size
        let curr_counter = db.counter
        for i in 0..<(db.hash_size):
            db.stored_hashes_arr[(curr_counter * db.hash_size) + i] = token_hash_u8[i]

        # save 4 bytes into prefix arr also, to speed up hash presence checking!
        let temp_2 = cast[ptr UncheckedArray[uint8]](cast[int](db.hash_prefixes_4) + db.counter * 4)
        for i in 0..<4:
            temp_2[i] = token_hash_u8[i]
        
        # save first byte of token also, why? it would help us make sure to implement `prefix match`, we just save 1 byte.
        let temp_3 = cast[ptr UncheckedArray[uint8]](cast[int](db.token_prefixes_1) + db.counter * 1)
        for i in 0..<1:
            temp_3[i] = uint8(token[i])
        
        db.document_ids_arr[db.counter].add(document_id)
        db.tokens_original[db.counter] = token
        db.counter += 1
    return 0

proc get_token*(db: InvertedDB, idx:int):string  =
    assert idx < db.counter
    return db.tokens_original[idx]

proc get_stats*(db: InvertedDB):string = 
    # for now just return an estimate of occupied Memory, if using Nim allocator, this should give good estimate!
    return $getOccupiedMem()
