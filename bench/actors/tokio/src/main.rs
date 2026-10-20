//! A counter run as a Tokio actor, the pattern Tokio teaches: a task
//! that owns the count and serves a bounded `mpsc` channel, each call a
//! message with a `oneshot` for its answer. Timed as
//! bench/actors/actors.rig times Rig's actors: solo, contend, spread.
//! Prints `NAME NS CHECK` per benchmark.

use std::time::Instant;
use tokio::sync::{mpsc, oneshot};

const SOLO: i64 = 1_000_000;
const CONTEND_TASKS: i64 = 8;
const CONTEND_CALLS: i64 = 100_000;
const SPREAD_TASKS: i64 = 1000;
const SPREAD_CALLS: i64 = 1000;

/// The mailbox's bound, as Rig's actors take 64 calls made with `&`.
const MAILBOX: usize = 64;

enum Msg {
    Add(i64, oneshot::Sender<i64>),
    Get(oneshot::Sender<i64>),
}

#[derive(Clone)]
struct Counter {
    tx: mpsc::Sender<Msg>,
}

impl Counter {
    fn new() -> Counter {
        let (tx, mut rx) = mpsc::channel(MAILBOX);
        tokio::spawn(async move {
            let mut hits = 0i64;
            while let Some(m) = rx.recv().await {
                match m {
                    Msg::Add(n, reply) => {
                        hits += n;
                        let _ = reply.send(hits);
                    }
                    Msg::Get(reply) => {
                        let _ = reply.send(hits);
                    }
                }
            }
        });
        Counter { tx }
    }

    async fn add(&self, n: i64) -> i64 {
        let (reply, answer) = oneshot::channel();
        self.tx.send(Msg::Add(n, reply)).await.unwrap();
        answer.await.unwrap()
    }

    async fn get(&self) -> i64 {
        let (reply, answer) = oneshot::channel();
        self.tx.send(Msg::Get(reply)).await.unwrap();
        answer.await.unwrap()
    }
}

async fn solo() {
    let c = Counter::new();
    let t = Instant::now();
    let mut last = 0;
    for _ in 0..SOLO {
        last = c.add(1).await;
    }
    println!("solo {} {}", t.elapsed().as_nanos(), last);
}

async fn contend() {
    let c = Counter::new();
    let t = Instant::now();
    let mut hs = Vec::new();
    for _ in 0..CONTEND_TASKS {
        let c = c.clone();
        hs.push(tokio::spawn(async move {
            for _ in 0..CONTEND_CALLS {
                c.add(1).await;
            }
        }));
    }
    for h in hs {
        h.await.unwrap();
    }
    println!("contend {} {}", t.elapsed().as_nanos(), c.get().await);
}

async fn spread() {
    let t = Instant::now();
    let mut hs = Vec::new();
    for _ in 0..SPREAD_TASKS {
        hs.push(tokio::spawn(async move {
            let c = Counter::new();
            let mut last = 0;
            for _ in 0..SPREAD_CALLS {
                last = c.add(1).await;
            }
            last
        }));
    }
    let mut sum = 0;
    for h in hs {
        sum += h.await.unwrap();
    }
    println!("spread {} {}", t.elapsed().as_nanos(), sum);
}

// The benchmarks run in a task, as bench/tasks/tokio does, so every wait
// stays on the worker threads.
#[tokio::main(flavor = "multi_thread")]
async fn main() {
    tokio::spawn(async {
        solo().await;
        contend().await;
        spread().await;
    })
    .await
    .unwrap();
}
