// prog FILE N: N full parses of FILE into serde_json::Value, timed; prints "<ns> <check>".
// check = top-level element count (array len / object len, 1 for a scalar), summed over runs.
// The Value is dropped inside the timed loop (parse + free). No buffer reuse API exists.
use std::hint::black_box;
use std::time::Instant;

fn top_count(v: &serde_json::Value) -> usize {
    match v {
        serde_json::Value::Array(a) => a.len(),
        serde_json::Value::Object(o) => o.len(),
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
    let mut check: usize = 0;
    let t = Instant::now();
    for _ in 0..n {
        match serde_json::from_slice::<serde_json::Value>(black_box(&input)) {
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
