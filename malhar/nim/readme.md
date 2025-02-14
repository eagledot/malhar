# About:
Contains Nim source code/modules .
Compiled code is then leveraged as python extensions and helps in speeding up some bottleneck portions of the codebase.

For now these compiled extensions for `Windows` and `Linux` are included in ``../ext`` directory to , but it is recommended to compile Nim code natively for a platform you want to actually run this code on.
Compilation only requires `Nim` installation. (which expects a `C` compiler.)

# Installation:
* Download any Nim toolchain from `https://nim-lang.org/install.html` and follow the `instructions` on the website to install.

* `cd` into this directory and run the following commands.
```cmd
nimble install nimpy
nimble install jsony (for faster json encoding than standard !)
nimble compileExtension  # generated shared libaries would be available in ``../ext`` directory after a succesful build
```

# Alternate (if nimble acts weirdly..)
```cmd
# nimpy installation
git clone https://github.com/yglukhov/nimpy
cd nimpy
nimble install

# jsony (json encoding/decoding)
https://github.com/treeform/jsony.git
cd jsony
nimble install

# (for windows use `.pyd` as extension, for linux use `.so`)
nim c --gc:arc -d:danger --app:lib --threads:off -f --out:../ext/tokenizer.so ./tokenizer.nim
nim c --gc:arc -d:danger --app:lib --threads:on --passL:-static --tlsEmulation:off -f --out:../ext/search_python_module.so ./search_python_module.nim
```




