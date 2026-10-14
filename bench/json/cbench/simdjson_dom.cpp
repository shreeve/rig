// prog FILE N: N full parses of FILE with simdjson's DOM parser (one
// reused parser: tape and string buffer kept between runs), timed; prints
// "<ns> <check>", check = the top-level element count summed over runs.
#include "simdjson.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
using namespace simdjson;

int main(int argc, char **argv) {
    if (argc != 3) { std::fprintf(stderr, "usage: %s FILE N\n", argv[0]); return 2; }
    padded_string json;
    if (padded_string::load(argv[1]).get(json)) { std::fprintf(stderr, "read %s\n", argv[1]); return 2; }
    long n = std::atol(argv[2]);
    dom::parser parser;
    unsigned long check = 0;
    auto t = std::chrono::steady_clock::now();
    for (long i = 0; i < n; i++) {
        dom::element doc;
        auto err = parser.parse(json).get(doc);
        if (err) { std::fprintf(stderr, "parse error: %s\n", error_message(err)); return 1; }
        dom::array a; dom::object o;
        if (!doc.get_array().get(a)) check += a.size();
        else if (!doc.get_object().get(o)) check += o.size();
        else check += 1;
    }
    long long ns = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t).count();
    std::printf("%lld %lu\n", ns, check);
    return 0;
}
