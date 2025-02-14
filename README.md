
Installation:
-----------
```
git clone https://github.com/eageldot/malhar

cd malhar  # change directory to root of clone repository

pip install .   # build and install package
```

# A basic example:
```python
# an example to index filenames from a directory.

from malhar import MalharSearch
import os

# choose any directory like "D://movies"
filenames = os.listdir(".")

# initialize
db = MalharSearch(capacity = 100_000) # capacity could be set based on your needs/dataset-diversity, by default is set to 1 Million.

# populate
for i,name in enumerate(filenames):
    db.append(document_id = i, content = name)  # keep key unique, to later retrieve original content.

# some stats!
print(db.get_count())        # unique number of tokens

# query
query = "m4p"            
db.query(query, top_k = 100)  # NOTE: you will note that, for each result, `document` field would be None, and it refers the original content. If you want to return the original document too. Please take a look below.
# 

# provide your own routine to also return the corresponding original_document, if needed!
def my_document(document_id:int, **kwargs):    # use this signature!
    return files[document_id]          # replace it with get_from_dataset(document_id,..)  or get_from_s3_storage(document_id,...) based on your needs!

## either set it directly, since python's functions are first class objects.
db.get_document = my_document

## Classic way, by subclassing parent Class.
class FileSearch(MalharSearch):
    def get_document(document_id:int, **kwargs):
        return files[document_id]
db = FileSearch(capacity .....)
...

```

Copyright:
-----------
Copyright 2024, Anubhav Nain.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Resources:
-------
[Malhar: Towards a fast, generic and minimal Fuzzy Search Index](https://eagledot.xyz/malhar.md.html)
