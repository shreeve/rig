// hpage LOG OUTPREFIX LOAD_START LOAD_END [LOAD_END2]: a page model of Rig's small classes from a tid heap-event log (rigtid:
// the allocating thread's id in the upper 32 bits of a made/moved record's size; 40-byte records t, addr, size, site,
// owner, old; owner 0xffffffff = free; old != 0 = moved or grown). Extends hfragh: a heap per thread id, each class
// carving 64 KiB pages; free lists LIFO, taken before carving. Arms:
//   M     today's allocator: one page set per class, a page never leaves its class.
//   Mp    M, and a page whose blocks are all free goes to its heap's pool, which any class takes from before carving.
//   I     Mp, and every block made in [LOAD_START, LOAD_END] that is dead by the reference peak goes to transient pages of its class
//         (an ideal per-block hint); transient free blocks serve transient requests only.
//   P     Mp, and every block made in [LOAD_START, LOAD_END], any thread, goes to transient pages (a phase hint).
//   Pm    P, and after the load a normal request takes a transient free block of its class before carving.
//   I2,P2,Pm2 as I, P and Pm with LOAD_END2 (if given).
// Footprint F(t) = small segment bytes + live large bytes. Small segment bytes: "trim" = pages carved - pages in the
// pools (pool pages given back), "keep" = pages carved (pool pages kept resident for reuse). The reference peak is
// M's F-peak. Writes OUTPREFIX.arms (one line per arm) and OUTPREFIX.cls (pages in use per class size at M's peak).
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <unordered_map>
#include <algorithm>
#include <string>

struct Rec { uint64_t t, addr, size; uint32_t site, owner; uint64_t old; };
static_assert(sizeof(Rec) == 40, "rec");

static const uint64_t max_small = 32 << 10;
static const int quarter_class = 8 + 8 * 7;
static const int class_count = quarter_class + 4 * 2;
static const uint64_t page_size = 64 << 10;
static uint64_t classSize(int c) {
    if (c < 8) return (uint64_t)(c + 1) * 8;
    if (c < quarter_class) { int k = c - 8; uint64_t base = (uint64_t)64 << (k / 8); return base + (base / 8) * (k % 8 + 1); }
    int k = c - quarter_class; uint64_t base = (uint64_t)(8 << 10) << (k / 4); return base + (base / 4) * (k % 4 + 1);
}
static int log2i(uint64_t x) { return 63 - __builtin_clzll(x); }
static int classOf(uint64_t len) {
    if (len > max_small) return -1;
    if (len <= 64) return len == 0 ? 0 : (int)((len - 1) / 8);
    uint64_t n = len; int lg = log2i(n - 1);
    if (n > (8 << 10)) { int step = (int)((n - 1 - (1ULL << lg)) >> (lg - 2)); return quarter_class + (lg - 13) * 4 + step; }
    int shift = lg - 3; int step = (int)((n - 1 - (1ULL << lg)) >> shift); return 8 + (lg - 6) * 8 + step;
}
static const int MAXH = 64;
static std::unordered_map<uint32_t, int> heap_of; static std::vector<uint32_t> heap_tid;
static std::vector<uint64_t> heap_first, heap_last, heap_made;
static int heapId(uint32_t tid, uint64_t ev) {
    auto it = heap_of.find(tid);
    if (it != heap_of.end()) { heap_last[it->second] = ev; heap_made[it->second]++; return it->second; }
    int h = (int)heap_tid.size(); if (h >= MAXH) { fprintf(stderr, "too many heaps\n"); exit(1); }
    heap_of[tid] = h; heap_tid.push_back(tid); heap_first.push_back(ev); heap_last.push_back(ev); heap_made.push_back(1); return h;
}

// The op stream: per event, what it does to the small classes and the large bytes.
enum : uint8_t { OP_NONE, OP_ALLOC, OP_FREE, OP_MOVE, OP_RESIZE };
struct Op { uint8_t kind; int16_t hc_new; int16_t hc_old; uint32_t inc_old; int64_t large_delta; };
// inc: an incarnation = the event that made it (an allocation or a move's new block).

int main(int argc, char** argv) {
    if (argc < 5) { fprintf(stderr, "usage: hpage LOG OUTPREFIX LOAD_START LOAD_END [LOAD_END2]\n"); return 2; }
    std::string out = argv[2];
    uint64_t load_start = strtoull(argv[3], nullptr, 10);
    uint64_t load_end = strtoull(argv[4], nullptr, 10);
    uint64_t load_end2 = argc > 5 ? strtoull(argv[5], nullptr, 10) : 0;
    FILE* f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    size_t N = sz / sizeof(Rec);
    std::vector<Rec> ev(N);
    if (fread(ev.data(), sizeof(Rec), N, f) != N) { fprintf(stderr, "short read\n"); return 1; }
    fclose(f);
    // Pass 0: the op stream, each incarnation's death, live bytes and its peak.
    std::vector<Op> ops(N);
    std::vector<uint32_t> death(N, UINT32_MAX);
    std::vector<int16_t> inc_hc(N, -1);
    struct L { uint32_t inc; uint32_t size; int16_t hc; };
    std::unordered_map<uint64_t, L> live; live.reserve(1 << 22);
    int64_t bytes = 0, peak_bytes = 0; uint64_t peak_live_ev = 0, bad = 0;
    for (size_t e = 0; e < N; e++) {
        const Rec& r = ev[e]; Op op{OP_NONE, -1, -1, 0, 0};
        auto mk = [&](uint64_t addr, uint64_t raw) {
            uint64_t s = raw & 0xffffffffULL; int c = classOf(s);
            int16_t hc = c < 0 ? -1 : (int16_t)(heapId((uint32_t)(raw >> 32), e) * class_count + c);
            live[addr] = {(uint32_t)e, (uint32_t)s, hc}; inc_hc[e] = hc; bytes += s;
            op.hc_new = hc; if (hc < 0) op.large_delta += (int64_t)s;
        };
        auto kill = [&](uint64_t addr) -> bool {
            auto it = live.find(addr); if (it == live.end()) { bad++; return false; }
            death[it->second.inc] = (uint32_t)e; bytes -= it->second.size;
            op.hc_old = it->second.hc; op.inc_old = it->second.inc;
            if (it->second.hc < 0) op.large_delta -= (int64_t)it->second.size;
            live.erase(it); return true;
        };
        if (r.owner == 0xffffffffu) { if (kill(r.addr)) op.kind = OP_FREE; }
        else if (r.old != 0 && r.old == r.addr) {
            auto it = live.find(r.addr);
            if (it == live.end()) { bad++; mk(r.addr, r.size); op.kind = OP_ALLOC; }
            else {
                int64_t s = (int64_t)(r.size & 0xffffffffULL);
                bytes += s - (int64_t)it->second.size;
                if (it->second.hc < 0) op.large_delta = s - (int64_t)it->second.size;
                it->second.size = (uint32_t)s; op.kind = OP_RESIZE;
            }
        } else if (r.old != 0) {
            bool k = kill(r.old); mk(r.addr, r.size); op.kind = k ? OP_MOVE : OP_ALLOC;
        } else { mk(r.addr, r.size); op.kind = OP_ALLOC; }
        ops[e] = op;
        if (bytes > peak_bytes) { peak_bytes = bytes; peak_live_ev = e; }
    }
    int H = (int)heap_tid.size();
    fprintf(stderr, "events %zu, bad %llu, heaps %d, live peak %.1f MiB at event %llu, load_end %llu, load_end2 %llu\n", N,
            (unsigned long long)bad, H, peak_bytes / 1048576.0, (unsigned long long)peak_live_ev, (unsigned long long)load_end,
            (unsigned long long)load_end2);
    for (int h = 0; h < H; h++)
        fprintf(stderr, "  heap %d tid %u made %llu events %llu..%llu\n", h, heap_tid[h], (unsigned long long)heap_made[h],
                (unsigned long long)heap_first[h], (unsigned long long)heap_last[h]);
    ev.clear(); ev.shrink_to_fit();

    const int NC = H * class_count;
    struct Res { std::string name; double trim_peak, keep_peak; uint64_t trim_ev, keep_ev; double trim_at_ref, keep_at_ref, freeblk_at_live_peak;
                 std::vector<int64_t> cls_pages; double touch_peak = 0; uint64_t touch_ev = 0; std::vector<double> at_keys; };
    std::vector<uint64_t> keys;
    // mode: 0 M, 1 Mp, 2 I, 3 P, 4 Pm (P, and a normal request takes a transient free block before carving); le: the load end for 2/3. ref: the reference peak for I's oracle (M's F-peak).
    auto run = [&](const char* name, int mode, uint64_t le, uint64_t ref) -> Res {
        struct Page { int16_t hc; uint8_t trans; uint8_t pooled; uint32_t gen; int32_t live; uint32_t carved; };
        std::vector<Page> pages; pages.reserve(1 << 16);
        struct Cls { std::vector<uint64_t> fl[2]; int64_t cur[2] = {-1, -1}; };
        std::vector<Cls> cls(NC);
        std::vector<std::vector<uint32_t>> pool(H);
        std::vector<int64_t> carved_pages(H, 0);
        std::vector<uint32_t> slot(N, UINT32_MAX);  // per incarnation: page << 13 | index
        int64_t large = 0, carved_tot = 0, pooled_tot = 0, carved_slot_bytes = 0, live_slot_bytes = 0, touch_tot = 0;
        auto touched = [](uint32_t carved, uint64_t csz) -> int64_t { return (int64_t)((carved * csz + 4095) / 4096 * 4096); };
        bool pooling = mode != 0;
        Res res{name, 0, 0, 0, 0, 0, 0, 0, std::vector<int64_t>(class_count, 0)};
        res.at_keys.assign(keys.size(), 0);
        auto take = [&](int hc, int k) -> uint32_t {
            int c = hc % class_count, h = hc / class_count; uint64_t csz = classSize(c); uint32_t bpp = (uint32_t)(page_size / csz);
            Cls& C = cls[hc];
            for (int j : {k, (mode == 4 && k == 0) ? 1 : -1}) {
                if (j < 0) break;
                while (!C.fl[j].empty()) {
                    uint64_t x = C.fl[j].back(); C.fl[j].pop_back();
                    uint32_t s = (uint32_t)x, g = (uint32_t)(x >> 32), p = s >> 13;
                    if (pages[p].gen != g || pages[p].pooled) continue;  // stale: its page went to the pool
                    pages[p].live++; live_slot_bytes += csz; return s;
                }
            }
            if (C.cur[k] >= 0 && pages[C.cur[k]].carved < bpp && !pages[C.cur[k]].pooled && pages[C.cur[k]].hc == hc) {
                Page& P = pages[C.cur[k]]; uint32_t s = ((uint32_t)C.cur[k] << 13) | P.carved;
                touch_tot += touched(P.carved + 1, csz) - touched(P.carved, csz); P.carved++; P.live++;
                carved_slot_bytes += csz; live_slot_bytes += csz; return s;
            }
            uint32_t p;
            if (pooling && !pool[h].empty()) { p = pool[h].back(); pool[h].pop_back(); pooled_tot--; }
            else { p = (uint32_t)pages.size(); pages.push_back(Page{0, 0, 0, 0, 0, 0}); carved_pages[h]++; carved_tot++; }
            Page& P = pages[p]; P.hc = (int16_t)hc; P.trans = (uint8_t)k; P.pooled = 0; P.gen++; P.live = 1; P.carved = 1;
            C.cur[k] = p; carved_slot_bytes += csz; live_slot_bytes += csz; touch_tot += touched(1, csz);
            return p << 13;
        };
        auto give = [&](uint32_t s) {
            uint32_t p = s >> 13; Page& P = pages[p]; int hc = P.hc; uint64_t csz = classSize(hc % class_count);
            P.live--; live_slot_bytes -= csz;
            cls[hc].fl[P.trans].push_back(((uint64_t)P.gen << 32) | s);
            if (pooling && P.live == 0) {
                P.pooled = 1; pool[hc / class_count].push_back(p); pooled_tot++;
                carved_slot_bytes -= (int64_t)P.carved * csz; touch_tot -= touched(P.carved, csz);
                if (cls[hc].cur[P.trans] == (int64_t)p) cls[hc].cur[P.trans] = -1;
            }
        };
        for (size_t e = 0; e < N; e++) {
            const Op& op = ops[e];
            large += op.large_delta;
            if ((op.kind == OP_FREE || op.kind == OP_MOVE) && op.hc_old >= 0) { give(slot[op.inc_old]); }
            if ((op.kind == OP_ALLOC || op.kind == OP_MOVE) && op.hc_new >= 0) {
                int k = 0;
                if (mode == 2) k = (e >= load_start && e <= le && death[e] <= ref) ? 1 : 0;
                else if (mode == 3 || mode == 4) k = (e >= load_start && e <= le) ? 1 : 0;
                slot[e] = take(op.hc_new, k);
            }
            double trim = (double)(carved_tot - pooled_tot) * page_size + large, keep = (double)carved_tot * page_size + large;
            if (trim > res.trim_peak) { res.trim_peak = trim; res.trim_ev = e; }
            if (keep > res.keep_peak) { res.keep_peak = keep; res.keep_ev = e; }
            double tch = (double)touch_tot + large;
            if (tch > res.touch_peak) { res.touch_peak = tch; res.touch_ev = e; }
            for (size_t q = 0; q < keys.size(); q++) if (keys[q] == e) res.at_keys[q] = trim;
            if (e == ref) {
                res.trim_at_ref = trim; res.keep_at_ref = keep;
                for (auto& P : pages) if (!P.pooled && P.carved) res.cls_pages[P.hc % class_count]++;
            }
            if (e == peak_live_ev) res.freeblk_at_live_peak = (double)(carved_slot_bytes - live_slot_bytes);
        }
        return res;
    };
    std::vector<Res> rs;
    rs.push_back(run("M", 0, 0, 0));
    uint64_t ref = rs[0].trim_ev;
    keys = {load_start, load_end, load_end2, ref, peak_live_ev};
    rs[0] = run("M", 0, 0, ref);
    rs.push_back(run("Mp", 1, 0, ref));
    rs.push_back(run("I", 2, load_end, ref));
    rs.push_back(run("P", 3, load_end, ref));
    rs.push_back(run("Pm", 4, load_end, ref));
    if (load_end2) { rs.push_back(run("I2", 2, load_end2, ref)); rs.push_back(run("P2", 3, load_end2, ref)); rs.push_back(run("Pm2", 4, load_end2, ref)); }
    // M's free blocks at the live peak, as hfragh counts them (HWM - live).
    const double M_ = 1048576.0;
    FILE* af = fopen((out + ".arms").c_str(), "w");
    fprintf(af, "# ref peak (M's F-peak) event %llu; live peak event %llu; load_start %llu load_end %llu load_end2 %llu; heaps %d\n",
            (unsigned long long)ref, (unsigned long long)peak_live_ev, (unsigned long long)load_start, (unsigned long long)load_end, (unsigned long long)load_end2, H);
    fprintf(af, "# arm\ttrim_peak_MiB\ttrim_ev\tsave_trim_MiB\tkeep_peak_MiB\tkeep_ev\tsave_keep_MiB\ttrim_at_ref\tkeep_at_ref\tfreeblk_at_live_peak_MiB\n");
    for (auto& r : rs)
        fprintf(af, "%s\t%.2f\t%llu\t%.2f\t%.2f\t%llu\t%.2f\t%.2f\t%.2f\t%.2f\n", r.name.c_str(), r.trim_peak / M_, (unsigned long long)r.trim_ev,
                (rs[0].trim_peak - r.trim_peak) / M_, r.keep_peak / M_, (unsigned long long)r.keep_ev, (rs[0].keep_peak - r.keep_peak) / M_,
                r.trim_at_ref / M_, r.keep_at_ref / M_, r.freeblk_at_live_peak / M_);
    fprintf(af, "# touch: small bytes counted as each page's carved bytes rounded up to 4 KiB (no prefault; pool pages given back)\n# arm\ttouch_peak_MiB\ttouch_ev\tsave_touch_MiB\n");
    for (auto& r : rs) fprintf(af, "%s\t%.2f\t%llu\t%.2f\n", r.name.c_str(), r.touch_peak / M_, (unsigned long long)r.touch_ev, (rs[0].touch_peak - r.touch_peak) / M_);
    fprintf(af, "# F (trim) at key events: load_start %llu, load_end %llu, load_end2 %llu, ref %llu, live_peak %llu\n# arm\tat_ls\tat_le\tat_le2\tat_ref\tat_livepeak\n",
            (unsigned long long)keys[0], (unsigned long long)keys[1], (unsigned long long)keys[2], (unsigned long long)keys[3], (unsigned long long)keys[4]);
    for (auto& r : rs) { fprintf(af, "%s", r.name.c_str()); for (double v : r.at_keys) fprintf(af, "\t%.2f", v / M_); fprintf(af, "\n"); }
    fclose(af);
    FILE* cf = fopen((out + ".cls").c_str(), "w");
    fprintf(cf, "# class_size");
    for (auto& r : rs) fprintf(cf, "\t%s_MiB", r.name.c_str());
    fprintf(cf, "\n");
    for (int c = 0; c < class_count; c++) {
        bool any = false; for (auto& r : rs) any |= r.cls_pages[c] != 0;
        if (!any) continue;
        fprintf(cf, "%llu", (unsigned long long)classSize(c));
        for (auto& r : rs) fprintf(cf, "\t%.2f", r.cls_pages[c] * (double)page_size / M_);
        fprintf(cf, "\n");
    }
    fclose(cf);
    FILE* x = fopen((out + ".arms").c_str(), "r"); char line[512]; while (fgets(line, sizeof line, x)) fputs(line, stderr); fclose(x);
    return 0;
}
