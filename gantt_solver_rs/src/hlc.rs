use chrono::{DateTime, TimeZone, Utc};
use std::cmp::Ordering;
use std::fmt;
use std::str::FromStr;

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Hlc {
    pub millis: i64,
    pub counter: u16,
    pub node_id: String,
}

impl Hlc {
    pub fn new(millis: i64, counter: u16, node_id: String) -> Self {
        Self {
            millis,
            counter,
            node_id,
        }
    }

    pub fn zero() -> Self {
        Self {
            millis: 0,
            counter: 0,
            node_id: "node".to_string(),
        }
    }

    pub fn from_date(date: DateTime<Utc>, node_id: String) -> Self {
        Self {
            millis: date.timestamp_millis(),
            counter: 0,
            node_id,
        }
    }

    pub fn transmit(&self, wall_time_millis: i64) -> Self {
        let new_millis = std::cmp::max(self.millis, wall_time_millis);
        let new_counter = if new_millis == self.millis {
            self.counter + 1
        } else {
            0
        };
        Self {
            millis: new_millis,
            counter: new_counter,
            node_id: self.node_id.clone(),
        }
    }

    pub fn receive(&self, remote: &Hlc, wall_time_millis: i64) -> Self {
        let new_millis = std::cmp::max(std::cmp::max(self.millis, remote.millis), wall_time_millis);
        let new_counter = if new_millis == self.millis && new_millis == remote.millis {
            std::cmp::max(self.counter, remote.counter) + 1
        } else if new_millis == self.millis {
            self.counter + 1
        } else if new_millis == remote.millis {
            remote.counter + 1
        } else {
            0
        };
        Self {
            millis: new_millis,
            counter: new_counter,
            node_id: self.node_id.clone(),
        }
    }
}

impl Ord for Hlc {
    fn cmp(&self, other: &Self) -> Ordering {
        match self.millis.cmp(&other.millis) {
            Ordering::Equal => match self.counter.cmp(&other.counter) {
                Ordering::Equal => self.node_id.cmp(&other.node_id),
                other => other,
            },
            other => other,
        }
    }
}

impl PartialOrd for Hlc {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl fmt::Display for Hlc {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let dt = Utc
            .timestamp_millis_opt(self.millis)
            .single()
            .unwrap_or(Utc::now());
        write!(
            f,
            "{}-{:04X}-{}",
            dt.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            self.counter,
            self.node_id
        )
    }
}

#[derive(Debug)]
pub struct ParseHlcError(String);

impl fmt::Display for ParseHlcError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ParseHlcError: {}", self.0)
    }
}

impl std::error::Error for ParseHlcError {}

impl FromStr for Hlc {
    type Err = ParseHlcError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        // Regex replacement with manual split parsing to avoid regex dependency if possible,
        // but given the complexity (standard vs legacy vs no-node), manual splitting is tricky but efficient.
        // Format: ISO-Counter(hex)-NodeId

        // Find last hyphen for NodeId
        let last_hyphen = s.rfind('-');
        if let Some(last_idx) = last_hyphen {
            let (rest, node_auth) = s.split_at(last_idx);
            let node_id = &node_auth[1..]; // skip hyphen

            // Find second to last hyphen for Counter
            if let Some(second_last_idx) = rest.rfind('-') {
                let (iso_part, counter_part) = rest.split_at(second_last_idx);
                let counter_hex = &counter_part[1..];

                if let Ok(counter) = u16::from_str_radix(counter_hex, 16) {
                    // Parse ISO
                    // ensure 'Z' if missing (naive check)
                    let iso_str = if iso_part.ends_with('Z') {
                        iso_part.to_string()
                    } else {
                        format!("{}Z", iso_part)
                    };
                    if let Ok(dt) = DateTime::parse_from_rfc3339(&iso_str) {
                        return Ok(Hlc {
                            millis: dt.timestamp_millis(),
                            counter,
                            node_id: node_id.to_string(),
                        });
                    }
                }
            }
        }

        // Fallback or more robust parsing could be added here similar to dart
        // For now, assume the standard format is prioritized as this is for the solver internal use mostly or strict logs.
        Err(ParseHlcError(format!("Invalid HLC format: {}", s)))
    }
}
