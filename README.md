
Installation:
-----------
```cmd
git clone https://github.com/eageldot/malhar

cd malhar  # change directory to root of clone repository

pip install .   # build and install package
```

# A basic example:
```python
# an example to index filenames from a directory.

from malhar import FuzzyIndex
import os

# choose any directory like "D://movies"
filenames = os.listdir(".")

# initialize
db = FuzzyIndex(name = "filesearch")

# populate
for i,name in enumerate(filenames):
    db.update(key = i, data = name)  # keep key unique, to later retrieve original content.

# display stats.
print(db)

# query
def show_results(query:str):
    top_k = 10
    pkey_scores = db.query(query)    # returned sorted results..
    for pkey, _ in pkey_scores[:top_k]:
        print(filenames[pkey])


# save the index, for later retrieval.
db.save("./filemeta.json")

# load the saved index.
db_new = FuzzyIndex(file_path = "./filemeta.json")
print(db_new)

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
