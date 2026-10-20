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

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let addr = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:0".to_string());
    let l = TcpListener::bind(&addr).await.unwrap();
    println!("{}", l.local_addr().unwrap().port());
    loop {
        let (c, _) = l.accept().await.unwrap();
        tokio::spawn(async move {
            let _ = http1::Builder::new().serve_connection(TokioIo::new(c), service_fn(hello)).await;
        });
    }
}
