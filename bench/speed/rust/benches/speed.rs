//! Speed of the haus Rust binding against serde_json, with criterion, on
//! the corpus `bench convert` exported (`bench/.out/<source>/corpus/`), the
//! same documents the TypeScript step reads. The tasks mirror TypeScript's:
//!
//! ```text
//! parse   serde_json::from_str::<serde_json::Value>   vs  haus::parse (text → Value, no schema)
//! typed   haus::parse + haus_schema::Schema::decode with the document's type (spec §15, at runtime)
//! write   serde_json::to_string(&Value)               vs  haus::to_string_minimised, haus::to_string (compact)
//! ```
//!
//! each on the whole corpus as one text (`all.json`, a JSON array;
//! `all.haus`, a haus stream) and on every document on its own (the time is
//! for all of them). Inputs are the wire forms: minified JSON, minimised haus.
//!
//! ```sh
//! cargo bench                                    # every source in bench/sources.haus
//! HAUS_BENCH_SOURCES=vega-lite,geojson cargo bench
//! HAUS_BENCH_QUICK=1 cargo bench                 # a short budget: checks the harness, not for publishing
//! HAUS_BENCH_OUT=/elsewhere cargo bench          # the results directory convert wrote to (default bench/.out)
//! ```
//!
//! Before timing, every pair is checked once: each haus document parses to
//! a value that writes back to the same text, its pretty form reads as the
//! same value, it decodes with its type, the corpus stream reads as the
//! documents' values and is what `to_string_minimised` writes for them,
//! serde_json reads every JSON document and the corpus array. Every output
//! is passed through `black_box`. Results: `bench/.out/<source>/speed-rust.json`.

use criterion::{Criterion, SamplingMode, Throughput};
use haus::Value;
use haus_bench_speed::corpus::{self, Corpus};
use haus_bench_speed::machine::Machine;
use haus_bench_speed::results::{Format, Group, Input, Options, Row, Samples, SpeedOut};
use haus_bench_speed::{Error, fail};
use haus_schema::Schema;
use std::env;
use std::hint::black_box;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// The harness, as recorded in the results (the version Cargo.toml pins).
const HARNESS: &str = "criterion 0.8.2";

/// What to run, from the environment (criterion reads the command line).
struct Settings {
    out: PathBuf,
    sources: Vec<String>,
    options: Options,
}

impl Settings {
    fn from_env() -> Result<Settings, Error> {
        let bench = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let out = env::var_os("HAUS_BENCH_OUT").map_or_else(|| bench.join(".out"), PathBuf::from);
        let all = corpus::sources(&bench.join("sources.haus"))?;
        let sources = match env::var("HAUS_BENCH_SOURCES") {
            Ok(list) => {
                let names: Vec<String> = list.split(',').map(str::to_owned).collect();
                if let Some(unknown) = names.iter().find(|n| !all.contains(n)) {
                    return fail(format!("no corpus source {unknown} in sources.haus"));
                }
                names
            }
            Err(_) => all,
        };
        let quick = env::var("HAUS_BENCH_QUICK").is_ok_and(|v| !v.is_empty() && v != "0");
        let options = if quick {
            Options { time_ms: 300, warmup_ms: 100, quick }
        } else {
            Options { time_ms: 3000, warmup_ms: 1000, quick }
        };
        Ok(Settings { out, sources, options })
    }
}

/// The inputs of one source, prepared and checked once.
struct Inputs {
    corpus: Corpus,
    schema: Schema,
    /// Each haus document, parsed.
    values: Vec<Value>,
    /// Each JSON document, parsed by serde_json.
    json_values: Vec<serde_json::Value>,
}

fn one(text: &str, what: &str) -> Result<Value, Error> {
    match haus::parse(text).map_err(|e| Error(format!("{what}: {e}")))?.as_slice() {
        [v] => Ok(v.clone()),
        vs => fail(format!("{what}: {} values", vs.len())),
    }
}

/// A haus stream, minimised: each item followed by `,` and a line feed (spec §6, §11).
fn minimised_stream(values: &[Value]) -> String {
    values.iter().map(|v| haus::to_string_minimised(v).expect("written") + ",\n").collect()
}

impl Inputs {
    fn prepare(corpus: Corpus) -> Result<Inputs, Error> {
        if corpus.documents.is_empty() {
            return fail(format!("{}: no documents: run convert first", corpus.source));
        }
        let schema = Schema::parse(&corpus.schema).map_err(|e| Error(format!("{} schema: {e}", corpus.source)))?;
        let values = corpus.documents.iter().map(|d| one(&d.haus, &d.id)).collect::<Result<Vec<_>, _>>()?;
        let json_values = corpus
            .documents
            .iter()
            .map(|d| serde_json::from_str(&d.json).map_err(|e| Error(format!("{}: serde_json: {e}", d.id))))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Inputs { corpus, schema, values, json_values })
    }

    /// The checks before timing; the number of documents serde_json's
    /// `Value` writes back as another document (exact numbers, member order
    /// aside).
    fn check(&self) -> Result<u64, Error> {
        let mut json_not_stable = 0;
        for ((d, v), j) in self.corpus.documents.iter().zip(&self.values).zip(&self.json_values) {
            let written = haus::to_string_minimised(v).map_err(|e| Error(format!("{}: {e}", d.id)))?;
            if written != d.haus {
                return fail(format!("{}: haus parse → to_string_minimised is not the same text", d.id));
            }
            if &one(&d.pretty, &d.id)? != v {
                return fail(format!("{}: the pretty text reads as another value", d.id));
            }
            self.schema.decode(&d.root, v).map_err(|e| Error(format!("{}: decode as {}: {e}", d.id, d.root)))?;
            let back = serde_json::to_string(j).map_err(|e| Error(e.to_string()))?;
            let same = |text: &str| haus::import_json(text).map_err(|e| Error(format!("{}: {e}", d.id)));
            if !haus::equals(&same(&back)?, &same(&d.json)?) {
                json_not_stable += 1;
            }
        }
        let stream = haus::parse(&self.corpus.all_haus).map_err(|e| Error(format!("all.haus: {e}")))?;
        if stream != self.values {
            return fail("the haus corpus stream reads as other values");
        }
        if minimised_stream(&self.values) != self.corpus.all_haus {
            return fail("the haus corpus stream isn't what to_string_minimised writes for the documents");
        }
        let array: serde_json::Value =
            serde_json::from_str(&self.corpus.all_json).map_err(|e| Error(format!("all.json: {e}")))?;
        if array.as_array().map(Vec::len) != Some(self.values.len()) {
            return fail("the JSON corpus array has the wrong length");
        }
        Ok(json_not_stable)
    }
}

/// One timed task: what it is, and its body (the library calls; returns a
/// size, which is passed through `black_box`).
struct Task<'a> {
    id: &'static str,
    group: Group,
    input: Input,
    format: Format,
    implementation: &'static str,
    bytes: u64,
    run: Box<dyn Fn() -> usize + 'a>,
}

fn task<'a>(
    id: &'static str,
    group: Group,
    input: Input,
    format: Format,
    implementation: &'static str,
    bytes: u64,
    run: Box<dyn Fn() -> usize + 'a>,
) -> Task<'a> {
    Task { id, group, input, format, implementation, bytes, run }
}

/// The tasks, in the TypeScript step's order. Bytes are those of the text
/// read or written, as there.
fn tasks(i: &Inputs) -> Vec<Task<'_>> {
    use Format::{Haus, Json};
    use Group::{Parse, Typed, Write};
    use Input::{Corpus, PerDoc};
    let docs = &i.corpus.documents;
    let all_json = i.corpus.all_json.as_str();
    let all_haus = i.corpus.all_haus.as_str();
    let json_bytes = docs.iter().map(|d| d.json.len() as u64).sum();
    let haus_bytes = docs.iter().map(|d| d.haus.len() as u64).sum();
    let compact_bytes = i.values.iter().map(|v| haus::to_string(v).expect("written").len() as u64).sum();
    vec![
        task(
            "parse-corpus-json",
            Parse,
            Corpus,
            Json,
            "serde_json::from_str (Value)",
            all_json.len() as u64,
            Box::new(move || {
                let v: serde_json::Value = serde_json::from_str(black_box(all_json)).expect("parsed");
                v.as_array().map_or(0, Vec::len)
            }),
        ),
        task(
            "parse-corpus-haus",
            Parse,
            Corpus,
            Haus,
            "haus::parse",
            all_haus.len() as u64,
            Box::new(move || haus::parse(black_box(all_haus)).expect("parsed").len()),
        ),
        task(
            "parse-doc-json",
            Parse,
            PerDoc,
            Json,
            "serde_json::from_str (Value)",
            json_bytes,
            Box::new(move || {
                docs.iter()
                    .map(|d| {
                        let v: serde_json::Value = serde_json::from_str(black_box(&d.json)).expect("parsed");
                        usize::from(!v.is_null())
                    })
                    .sum()
            }),
        ),
        task(
            "parse-doc-haus",
            Parse,
            PerDoc,
            Haus,
            "haus::parse",
            haus_bytes,
            Box::new(move || docs.iter().map(|d| haus::parse(black_box(&d.haus)).expect("parsed").len()).sum()),
        ),
        task(
            "typed-corpus-haus",
            Typed,
            Corpus,
            Haus,
            "haus::parse + Schema::decode",
            all_haus.len() as u64,
            Box::new(move || {
                let values = haus::parse(black_box(all_haus)).expect("parsed");
                values.iter().zip(docs).map(|(v, d)| usize::from(i.schema.decode(&d.root, v).is_ok())).sum()
            }),
        ),
        task(
            "typed-doc-haus",
            Typed,
            PerDoc,
            Haus,
            "haus::parse + Schema::decode",
            haus_bytes,
            Box::new(move || {
                docs.iter()
                    .map(|d| {
                        let values = haus::parse(black_box(&d.haus)).expect("parsed");
                        usize::from(i.schema.decode(&d.root, &values[0]).is_ok())
                    })
                    .sum()
            }),
        ),
        task(
            "write-corpus-json",
            Write,
            Corpus,
            Json,
            "serde_json::to_string",
            all_json.len() as u64,
            Box::new(move || serde_json::to_string(black_box(&i.json_values)).expect("written").len()),
        ),
        task(
            "write-corpus-haus",
            Write,
            Corpus,
            Haus,
            "haus::to_string_minimised (stream)",
            all_haus.len() as u64,
            Box::new(move || minimised_stream(black_box(&i.values)).len()),
        ),
        task(
            "write-doc-json",
            Write,
            PerDoc,
            Json,
            "serde_json::to_string",
            json_bytes,
            Box::new(move || {
                i.json_values.iter().map(|v| serde_json::to_string(black_box(v)).expect("written").len()).sum()
            }),
        ),
        task(
            "write-doc-haus-minimised",
            Write,
            PerDoc,
            Haus,
            "haus::to_string_minimised",
            haus_bytes,
            Box::new(move || {
                i.values.iter().map(|v| haus::to_string_minimised(black_box(v)).expect("written").len()).sum()
            }),
        ),
        task(
            "write-doc-haus-compact",
            Write,
            PerDoc,
            Haus,
            "haus::to_string (compact)",
            compact_bytes,
            Box::new(move || i.values.iter().map(|v| haus::to_string(black_box(v)).expect("written").len()).sum()),
        ),
    ]
}

/// Where criterion keeps its samples: `<target>/criterion`.
fn criterion_dir() -> PathBuf {
    env::var_os("CARGO_TARGET_DIR")
        .map_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("target"), PathBuf::from)
        .join("criterion")
}

/// The tasks of one source, timed, and its results written (when criterion
/// measured every task: not with a filter that leaves some out, nor `--test`).
fn bench_source(c: &mut Criterion, settings: &Settings, machine: &Machine, source: &str) -> Result<(), Error> {
    let inputs = Inputs::prepare(Corpus::load(&settings.out, source)?)?;
    let json_not_stable = inputs.check()?;
    let tasks = tasks(&inputs);
    let checksum = tasks.iter().map(|t| (t.run)() as u64).sum();
    let docs = inputs.corpus.documents.len() as u64;

    let start = SystemTime::now();
    let mut group = c.benchmark_group(source);
    // Equal batches: the long tasks (a whole corpus of megabytes) would need
    // minutes for criterion's linear sampling.
    group.sampling_mode(SamplingMode::Flat);
    for t in &tasks {
        group.throughput(Throughput::Bytes(t.bytes));
        group.bench_function(t.id, |b| b.iter(|| black_box((t.run)())));
    }
    group.finish();

    let dir = criterion_dir().join(source);
    let mut rows = Vec::new();
    for t in &tasks {
        let Some(samples) = Samples::read(&dir.join(t.id), start)? else {
            println!("{source}: {} was not measured (a filter, or --test): no results written", t.id);
            return Ok(());
        };
        rows.push(Row {
            group: t.group,
            input: t.input,
            format: t.format,
            implementation: t.implementation.to_owned(),
            bytes: t.bytes,
            docs,
            samples,
        });
    }
    let out = SpeedOut {
        harness: HARNESS.to_owned(),
        machine: machine.clone(),
        options: settings.options,
        documents: inputs.corpus.documents.iter().map(|d| d.id.clone()).collect(),
        json_not_stable,
        rows,
        checksum,
    };
    let path = out.write(&settings.out, source)?;
    println!(
        "\n{source}: {}, {}{}",
        machine.cpu,
        machine.runtime,
        if settings.options.quick { " (quick)" } else { "" }
    );
    for row in &out.rows {
        println!("{}", row.line());
    }
    println!("serde_json wrote {json_not_stable} documents back as another document; wrote {}\n", path.display());
    Ok(())
}

fn main() {
    let settings = match Settings::from_env() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };
    let o = settings.options;
    let mut c = Criterion::default()
        .sample_size(if o.quick { 10 } else { 50 })
        .warm_up_time(Duration::from_millis(o.warmup_ms))
        .measurement_time(Duration::from_millis(o.time_ms))
        .output_directory(&criterion_dir())
        .configure_from_args();
    let machine = Machine::detect();
    for source in &settings.sources {
        if let Err(e) = bench_source(&mut c, &settings, &machine, source) {
            eprintln!("error: {source}: {e}");
            std::process::exit(1);
        }
    }
    c.final_summary();
}
