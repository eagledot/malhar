from typing import Dict, Iterable, List

def extended_tokenizer(words:Iterable[str], vocab:Dict[str, Iterable[str]]) -> List[str]:
    """
    This is about dividing a word into subwords based on the some learned vocabulary. (using byte-pair encoding like algorithm).
    We just take such dictionary and apply a very simple encoding scheme. (rather than using exact encoding scheme from the tokenizer !!)

    words: we get from a basic "tokenizer". (We follow those with this extended tokenizer to further enhance context..)
    Vocab: List of words.
    """
    assert not isinstance(words, str), "Expected to be an iterable.."
    if len(words) == 0:
        return []
    
    X_WORD = "X".join([w.lower() for w in words]) # since we are using uncased vocabulary.

    result = []
    for v in vocab:
        if v in X_WORD:
            result.append(v)
            X_WORD = X_WORD.replace(v, "N") # replace it with any upper case, so that no further matches could occur in already searched regions.
    return result
