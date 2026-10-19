//! Tokio's tasks timed as bench/tasks/tasks.rig times Rig's: spawn,
//! chain, fanout, yield, hog. Prints `NAME NS CHECK` per benchmark.

use std::hint::black_box;
use std::time::Instant;

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
#[tokio::main(flavor = "multi_thread")]
async fn main() {
    tokio::spawn(run()).await.unwrap();
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
