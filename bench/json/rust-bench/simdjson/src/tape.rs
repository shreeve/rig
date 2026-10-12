// prog FILE N: N full parses of FILE into a simd_json Tape, timed; prints "<ns> <check>".
// Reuses simd_json::Buffers (string buffer, structural indexes, aligned input copy, stage-2
// stack) and the Tape's Vec<Node> across runs via fill_tape + Tape::reset.
// simd-json parses in place, so each run first copies the input into a preallocated
// mutable buffer (copy_from_slice) INSIDE the timed loop.
// check = tape length (node count), summed over runs.
use simd_json::{Buffers, Tape};
use std::hint::black_box;
use std::time::Instant;

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
    let mut store: Option<Tape<'static>> = Some(Tape(Vec::new()));
    let mut check: usize = 0;
    let t = Instant::now();
    for _ in 0..n {
        buf.copy_from_slice(black_box(&input));
        let mut tape = store.take().unwrap().reset();
        if let Err(e) = simd_json::fill_tape(&mut buf, &mut buffers, &mut tape) {
            eprintln!("parse error: {e}");
            std::process::exit(1);
        }
        check = check.wrapping_add(black_box(&tape).0.len());
        store = Some(tape.reset());
    }
    let ns = t.elapsed().as_nanos();
    println!("{} {}", ns, black_box(check));
}
