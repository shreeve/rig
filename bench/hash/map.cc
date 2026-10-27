// The C++ contestants, timed as bench/hash/map.rs times hashbrown: Int
// keys at 16, 1,000, 100,000, and 4,000,000, insert, remove, hit, miss,
// and iterate, 4,000,000 operations a row. One table a build:
//
//   -DTABLE_ABSL   absl::flat_hash_map (SwissTable, groups of 16 on x86, 8 on Arm)
//   -DTABLE_BOOST  boost::unordered_flat_map (groups of 15 and an overflow byte)
//   -DTABLE_DENSE  ankerl::unordered_dense::map (a dense array of entries
//                  beside a table of buckets, in insertion order until an erase)
//
// and its own hash (absl::Hash, boost::hash with boost's mixing, ankerl's
// wyhash), or with -DMIX, Rig's hash of an Int (`hashWord` in
// src/runtime.zig): a full 64x64 multiply folded to 64 bits, marked as
// avalanching so neither boost nor ankerl mixes it again. bench/hash/bench-hash
// builds it; it prints `KEYS OP NS CHECK` per line.
#include <chrono>
#include <cstdint>
#include <cstdio>
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

#if defined(TABLE_ABSL)
#ifdef MIX
using Map = absl::flat_hash_map<int64_t, int64_t, Mix>;
#else
using Map = absl::flat_hash_map<int64_t, int64_t>;
#endif
#elif defined(TABLE_BOOST)
#ifdef MIX
using Map = boost::unordered_flat_map<int64_t, int64_t, Mix>;
#else
using Map = boost::unordered_flat_map<int64_t, int64_t>;
#endif
#else
#ifdef MIX
using Map = ankerl::unordered_dense::map<int64_t, int64_t, MixDense>;
#else
using Map = ankerl::unordered_dense::map<int64_t, int64_t>;
#endif
#endif

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

int main() {
    for (int64_t s : {16, 1000, 100000, 4000000}) sized(s);
    for (int64_t s : {16, 1000, 100000, 4000000}) random_keys(s);
}
