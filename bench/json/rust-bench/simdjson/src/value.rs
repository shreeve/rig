// prog FILE N: N full parses of FILE into simd_json::BorrowedValue, timed; prints "<ns> <check>".
// Uses to_borrowed_value_with_buffers, reusing simd_json::Buffers across runs (the
// intermediate tape Vec and the DOM itself are allocated fresh each run, as the API requires).
// simd-json parses in place, so each run first copies the input into a preallocated
// mutable buffer (copy_from_slice) INSIDE the timed loop. The DOM is dropped inside the loop.
// check = top-level element count (array len / object len, 1 for a scalar), summed over runs.
use simd_json::{BorrowedValue, Buffers};
use std::hint::black_box;
use std::time::Instant;

fn top_count(v: &BorrowedValue) -> usize {
    match v {
        BorrowedValue::Array(a) => a.len(),
        BorrowedValue::Object(o) => o.len(),
        _ => 1,
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: {} FILE N", args[0]);
        std::process::exit(2);
    }
    let input = std::fs::read(&args[1]).unwrap_or_else(|e| {
        eprintln!("read {}: {e}", args[1]);
        std::process::exit(2)
    });
    let n: u64 = args[2].parse().expect("N");
    eprintln!("simd-json implementation: {}", simd_json::Deserializer::algorithm());
    let mut buf = vec![0u8; input.len()];
    let mut buffers = Buffers::new(input.len());
    let mut check: usize = 0;
    let t = Instant::now();
    for _ in 0..n {
        buf.copy_from_slice(black_box(&input));
        match simd_json::to_borrowed_value_with_buffers(&mut buf, &mut buffers) {
            Ok(v) => check = check.wrapping_add(top_count(black_box(&v))),
            Err(e) => {
                eprintln!("parse error: {e}");
                std::process::exit(1);
            }
        }
    }
    let ns = t.elapsed().as_nanos();
    println!("{} {}", ns, black_box(check));
}
