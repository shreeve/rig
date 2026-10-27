// The C++ contestants, timed as bench/hash/rust/src/main.rs times
// hashbrown, every row of bench/hash/WORKLOADS.md: Int keys in order and
// at random, chained lookups, turnover, half-hit lookups, text keys, and
// values of eight integers. One table a build:
//
//   -DTABLE_ABSL   absl::flat_hash_map (SwissTable, groups of 16 on x86, 8 on Arm)
//   -DTABLE_BOOST  boost::unordered_flat_map (groups of 15 and an overflow byte)
//   -DTABLE_DENSE  ankerl::unordered_dense::map (a dense array of entries
//                  beside a table of buckets, in insertion order until an erase)
//
// and its own hash (absl::Hash, boost::hash with boost's mixing, ankerl's
// wyhash), or with -DMIX, Rig's hash of an Int (`hashWord` in
// src/runtime.zig): a full 64x64 multiply folded to 64 bits, marked as
// avalanching so neither boost nor ankerl mixes it again. Text keys hash
// with the table's own string hash in every build: -DMIX is a hash of
// integers. bench/hash/bench-hash builds it; it prints `KEYS OP NS CHECK`
// per line, or with the argument `mem` (`mem0`) builds one map of
// 4,000,000 keys (the keys alone) for its peak memory.
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <numeric>
#include <string>
#include <utility>
#include <vector>

#if defined(TABLE_ABSL)
#include <absl/container/flat_hash_map.h>
#include <absl/hash/hash.h>
#elif defined(TABLE_BOOST)
#include <boost/unordered/unordered_flat_map.hpp>
#elif defined(TABLE_DENSE)
#include <ankerl/unordered_dense.h>
#else
#error define TABLE_ABSL, TABLE_BOOST, or TABLE_DENSE
#endif

struct Mix {
    using is_avalanching = std::true_type;  // boost
    using is_avalanching_dense = void;      // see below
    uint64_t operator()(int64_t x) const {
        unsigned __int128 p = (unsigned __int128)((uint64_t)x ^ 0x2d358dccaa6c78a5ull) * 0x4b33a62ed433d4a3ull;
        return (uint64_t)p ^ (uint64_t)(p >> 64);
    }
};

#if defined(TABLE_DENSE)
// ankerl marks a hash as avalanching with a member type of this name.
struct MixDense : Mix {
    using is_avalanching = void;
};
#endif

// The hash of an Int key: the table's own, or with -DMIX, Rig's.
#if defined(TABLE_ABSL)
#ifdef MIX
using IntHash = Mix;
#else
using IntHash = absl::Hash<int64_t>;
#endif
template <class K, class V, class H>
using MapOf = absl::flat_hash_map<K, V, H>;
using StrMap = absl::flat_hash_map<std::string, int64_t>;
#elif defined(TABLE_BOOST)
#ifdef MIX
using IntHash = Mix;
#else
using IntHash = boost::hash<int64_t>;
#endif
template <class K, class V, class H>
using MapOf = boost::unordered_flat_map<K, V, H>;
using StrMap = boost::unordered_flat_map<std::string, int64_t>;
#else
#ifdef MIX
using IntHash = MixDense;
#else
using IntHash = ankerl::unordered_dense::hash<int64_t>;
#endif
template <class K, class V, class H>
using MapOf = ankerl::unordered_dense::map<K, V, H>;
using StrMap = ankerl::unordered_dense::map<std::string, int64_t>;
#endif

using Map = MapOf<int64_t, int64_t, IntHash>;
// A value of eight integers (`big`).
using Big = std::array<int64_t, 8>;
using BigMap = MapOf<int64_t, Big, IntHash>;

static const int64_t MUL = -7046029254386353131;
static const int64_t N = 1000000;

// Keeps a value the optimizer must compute, as Rust's black_box does.
template <class T>
static inline T opaque(T x) {
    asm volatile("" : "+r"(x));
    return x;
}
template <class T>
static inline void keep(T const& x) {
    asm volatile("" : : "r"(&x) : "memory");
}

static int64_t wrap_mul(int64_t a, int64_t b) { return (int64_t)((uint64_t)a * (uint64_t)b); }

static uint64_t now() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

static void out(const char* keys, const char* op, uint64_t ns, int64_t check) {
    std::printf("%s %s %llu %lld\n", keys, op, (unsigned long long)ns, (long long)check);
}

static void sized(int64_t s) {
    int64_t total = 4 * N;
    int64_t k = s < N ? N / s : 1;
    int64_t reps = total / (k * s);
    char name[32];
    std::snprintf(name, sizeof name, "int%lld", (long long)s);
    uint64_t ins = 0, rem = 0;
    int64_t check = 0;
    for (int64_t r = 0; r < reps; r++) {
        std::vector<Map> maps(k);
        uint64_t t = now();
        for (int64_t j = 0; j < k; j++) {
            Map& m = maps[j];
            int64_t base = j * s;
            for (int64_t i = 0; i < s; i++) m.insert_or_assign(wrap_mul(base + i, MUL), i);
        }
        ins += now() - t;
        t = now();
        for (int64_t j = 0; j < k; j++) {
            Map& m = maps[j];
            int64_t base = j * s;
            for (int64_t i = 0; i < s; i++) {
                auto it = m.find(wrap_mul(base + i, MUL));
                if (it != m.end()) {
                    check += it->second;
                    m.erase(it);
                }
            }
        }
        rem += now() - t;
        keep(maps);
    }
    auto scale = [&](uint64_t ns) { return ns * (uint64_t)N / (uint64_t)total; };
    out(name, "insert", scale(ins), reps * k * s);
    out(name, "remove", scale(rem), check);
    Map m;
    for (int64_t i = 0; i < s; i++) m.insert_or_assign(wrap_mul(i, MUL), i);
    int64_t rounds = total / s;
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++)
        for (int64_t i = 0; i < s; i++) {
            auto it = m.find(wrap_mul(opaque(i), MUL));
            if (it != m.end()) sum += it->second;
        }
    out(name, "hit", scale(now() - t), sum);
    int64_t found = 0;
    t = now();
    for (int64_t r = 0; r < rounds; r++)
        for (int64_t i = s; i < 2 * s; i++)
            if (m.contains(wrap_mul(opaque(i), MUL))) found++;
    out(name, "miss", scale(now() - t), found);
    sum = 0;
    t = now();
    for (int64_t r = 0; r < rounds; r++) {
        Map const& mm = *opaque(&m);
        for (auto const& kv : mm) sum += kv.second;
    }
    out(name, "iterate", scale(now() - t), sum);
}

// splitmix64's output for `n + 1`: a bijection, so distinct `n` give
// distinct keys, scattered over all 64 bits.
static int64_t scatter(int64_t n) {
    uint64_t z = ((uint64_t)n + 1) * 0x9e3779b97f4a7c15ull;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return (int64_t)(z ^ (z >> 31));
}

static const int64_t SEED = 0x5eed;

// `v` shuffled by Fisher-Yates, swap `i` choosing `scatter(SEED + i) % (i + 1)`.
static void shuffle(std::vector<int64_t>& v) {
    for (size_t i = v.size() - 1; i > 0; i--) {
        size_t j = (size_t)((uint64_t)scatter(SEED + (int64_t)i) % (uint64_t)(i + 1));
        std::swap(v[i], v[j]);
    }
}

// The ops of `sized` on random keys (`scatter` of 0, 1, ...), read from
// arrays made before the timing; hits look the keys up in shuffled order.
static void random_keys(int64_t s) {
    int64_t total = 4 * N;
    int64_t k = s < N ? N / s : 1;
    int64_t reps = total / (k * s);
    char name[32];
    std::snprintf(name, sizeof name, "rnd%lld", (long long)s);
    std::vector<int64_t> keys(k * s);
    for (int64_t n = 0; n < k * s; n++) keys[n] = scatter(n);
    uint64_t ins = 0, rem = 0;
    int64_t check = 0;
    for (int64_t r = 0; r < reps; r++) {
        std::vector<Map> maps(k);
        uint64_t t = now();
        for (int64_t j = 0; j < k; j++) {
            Map& m = maps[j];
            const int64_t* ks = keys.data() + j * s;
            for (int64_t i = 0; i < s; i++) m.insert_or_assign(ks[i], i);
        }
        ins += now() - t;
        t = now();
        for (int64_t j = 0; j < k; j++) {
            Map& m = maps[j];
            const int64_t* ks = keys.data() + j * s;
            for (int64_t i = 0; i < s; i++) {
                auto it = m.find(ks[i]);
                if (it != m.end()) {
                    check += it->second;
                    m.erase(it);
                }
            }
        }
        rem += now() - t;
        keep(maps);
    }
    auto scale = [&](uint64_t ns) { return ns * (uint64_t)N / (uint64_t)total; };
    out(name, "insert", scale(ins), reps * k * s);
    out(name, "remove", scale(rem), check);
    Map m;
    for (int64_t i = 0; i < s; i++) m.insert_or_assign(keys[i], i);
    std::vector<int64_t> hit(keys.begin(), keys.begin() + s);
    shuffle(hit);
    std::vector<int64_t> miss(s);
    for (int64_t i = 0; i < s; i++) miss[i] = scatter(8 * N + i);
    int64_t rounds = total / s;
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++) {
        const int64_t* hs = opaque(hit.data());
        for (int64_t i = 0; i < s; i++) {
            auto it = m.find(hs[i]);
            if (it != m.end()) sum += it->second;
        }
    }
    out(name, "hit", scale(now() - t), sum);
    int64_t found = 0;
    t = now();
    for (int64_t r = 0; r < rounds; r++) {
        const int64_t* ms = opaque(miss.data());
        for (int64_t i = 0; i < s; i++)
            if (m.contains(ms[i])) found++;
    }
    out(name, "miss", scale(now() - t), found);
    sum = 0;
    t = now();
    for (int64_t r = 0; r < rounds; r++) {
        Map const& mm = *opaque(&m);
        for (auto const& kv : mm) sum += kv.second;
    }
    out(name, "iterate", scale(now() - t), sum);
}

// `text(n)` of bench/hash/WORKLOADS.md: 7 to 27 bytes, distinct by
// the part after `#`.
static std::string text(int64_t n) {
    return std::to_string((uint64_t)scatter(n) >> (n % 48)) + "#" + std::to_string(n);
}

// `big(i)`: eight integers from `i`.
static Big big(int64_t i) { return {i, i + 1, i + 2, i + 3, i + 4, i + 5, i + 6, i + 7}; }

// 0, 1, ..., s - 1, shuffled.
static std::vector<int64_t> shuffled_range(int64_t s) {
    std::vector<int64_t> p(s);
    std::iota(p.begin(), p.end(), 0);
    shuffle(p);
    return p;
}

// One lookup at a time, each waiting for the last: the map is one
// cycle through its keys, in shuffled order. Each key `scatter(i)` is
// put in order of `i`, with the key after it in the cycle as its value,
// so a map that keeps its entries in order meets them out of order.
static void latency(int64_t s) {
    int64_t total = 4 * N;
    std::vector<int64_t> p = shuffled_range(s);
    Map m;
    std::vector<int64_t> next(s);
    for (int64_t t = 0; t < s; t++) next[p[t]] = p[(t + 1) % s];
    for (int64_t i = 0; i < s; i++) m.insert_or_assign(scatter(i), scatter(next[i]));
    int64_t key = scatter(p[0]);
    uint64_t t = now();
    for (int64_t r = 0; r < total; r++) key = m.find(key)->second;
    char name[32];
    std::snprintf(name, sizeof name, "lat%lld", (long long)s);
    out(name, "chain", (now() - t) * (uint64_t)N / (uint64_t)total, key);
}

// A map of `s` keys turned over: each step removes the oldest key and
// inserts a new one.
static void churn(int64_t s) {
    int64_t total = 4 * N;
    int64_t turns = total / 2;
    std::vector<int64_t> keys(s + turns);
    for (int64_t n = 0; n < s + turns; n++) keys[n] = scatter(n);
    Map m;
    for (int64_t i = 0; i < s; i++) m.insert_or_assign(keys[i], i);
    uint64_t check = 0;
    uint64_t t = now();
    for (int64_t i = 0; i < turns; i++) {
        auto it = m.find(keys[i]);
        if (it != m.end()) {
            check += (uint64_t)it->second;
            m.erase(it);
        }
        m.insert_or_assign(keys[s + i], s + i);
    }
    uint64_t ns = now() - t;
    keep(m);
    char name[32];
    std::snprintf(name, sizeof name, "churn%lld", (long long)s);
    out(name, "turnover", ns * (uint64_t)N / (uint64_t)total, (int64_t)check);
}

// Lookups that hit half the time, in shuffled order.
static void mixed(int64_t s) {
    int64_t total = 4 * N;
    Map m;
    for (int64_t i = 0; i < s; i++) m.insert_or_assign(scatter(i), i);
    std::vector<int64_t> look(s);
    for (int64_t i = 0; i < s; i++) look[i] = i % 2 == 0 ? scatter(i) : scatter(8 * N + i);
    shuffle(look);
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < total / s; r++) {
        const int64_t* ls = opaque(look.data());
        for (int64_t i = 0; i < s; i++) {
            auto it = m.find(ls[i]);
            if (it != m.end()) sum += it->second;
        }
    }
    char name[32];
    std::snprintf(name, sizeof name, "mix%lld", (long long)s);
    out(name, "half", (now() - t) * (uint64_t)N / (uint64_t)total, sum);
}

// Text keys, each moved into the map and found by an equal text made
// apart; a million operations a row.
static void text_keys(int64_t s) {
    int64_t k = s < N ? N / s : 1;
    int64_t reps = N / (k * s);
    char name[32];
    std::snprintf(name, sizeof name, "str%lld", (long long)s);
    uint64_t ins = 0, rem = 0;
    int64_t check = 0;
    for (int64_t r = 0; r < reps; r++) {
        std::vector<std::string> put(k * s), take(k * s);
        for (int64_t n = 0; n < k * s; n++) put[n] = text(n);
        for (int64_t n = 0; n < k * s; n++) take[n] = text(n);
        std::vector<StrMap> maps(k);
        uint64_t t = now();
        for (int64_t j = 0; j < k; j++) {
            StrMap& m = maps[j];
            std::string* ks = put.data() + j * s;
            for (int64_t i = 0; i < s; i++) m.insert_or_assign(std::move(ks[i]), i);
        }
        ins += now() - t;
        t = now();
        for (int64_t j = 0; j < k; j++) {
            StrMap& m = maps[j];
            const std::string* ks = take.data() + j * s;
            for (int64_t i = 0; i < s; i++) {
                auto it = m.find(ks[i]);
                if (it != m.end()) {
                    check += it->second;
                    m.erase(it);
                }
            }
        }
        rem += now() - t;
        keep(maps);
    }
    out(name, "insert", ins, reps * k * s);
    out(name, "remove", rem, check);
    StrMap m;
    for (int64_t i = 0; i < s; i++) m.insert_or_assign(text(i), i);
    std::vector<int64_t> p = shuffled_range(s);
    std::vector<std::string> hit(s), miss(s);
    for (int64_t i = 0; i < s; i++) hit[i] = text(p[i]);
    for (int64_t i = 0; i < s; i++) miss[i] = text(8 * N + i);
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < N / s; r++) {
        const std::string* hs = opaque(hit.data());
        for (int64_t i = 0; i < s; i++) {
            auto it = m.find(hs[i]);
            if (it != m.end()) sum += it->second;
        }
    }
    out(name, "hit", now() - t, sum);
    int64_t found = 0;
    t = now();
    for (int64_t r = 0; r < N / s; r++) {
        const std::string* ms = opaque(miss.data());
        for (int64_t i = 0; i < s; i++)
            if (m.contains(ms[i])) found++;
    }
    out(name, "miss", now() - t, found);
}

// `random_keys`' insert, remove, hit and iterate with a value of eight
// integers.
static void bigs(int64_t s) {
    int64_t total = 4 * N;
    int64_t k = s < N ? N / s : 1;
    int64_t reps = total / (k * s);
    char name[32];
    std::snprintf(name, sizeof name, "big%lld", (long long)s);
    std::vector<int64_t> keys(k * s);
    for (int64_t n = 0; n < k * s; n++) keys[n] = scatter(n);
    uint64_t ins = 0, rem = 0;
    int64_t check = 0;
    for (int64_t r = 0; r < reps; r++) {
        std::vector<BigMap> maps(k);
        uint64_t t = now();
        for (int64_t j = 0; j < k; j++) {
            BigMap& m = maps[j];
            const int64_t* ks = keys.data() + j * s;
            for (int64_t i = 0; i < s; i++) m.insert_or_assign(ks[i], big(i));
        }
        ins += now() - t;
        t = now();
        for (int64_t j = 0; j < k; j++) {
            BigMap& m = maps[j];
            const int64_t* ks = keys.data() + j * s;
            for (int64_t i = 0; i < s; i++) {
                auto it = m.find(ks[i]);
                if (it != m.end()) {
                    check += it->second[7];
                    m.erase(it);
                }
            }
        }
        rem += now() - t;
        keep(maps);
    }
    auto scale = [&](uint64_t ns) { return ns * (uint64_t)N / (uint64_t)total; };
    out(name, "insert", scale(ins), reps * k * s);
    out(name, "remove", scale(rem), check);
    BigMap m;
    for (int64_t i = 0; i < s; i++) m.insert_or_assign(keys[i], big(i));
    std::vector<int64_t> hit(keys.begin(), keys.begin() + s);
    shuffle(hit);
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < total / s; r++) {
        const int64_t* hs = opaque(hit.data());
        for (int64_t i = 0; i < s; i++) {
            auto it = m.find(hs[i]);
            if (it != m.end()) sum += it->second[7];
        }
    }
    out(name, "hit", scale(now() - t), sum);
    sum = 0;
    t = now();
    for (int64_t r = 0; r < total / s; r++) {
        BigMap const& mm = *opaque(&m);
        for (auto const& kv : mm) sum += kv.second[0];
    }
    out(name, "iterate", scale(now() - t), sum);
}

// `mem`: one map of 4,000,000 keys, for its peak memory; `mem0`: the
// keys alone, the baseline.
static void memory(bool with_map) {
    int64_t n = 4000000;
    std::vector<int64_t> keys(n);
    for (int64_t i = 0; i < n; i++) keys[i] = scatter(i);
    keep(keys);
    if (!with_map) {
        std::printf("mem0 %lld len %zu\n", (long long)n, keys.size());
        return;
    }
    Map m;
    for (int64_t i = 0; i < n; i++) m.insert_or_assign(keys[i], i);
    keep(m);
    std::printf("mem %lld len %zu\n", (long long)n, (size_t)m.size());
}

int main(int argc, char** argv) {
    if (argc > 1 && std::strcmp(argv[1], "mem") == 0) return memory(true), 0;
    if (argc > 1 && std::strcmp(argv[1], "mem0") == 0) return memory(false), 0;
    for (int64_t s : {16, 1000, 100000, 4000000}) sized(s);
    for (int64_t s : {16, 24, 1000, 1500, 100000, 150000, 3000000, 4000000}) random_keys(s);
    for (int64_t s : {16, 1000, 100000, 4000000}) latency(s);
    for (int64_t s : {16, 1000, 100000, 4000000}) churn(s);
    for (int64_t s : {16, 1000, 100000, 4000000}) mixed(s);
    for (int64_t s : {16, 1000, 100000, 1000000}) text_keys(s);
    for (int64_t s : {16, 1000, 100000, 1000000}) bigs(s);
}
