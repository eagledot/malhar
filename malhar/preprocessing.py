# This is supposed to contain all the code for preprocessing ..
# Credits: Some code is taken from `https://github.com/mistralai/mistral-common` (under Apache 2.0 license)

from typing import Dict, List, Optional, Type, TypedDict, Union, Iterable, Tuple
from dataclasses import dataclass
from pathlib import Path
import base64
import json
import os

# extension!
from .ext import tokenizer as tokenizer_nim

## a bunch of classes taken from tekken.py .. just to have easier understanding..
class TokenInfo(TypedDict):
    rank: int
    token_bytes: str  # base64 encoded
    token_str: Optional[str]

class TekkenConfig(TypedDict):
    pattern: str
    num_vocab_tokens: int
    default_vocab_size: int
    default_num_special_tokens: int
    version: str

@dataclass
class MultimodalConfig:
    image_patch_size: int
    max_image_size: int

class ModelData(TypedDict):
    vocab: List[TokenInfo]
    config: TekkenConfig
    version: int
    type: str
    multimodal: MultimodalConfig

def load_tekken_json(path:str):
    """
    Load tekken.json comes with Nemo mistral
    Contains the actual pairs which are generated during training, over the corpus.
    Doesn't contain special tokens, handled separately for mistral models ateast
    it just loads the vocabulary words and ranks, bytes are base64 encoded .
    """
    if isinstance(path, str):
        path = Path(path)
    assert path.exists()
    with open(path, "r", encoding = "utf8") as f:
        untyped = json.load(f)
        model_data: ModelData = untyped
        return model_data

def reload_mergeable_ranks(
    vocab: List[TokenInfo],
    max_vocab: Union[int, None] = None,
) -> Dict[bytes, int]:
    """
    Reload our tokenizer JSON file and convert it to Tiktoken format.
    """
    if max_vocab is not None:
        assert len(vocab) >= max_vocab, (len(vocab), max_vocab)
        vocab = vocab[:max_vocab]

    # build ranks
    ranks: Dict[bytes, int] = {}
    for i, x in enumerate(vocab):
        assert x.keys() == {"rank", "token_bytes", "token_str"}
        assert x["rank"] == i
        merge = base64.b64decode(x["token_bytes"])
        assert i >= 256 or merge == bytes([i]), (i, merge)
        
        # original (file in ordered, so best rank is assigned to all 4 variations!)
        if merge not in ranks:
            ranks[merge] = x["rank"]
            ranks[merge.strip()] = x["rank"]
            ranks[merge.lower()] = x["rank"]
            ranks[merge.lower().strip()] = x["rank"] 
        
    # sanity check (don't we have changed the code !)
    #     assert len(ranks) == len(vocab)
    #     assert set(ranks.values()) == set(range(len(ranks)))

    return ranks


def simple_merge(text:str, merge_pairs:Dict[bytes, int], return_ids:bool = False):
    """
    Our own naive merging, it is in pure python around 10-12 times slower than tik-token i guess!
    But we keep it simple, don't use regex patterns and stuff.. works well for almost all cases.
    Later we can speed it by writing it in a faster language, if all logic works out correctly!
    
    return_ids: in case want to return the "id/rank" provided in tokenizer.json/data. (by default false we are more interested in tokens and we mostly create our own final mapping from token to ids, irrespective of a tokenizer)
    
    """
    
    text_bytes = text.encode("utf8")  # it should not fail
    byte_pairs = [bytes([x]) for x in text_bytes]   # original bytes, we keep updating this.. until we merge all the possible pairs ..
    
    while True:
        results = []  # temporary storage
        for i,pair in enumerate(byte_pairs[:-1]):
            temp = pair + byte_pairs[i+1]
            
            if temp in merge_pairs:
                rank = merge_pairs[temp]
                results.append((temp, (i,i+1), rank))
            del temp
            
        # now merge the pair with highest rank!
        if len(results) > 0:
            # TODO: in case pairs have same spelling , do all those at once!
            merge_ix = sorted(results, key = lambda x: x[2], reverse = False)[0]
            
            ix = merge_ix[1][0]
            ix_plus1 = merge_ix[1][1]
            
            #update byte pairs.
            byte_pairs[ix] = byte_pairs[ix] + byte_pairs[ix_plus1] # replace with merged pair
            _ = byte_pairs.pop(ix_plus1) # delete one of the indices used in merging.
            
        else:
            # nothing left to merge..
            break
            
    if return_ids:
        final_result = [(p.decode("utf8"), merge_pairs[p]) for p in byte_pairs]
    else:
        final_result = [p.decode("utf8") for p in byte_pairs]
    return final_result


class TokenizerNemoMistral(object):
    """
    We keep it simple, by doing away with regex patterns, that tiktoken would be employing.
    We collect the Pairs obtained during training, as presented in `tekken.json`, and just use that.
    We write our own simple merge/encoding routine in python for now !
    """
    def __init__(self, tekken_path:str) -> None:
        self._tekken_path = tekken_path
        assert os.path.exists(self._tekken_path)
        self._model_data = load_tekken_json(self._tekken_path)
        self._merge_pairs = reload_mergeable_ranks(self._model_data["vocab"])

    def tokenize(self, content:str, return_ids:bool = False) -> Iterable[Tuple[str, int]]:
        return simple_merge(
            text = content,
            merge_pairs = self._merge_pairs,
            return_ids = return_ids
        )

def get_merged_tokens(tokens:list[str], merge_threshold:int = 4):
        result = []
        
        count = 0
        to_merge = None
        while count <= len(tokens) - 1:
            to_merge = tokens[count]
            count += 1
            
            for t_next in tokens[count:]:
                to_merge = to_merge + t_next
                if len(to_merge) >= merge_threshold:
                    result.append(to_merge)
                    to_merge = None
                    break
                else:
                    continue
            
            if not(to_merge is None):
                result.append(to_merge)               
        return result


class PreprocessPipeline(object):
    """Generate keywords/subwords to index/store.."""
    def __init__(self, 
                language = "english_multilingual", 
                tokenizer_data_path:str = "./data/tekken.json",
                faster:bool = True,       # use Nim code for tokenization, but results must be same!
                
                # extra options to influence tokenization.. better to initialize/provide them here for clearer purpose of this pipeline!
                lowercase:bool = True,
                whitespace_split:bool = True,  # further split using whitespace , complementary to tokenizer. (really helps if content have unique/less-frequent longer words)
                strip_whitespace:bool = True,

                # TOdo remove this debugging and stuff.. and no need to return token-ids as backend would store the tokens too... much simpler..
                debug = False) -> None:
        
        # based on language, choose an available tokenizer!
        self._language = language  # english but also some multilingual capabilities too!
        self._faster = faster
        if faster == False:
            self._tokenizer = TokenizerNemoMistral(tekken_path=tokenizer_data_path)
        else:
            tokenizer_nim.initTokenizer(tokenizer_data_path)

        self.extra_delimiters = [" ", "(", ")", "[","]" "_", ".", "-", ":", "//","/","\\", "?", "=", ",","~", '"']  # helps in further segmenting text into tokens.

        self.debug = debug
        # post tokenization processing! 
        self.whitespace_split = whitespace_split
        self.lowercase = lowercase
        self.strip_whitespace = strip_whitespace

    # @profile
    def preprocess(self,
                    content:str,             # some text/paragraph we want to preprocess/tokenize, can be arbitrarly long, content should correspond to language argument in init!
                   ) -> Iterable[Tuple[str, int]]:

        if self.lowercase:         # SHOULD BE DEFAULT, as our merge_pairs from `tekken.json` is modified to have lowercase counterparts!
            content = content.lower()
        content_original = content  # reference to exact content we recieved . 
                
        for x in self.extra_delimiters:
            content = content.replace(x, " ") # so that later can be whitespace delimited!
        
        # --------------------------------------------------------------------------------------
        if self._faster:
            temp_tokens = json.loads(tokenizer_nim.tokenize(content))
        else:
            temp_tokens = self._tokenizer.tokenize(content, return_ids = False)

        # ---------------------------------------------------------
        #  More like trigram but at token-level! (adds latency may be visible for larger content. TODO!)
        # ----------------------------------------------------------
        merged_tokens = get_merged_tokens(temp_tokens)
        for m_token in merged_tokens:
            temp_tokens.append(m_token) # we do duplication below anyway!
        # --------------------------------------------------------------------------------------------------
        
        tokens = list()
        if self.strip_whitespace: # should be default
            for x in temp_tokens:
                temp = x.replace(" ","")
                tokens.append(temp)  
        else:
            tokens = temp_tokens


        # --------------------------------------------------------------------------------------------------------
        if self.whitespace_split:
            for x in content.split(" "):
                tokens.append(x)

        # ------------------------------------------
        # deduplication and optionally valid substring as tokens
        # ----------------------------
        final_tokens = []  # de-duplicate and keep only valid substring,
        for t in tokens:
            if len(t) > 0 and not (t in final_tokens):
                if t in content_original: # due to minor modifications of original content, may be some tokens collected may not be valid substring.. so we check it here.
                    # This is optional, as may become a bit difficult to highlight later!
                    final_tokens.append(t)
        del tokens

        # ----------------------------------------------------------------------------------------------------------
        return final_tokens