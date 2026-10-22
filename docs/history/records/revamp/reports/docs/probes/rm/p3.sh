R=/Users/shreeve/Data/Code/rig-rv-docs/bin/rig
probe(){ echo "== $1"; printf "$2" > $1.rig; $R run $1.rig 2>&1 | head -4; }
probe optopt2 'sub main\n  x: (Int?)? = none\n  y: (Int?)? = 3\n  print(x, y)\n'
probe label_if_break 'sub main\n  :blk if true\n    break :blk\n    print(1)\n  print(2)\n'
probe label_call ':a print(1)\n'
probe label_call2 'sub main\n  :a print(1)\n'
probe label_match 'sub main\n  x = 1\n  :m match x\n    1 => break :m\n    _ => print(0)\n  print(2)\n'
probe label_block 'sub main\n  :a\n    print(1)\n'
