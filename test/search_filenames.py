# A simple programme to showcase usage.
# It indexes all the immediate filenames returned by `os.listdir(...)` and then run some queries.

import sys
import os
sys.path.append("D://nim_learning")
from malhar import FuzzyIndex

filenames = os.listdir("D://nim_learning")

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

query = "avbin" # expected badminton (fOR MY contents)
query = "wjSgoWPm5bWAhXB"
print(db._tokenize(query))
sample_test = "(http://freebsdfoundation.blogspot.com/2014/11/freeBSD-foundation-announces-generous.html?HN)"
print(db._tokenize(sample_test))
print(db._tokenize("freebsd"))
print(db._tokenize("freebsdfoundation"))

db._debug_new(query = "freebsd", paragraph = sample_test)

db._debug_new(query = query, paragraph = "wjsogpmwb5awh")
# db._debug_new(query = "tnnise", paragraph = "tennis")

# we would want to compare some results....


# show_results(query)




# print(db._tokenize(query))
# print(db._tokenize("dininghall"))
# print(db._tokenize("bean bags are nice!"))
# db._debug_new(query = query, paragraph = "bean bags are nice!")
