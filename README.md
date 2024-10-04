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