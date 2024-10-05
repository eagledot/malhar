# A simple programme to showcase usage.
# It indexes all the immediate filenames returned by `os.listdir(...)` and then run some queries.

# Run: python search_filename.py
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..",".."))
from malhar import FuzzyIndex

filenames = os.listdir("C://users/random/downloads")

# index
db = FuzzyIndex(name = "filesearch")
for i, filename in enumerate(filenames):
    db.update(key = i, data = filename)

print(db) # some basic stats.
print("\n")

# query
def show_results(query:str):
    top_k = 10
    pkey_scores = db.query(query)    # returned sorted results..
    for pkey,score in pkey_scores[:top_k]:
        print(filenames[pkey], score)

show_results(query = "wulvrine")

