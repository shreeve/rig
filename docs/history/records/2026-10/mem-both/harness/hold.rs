// Open N connections, one SET and one GET on each, then hold them open
// for SECS seconds (prints "held N" once all are open).
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let n: usize = a[2].parse().unwrap();
    let secs: f64 = a[3].parse().unwrap();
    let mut v = vec![];
    let mut buf = [0u8; 256];
    for i in 0..n {
        let mut s = TcpStream::connect(&a[1]).unwrap();
        s.set_nodelay(true).unwrap();
        let k = format!("key:{:06}", i);
        let m = format!("*3\r\n$3\r\nSET\r\n${}\r\n{}\r\n$32\r\n{}\r\n*2\r\n$3\r\nGET\r\n${}\r\n{}\r\n", k.len(), k, "x".repeat(32), k.len(), k);
        s.write_all(m.as_bytes()).unwrap();
        let mut got = 0; while got < 5 + 4 + 34 { let r = s.read(&mut buf[got..]).unwrap(); assert!(r > 0); got += r; }
        v.push(s);
    }
    println!("held {}", n);
    std::thread::sleep(Duration::from_secs_f64(secs));
}
