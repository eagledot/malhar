# Package

version       = "0.1.0"
author        = "Anubhav N. (eagledot)"
description   = "a nimble file to make compilation easier, contains task to run commands easily."
license       = "Apache 2.0"
# srcDir        = "src"

# Dependencies
requires "nim >= 1.6.0" # should work with almost all of nim versions i guess !

# Tasks
# NOTE: on windows, it is recommended to use `clang` for multi-threaded code. Atleast my GCC version is producing slower code compared to Clang!
task compileExtension, "Native compilation of Nim code to python extensions":
  when defined(windows):
    exec("""nim c --gc:arc -f -d:danger --threads:off --app:lib --tlsEmulation:off --passL:-static --out:../ext/tokenizer.pyd ./tokenizer.nim""")
    exec("""nim c --gc:arc -f -d:danger --threads:on --app:lib --tlsEmulation:off --passL:-static --out:../ext/search_python_module.pyd ./search_python_module.nim""")
  
  else: 
    exec("""nim c --gc:arc -f -d:danger --threads:off --app:lib --out:../ext/tokenizer.so ./tokenizer.nim""")
    exec("""nim c --gc:arc -f -d:danger --threads:off --app:lib --out:../ext/search_python_module.so ./search_python_module.nim""")

