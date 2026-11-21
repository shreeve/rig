// Jiff 1.0.0's answers for std.datetime, one line out for each line in.
// The line format is in README.md; gen.py writes the inputs.
//
// A value Jiff refuses prints `error`. A case where Rig differs from Jiff
// on purpose (DATETIME-DESIGN §6.8, §9) prints `skip`. A line the oracle
// cannot read is a generator's mistake, not an answer: it stops the run
// with exit status 2, naming the line.

use std::collections::HashMap;
use std::fmt::Display;
use std::io::{BufRead, BufWriter, Write};

use jiff::civil::{Date, DateTime, Time, Weekday};
use jiff::fmt::temporal::DateTimeParser;
use jiff::tz::{Disambiguation, OffsetConflict, TimeZone};
use jiff::{
    RoundMode, SignedDuration, Span, Timestamp, Unit, ZonedDateTime,
};

type Res<T> = Result<T, String>;

struct Oracle {
    zones: HashMap<String, TimeZone>,
}

fn main() {
    let mut args = std::env::args().skip(1);
    if let Some(a) = args.next() {
        match a.as_str() {
            "--version" => {
                // The database Jiff uses and the bundle it came from.
                println!(
                    "jiff 1.0.0, {:?}, jiff-tzdb {}",
                    jiff::tz::db(),
                    jiff_tzdb::VERSION
                );
                return;
            }
            _ => {
                eprintln!("usage: jiff-oracle [--version] < cases > answers");
                std::process::exit(2);
            }
        }
    }
    let stdin = std::io::stdin().lock();
    let stdout = std::io::stdout().lock();
    let mut out = BufWriter::with_capacity(1 << 20, stdout);
    let mut o = Oracle { zones: HashMap::new() };
    let mut n = 0usize;
    for line in stdin.lines() {
        n += 1;
        let line = line.unwrap_or_else(|e| die(n, &format!("unreadable: {e}")));
        match o.case(&line) {
            Ok(answer) => {
                out.write_all(answer.as_bytes()).unwrap();
                out.write_all(b"\n").unwrap();
            }
            Err(msg) => {
                out.flush().unwrap();
                die(n, &format!("{msg}: {line}"));
            }
        }
    }
    out.flush().unwrap();
}

fn die(n: usize, msg: &str) -> ! {
    eprintln!("jiff-oracle: line {n}: {msg}");
    std::process::exit(2);
}

// A result as the line format prints it: the value, or `error`.
fn show<T: Display, E>(r: Result<T, E>) -> String {
    match r {
        Ok(v) => v.to_string(),
        Err(_) => "error".to_string(),
    }
}

fn weekday(w: Weekday) -> &'static str {
    match w {
        Weekday::Monday => "Monday",
        Weekday::Tuesday => "Tuesday",
        Weekday::Wednesday => "Wednesday",
        Weekday::Thursday => "Thursday",
        Weekday::Friday => "Friday",
        Weekday::Saturday => "Saturday",
        Weekday::Sunday => "Sunday",
    }
}

fn args<'a>(rest: &'a str, n: usize) -> Res<Vec<&'a str>> {
    let v: Vec<&str> = rest.split(' ').collect();
    if v.len() != n || v.iter().any(|a| a.is_empty()) {
        return Err(format!("expected {n} arguments"));
    }
    Ok(v)
}

fn date(s: &str) -> Res<Date> {
    s.parse().map_err(|e| format!("bad date {s:?}: {e}"))
}
fn time(s: &str) -> Res<Time> {
    s.parse().map_err(|e| format!("bad time {s:?}: {e}"))
}
fn datetime(s: &str) -> Res<DateTime> {
    s.parse().map_err(|e| format!("bad datetime {s:?}: {e}"))
}
fn instant(s: &str) -> Res<Timestamp> {
    if !s.ends_with('Z') {
        return Err(format!("an instant ends in Z: {s:?}"));
    }
    s.parse().map_err(|e| format!("bad instant {s:?}: {e}"))
}
fn duration(s: &str) -> Res<SignedDuration> {
    s.parse().map_err(|e| format!("bad duration {s:?}: {e}"))
}
fn int(s: &str) -> Res<i64> {
    s.parse().map_err(|e| format!("bad integer {s:?}: {e}"))
}

fn unit(s: &str) -> Res<Unit> {
    Ok(match s {
        "ns" => Unit::Nanosecond,
        "us" => Unit::Microsecond,
        "ms" => Unit::Millisecond,
        "seconds" => Unit::Second,
        "minutes" => Unit::Minute,
        "hours" => Unit::Hour,
        "days" => Unit::Day,
        _ => return Err(format!("bad unit {s:?}")),
    })
}

// The calendar amounts and a duration, as one Span. Jiff's span has one
// sign, so amounts of both signs are a generator's mistake (Rig applies
// each group with its own sign, §6.2, which Jiff cannot answer).
fn span(y: &str, m: &str, w: &str, d: &str, dur: Option<SignedDuration>) -> Res<Result<Span, ()>> {
    let (y, m, w, d) = (int(y)?, int(m)?, int(w)?, int(d)?);
    let mut signs = vec![y.signum(), m.signum(), w.signum(), d.signum()];
    if let Some(t) = dur {
        signs.push(t.signum() as i64);
    }
    if signs.contains(&1) && signs.contains(&-1) {
        return Err("amounts of both signs".into());
    }
    let mk = || -> Result<Span, jiff::Error> {
        let s = match dur {
            Some(t) => Span::try_from(t)?,
            None => Span::new(),
        };
        s.try_years(y)?.try_months(m)?.try_weeks(w)?.try_days(d)
    };
    Ok(mk().map_err(|_| ()))
}

// The time part of a span, as a duration.
fn rest(s: Span) -> SignedDuration {
    SignedDuration::try_from(s.years(0).months(0).weeks(0).days(0))
        .expect("a span below a day is a duration")
}

impl Oracle {
    fn zone(&mut self, name: &str) -> Res<TimeZone> {
        if let Some(tz) = self.zones.get(name) {
            return Ok(tz.clone());
        }
        let tz = if name.starts_with('+') || name.starts_with('-') {
            DateTimeParser::new()
                .parse_time_zone(name)
                .map_err(|e| format!("bad offset {name:?}: {e}"))?
        } else {
            TimeZone::get(name).map_err(|e| format!("no zone {name:?}: {e}"))?
        };
        self.zones.insert(name.to_string(), tz.clone());
        Ok(tz)
    }

    fn zoned(&mut self, zone: &str, at: &str) -> Res<ZonedDateTime> {
        Ok(instant(at)?.to_zoned_datetime(self.zone(zone)?))
    }

    fn case(&mut self, line: &str) -> Res<String> {
        let (op, rest) = line.split_once(' ').unwrap_or((line, ""));
        match op {
            // 1. Calendar arithmetic (§6.2, §6.3) and a date's readers.
            "date.add" => {
                let a = args(rest, 5)?;
                let d = date(a[0])?;
                Ok(match span(a[1], a[2], a[3], a[4], None)? {
                    Ok(s) => show(d.checked_add(s)),
                    Err(()) => "error".into(),
                })
            }
            "date.info" => {
                let d = date(args(rest, 1)?[0])?;
                let w = d.iso_week_date();
                Ok(format!(
                    "{} {} {} {} {} {} {}",
                    weekday(d.weekday()),
                    d.day_of_year(),
                    d.days_in_month(),
                    w.week(),
                    w.year(),
                    d.first_of_month(),
                    d.last_of_month()
                ))
            }
            "datetime.add" => {
                let a = args(rest, 6)?;
                let dt = datetime(a[0])?;
                let t = duration(a[5])?;
                Ok(match span(a[1], a[2], a[3], a[4], Some(t))? {
                    Ok(s) => show(dt.checked_add(s)),
                    Err(()) => "error".into(),
                })
            }
            "zoned.add" => {
                let a = args(rest, 7)?;
                let z = self.zoned(a[0], a[1])?;
                let t = duration(a[6])?;
                Ok(match span(a[2], a[3], a[4], a[5], Some(t))? {
                    Ok(s) => show(z.checked_add(s)),
                    Err(()) => "error".into(),
                })
            }
            "time.add" => {
                let a = args(rest, 2)?;
                let t = time(a[0])?;
                let d = duration(a[1])?;
                Ok(format!("{} {}", t.wrapping_add(d), show(t.checked_add(d))))
            }
            "instant.add" => {
                let a = args(rest, 2)?;
                let i = instant(a[0])?;
                Ok(show(i.checked_add(duration(a[1])?)))
            }

            // 2. Zones (§6.5, §6.7, §7.4).
            "instant.in_zone" => {
                let a = args(rest, 2)?;
                let i = instant(a[0])?;
                let tz = self.zone(a[1])?;
                let info = tz.to_offset_info(i);
                let z = i.to_zoned_datetime(tz.clone());
                Ok(format!("{} {} {}", z, info.offset(), info.abbreviation()))
            }
            "datetime.in_zone" => {
                let a = args(rest, 2)?;
                let dt = datetime(a[0])?;
                let tz = self.zone(a[1])?;
                let amb = tz.to_ambiguous_zoned_datetime(dt);
                let r: Vec<String> = [
                    Disambiguation::Compatible,
                    Disambiguation::Earlier,
                    Disambiguation::Later,
                    Disambiguation::Reject,
                ]
                .into_iter()
                .map(|d| show(amb.clone().disambiguate(d)))
                .collect();
                Ok(r.join(" "))
            }
            "date.in_zone" => {
                let a = args(rest, 2)?;
                let d = date(a[0])?;
                Ok(show(d.to_zoned_datetime(self.zone(a[1])?)))
            }
            "zoned.start_of_day" => {
                let a = args(rest, 2)?;
                Ok(show(self.zoned(a[0], a[1])?.start_of_day()))
            }
            "zone.name" => {
                let tz = self.zone(args(rest, 1)?[0])?;
                Ok(match tz.iana_name() {
                    Some(n) => n.to_string(),
                    None => "none".into(),
                })
            }
            "zone.eq" => {
                let a = args(rest, 2)?;
                Ok((self.zone(a[0])? == self.zone(a[1])?).to_string())
            }
            "zone.transitions" => {
                // Every transition before an instant, after the offset in
                // force before the first: OFFSET/ABBR, then UNIX/OFFSET/ABBR
                // for each. For checking the bundle (README).
                let a = args(rest, 2)?;
                let tz = self.zone(a[0])?;
                let end = instant(a[1])?;
                let first = tz.to_offset_info(Timestamp::MIN);
                let mut s = format!(
                    "{}/{}",
                    first.offset().seconds(),
                    first.abbreviation()
                );
                for t in tz.following(Timestamp::MIN) {
                    if t.timestamp() >= end {
                        break;
                    }
                    s.push_str(&format!(
                        " {}/{}/{}",
                        t.timestamp().as_second(),
                        t.offset().seconds(),
                        t.abbreviation()
                    ));
                }
                Ok(s)
            }

            // 3. Counts (§6.4): a since b, for days, weeks, months, years;
            // then the years, months, days and the rest from the earlier.
            "date.count" => {
                let a = args(rest, 2)?;
                let (x, y) = (date(a[0])?, date(a[1])?);
                let (e, l, sign) = if x < y { (x, y, -1) } else { (y, x, 1) };
                let c = |u: Unit| e.until((u, l)).expect("a count of dates");
                let ymd = c(Unit::Year);
                Ok(format!(
                    "{} {} {} {} {} {} {}",
                    sign * c(Unit::Day).get_days() as i64,
                    sign * c(Unit::Week).get_weeks() as i64,
                    sign * c(Unit::Month).get_months() as i64,
                    sign * c(Unit::Year).get_years() as i64,
                    ymd.get_years(),
                    ymd.get_months(),
                    ymd.get_days()
                ))
            }
            "datetime.count" => {
                let a = args(rest, 2)?;
                let (x, y) = (datetime(a[0])?, datetime(a[1])?);
                let (e, l, sign) = if x < y { (x, y, -1) } else { (y, x, 1) };
                let c = |u: Unit| e.until((u, l)).expect("a count of datetimes");
                Ok(counts(sign, c(Unit::Day), c(Unit::Week), c(Unit::Month), c(Unit::Year)))
            }
            "zoned.count" => {
                // One zone: across two, Rig uses the earlier value's
                // calendar where Jiff refuses (§6.4, §9).
                let a = args(rest, 3)?;
                let x = self.zoned(a[0], a[1])?;
                let y = self.zoned(a[0], a[2])?;
                let (e, l, sign) = if x < y { (&x, &y, -1) } else { (&y, &x, 1) };
                let c = |u: Unit| e.until((u, l)).expect("a count in one zone");
                Ok(counts(sign, c(Unit::Day), c(Unit::Week), c(Unit::Month), c(Unit::Year)))
            }

            // 4. Text (§5.5, §8.1, §8.3).
            "date.parse" => Ok(show(rest.parse::<Date>())),
            "time.parse" => Ok(show(rest.parse::<Time>())),
            "datetime.parse" => Ok(show(rest.parse::<DateTime>())),
            "instant.parse" => Ok(show(rest.parse::<Timestamp>())),
            "duration.parse" => Ok(show(rest.parse::<SignedDuration>())),
            "zoned.parse" => {
                let r: Vec<String> = [
                    OffsetConflict::Reject,
                    OffsetConflict::AlwaysOffset,
                    OffsetConflict::AlwaysTimeZone,
                ]
                .into_iter()
                .map(|c| {
                    show(
                        DateTimeParser::new()
                            .offset_conflict(c)
                            .parse_zoned_datetime(rest),
                    )
                })
                .collect();
                Ok(r.join(" "))
            }

            // 5. Rounding (§6.8): the round, then the floor.
            "time.round" => {
                let a = args(rest, 3)?;
                let t = time(a[0])?;
                let (u, i) = (unit(a[1])?, int(a[2])?);
                let r = |m| show(t.round(jiff::civil::TimeRound::new().smallest(u).increment(i).mode(m)));
                Ok(format!("{} {}", r(RoundMode::HalfExpand), r(RoundMode::Floor)))
            }
            "datetime.round" => {
                let a = args(rest, 3)?;
                let dt = datetime(a[0])?;
                let (u, i) = (unit(a[1])?, int(a[2])?);
                let r = |m| show(dt.round(jiff::civil::DateTimeRound::new().smallest(u).increment(i).mode(m)));
                // Jiff 1.0.0 does not carry a round past midnight into the
                // next day in years at or below 0 (§6.8, §9 item 14).
                let round = if dt.year() <= 0 { "skip".into() } else { r(RoundMode::HalfExpand) };
                Ok(format!("{} {}", round, r(RoundMode::Floor)))
            }
            "instant.round" => {
                let a = args(rest, 3)?;
                let t = instant(a[0])?;
                let (u, i) = (unit(a[1])?, int(a[2])?);
                let r = |m| t.round(jiff::TimestampRound::new().smallest(u).increment(i).mode(m));
                let floor = r(RoundMode::Floor);
                // Jiff takes a half away from 1970; Rig takes it to the
                // later value before 1970 too (§6.8, §9 item 12).
                let half = match &floor {
                    Ok(f) => t < Timestamp::UNIX_EPOCH && is_half(t.duration_since(*f), u, i),
                    Err(_) => false,
                };
                let round = if half { "skip".into() } else { show(r(RoundMode::HalfExpand)) };
                Ok(format!("{} {}", round, show(floor)))
            }
            "zoned.round" => {
                let a = args(rest, 4)?;
                let z = self.zoned(a[0], a[1])?;
                let (u, i) = (unit(a[2])?, int(a[3])?);
                let r = |m| show(z.round(jiff::ZonedDateTimeRound::new().smallest(u).increment(i).mode(m)));
                let round = if z.year() <= 0 || (u == Unit::Day && !day_round_agrees(&z)) {
                    "skip".into()
                } else {
                    r(RoundMode::HalfExpand)
                };
                Ok(format!("{} {}", round, r(RoundMode::Floor)))
            }
            "duration.round" => {
                let a = args(rest, 3)?;
                let d = duration(a[0])?;
                let (u, i) = (unit(a[1])?, int(a[2])?);
                let r = |m| show(d.round(jiff::SignedDurationRound::new().smallest(u).increment(i).mode(m)));
                Ok(format!("{} {}", r(RoundMode::HalfExpand), r(RoundMode::Floor)))
            }

            _ => Err(format!("unknown case {op:?}")),
        }
    }
}

fn counts(sign: i64, d: Span, w: Span, m: Span, y: Span) -> String {
    // The rest after the whole days, and after the years, months and days:
    // §6.4 says they are one; were they not, both print, joined by `/`.
    let (rd, ry) = (rest(d), rest(y));
    let r = if rd == ry { rd.to_string() } else { format!("{rd}/{ry}") };
    format!(
        "{} {} {} {} {} {} {} {}",
        sign * d.get_days() as i64,
        sign * w.get_weeks() as i64,
        sign * m.get_months() as i64,
        sign * y.get_years() as i64,
        y.get_years(),
        y.get_months(),
        y.get_days(),
        r
    )
}

// Whether `past`, the time since the floor, is exactly half the increment.
fn is_half(past: SignedDuration, u: Unit, i: i64) -> bool {
    let per: i128 = match u {
        Unit::Nanosecond => 1,
        Unit::Microsecond => 1_000,
        Unit::Millisecond => 1_000_000,
        Unit::Second => 1_000_000_000,
        Unit::Minute => 60_000_000_000,
        Unit::Hour => 3_600_000_000_000,
        _ => return false,
    };
    past.as_nanos() * 2 == per * i as i128
}

// Whether Jiff's `round(days: 1)` measures what Rig's does (§6.8): the value
// lies in its own date's range, and the start of that date plus one day on
// the clock is the start of the next date.
fn day_round_agrees(z: &ZonedDateTime) -> bool {
    let tz = z.time_zone().clone();
    let d = z.date();
    let Ok(next) = d.tomorrow() else { return false };
    let (Ok(start), Ok(end)) = (d.to_zoned_datetime(tz.clone()), next.to_zoned_datetime(tz)) else {
        return false;
    };
    if !(&start <= z && z < &end) {
        return false;
    }
    match start.checked_add(Span::new().days(1)) {
        Ok(s) => s.timestamp() == end.timestamp(),
        Err(_) => false,
    }
}
