# Python interface to enable schema-less (fuzzy) search.
# TODO: Use a lock to to make up for Nim side (lack of) lock for now, if using from multiple threads! 

import json
import os
import time
from collections import OrderedDict
from typing import Iterable, Any

from .ext import search_python_module as backend              # which encapsulates the backend (inverted index)
from .preprocessing import PreprocessPipeline                 # contains frontend 

TOKENIZER_DATA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data","tekken.json")
class MalharSearch(object):
    def __init__(self, capacity:int = 1_000_000, top_k:int = 10_000):
        """
        Inputs:
            capacity:int, capacity to store unique tokens, 1 Million seems good enough, if already have an idea could be set smaller to save RAM. (TODO: automatic increment/decrement)
            top_k:int     (top possible best matches for a token, its more than enough.)
        """

        # frontend.
        self.frontend = PreprocessPipeline(
                tokenizer_data_path = TOKENIZER_DATA_PATH,
                faster = True,
                debug = False)
        
        # backend
        backend.initDB(capacity = capacity, top_k = top_k)

    def append(self, document_id:int, content:str) -> int:
        """Return -1 when capacity is reached, else 0"""
        tokens = self.frontend.preprocess(content)
        err_code = backend.append(document_id, tokens)  # -1, when capacity is reached. TODO: update/increase capacity routine in backend..
        return err_code
    
    def query(self, query:str, prefix_match:bool = True, threshold:int = 120, num_threads:int = 1, top_k:int = 200, **kwargs):
        """
        For example for a query : `hellop world`,
        we generate following:  [ ["hello", "p", "hellop"],  # possible tokenization of a wrong/user spelling, with user spelling append always in the last.
                                  ["world"],            
                                ]

        Inputs:
            query: user keywords/phrase
            prefix_match:bool, in case user is sure about the first character/byte, in the keyword spelling. 
            threshold , higher value would lead to inclusion of more un-sure matches. but may be useful for some rare cases with very different spellings!
            num_threads, set the number of threads dynamically, most of the time extra overhead in creating threads dynamically is well worth this!
            top_k:int = 100  (TODO: add pagination or stuff, otherwise keep it < 500, as python json-decoder could be a bit slow!)
            kwargs: keyword arguments for `get_document` routine, i am not a fan of passing kwargs/args, but so that can easily passed to the CUSTOM `get_document` routine, if needed. For example a transaction handle or something to get data from a database!! 
        
        """

        # split on delimiters first, for `id?xyz`, it should be "id" and "xyz", as we donot include delimiters in the "indexed" tokens!
        query_orig = query       # for later 
        for x in self.frontend.extra_delimiters:
            query = query.replace(x, " ")        
        
        keywords = []
        for q in query.split(" "):
            if len(q) > 0:
                keywords.append(q)
        
        keyword_tokens = []
        for k in keywords:            
            keyword_tokens.append([k])

        n_user_keywords = len(keywords)

        tic = time.perf_counter_ns()
        result_json = backend.query(
            query_json = json.dumps(keyword_tokens), # serialize!
            prefix_match = prefix_match,             
            threshold = threshold, 
            num_threads = num_threads,
            top_k = top_k         # keep it even thousand, main idea is keeping limited, we just speed up json decoding in python, 1000 is more than enough for demos!
            )
        toc = time.perf_counter_ns()
        # print("[BACKEND Python]: {}ms".format((toc - tic) / 1e6))
        search_latency = (toc - tic) / 1e6
        # print(result_json)

        tic = time.perf_counter_ns()
        query_result = json.loads(result_json)  # deserialize! # later can cache it..so as to stream actual document content for a page! when only asked!
        toc = time.perf_counter_ns()
        # print("[JSON Load Python]: {}ms".format((toc - tic) / 1e6))


        # NOTE: JSON parsing latency just is present because we are using python API, otherwise can use a Nim server to just returned final JSON directly to client/browser!
        top_matches = len(query_result[0])  # limited to top_k or less
        actual_matches_found = query_result[4] 
        token_mapping = query_result[2]
        suggestions = query_result[3]
        token_mapping = {int(k):v for k,v in token_mapping.items()} # JsonDecoder creates/expects strings as keys!
        assert len(query_result[1]) == (top_matches * n_user_keywords), "For each doc_id, there must be some (matched/unmatched) token for each of user keyword!!"
        def collect_matched_tokens(doc_index:int) -> list[str]:
            # doc_index: logical index into the query_result[0] aka doc_ids, not doc_id itself.. to get corresponding matching tokens.
            # since query_result[1] is returned as packed array, this is for demo, may add minor latency, on nim side we already have everything!  
            result = []
            for i in range(n_user_keywords):
                matched_token_idx = query_result[1][doc_index * n_user_keywords + i]
                if matched_token_idx != -1:
                    result.append(token_mapping[matched_token_idx])
            return result
        
        def collect_suggestions():
            """
            We generate/collect the "suggestions" for each of the keyword.
            So as to display corresponding suggestions on an interface to better understand the database/domain user is querying...
            """
            counter = 0
            result = {}
            for keyword in keywords:
                result[keyword] = []
                temp_count = suggestions[counter]
                counter += 1
                for _ in range(temp_count):
                    result[keyword].append(token_mapping[suggestions[counter]])
                    counter += 1
            return result
        
        final_results = []
        for logical_index, doc_id in enumerate(query_result[0]):
            doc_content = self.get_document(doc_id, **kwargs)         # this could/should be overridden, depending on where original data is stored!
            final_results.append({
                "doc_id":doc_id,
                "query":query,             # NOTE:(may have been stripped/lowered), helps in case client sends multiple requests, to render expected order!
                "matched_tokens":collect_matched_tokens(logical_index),       # TODO: we already have, just have to parse quickly and add here!
                "document":doc_content
                })
            
        return {"suggestions":collect_suggestions(), "results":final_results,"latency":int(search_latency), "found":actual_matches_found}

    def get_count(self) -> int:
        return backend.get_count()
    def get_token(self, token_idx:int) -> str:
        return backend.get_token(token_idx)
    def get_stats(self) -> str:
        # TODO: for now just an estimate of RAM
        return backend.get_stats()
    
    def get_document(self, document_id:int, **kwargs) -> Any:
        """
        This routine is responsible to getting the actual original Content given a document_id, as this library doesn't concern itself with storage for original content.
        It could be in a database/S3 storage, based on the document-id, user should be able to retrieve it on demand!
        """
        # NOTE: provide your own routine, by using this as ParentClass. For now we return None so as not to raise exception!
        # Supposed to be overridden, depending upon the database/domain!
        return None