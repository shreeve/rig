//! Rayon timed on bench/tasks/bench-scale's scaling benchmarks, as
//! bench/tasks/tasks.rig runs them: each run alone as
//! `tasks-rayon scale NAME W`, with W 1 for the work and 0 for none.
//! The chunks go through `into_par_iter`, and the tree splits through
//! `rayon::join`. Rayon's model has no sleeping tasks, yields, or
//! waiting behind a computation, so it runs only these. Prints
//! `NAME NS CHECK`.

use rayon::prelude::*;
use std::hint::black_box;
use std::time::Instant;

const CHUNKS: i64 = 1024;
const EVEN_WORK: i64 = 61000;
const SKEW_BASE: i64 = 1200;
const ALLOC_ROUNDS: i64 = 4400;

fn spin(n: i64) -> i64 {
    let n = black_box(n);
    let mut total = 0i64;
    for i in 0..n {
        total = (total + i * 7) % 1000003;
    }
    total
}

fn cost(i: i64) -> i64 {
    SKEW_BASE * (1 + i * 7919 % 100)
}

fn churn(i: i64, rounds: i64) -> i64 {
    let mut total = 0i64;
    for k in 0..black_box(rounds) {
        let mut xs = Vec::new();
        for j in 0..16 {
            xs.push(i + j + k);
        }
        let s = format!("item {}", k);
        let xs = black_box(xs);
        let s = black_box(s);
        for x in &xs {
            total = (total + x) % 1000003;
        }
        total = (total + s.len() as i64) % 1000003;
    }
    total
}

fn chunk(name: &str, i: i64, w: i64) -> i64 {
    match name {
        "even" => spin(w * (EVEN_WORK + i)),
        "skew" => spin(w * cost(i)),
        _ => churn(i, w * ALLOC_ROUNDS),
    }
}

fn tree(lo: i64, hi: i64, w: i64) -> i64 {
    if hi - lo == 1 {
        return spin(w * cost(lo));
    }
    let mid = (lo + hi) / 2;
    let (a, b) = rayon::join(|| tree(lo, mid, w), || tree(mid, hi, w));
    (b + a) % 1000003
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 || args[1] != "scale" {
        eprintln!("usage: tasks-rayon scale NAME W");
        std::process::exit(2);
    }
    let name = args[2].as_str();
    let w = if args[3] == "0" { 0 } else { 1 };
    // Start the pool before the clock, as the other runtimes start
    // theirs before their benchmarks run.
    rayon::broadcast(|_| ());
    let t = Instant::now();
    let check = if name == "tree" {
        tree(0, CHUNKS, w)
    } else {
        let xs: Vec<i64> = (0..CHUNKS).into_par_iter().map(|i| chunk(name, i, w)).collect();
        xs.iter().fold(0, |c, x| (c + x) % 1000003)
    };
    println!("{} {} {}", name, t.elapsed().as_nanos(), check);
}
