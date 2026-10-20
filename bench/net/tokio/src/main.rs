//! Tokio's TCP sockets timed as bench/net/net.rig times Rig's std.net:
//! pingpong, echo, connect. Prints `NAME NS CHECK` per benchmark.

use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const PING: usize = 20_000;
const ECHO_CONNS: usize = 100;
const ECHO_TRIPS: usize = 1000;
const CONNECTS: usize = 500;
const SIZE: usize = 64;

async fn echo(mut c: TcpStream) -> i64 {
    let mut buf = vec![0u8; 4096];
    let mut total = 0i64;
    loop {
        let n = match c.read(&mut buf).await {
            Ok(0) | Err(_) => return total,
            Ok(n) => n,
        };
        total += n as i64;
        if c.write_all(&buf[..n]).await.is_err() {
            return total;
        }
    }
}

fn serve(l: TcpListener, conns: usize) -> tokio::task::JoinHandle<i64> {
    tokio::spawn(async move {
        let mut hs = Vec::with_capacity(conns);
        for _ in 0..conns {
            let (c, _) = l.accept().await.unwrap();
            hs.push(tokio::spawn(echo(c)));
        }
        let mut sum = 0;
        for h in hs {
            sum += h.await.unwrap();
        }
        sum
    })
}

async fn client(addr: std::net::SocketAddr, msg: &[u8], trips: usize) -> i64 {
    let mut c = TcpStream::connect(addr).await.unwrap();
    let mut got = vec![0u8; SIZE];
    let mut back = 0i64;
    for _ in 0..trips {
        c.write_all(msg).await.unwrap();
        c.read_exact(&mut got).await.unwrap();
        back += SIZE as i64;
    }
    back
}

async fn listen() -> (TcpListener, std::net::SocketAddr) {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let a = l.local_addr().unwrap();
    (l, a)
}

// The benchmarks run in a task, as bench/tasks/tokio does.
#[tokio::main(flavor = "multi_thread")]
async fn main() {
    tokio::spawn(async {
        let msg = vec![b'x'; SIZE];
        {
            let (l, addr) = listen().await;
            let s = serve(l, 1);
            let t = Instant::now();
            let back = client(addr, &msg, PING).await;
            let ns = t.elapsed().as_nanos();
            println!("pingpong {} {}", ns, back + s.await.unwrap());
        }
        {
            let (l, addr) = listen().await;
            let s = serve(l, ECHO_CONNS);
            let t = Instant::now();
            let mut hs = Vec::with_capacity(ECHO_CONNS);
            for _ in 0..ECHO_CONNS {
                let m = msg.clone();
                hs.push(tokio::spawn(async move { client(addr, &m, ECHO_TRIPS).await }));
            }
            let mut back = 0;
            for h in hs {
                back += h.await.unwrap();
            }
            let ns = t.elapsed().as_nanos();
            println!("echo {} {}", ns, back + s.await.unwrap());
        }
        {
            let (l, addr) = listen().await;
            let s = serve(l, CONNECTS);
            let t = Instant::now();
            let mut back = 0;
            for _ in 0..CONNECTS {
                back += client(addr, &msg, 1).await;
            }
            let ns = t.elapsed().as_nanos();
            println!("connect {} {}", ns, back + s.await.unwrap());
        }
    })
    .await
    .unwrap();
}
