# Check-speed guard

`guard.py` holds `rig check` to what it has won: the instructions it retires on a generated workload, each pass's time, and how the cost grows with a program's size, against `guard.txt` (macOS only; `--update` writes a new baseline).
`gen.py` writes the programs: one generator for each dimension (functions, statements, fields, variants, methods, modules), and a `workload` of all of them in one program about the size of Trig's parser.
`guard.txt` holds the baseline: the workload's instruction count and each pass's best time on the Mac.
