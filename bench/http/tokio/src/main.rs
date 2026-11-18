//! A Tokio and hyper server for bench/http/bench-http: `Hello, world!`
//! at `/`, 404 elsewhere. It prints the port it listens on, then serves
//! until it is killed.

use http_body_util::Full;
use hyper::body::Bytes;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use std::convert::Infallible;
use tokio::net::TcpListener;

async fn hello(req: Request<hyper::body::Incoming>) -> Result<Response<Full<Bytes>>, Infallible> {
    if req.uri().path() == "/" {
        Ok(Response::builder()
            .header("content-type", "text/plain; charset=utf-8")
            .body(Full::new(Bytes::from_static(b"Hello, world!")))
            .unwrap())
    } else {
        Ok(Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Full::new(Bytes::from_static(b"not found\n")))
            .unwrap())
    }
}

// `HYPER_WORKERS=N` sets the runtime's worker count (default: Tokio's,
// one per core it may run on), and `HYPER_NODELAY=1` sets TCP_NODELAY on
// each connection, as Rig's server does: probes of what holds hyper's
// throughput, never set by bench-http itself.
fn main() {
    let mut rt = tokio::runtime::Builder::new_multi_thread();
    if let Some(n) = std::env::var("HYPER_WORKERS").ok().and_then(|v| v.parse().ok()) {
        rt.worker_threads(n);
    }
    rt.enable_all().build().unwrap().block_on(serve());
}

async fn serve() {
    let nodelay = std::env::var("HYPER_NODELAY").map(|v| v == "1").unwrap_or(false);
    let addr = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:0".to_string());
    let l = TcpListener::bind(&addr).await.unwrap();
    println!("{}", l.local_addr().unwrap().port());
    loop {
        let (c, _) = l.accept().await.unwrap();
        if nodelay {
            let _ = c.set_nodelay(true);
        }
        tokio::spawn(async move {
            let _ = http1::Builder::new().serve_connection(TokioIo::new(c), service_fn(hello)).await;
        });
    }
}
