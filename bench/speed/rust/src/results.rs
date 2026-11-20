//! `bench/.out/<source>/speed-rust.json`: the shape the TypeScript step
//! writes (`SpeedOut` in bench/size/src/results.ts), so `bench report` puts
//! both languages side by side. The numbers come from criterion's samples
//! (`<criterion dir>/<source>/<task>/new/`).

use crate::machine::Machine;
use crate::{Error, fail};
use serde_json::{Value as Json, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// What a task measures, as the TypeScript step names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Group {
    Parse,
    Typed,
    Write,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Input {
    /// The whole corpus as one text: a JSON array, a haus stream.
    Corpus,
    /// Every document on its own (the time is for all of them).
    PerDoc,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Json,
    Haus,
}

impl Group {
    fn name(self) -> &'static str {
        match self {
            Group::Parse => "parse",
            Group::Typed => "typed",
            Group::Write => "write",
        }
    }
}

impl Input {
    fn name(self) -> &'static str {
        match self {
            Input::Corpus => "corpus",
            Input::PerDoc => "per doc",
        }
    }
}

impl Format {
    fn name(self) -> &'static str {
        match self {
            Format::Json => "json",
            Format::Haus => "haus",
        }
    }
}

/// One task's results.
#[derive(Debug, Clone)]
pub struct Row {
    pub group: Group,
    pub input: Input,
    pub format: Format,
    pub implementation: String,
    /// Bytes read (parse, typed) or written (write) per iteration.
    pub bytes: u64,
    pub docs: u64,
    pub samples: Samples,
}

/// Criterion's samples of one task: `times[i]` nanoseconds for `iters[i]`
/// iterations, and its estimate of the time per iteration.
#[derive(Debug, Clone)]
pub struct Samples {
    pub iters: Vec<f64>,
    pub times: Vec<f64>,
    /// Criterion's point estimate (the slope for linear sampling, else the mean), in ns.
    pub estimate_ns: f64,
}

/// The `q` quantile of sorted values, interpolated between the nearest ranks.
fn quantile(sorted: &[f64], q: f64) -> f64 {
    let pos = q * (sorted.len() - 1) as f64;
    let (lo, hi) = (pos.floor() as usize, pos.ceil() as usize);
    sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo as f64)
}

fn load_json(path: &Path) -> Result<Json, Error> {
    let text = fs::read_to_string(path).map_err(|e| Error(format!("{}: {e}", path.display())))?;
    serde_json::from_str(&text).map_err(|e| Error(format!("{}: {e}", path.display())))
}

fn numbers(v: &Json, key: &str, path: &Path) -> Result<Vec<f64>, Error> {
    v[key]
        .as_array()
        .and_then(|xs| xs.iter().map(Json::as_f64).collect())
        .ok_or_else(|| Error(format!("{}: no {key}", path.display())))
}

impl Samples {
    /// Reads what criterion saved for a benchmark (`<dir>/new/sample.json`
    /// and `estimates.json`), if it was written at or after `since`: a
    /// benchmark a filter left out, or `--test`, leaves none, or an old one.
    pub fn read(dir: &Path, since: SystemTime) -> Result<Option<Samples>, Error> {
        let sample = dir.join("new").join("sample.json");
        let estimates = dir.join("new").join("estimates.json");
        let fresh = fs::metadata(&sample).and_then(|m| m.modified()).is_ok_and(|t| t >= since);
        if !fresh {
            return Ok(None);
        }
        let s = load_json(&sample)?;
        let e = load_json(&estimates)?;
        let point = |key: &str| e[key]["point_estimate"].as_f64();
        let Some(estimate_ns) = point("slope").or_else(|| point("mean")) else {
            return fail(format!("{}: no estimate", estimates.display()));
        };
        Ok(Some(Samples { iters: numbers(&s, "iters", &sample)?, times: numbers(&s, "times", &sample)?, estimate_ns }))
    }

    /// Time per iteration of each sample, in ms, sorted.
    fn per_iteration_ms(&self) -> Vec<f64> {
        let mut ms: Vec<f64> = self.times.iter().zip(&self.iters).map(|(t, n)| t / n / 1e6).collect();
        ms.sort_by(f64::total_cmp);
        ms
    }
}

impl Row {
    fn to_json(&self) -> Json {
        let mean_ms = self.samples.estimate_ns / 1e6;
        let per = self.samples.per_iteration_ms();
        json!({
            "group": self.group.name(),
            "input": self.input.name(),
            "format": self.format.name(),
            "impl": self.implementation,
            "bytes": self.bytes,
            "docs": self.docs,
            "hz": 1000.0 / mean_ms,
            "mean_ms": mean_ms,
            "p75_ms": quantile(&per, 0.75),
            "p99_ms": quantile(&per, 0.99),
            "samples": per.len(),
            "mb_s": self.bytes as f64 / 1e6 / (mean_ms / 1000.0),
            "us_per_doc": mean_ms * 1000.0 / self.docs as f64,
        })
    }

    /// One line for the terminal, as the TypeScript step prints it.
    pub fn line(&self) -> String {
        let mean_ms = self.samples.estimate_ns / 1e6;
        let per = self.samples.per_iteration_ms();
        let task = format!("{} | {} | {}", self.group.name(), self.input.name(), self.implementation);
        format!(
            "{task:<56} {:>8.1} MB/s {:>9.2} µs/doc  p99 {:.3} ms  ({} samples)",
            self.bytes as f64 / 1e6 / (mean_ms / 1000.0),
            mean_ms * 1000.0 / self.docs as f64,
            quantile(&per, 0.99),
            per.len()
        )
    }
}

/// Timing options, as recorded.
#[derive(Debug, Clone, Copy)]
pub struct Options {
    pub time_ms: u64,
    pub warmup_ms: u64,
    pub quick: bool,
}

/// One source's results.
#[derive(Debug, Clone)]
pub struct SpeedOut {
    pub harness: String,
    pub machine: Machine,
    pub options: Options,
    pub documents: Vec<String>,
    /// Documents serde_json's `Value` writes back as another document (other than member order).
    pub json_not_stable: u64,
    pub rows: Vec<Row>,
    /// The sizes of every task's output, once: changes when an output changes.
    pub checksum: u64,
}

impl SpeedOut {
    pub fn to_json(&self) -> Json {
        let m = &self.machine;
        json!({
            "lang": "rust",
            "harness": self.harness,
            "machine": { "cpu": m.cpu, "cores": m.cores, "memory_gb": m.memory_gb, "os": m.os, "runtime": m.runtime, "gc": false },
            "options": { "time_ms": self.options.time_ms, "warmup_ms": self.options.warmup_ms, "quick": self.options.quick },
            "documents": self.documents,
            "jsonNotStable": self.json_not_stable,
            "rows": self.rows.iter().map(Row::to_json).collect::<Vec<_>>(),
            "checksum": self.checksum,
        })
    }

    /// Writes `<out>/<source>/speed-rust.json`; returns its path.
    pub fn write(&self, out: &Path, source: &str) -> Result<PathBuf, Error> {
        let path = out.join(source).join("speed-rust.json");
        let text = serde_json::to_string_pretty(&self.to_json()).map_err(|e| Error(e.to_string()))?;
        fs::write(&path, text).map_err(|e| Error(format!("{}: {e}", path.display())))?;
        Ok(path)
    }
}

#[cfg(test)]
mod tests {
    use super::quantile;

    #[test]
    fn quantiles_interpolate() {
        let xs = [1.0, 2.0, 3.0, 4.0, 5.0];
        assert_eq!(quantile(&xs, 0.0), 1.0);
        assert_eq!(quantile(&xs, 0.5), 3.0);
        assert_eq!(quantile(&xs, 0.75), 4.0);
        assert!((quantile(&xs, 0.99) - 4.96).abs() < 1e-9);
        assert_eq!(quantile(&[7.0], 0.99), 7.0);
    }
}
