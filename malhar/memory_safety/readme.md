# Memory safety [WIP]

A try to enforce a `borrow first` form of memory management i.e only suggest `clone` or do a `deepcopy` if absolutely required. it will requires some form of mutation tracking .

Idea is to reduce memory allocations, encourage underyling buffer reuse and eventually make it easier to pass/move memory/buffer to threads coupled with memory-safety checks!

Eventually create common data-structures like vector/sequence and strings, to leverage this.

It is implemented at allocator-level, rather than compiler-level, still many things to figure out !

A blog-post is pending articulating the `ideas` and motivations behind this experiment.