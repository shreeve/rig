# gen_matrix.py <matrix.py> <outdir> [-k filter]: write the matrix cells and cells.tsv
import sys, importlib.util, os
mp, out = sys.argv[1], os.path.abspath(sys.argv[2])
spec = importlib.util.spec_from_file_location("matrix", mp)
m = importlib.util.module_from_spec(spec)
sys.argv = [mp, '--keep', out, '--oracle'] + sys.argv[3:]
spec.loader.exec_module(m)
def stub(work, cells, args):
    with open(os.path.join(work, 'cells.tsv'), 'w') as fh:
        for ident, path in cells:
            fh.write(f"{ident}\t{path}\n")
    return 0
m.run_oracle = stub
try:
    m.main()
except SystemExit as e:
    if e.code not in (0, None): raise
