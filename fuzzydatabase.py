from typing import List, Tuple, Optional, Iterable, Union
from threading import RLock
import os
import json
from collections import OrderedDict
import array

#local unidecode python package.
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".", "unidecode"))
import unidecode

from .ext import tlsh_python_module as tlsh_nim
from .ext import fasterfuzzy

from .utils import extended_tokenizer

############################################################################################################
def defaultPreprocessor(data:str, remove_stop_words:bool = False, use_stemmer:bool = True, skip_numbers:bool = False) -> Tuple[bool, str]:
    
    assert use_stemmer == False, "expected this to be false, as we donot need for now and later intead copy stemmer to separate pure python code."
    if use_stemmer:
        # TODO: remove this stemmer dependency, include code directly....
        from nltk.stem.snowball import SnowballStemmer  # or porter stemmer .
        stemmer = SnowballStemmer(language="english")

    STRIP_CHARS = ["*",":", ",", ")", "(", "'", ".",'"',"\n","\r", "[", "]","?"]  # may be more i guess..
    STOP_WORDS = ['the',
     'in',
     'of',
     'is',
     'a',
     'an',
     'and',
     'was',
     'it',
     'to',
     'he',
     'for',
     'an',
     'as',
     'by',
     'on',
     'from',
     'are',
     'or',
     'that',
     'also',
     'with',
     '–',
     'at',
     'known',
     'his',
     'she',
     'has']
    
    
    content = data
    
    # Strip characters.
    for char in STRIP_CHARS:
        content = content.strip(char)

    if len(content) == 0:
        return (False, "")
    
    if remove_stop_words == True and content.lower() in STOP_WORDS:
        return (False, "")
    
    if content[0].isupper():
        return (True, content.lower()) # as it is , no stemming, (supposed to be a named entity).
    
    if skip_numbers == True:
        should_skip = False
        for i in [str(j) for j in [0,1,2,3,4,5,6,7,8,9]]:
            if i in content:
                should_skip = True
                break
        if should_skip == True:
            return (False, "")
        
    if use_stemmer == True:
        stemmed = stemmer.stem(content.lower())
        return (len(stemmed) > 0, stemmed)
    else:
        return (True, content.lower())
#########################################################################################

class FuzzyIndex(object):
    def __init__(self, name = "keywordsearch", file_path:Optional[os.PathLike] = None):
        
        self.__lock = RLock()
        self.name = name
        
        self.hash2ix = OrderedDict()     # mapping from a hash to set a {ix}
        self.__invalid_indices = set()     # invalidate an index, by adding to it.  would not be considered during query.
        # in case we are using the nim backend for querying.
        self.hash_array = array.array("B")          # uint8
        
        self.query_cache = OrderedDict()
        self.__query_cache_size = 10    # soft limit..        
        self.__n_resources = 0
        self.__hash_size = 35                       # base hash_size
        self.__threshold = 150                      # should be in range (120 - 200)!

        # delimiters to tokenize a query. (Add more if one is commonly used and not included)
        self.extra_delimiters = [" ", "_", ".", "-", ":", "//","/","\\"]  # order not expected to matter!

        # use a predefined vocabulary to generate subwords from words too..
        vocab_path = os.path.join(os.path.dirname(__file__), "data", "vocab.txt")
        assert os.path.exists(vocab_path)
        with open(vocab_path, "r", encoding="utf8") as f:
            self.__vocab = f.read().strip().split("\n") # A list, sorted by length .
        del vocab_path 
        
        if file_path is not None:
            self.load(file_path)

    def __str__(self) -> str:
        info = "FuzzyDatabase: {} \nUnique Resources Indexed: {}\nUnique Hashes: {}\nInvalid keys: {}".format(self.name, self.__n_resources, len(self.hash2ix), len(self.__invalid_indices))
        return info
    
    def _tokenize(self, content:Union[str, Iterable[str]], delimiter_ix:int = 0, use_extended_tokenizer:bool = True) -> Iterable[str]:
        """ Supposed to run all delimiters on an original string content, to tokenize exhaustively.
        """
        if isinstance(content, str):
            content = [content]
        
        result = []
        for c in content:
            for x in c.split(self.extra_delimiters[delimiter_ix]):
                if len(x) > 0:
                    result.append(x)
        
        if delimiter_ix ==  len(self.extra_delimiters) - 1: 
            
            if use_extended_tokenizer == True:
                subwords = extended_tokenizer(words = result, vocab = self.__vocab)
                
                for subword in subwords:
                    if subword not in result:
                        result.append(subword)
                    del subword
                del subwords            
            return result
        else:
            return self._tokenize(result, delimiter_ix = delimiter_ix + 1, use_extended_tokenizer=use_extended_tokenizer)
            
    def _augment_data(self, data:str) -> str:
        # secret sauce !

        FREQUENCY = "etaonrishdlfcmugypwbvkjxzq"
        sample_dict = {}
        for i, character in enumerate(FREQUENCY):
            sample_dict[character] = FREQUENCY[len(FREQUENCY) -1 -i]

        random_string = "this is {}-{}-{} destined to be a value, otherwise would not have enough variation to begin with in the first place."

        for d in data:
            if d == "{" or d == "}":
                continue 
            random_string = random_string.replace(d,"*")

        new_data = ""
        for d in data:
            if d in sample_dict:
                new_data += sample_dict[d]
            else:
                new_data += d

        return random_string.format(new_data, new_data, new_data )
    
    def _preprocess(self, content:str, use_stemmer = False, remove_stop_words:bool = True) -> tuple[bool, str]:        
        flag = False
        fuzzy_hash = None
        preprocessed = None
        
        flag, preprocessed = defaultPreprocessor(data = content, remove_stop_words=remove_stop_words, use_stemmer = use_stemmer)            
        if flag == True:
            flag, fuzzy_hash = tlsh_nim.generate_tlsh_hash(self._augment_data(preprocessed).encode("utf8"))  # generate the fuzzy hash                    # invalide the ix if not a good hash.
        return (flag, fuzzy_hash, preprocessed)
    
    def _debug_new(self, query:str, paragraph:str):
        """
        Inputs:
            query aka word:str, a word without any "space" .
            paragraph:str, paragraph like text data .         
        """
        final_result = []
        main_delimiter = " "
        assert main_delimiter not in query, "expected a word, not a sentence."
        base_tokens = paragraph.split(main_delimiter)
        word_tokens = self._tokenize(query, use_extended_tokenizer = True)    

        for x in word_tokens:
            flag, x_hash, preprocessed_x = self._preprocess(x, use_stemmer = False)
            index_score = []  # (index, score) tuple iterable.
            
            for i,t in enumerate(base_tokens):            
                temp_tokens = self._tokenize(t, use_extended_tokenizer = True)
                old_score = 100000 # high enough... lower would be better

                best_base_substring = None
                for j in temp_tokens:
                    flag, j_hash, preprocessed_j = self._preprocess(j, use_stemmer=False)
                    if flag == False or preprocessed_x[0] != preprocessed_j[0]:
                        continue
                    
                    temp_score = tlsh_nim.compare_tlsh_hash(x_hash, j_hash)
                    if temp_score < old_score: # lower score means better match, very close to zero or zero indicates exact match.
                        old_score = temp_score
                        best_base_substring = j
                    del temp_score

                if best_base_substring is not None:
                    assert best_base_substring in t  # NOTE: must exist
                index_score.append((i, old_score, best_base_substring))  # best possible score for a base_token.
                del best_base_substring
            
            # here find the best base token
            ix, score, base_substring = sorted(index_score, key = lambda x: x[1], reverse = False)[0]
            final_result.append((x, base_substring, score))
            del x
        
        print("\nFor word: {}".format(query))
        for query_token, base_substring, score in final_result:
            print("\tquery token: {}, base_subtring: {}, score:{}".format(query_token, base_substring, score))

    def _get_query_cache(self, query_hash:str, unigram:str, threshold:int = 150) -> dict:
        """
        returns a mapping of relevant keys to score. (higher the better).
        relevant keys are selecting by comparing query_hash with already stored hashes.
        """
        
        THRESHOLD = threshold
        TOP_K = 120        # at max relevant keys/hashes for each query_hash.
        if query_hash not in self.query_cache:
            if len(self.query_cache) > self.__query_cache_size:
                _ = self.query_cache.popitem(last = False)
            
            # nim based comparing.. 
            idx_score_array = array.array("i", range(TOP_K * 2))  # 100 top_k.
            fasterfuzzy.compare_fast(
            self.hash_array,  # stored hashes. (along with unigrams)
            query_hash,       # query_hash (without any unigram)
            unigram,          # this query unigram aka first character.
            idx_score_array,
            THRESHOLD,
            self.__hash_size + 1          # 35 + 1
            )
            nim_relevant_keys = {}
            for j in range(len(idx_score_array) // 2):
                temp_ix = idx_score_array[2*j]
                temp_score = idx_score_array[2*j + 1]
                if temp_ix == -1:
                    break
                else:
                    ix_start = temp_ix*(self.__hash_size + 1)
                    ix_end = ix_start + self.__hash_size
                    nim_relevant_keys[bytearray(self.hash_array[ix_start:ix_end]).hex().upper() + unigram] = temp_score
                    del ix_start, ix_end
            self.query_cache[query_hash] = nim_relevant_keys
            del nim_relevant_keys
    
        return self.query_cache[query_hash]
    
    def __get_unigram(self, data:str) -> Tuple[bool, str]:
        # find nearest ascii, it helps for different langugages. and also would be 1 byte always.
        unigram = unidecode.unidecode(data[0])[:1]  # we accept only one byte !
        unigram = unigram.lower()  # to be consistent. (lead to a weird bug earlier!!)
        return (len(unigram) == 1, unigram)
        
    def query(self, query:str, threshold:int = 150, timed:bool = False) -> Iterable[Tuple[int, List[int]]]:
        """
        It would return an iterable of tuples: (primary-key, list of scores)

        query("Hello world") -> (11, [12, 20]) , (17, [0, 30]) would indicate for index 17 first part of the query was not matched.    

        timed:bool  just empties the cache for proper benchmarking.    
    
        """
        
        if timed == True:
            self.query_cache = OrderedDict()
        if threshold != self.__threshold:  # in case threshold is update, empty cache too.
            self.query_cache = OrderedDict()
            self.__threshold = threshold
        
        query_len = 0
        relevant_data = []
        for part in self._tokenize(query, use_extended_tokenizer= False):  # TODO: here we donot use extended tokenizer, should i use ?
            with self.__lock:
                flag, query_hash, preprocessed = self._preprocess(part, use_stemmer = False)
            
            if flag == False:
                continue
            
            flag, unigram = self.__get_unigram(preprocessed)
            if flag == False:
                continue
            
            query_len += 1
            with self.__lock:
                relevant_keys = self._get_query_cache(query_hash, unigram, threshold = threshold)
            relevant_data.append((preprocessed, relevant_keys)) # for each query part, collect releveant keys.            
        
        final_set = {}
        for i, (preprocessed,relevant_keys) in enumerate(relevant_data):
            new_set = {}
            for key, score in relevant_keys.items():
                for ix in self.hash2ix[key]:
                    if ix not in new_set:
                        new_set[ix] = score
                    else:
                        new_set[ix] = max(score, new_set[ix])  # best matching....
            
            for k, best_score in new_set.items():
                if k not in final_set:
                    prefix = [0 for _ in range(i)] # add prefix, if this is first.
                    final_set[k] = prefix + [best_score]
                else:
                    suffix = [0 for _ in range(i - len(final_set[k]))]
                    final_set[k] = final_set[k] + suffix + [best_score]
            
            del new_set
        del relevant_data
        
        # make sure we collect contribution for each key in final set, add [0] if needed.
        for k in final_set.keys():
            curr_len = len(final_set[k])
            if curr_len < (i+1):
                suffix = [0 for _ in range(i+1 - curr_len)]
                final_set[k] = final_set[k] + suffix
        
        return sorted(final_set.items(), reverse = True, key = lambda x: sum(x[1]))
        
    def update(self, data:str, key:int, use_extended_tokenizer:bool = True):
        with self.__lock:
            # tokenize paragraph/sentence into words.
            words = self._tokenize(data, use_extended_tokenizer = use_extended_tokenizer)
            # for part in self._tokenize(data):
            for part in words:
                flag, fuzzy_hash, preprocessed = self._preprocess(content = part, use_stemmer=False, remove_stop_words=True)
                if flag == False:
                    continue
                 
                flag, unigram = self.__get_unigram(preprocessed)
                if flag == False:
                    continue
    
                new_hash = fuzzy_hash + unigram  # storing the first character, along with hash.
                if new_hash not in self.hash2ix:
                    self.hash2ix[new_hash] = set()                    
                    for b in self.__bytearray_from_hash(new_hash):
                        self.hash_array.append(b)
                    
                self.hash2ix[new_hash].add(key)
            
            self.__n_resources +=1

            self.query_cache = OrderedDict()           # for very update, clear the cache too.., as there is new data...
    
    def __bytearray_from_hash(self, fuzzy_hash:str) -> bytearray:
        assert len(fuzzy_hash) == self.__hash_size*2 + 1
        temp = bytes.fromhex(fuzzy_hash[:-1])
        temp = temp + fuzzy_hash[-1].encode("ascii")
        return bytearray(temp)
    
    def invalidate(self, ix:int):
        self.invalid_indices.add(ix)

    def load(self, file_path:os.PathLike):
        """load from some persistent storage..
        TODO: not updating the exact number of resources for now.. it unioning set slows it down..later..
        """
        
        if not os.path.exists(file_path):
            return (False, "{} doesn't exist".format(file_path))
        
        result = (False, "unknown")
        with open(file_path, "r") as f:
            with self.__lock:
                # n_resources_set = set()  # was just for visualization of unique resources, costly while loading large hashes!!
                temp_dict = json.load(f)
                name = list(temp_dict.keys())[0]

                if "hash2ix" not in temp_dict[name]:
                    return (False,"expected hash2ix key")
                else:
                    temp_hash2ix = {}

                    for k,v in temp_dict[name]["hash2ix"].items():
                        temp_hash2ix[k] = set(v)
                        # n_resources_set = n_resources_set.union(set(v))  # costly op, removing this since was used to track unique resources only for visualization !! 
                        del k,v
                    
                    self.hash2ix = temp_hash2ix
                    del temp_hash2ix

                    # load self.hash array too.
                    temp_hash_array = array.array("B")
                    for key in self.hash2ix:
                        temp_barray = self.__bytearray_from_hash(key)
                        for b in temp_barray:
                            temp_hash_array.append(b)
                        del temp_barray

                    self.hash_array = temp_hash_array
                    del temp_hash_array

                if "invalid_indices" not in temp_dict[name]:
                    return (False, "expected invalid_indices key")
                else:
                    self.__invalid_indices = set(temp_dict[name]["invalid_indices"])
                
                self.name = name

                del temp_dict
                del name
                
                result = (True, "")
                # self.__n_resources = len(n_resources_set)
                # del n_resources_set
        return result

    def save(self, file_path:os.PathLike) -> Tuple[bool, str]:
        """save to persistent storage.
        Only storing invalid indices and hash2ix mapping for now.
        """

        result = (False, "unknown")
        with open(file_path, "w") as f:
            with self.__lock:
                temp_dict = {}

                temp_dict[self.name] = {}
                temp_dict[self.name]["hash2ix"] = {k:list(v) for k,v in self.hash2ix.items()} # set is not serializable for json.
                temp_dict[self.name]["invalid_indices"] = list(self.__invalid_indices)

                json.dump(temp_dict, f)
                result = (True, "")
        return result

    def reset(self, file_path:os.PathLike):
        with self.__lock:
            # reset the native data-structures
            self.hash2ix = OrderedDict()    
            self.__invalid_indices = set()     
            self.hash_array = array.array("B")
            self.query_cache = OrderedDict()
            self.__n_resources = 0

            # supposed to overwrite data on the disk too...
            self.save(file_path)  