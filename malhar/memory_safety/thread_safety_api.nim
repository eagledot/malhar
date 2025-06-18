# Minimal API to check memory corruption during a concurrent environment.
# For now: (try to) prove that `no concurrent access` to a shared byte is being done from different threads!
import system/ansi_c
import ./bit_array_simple
