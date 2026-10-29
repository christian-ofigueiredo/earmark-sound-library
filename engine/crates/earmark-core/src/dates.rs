//! Dates as GRDB stores them: text "yyyy-MM-dd HH:mm:ss.SSS" in UTC, rounded to the nearest
//! millisecond as Foundation's DateFormatter does (checked against it on 40,000 times,
//! 2026-10-29).

use std::time::{SystemTime, UNIX_EPOCH};

/// Seconds between 1970 and 2001, where Foundation's dates count from.
const REFERENCE_DATE: f64 = 978_307_200.0;

/// `Date(timeIntervalSince1970: seconds)` as GRDB writes it.
pub fn format(seconds_since_1970: f64) -> String {
    // The same arithmetic as Foundation: a date keeps seconds since 2001, which are turned back
    // into milliseconds since 1970 and rounded, halves up.
    let since_2001 = seconds_since_1970 - REFERENCE_DATE;
    let millis = ((since_2001 + REFERENCE_DATE) * 1000.0 + 0.5).floor() as i64;
    let (days, ms_of_day) = (millis.div_euclid(86_400_000), millis.rem_euclid(86_400_000));
    let (y, m, d) = civil_from_days(days);
    let s = ms_of_day / 1000;
    format!(
        "{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02}.{:03}",
        s / 3600,
        s / 60 % 60,
        s % 60,
        ms_of_day % 1000
    )
}

/// Now, as GRDB writes `Date()`.
pub fn now() -> String {
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    format(t)
}

/// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's algorithm).
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

#[cfg(test)]
mod tests {
    use super::format;

    // The values are written as Foundation was given them, more digits than a double keeps.
    #[test]
    #[allow(clippy::excessive_precision)]
    fn as_grdb_writes_them() {
        assert_eq!(format(0.0), "1970-01-01 00:00:00.000");
        // Foundation's own answers for these.
        assert_eq!(format(1754038260.09766), "2025-08-01 08:51:00.098");
        assert_eq!(format(1754038260.0004999), "2025-08-01 08:51:00.001");
        assert_eq!(format(0.0005), "1970-01-01 00:00:00.000");
        assert_eq!(format(0.0025), "1970-01-01 00:00:00.003");
        assert_eq!(format(1600000000.99949), "2020-09-13 12:26:40.999");
        assert_eq!(format(951782400.5), "2000-02-29 00:00:00.500");
        assert_eq!(format(4102444799.9999), "2100-01-01 00:00:00.000");
    }
}
