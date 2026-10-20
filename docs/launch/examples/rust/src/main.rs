//! The same server in Rust, with Tokio and hyper: a hit counter every
//! request shares, rooms people join, and one route that panics. Run it
//! with `cargo run --release`, then `curl localhost:8080/hit`,
//! `/join?room=rig`, `/boom`.

use http_body_util::Full;
use hyper::body::Bytes;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use std::collections::HashMap;
use std::convert::Infallible;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::net::TcpListener;

struct State {
    hits: AtomicI64,
    rooms: Mutex<HashMap<String, i64>>,
}

fn pick(xs: &[i64], i: usize) -> i64 {
    xs[i]
}

fn route(state: &State, path: &str, query: Option<&str>) -> (StatusCode, String) {
    match path {
        "/hit" => (StatusCode::OK, format!("hits {}", state.hits.fetch_add(1, Ordering::SeqCst) + 1)),
        "/join" => {
            let room = query
                .and_then(|q| q.split('&').find_map(|kv| kv.strip_prefix("room=")))
                .unwrap_or("lobby")
                .to_string();
            let mut rooms = state.rooms.lock().unwrap();
            let n = rooms.entry(room).or_insert(0);
            *n += 1;
            (StatusCode::OK, format!("members {}", n))
        }
        "/boom" => (StatusCode::OK, format!("{}", pick(&[1, 2, 3], 7))),
        _ => (StatusCode::NOT_FOUND, "not found\n".to_string()),
    }
}

async fn handle(state: Arc<State>, req: Request<hyper::body::Incoming>) -> Result<Response<Full<Bytes>>, Infallible> {
    // A panic in a handler would end the connection's task with no
    // answer, so a 500 takes catching it here.
    let (status, body) = catch_unwind(AssertUnwindSafe(|| route(&state, req.uri().path(), req.uri().query())))
        .unwrap_or((StatusCode::INTERNAL_SERVER_ERROR, "internal error\n".to_string()));
    Ok(Response::builder().status(status).body(Full::new(Bytes::from(body))).unwrap())
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let addr = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:8080".to_string());
    let state = Arc::new(State { hits: AtomicI64::new(0), rooms: Mutex::new(HashMap::new()) });
    let l = TcpListener::bind(&addr).await.unwrap();
    loop {
        let (c, _) = l.accept().await.unwrap();
        let state = state.clone();
        tokio::spawn(async move {
            let service = service_fn(move |req| handle(state.clone(), req));
            let _ = http1::Builder::new().serve_connection(TokioIo::new(c), service).await;
        });
    }
}
