# Print-size guard

`guard.py` holds the machine code one `print` adds to a program built with `--release`: it builds a program with no print lines and one with 200, each a mix of text and values of every kind, and divides the growth of the text section by 200.
More than the bound in `guard.txt` fails, so a change that makes Zig compile print's code again at each site shows here.
`guard.txt` holds the bound: the bytes per site measured on the Mac (arm64), plus 25%; `--update` writes it.
