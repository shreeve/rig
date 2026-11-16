//! A Tokio and hyper server for bench/mixed/bench-mixed: `Hello, world!`
//! at `/`, and at `/hash?seed=N` the FNV-1a hash of 4 KiB of data, 8
//! times over, starting from N, as decimal text; 404 elsewhere. It
//! prints the port it listens on, then serves until it is killed.

use http_body_util::Full;
use hyper::body::Bytes;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use std::convert::Infallible;
use std::sync::Arc;
use tokio::net::TcpListener;

/// 4 KiB of bytes from a xorshift generator, the same in every server.
fn make_data() -> Vec<u8> {
    let mut x: u64 = 0x9E3779B97F4A7C15;
    (0..4096)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

/// FNV-1a, 64 bits, over `data` `rounds` times, starting from `seed`.
fn fnv1a(data: &[u8], seed: u64, rounds: usize) -> u64 {
    let mut h: u64 = 14695981039346656037 ^ seed;
    for _ in 0..rounds {
        for &b in data {
            h ^= b as u64;
            h = h.wrapping_mul(1099511628211);
        }
    }
    h
}

fn text(body: impl Into<Bytes>) -> Response<Full<Bytes>> {
    Response::builder()
        .header("content-type", "text/plain; charset=utf-8")
        .body(Full::new(body.into()))
        .unwrap()
}

async fn handle(data: Arc<Vec<u8>>, req: Request<hyper::body::Incoming>) -> Result<Response<Full<Bytes>>, Infallible> {
    match req.uri().path() {
        "/" => Ok(text(Bytes::from_static(b"Hello, world!"))),
        "/hash" => {
            let seed: i64 = req
                .uri()
                .query()
                .and_then(|q| q.split('&').find_map(|kv| kv.strip_prefix("seed=")))
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            Ok(text(fnv1a(&data, seed as u64, 8).to_string()))
        }
        _ => Ok(Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Full::new(Bytes::from_static(b"not found\n")))
            .unwrap()),
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let addr = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:0".to_string());
    let data = Arc::new(make_data());
    let l = TcpListener::bind(&addr).await.unwrap();
    println!("{}", l.local_addr().unwrap().port());
    loop {
        let (c, _) = l.accept().await.unwrap();
        let data = data.clone();
        tokio::spawn(async move {
            let service = service_fn(move |req| handle(data.clone(), req));
            let _ = http1::Builder::new().serve_connection(TokioIo::new(c), service).await;
        });
    }
}
