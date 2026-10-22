import json, sys, collections
sys.argv = [sys.argv[0], sys.argv[1]]
exec(open('analyze.py').read().split("if __name__")[0])
F = json.load(open('findings.json'))
add = {'payload-loan-3 H2': 'm01 m03 m04 n02 n22 n23', 'payload-loan-4 C2': 'k01 d01 k03 k05 k06',
       'payload-loan-5 C1': 'c08 c09 d09', 'payload-loan-5 C2': 'b08'}
byid = {r['id']: r for r in res}
def stems(rev):
    return [i for i in byid if i.startswith(f'study/probes/{rev}/') and i.count('/') == 3]
def find(rev, pre):
    return [i for i in stems(rev) if i.split('/')[-1].split('_')[0] == pre or i.split('/')[-1][:-4] == pre]
groups = {}
for k, v in F.items():
    rev = k.split()[0]
    ids = [f'study/probes/{rev}/{s}.rig' for s in v]
    for pre in add.get(k, '').split():
        ids += find(rev, pre)
    groups[k] = list(dict.fromkeys(ids))
hp = 'study/probes/header-paths-1/'
groups['header-paths-1 H1 (oracle)'] = [hp + s + '.rig' for s in 'o01_store_readview_of_self_into_arg o02_store_writeview_of_self_into_arg o04_store_readview_bang_receiver o05_store_slice_of_self o06_store_into_struct_arg'.split()]
c1 = [hp + s + '.rig' for s in 'r06_match_readlend_bare_branch r07_match_writelend_bare_branch p08_as_write_plain_part_in_vec p09_match_write_branchpart'.split()]
c1 += sorted(i for i in byid if i.startswith(hp + 'grid2/') and byid[i]['acc'] and not i.split('/')[-1].startswith('l_for'))
c1 += sorted(i for i in byid if i.startswith(hp + 'grid1/g_for.meth_gvw') and byid[i]['acc'])
groups['header-paths-1 C1'] = c1
groups['header-paths-1 C2'] = [hp + s + '.rig' for s in 'q08_stmt_readlend_bare_branch q09_stmt_writelend_bare_branch q10_call_arg_readlend_bare_branch p10_lend_write_branchpart_stmt p11_lend_read_branchpart_stmt q03_stmt_lendw_branch_path_vec q06_stmt_lendw_branch_holder q07_stmt_lendw_branch_locals'.split()]
for k in groups.get('header-paths-1 C1', []): pass
del_keys = [k for k in groups if k in ('header-paths-1 H1', )]
for k in del_keys: del groups[k]
json.dump(groups, open('groups.json', 'w'), indent=1)
cols = ['12', '3', '3p', '4', '34', '1234']
print('| Finding | Probes | main acc | ' + ' | '.join('rej by ' + c for c in cols) + ' | not reached by 1234 |')
print('|---|---|---|' + '---|' * len(cols) + '---|')
for k, ids in groups.items():
    missing = [i for i in ids if i not in byid]
    rs = [byid[i] for i in ids if i in byid]
    cnt = [sum(1 for r in rs if r['HU'] & CONF[c]) for c in cols]
    left = [r['id'].split('/')[-1] for r in rs if not (r['HU'] & CONF['1234'])]
    print(f'| {k} | {len(rs)} | {sum(r["acc"] for r in rs)} | ' + ' | '.join(map(str, cnt)) + ' | ' + ', '.join(left) + (' MISSING ' + str(missing) if missing else '') + ' |')
