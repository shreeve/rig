//! Tokio's tasks timed as bench/tasks/tasks.rig times Rig's: spawn,
//! chain, fanout, yield, hog. Run as `tasks-tokio many`, it holds many
//! sleeping tasks at once (many), and as `tasks-tokio idle`, none,
//! sleeping as long. Prints `NAME NS CHECK` per benchmark.

use std::hint::black_box;
use std::time::{Duration, Instant};

const WAVES: i64 = 100;
const SIZE: i64 = 1000;
const CHAIN: i64 = 10000;
const FAN_TASKS: i64 = 10;
const FAN_WORK: i64 = 20_000_000;
const YIELD_TASKS: i64 = 100;
const YIELDS: i64 = 10000;
const HOG_TASKS: i64 = 32;
const HOG_WORK: i64 = 20_000_000;
const HOG_CHAIN: i64 = 50;
const HOG_SLICE: i64 = 1_000_000;
const MANY: i64 = 10000;
const MANY_NAP: Duration = Duration::from_millis(200);
const CHUNKS: i64 = 1024;
const EVEN_WORK: i64 = 61000;
const SKEW_BASE: i64 = 1200;
const ALLOC_ROUNDS: i64 = 4400;

fn leaf(i: i64) -> i64 {
    black_box(i)
}

fn spin(n: i64) -> i64 {
    let n = black_box(n);
    let mut total = 0i64;
    for i in 0..n {
        total = (total + i * 7) % 1000003;
    }
    total
}

// The benchmarks run in a task, as Go's run in the main goroutine and
// Rig's tasks start from `main`: `#[tokio::main]`'s own future runs
// outside the worker threads, where every wait would cross threads.
// The scaling benchmarks (bench/tasks/bench-scale), each run alone as
// `tasks-tokio scale NAME W`, as tasks.rig runs them: W is 1 for the work
// and 0 for none. Each chunk, and each split of the tree, is a task.

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

fn tree(lo: i64, hi: i64, w: i64) -> std::pin::Pin<Box<dyn std::future::Future<Output = i64> + Send>> {
    Box::pin(async move {
        if hi - lo == 1 {
            return spin(w * cost(lo));
        }
        let mid = (lo + hi) / 2;
        let a = tokio::spawn(tree(lo, mid, w));
        let b = tree(mid, hi, w).await;
        (b + a.await.unwrap()) % 1000003
    })
}

async fn scale(name: String, w: i64) {
    let t = Instant::now();
    let mut check = 0i64;
    if name == "tree" {
        check = tree(0, CHUNKS, w).await;
    } else {
        let name: &'static str = Box::leak(name.clone().into_boxed_str());
        let mut hs = Vec::with_capacity(CHUNKS as usize);
        for i in 0..CHUNKS {
            hs.push(tokio::spawn(async move { chunk(name, i, w) }));
        }
        for h in hs {
            check = (check + h.await.unwrap()) % 1000003;
        }
    }
    println!("{} {} {}", name, t.elapsed().as_nanos(), check);
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() > 3 && args[1] == "scale" {
        let w = if args[3] == "0" { 0 } else { 1 };
        tokio::spawn(scale(args[2].clone(), w)).await.unwrap();
        return;
    }
    // `long` sleeps 1 s, long enough for bench-scale to read the memory
    // of the tasks from outside while they sleep.
    let nap = if args.len() > 2 && args[2] == "long" { Duration::from_secs(1) } else { MANY_NAP };
    match std::env::args().nth(1).as_deref() {
        Some("many") => tokio::spawn(many(nap)).await.unwrap(),
        Some(_) => tokio::spawn(idle(nap)).await.unwrap(),
        None => tokio::spawn(run()).await.unwrap(),
    }
}

async fn idle(nap: Duration) {
    let t = Instant::now();
    tokio::time::sleep(nap).await;
    println!("idle {} {}", t.elapsed().as_nanos(), 1);
}

async fn many(nap: Duration) {
    let t = Instant::now();
    let mut hs = Vec::with_capacity(MANY as usize);
    for _ in 0..MANY {
        hs.push(tokio::spawn(async move {
            tokio::time::sleep(nap).await;
            1i64
        }));
    }
    let mut sum = 0i64;
    for h in hs {
        sum += h.await.unwrap();
    }
    println!("many {} {}", t.elapsed().as_nanos(), sum);
}

async fn run() {
    let t = Instant::now();
    let mut sum = 0i64;
    for _ in 0..WAVES {
        let mut hs = Vec::with_capacity(SIZE as usize);
        for i in 0..SIZE {
            hs.push(tokio::spawn(async move { leaf(i) }));
        }
        for h in hs {
            sum += h.await.unwrap();
        }
    }
    println!("spawn {} {}", t.elapsed().as_nanos(), sum);

    let t = Instant::now();
    let mut sum = 0i64;
    for i in 0..CHAIN {
        sum += tokio::spawn(async move { leaf(i) }).await.unwrap();
    }
    println!("chain {} {}", t.elapsed().as_nanos(), sum);

    let t = Instant::now();
    let mut hs = Vec::new();
    for i in 0..FAN_TASKS {
        hs.push(tokio::spawn(async move { spin(FAN_WORK + i) }));
    }
    let mut sum = 0i64;
    for h in hs {
        sum += h.await.unwrap();
    }
    println!("fanout {} {}", t.elapsed().as_nanos(), sum);

    let t = Instant::now();
    let mut hs = Vec::new();
    for _ in 0..YIELD_TASKS {
        hs.push(tokio::spawn(async move {
            for _ in 0..YIELDS {
                tokio::task::yield_now().await;
            }
            YIELDS
        }));
    }
    let mut sum = 0i64;
    for h in hs {
        sum += h.await.unwrap();
    }
    println!("yield {} {}", t.elapsed().as_nanos(), sum);

    let mut hogs = Vec::new();
    for i in 0..HOG_TASKS {
        hogs.push(tokio::spawn(async move { spin(HOG_WORK + i) }));
    }
    let mut slices = Vec::new();
    let t = Instant::now();
    let mut sum = 0i64;
    for i in 0..HOG_CHAIN {
        slices.push(tokio::spawn(async move { spin(HOG_SLICE + i) }));
        let a = tokio::spawn(async move { leaf(i) });
        let b = tokio::spawn(async move { leaf(i) });
        sum += a.await.unwrap();
        sum += b.await.unwrap();
    }
    let ns = t.elapsed().as_nanos();
    for h in hogs {
        sum += h.await.unwrap();
    }
    for h in slices {
        sum += h.await.unwrap();
    }
    println!("hog {} {}", ns, sum);
}
