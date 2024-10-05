# Package

version       = "0.1.0"
author        = "Anubhav N. (eagledot)"
description   = "a nimble file to make compilation easier, contains task to run commands easily."
license       = "Apache 2.0"
# srcDir        = "src"

# Dependencies
requires "nim >= 1.6.0" # should work with almost all of nim versions i guess !

# TODO: keeping threads off for now, weird performance issues with mingw, on windows due to TLS implementation.
# TODO: try using CLANG more on windows..
# TODO: since using gc:arc, shouldn't have issues running more than one extensions even with threaded python, i worked for me without issues.
# Tasks
task compileExtension, "Native compilation of Nim code to python extensions":
  when defined(windows):
    exec("""nim c --gc:arc -f -d:danger --threads:off --app:lib --tlsEmulation:off --passL:-static --out:../ext/fasterfuzzy.pyd ./fasterfuzzy.nim""")
    exec("""nim c --gc:arc -f -d:danger --threads:off --app:lib --tlsEmulation:off --passL:-static --out:../ext/tlsh_python_module.pyd ./tlsh_python_module.nim""")
    # exec("""nim c --gc:arc -d:danger -f  --threads:on --app:lib --out:../ext/fasterfuzzy.pyd --os:windows --cpu:amd64 --cc:clang --clang.exe="zcc" --clang.linkerexe="zcc"   --passC:"--target=x86_64-pc-windows-gnu" --passL:"--target=x86_64-pc-windows-gnu"  ./fasterfuzzy.nim """)
  
  else: 
    exec("""nim c --gc:arc -f -d:danger --threads:off --app:lib --out:../ext/fasterfuzzy.so ./fasterfuzzy.nim""")
    exec("""nim c --gc:arc -f -d:danger --threads:off --app:lib --out:../ext/tlsh_python_module.so ./tlsh_python_module.nim""")

# zcc actually runs "zig cc ..."
# task crossCompileLinux, "Cross static compilation from windows to linux, (gc:arc and -d:danger)":
#   exec("""nim c --gc:arc -d:danger --threads:off --app:lib --out:../ext/fasterfuzzy.so --os:linux --cpu:amd64 --cc:clang --clang.exe="zcc" --clang.linkerexe="zcc" --passC:"-target x86_64-linux-gnu.2.27" --passC:-v --passL:"-target x86_64-linux-gnu"  ./fasterfuzzy.nim """)
#   exec("""nim c --gc:arc -d:danger --threads:off --app:lib --out:../ext/tlsh_python_module.so --os:linux --cpu:amd64 --cc:clang --clang.exe="zcc" --clang.linkerexe="zcc" --passC:"-target x86_64-linux-gnu.2.27" --passC:-v --passL:"-target x86_64-linux-gnu"  ./tlsh_python_module.nim """)
