# About:
Contains Nim source code to generate TLSH hashes and search over hashes indexed.
Compiled code is then leveraged as python extensions and helps in speeding up some bottleneck portions of the codebase.

For now these compiled extensions for `Windows` and `Linux` are included in ``../ext`` directory to , but it is recommended to compile Nim code natively for a platform you want to actually run this code on.
Compilation only requires `Nim` installation. (which expects a `C` compiler.)

# Installation:
* Download any Nim toolchain from `https://nim-lang.org/install.html` and follow the `instructions` on the website to install.

* `cd` into this directory and run the following commands.
```cmd
nimble install nimpy
nimble compileExtension  # generated shared libaries would be available in ``../ext`` directory after a succesful build
```

# Alternate (if nimble acts weirdly..)
```cmd
# nimpy installation
git clone https://github.com/yglukhov/nimpy
cd nimpy
nimble install

nim c --gc:arc -d:danger --app:lib --threads:off -f --out:../ext/fasterfuzzy.so ./fasterfuzzy.nim
nim c --gc:arc -d:danger --app:lib --threads:off -f --out:../ext/tlsh_python_module.so ./tlsh_python_module.nim
```




