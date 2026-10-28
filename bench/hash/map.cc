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

// Each row's timed loop is a function of its own that is never inlined,
// so its registers are allotted for that loop alone, not shared with
// the other rows' loops in the caller. It reads the clock around the
// loop, so the call is not timed, and returns the time with the row's
// checksum.
#define NOINLINE __attribute__((noinline))

struct Timed {
    uint64_t ns;
    int64_t check;
};

NOINLINE static uint64_t int_insert(std::vector<Map>& maps, int64_t k, int64_t s) {
    uint64_t t = now();
    for (int64_t j = 0; j < k; j++) {
        Map& m = maps[j];
        int64_t base = j * s;
        for (int64_t i = 0; i < s; i++) m.insert_or_assign(wrap_mul(base + i, MUL), i);
    }
    return now() - t;
}

NOINLINE static Timed int_remove(std::vector<Map>& maps, int64_t k, int64_t s) {
    int64_t check = 0;
    uint64_t t = now();
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
    return {now() - t, check};
}

NOINLINE static Timed int_hit(Map& m, int64_t s, int64_t rounds) {
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++)
        for (int64_t i = 0; i < s; i++) {
            auto it = m.find(wrap_mul(opaque(i), MUL));
            if (it != m.end()) sum += it->second;
        }
    return {now() - t, sum};
}

NOINLINE static Timed int_miss(Map& m, int64_t s, int64_t rounds) {
    int64_t found = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++)
        for (int64_t i = s; i < 2 * s; i++)
            if (m.contains(wrap_mul(opaque(i), MUL))) found++;
    return {now() - t, found};
}

NOINLINE static Timed int_iterate(Map& m, int64_t rounds) {
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++) {
        Map const& mm = *opaque(&m);
        for (auto const& kv : mm) sum += kv.second;
    }
    return {now() - t, sum};
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
        ins += int_insert(maps, k, s);
        Timed d = int_remove(maps, k, s);
        rem += d.ns;
        check += d.check;
        keep(maps);
    }
    auto scale = [&](uint64_t ns) { return ns * (uint64_t)N / (uint64_t)total; };
    out(name, "insert", scale(ins), reps * k * s);
    out(name, "remove", scale(rem), check);
    Map m;
    for (int64_t i = 0; i < s; i++) m.insert_or_assign(wrap_mul(i, MUL), i);
    int64_t rounds = total / s;
    Timed d = int_hit(m, s, rounds);
    out(name, "hit", scale(d.ns), d.check);
    d = int_miss(m, s, rounds);
    out(name, "miss", scale(d.ns), d.check);
    d = int_iterate(m, rounds);
    out(name, "iterate", scale(d.ns), d.check);
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

NOINLINE static uint64_t rnd_insert(std::vector<Map>& maps, std::vector<int64_t> const& keys, int64_t k, int64_t s) {
    uint64_t t = now();
    for (int64_t j = 0; j < k; j++) {
        Map& m = maps[j];
        const int64_t* ks = keys.data() + j * s;
        for (int64_t i = 0; i < s; i++) m.insert_or_assign(ks[i], i);
    }
    return now() - t;
}

NOINLINE static Timed rnd_remove(std::vector<Map>& maps, std::vector<int64_t> const& keys, int64_t k, int64_t s) {
    int64_t check = 0;
    uint64_t t = now();
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
    return {now() - t, check};
}

NOINLINE static Timed rnd_hit(Map& m, std::vector<int64_t>& hit, int64_t s, int64_t rounds) {
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++) {
        const int64_t* hs = opaque(hit.data());
        for (int64_t i = 0; i < s; i++) {
            auto it = m.find(hs[i]);
            if (it != m.end()) sum += it->second;
        }
    }
    return {now() - t, sum};
}

NOINLINE static Timed rnd_miss(Map& m, std::vector<int64_t>& miss, int64_t s, int64_t rounds) {
    int64_t found = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++) {
        const int64_t* ms = opaque(miss.data());
        for (int64_t i = 0; i < s; i++)
            if (m.contains(ms[i])) found++;
    }
    return {now() - t, found};
}

NOINLINE static Timed rnd_iterate(Map& m, int64_t rounds) {
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++) {
        Map const& mm = *opaque(&m);
        for (auto const& kv : mm) sum += kv.second;
    }
    return {now() - t, sum};
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
        ins += rnd_insert(maps, keys, k, s);
        Timed d = rnd_remove(maps, keys, k, s);
        rem += d.ns;
        check += d.check;
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
    Timed d = rnd_hit(m, hit, s, rounds);
    out(name, "hit", scale(d.ns), d.check);
    d = rnd_miss(m, miss, s, rounds);
    out(name, "miss", scale(d.ns), d.check);
    d = rnd_iterate(m, rounds);
    out(name, "iterate", scale(d.ns), d.check);
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

NOINLINE static Timed lat_chain(Map& m, int64_t key, int64_t total) {
    uint64_t t = now();
    for (int64_t r = 0; r < total; r++) key = m.find(key)->second;
    return {now() - t, key};
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
    Timed d = lat_chain(m, scatter(p[0]), total);
    char name[32];
    std::snprintf(name, sizeof name, "lat%lld", (long long)s);
    out(name, "chain", d.ns * (uint64_t)N / (uint64_t)total, d.check);
}

NOINLINE static Timed churn_turnover(Map& m, std::vector<int64_t> const& keys, int64_t s, int64_t turns) {
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
    return {ns, (int64_t)check};
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
    Timed d = churn_turnover(m, keys, s, turns);
    keep(m);
    char name[32];
    std::snprintf(name, sizeof name, "churn%lld", (long long)s);
    out(name, "turnover", d.ns * (uint64_t)N / (uint64_t)total, d.check);
}

NOINLINE static Timed mix_half(Map& m, std::vector<int64_t>& look, int64_t s, int64_t rounds) {
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++) {
        const int64_t* ls = opaque(look.data());
        for (int64_t i = 0; i < s; i++) {
            auto it = m.find(ls[i]);
            if (it != m.end()) sum += it->second;
        }
    }
    return {now() - t, sum};
}

// Lookups that hit half the time, in shuffled order.
static void mixed(int64_t s) {
    int64_t total = 4 * N;
    Map m;
    for (int64_t i = 0; i < s; i++) m.insert_or_assign(scatter(i), i);
    std::vector<int64_t> look(s);
    for (int64_t i = 0; i < s; i++) look[i] = i % 2 == 0 ? scatter(i) : scatter(8 * N + i);
    shuffle(look);
    Timed d = mix_half(m, look, s, total / s);
    char name[32];
    std::snprintf(name, sizeof name, "mix%lld", (long long)s);
    out(name, "half", d.ns * (uint64_t)N / (uint64_t)total, d.check);
}

NOINLINE static uint64_t str_insert(std::vector<StrMap>& maps, std::vector<std::string>& put, int64_t k, int64_t s) {
    uint64_t t = now();
    for (int64_t j = 0; j < k; j++) {
        StrMap& m = maps[j];
        std::string* ks = put.data() + j * s;
        for (int64_t i = 0; i < s; i++) m.insert_or_assign(std::move(ks[i]), i);
    }
    return now() - t;
}

NOINLINE static Timed str_remove(std::vector<StrMap>& maps, std::vector<std::string> const& take, int64_t k, int64_t s) {
    int64_t check = 0;
    uint64_t t = now();
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
    return {now() - t, check};
}

NOINLINE static Timed str_hit(StrMap& m, std::vector<std::string>& hit, int64_t s, int64_t rounds) {
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++) {
        const std::string* hs = opaque(hit.data());
        for (int64_t i = 0; i < s; i++) {
            auto it = m.find(hs[i]);
            if (it != m.end()) sum += it->second;
        }
    }
    return {now() - t, sum};
}

NOINLINE static Timed str_miss(StrMap& m, std::vector<std::string>& miss, int64_t s, int64_t rounds) {
    int64_t found = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++) {
        const std::string* ms = opaque(miss.data());
        for (int64_t i = 0; i < s; i++)
            if (m.contains(ms[i])) found++;
    }
    return {now() - t, found};
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
        ins += str_insert(maps, put, k, s);
        Timed d = str_remove(maps, take, k, s);
        rem += d.ns;
        check += d.check;
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
    Timed d = str_hit(m, hit, s, N / s);
    out(name, "hit", d.ns, d.check);
    d = str_miss(m, miss, s, N / s);
    out(name, "miss", d.ns, d.check);
}

NOINLINE static uint64_t big_insert(std::vector<BigMap>& maps, std::vector<int64_t> const& keys, int64_t k, int64_t s) {
    uint64_t t = now();
    for (int64_t j = 0; j < k; j++) {
        BigMap& m = maps[j];
        const int64_t* ks = keys.data() + j * s;
        for (int64_t i = 0; i < s; i++) m.insert_or_assign(ks[i], big(i));
    }
    return now() - t;
}

NOINLINE static Timed big_remove(std::vector<BigMap>& maps, std::vector<int64_t> const& keys, int64_t k, int64_t s) {
    int64_t check = 0;
    uint64_t t = now();
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
    return {now() - t, check};
}

NOINLINE static Timed big_hit(BigMap& m, std::vector<int64_t>& hit, int64_t s, int64_t rounds) {
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++) {
        const int64_t* hs = opaque(hit.data());
        for (int64_t i = 0; i < s; i++) {
            auto it = m.find(hs[i]);
            if (it != m.end()) sum += it->second[7];
        }
    }
    return {now() - t, sum};
}

NOINLINE static Timed big_iterate(BigMap& m, int64_t rounds) {
    int64_t sum = 0;
    uint64_t t = now();
    for (int64_t r = 0; r < rounds; r++) {
        BigMap const& mm = *opaque(&m);
        for (auto const& kv : mm) sum += kv.second[0];
    }
    return {now() - t, sum};
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
        ins += big_insert(maps, keys, k, s);
        Timed d = big_remove(maps, keys, k, s);
        rem += d.ns;
        check += d.check;
        keep(maps);
    }
    auto scale = [&](uint64_t ns) { return ns * (uint64_t)N / (uint64_t)total; };
    out(name, "insert", scale(ins), reps * k * s);
    out(name, "remove", scale(rem), check);
    BigMap m;
    for (int64_t i = 0; i < s; i++) m.insert_or_assign(keys[i], big(i));
    std::vector<int64_t> hit(keys.begin(), keys.begin() + s);
    shuffle(hit);
    Timed d = big_hit(m, hit, s, total / s);
    out(name, "hit", scale(d.ns), d.check);
    d = big_iterate(m, total / s);
    out(name, "iterate", scale(d.ns), d.check);
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
