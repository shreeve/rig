// hmark LOG GROUPS: GROUPS lines "group\tsite"; prints per group the first and last event made by its sites, the count,
// and the event count. Also the tid (rigtid) of the first and last.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>
#include <unordered_map>
struct Rec { uint64_t t, addr, size; uint32_t site, owner; uint64_t old; };
int main(int argc, char** argv) {
    std::unordered_map<uint32_t, std::vector<int>> g; std::vector<std::string> names; std::map<std::string, int> idx;
    FILE* gf = fopen(argv[2], "r"); char a[256]; unsigned s;
    while (fscanf(gf, "%255s %u", a, &s) == 2) { auto it = idx.find(a); int i; if (it == idx.end()) { i = names.size(); idx[a] = i; names.push_back(a); } else i = it->second; g[s].push_back(i); }
    fclose(gf);
    std::vector<uint64_t> first(names.size(), ~0ULL), last(names.size(), 0), cnt(names.size(), 0); std::vector<uint32_t> ft(names.size()), lt(names.size());
    FILE* f = fopen(argv[1], "rb"); std::vector<Rec> b(1 << 16); uint64_t e = 0; size_t n;
    while ((n = fread(b.data(), sizeof(Rec), b.size(), f)) > 0) for (size_t i = 0; i < n; i++, e++) {
        const Rec& r = b[i]; if (r.owner == 0xffffffffu) continue;
        auto it = g.find(r.site); if (it == g.end()) continue;
        for (int k : it->second) { if (first[k] == ~0ULL) { first[k] = e; ft[k] = r.size >> 32; } last[k] = e; lt[k] = r.size >> 32; cnt[k]++; }
    }
    printf("events %llu\n", (unsigned long long)e);
    for (size_t k = 0; k < names.size(); k++) printf("%s\tfirst %llu (tid %u)\tlast %llu (tid %u)\tmade %llu\n", names[k].c_str(), (unsigned long long)first[k], ft[k], (unsigned long long)last[k], lt[k], (unsigned long long)cnt[k]);
}
