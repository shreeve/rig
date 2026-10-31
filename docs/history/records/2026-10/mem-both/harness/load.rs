// A RESP load generator: C connections, each a thread, sending batches of
// P commands (half SET, half GET over K keys, V-byte values) and waiting
// for all P replies; for S seconds. Prints req/s and batch latency p50/p99.
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
use std::time::{Duration, Instant};

fn cmd(out: &mut Vec<u8>, set: bool, key: &str, val: &[u8]) {
    if set {
        out.extend_from_slice(format!("*3\r\n$3\r\nSET\r\n${}\r\n{}\r\n${}\r\n", key.len(), key, val.len()).as_bytes());
        out.extend_from_slice(val);
        out.extend_from_slice(b"\r\n");
    } else {
        out.extend_from_slice(format!("*2\r\n$3\r\nGET\r\n${}\r\n{}\r\n", key.len(), key).as_bytes());
    }
}

// Count complete replies in buf[..n] from `pos`; return (replies, new pos).
fn replies(buf: &[u8], mut pos: usize) -> (usize, usize) {
    let mut got = 0;
    loop {
        if pos >= buf.len() { return (got, pos); }
        let e = match buf[pos..].windows(2).position(|w| w == b"\r\n") { Some(e) => e, None => return (got, pos) };
        match buf[pos] {
            b'+' | b'-' | b':' => { pos += e + 2; got += 1; }
            b'$' => {
                let n: i64 = std::str::from_utf8(&buf[pos + 1..pos + e]).unwrap().parse().unwrap();
                if n < 0 { pos += e + 2; got += 1; continue; }
                let end = pos + e + 2 + n as usize + 2;
                if end > buf.len() { return (got, pos); }
                pos = end; got += 1;
            }
            c => panic!("bad reply byte {}", c),
        }
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let addr = a[1].clone();
    let conns: usize = a[2].parse().unwrap();
    let pipe: usize = a[3].parse().unwrap();
    let secs: f64 = a[4].parse().unwrap();
    let keys: usize = a.get(5).map(|s| s.parse().unwrap()).unwrap_or(10000);
    let vlen: usize = a.get(6).map(|s| s.parse().unwrap()).unwrap_or(32);
    let stop = Arc::new(AtomicBool::new(false));
    let val = vec![b'x'; vlen];
    let mut hs = vec![];
    let start = Instant::now();
    for t in 0..conns {
        let (addr, stop, val) = (addr.clone(), stop.clone(), val.clone());
        hs.push(std::thread::spawn(move || {
            let mut s = TcpStream::connect(&addr).unwrap();
            s.set_nodelay(true).unwrap();
            let mut lat: Vec<u32> = Vec::with_capacity(1 << 20);
            let mut out = Vec::new();
            let mut buf = vec![0u8; 1 << 16];
            let mut i = t * 7919;
            let mut done = 0usize;
            while !stop.load(Ordering::Relaxed) {
                out.clear();
                for j in 0..pipe {
                    let key = format!("key:{:06}", (i + j / 2) % keys);
                    cmd(&mut out, j % 2 == 0, &key, &val);
                }
                i += pipe;
                let t0 = Instant::now();
                s.write_all(&out).unwrap();
                let (mut fill, mut pos, mut got) = (0usize, 0usize, 0usize);
                while got < pipe {
                    let n = s.read(&mut buf[fill..]).unwrap();
                    assert!(n > 0, "server closed");
                    fill += n;
                    let (g, p) = replies(&buf[..fill], pos);
                    got += g; pos = p;
                }
                lat.push(t0.elapsed().as_nanos() as u32);
                done += pipe;
            }
            (done, lat)
        }));
    }
    std::thread::sleep(Duration::from_secs_f64(secs));
    stop.store(true, Ordering::Relaxed);
    let mut total = 0;
    let mut lat = vec![];
    for h in hs { let (d, l) = h.join().unwrap(); total += d; lat.extend(l); }
    let el = start.elapsed().as_secs_f64();
    lat.sort_unstable();
    let p = |q: f64| lat[((lat.len() as f64 - 1.0) * q) as usize] as f64 / 1000.0;
    println!("conns={} pipe={} req/s={:.0} p50={:.1}us p99={:.1}us batches={}", conns, pipe, total as f64 / el, p(0.50), p(0.99), lat.len());
}
