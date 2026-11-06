//! `find FILE [finder]`: the nanoseconds of one memchr search for each
//! case of bench/text/time.rig, the same cases, reps, and loop, printed
//! as time.rig prints them (`SIZE K KIND NS FOUND`). `memmem::find` takes the
//! needle at each call, as std.text's `find` does; with `finder`, a
//! `memmem::Finder` is built once per case, outside the timed loop.

use memchr::memmem;
use std::hint::black_box;
use std::time::Instant;

fn case_ns(s: &[u8], pat: &[u8], reps: usize, finder: bool) -> u128 {
    let f = memmem::Finder::new(pat);
    let mut best = u128::MAX;
    let mut sum: i64 = 0;
    for _ in 0..5 {
        let t0 = Instant::now();
        for _ in 0..reps {
            // So no search is moved out of the loop.
            let s = black_box(s);
            let r = if finder { f.find(s) } else { memmem::find(s, pat) };
            sum += r.map_or(7, |i| i as i64);
        }
        best = best.min(t0.elapsed().as_nanos());
    }
    if sum == -1 {
        println!();
    }
    best
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: find FILE [finder]");
        std::process::exit(2);
    }
    let finder = args.get(2).is_some_and(|a| a == "finder");
    let all = std::fs::read(&args[1]).expect("find: cannot read the file");
    if all.len() < 8192 {
        eprintln!("find: the file is shorter than 8 KiB");
        std::process::exit(1);
    }
    for size in [8, 16, 32, 64, 1024, 4096, all.len()] {
        let start = if size == all.len() { 0 } else { all.len() / 2 + 17 };
        let s = &all[start..start + size];
        for k in [1, 3, 12, 40] {
            if k > size {
                continue;
            }
            for kind in ["early", "late", "miss"] {
                let at = if kind == "early" { s.len() / 16 } else { (s.len() - k) * 15 / 16 };
                let pat: Vec<u8> = (0..k).map(|j| if kind == "miss" && j == k / 2 { 1 } else { s[at + j] }).collect();
                let found = memmem::find(s, &pat).map_or(-1, |i| i as i64);
                let work = if found < 0 { s.len() } else { found as usize } + 64;
                let reps = (100_000_000 / work).max(16);
                let ns = case_ns(s, &pat, reps, finder);
                println!("{} {} {} {} {}", size, k, kind, ns as f64 / reps as f64, found);
            }
        }
    }
}
