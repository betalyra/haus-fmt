//! The package suite's rules (test-suite/packages/rules.haus; packages.md
//! §3, §4, §6, §7), run with the official packages built in as the `haus`
//! command has them: read the packages a case gives (by directory and in
//! folders) and the schema's files, then compile them with the official
//! packages and their rules, the case's `shapeOnly` and `withRule`.

use haus::Value;
use haus_schema::{Package, PackageRule, Schema, Sources, read_folder};
use std::fs;
use std::path::Path;

fn suite() -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/packages/rules.haus");
    fs::read_to_string(path).unwrap()
}

fn string(v: &Value) -> &str {
    v.as_str().unwrap_or_else(|| panic!("not a string: {v:?}"))
}

fn strings(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array).map(|items| items.iter().map(|s| string(s).to_owned()).collect()).unwrap_or_default()
}

/// Writes the case's file tree into `dir`: `File`, `Package` and `Link` entries.
fn write_tree(dir: &Path, files: &[Value]) {
    let (links, others): (Vec<&Value>, Vec<&Value>) =
        files.iter().partition(|e| e.as_variant().is_some_and(|(tag, _)| tag == "Link"));
    for entry in others.into_iter().chain(links) {
        let (tag, args) = entry.as_variant().expect("an entry");
        let at = |p: &Value| {
            let path = dir.join(string(p));
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            path
        };
        match (tag.as_str(), args) {
            ("File", [path, text]) => fs::write(at(path), string(text)).unwrap(),
            ("Package", [path, name, version, schema]) => {
                let dir = at(path);
                fs::create_dir_all(&dir).unwrap();
                let manifest = format!("{{ name: \"{}\", version: \"{}\" }}", string(name), string(version));
                fs::write(dir.join("package.haus"), manifest).unwrap();
                fs::write(dir.join("schema.haus"), string(schema)).unwrap();
            }
            #[cfg(unix)]
            ("Link", [path, target]) => std::os::unix::fs::symlink(string(target), at(path)).unwrap(),
            other => panic!("an entry this runner doesn't write: {other:?}"),
        }
    }
}

/// The official packages and their rules, as the command has them built in.
fn official() -> (Vec<Package>, Vec<PackageRule>) {
    let packages = [
        (haus_money::MANIFEST, haus_money::SCHEMA),
        (haus_geo::MANIFEST, haus_geo::SCHEMA),
        (haus_uuid::MANIFEST, haus_uuid::SCHEMA),
    ]
    .map(|(manifest, schema)| Package::make(manifest, schema).unwrap());
    let rules = vec![
        PackageRule::of::<haus_money::rules::Iso>(),
        PackageRule::of::<haus_geo::rules::Wgs84>(),
        PackageRule::of::<haus_geo::rules::Wgs84BBox>(),
        PackageRule::of::<haus_uuid::rules::Rfc9562>(),
    ];
    (packages.into(), rules)
}

/// The case compiled: the packages the schema reaches (`name@version`, sorted), or the error.
fn run(case: &Value) -> Result<Vec<String>, haus_schema::Error> {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().canonicalize().unwrap();
    write_tree(&dir, case.get("files").and_then(Value::as_array).expect("files"));
    let mode = case.get("mode").and_then(Value::as_variant).expect("a mode");
    let field = |name: &str| mode.1.first().and_then(|r| r.get(name));
    let (shape_only, with_rule) = (strings(case.get("shapeOnly")), strings(case.get("withRule")));
    // Read: the packages given by their directory, then those in folders.
    let mut given: Vec<Package> =
        strings(field("packages")).iter().map(|p| Package::read(dir.join(p))).collect::<Result<_, _>>()?;
    for folder in strings(field("folders")) {
        given.extend(read_folder(dir.join(folder))?.packages);
    }
    let (built_in, rules) = official();
    // The program's choices for its packages: shape-only, and the rules it supplies.
    let accept = |id: &String| PackageRule { id: id.clone(), name: String::new(), check: |_| Ok(()) };
    let choose = |p: Package| {
        let prefix = format!("{}@", p.name());
        let supplied: Vec<PackageRule> = with_rule.iter().filter(|id| id.starts_with(&prefix)).map(accept).collect();
        let p = supplied.into_iter().fold(p, Package::with);
        if shape_only.iter().any(|n| n == p.name()) { p.shape_only() } else { p }
    };
    let sources = Sources::read(dir.join(string(case.get("root").expect("a root"))))?
        .with_packages(built_in.into_iter().map(choose))?
        .with_packages(given.into_iter().map(choose))?;
    let schema = Schema::compile_with(&sources, &rules)?;
    let mut reached: Vec<String> = schema.packages().iter().map(|p| format!("{}@{}", p.name, p.version)).collect();
    reached.sort();
    Ok(reached)
}

#[test]
fn rules_suite() {
    let cases: Vec<Value> = haus::parse(&suite())
        .unwrap()
        .into_iter()
        .map(|entry| match entry.as_variant() {
            Some((tag, [fields])) if tag == "Case" => fields.clone(),
            _ => panic!("every entry is Case {{ … }}"),
        })
        .collect();
    let mut failures = vec![];
    for case in &cases {
        let name = case.get("name").map(string).unwrap_or("?");
        let expect = case.get("expect").and_then(Value::as_variant).expect("an expect");
        let fields = expect.1.first();
        let got = run(case);
        let failure = match (expect.0.as_str(), got) {
            ("Ok", Ok(reached)) if reached == strings(fields.and_then(|f| f.get("packages"))) => None,
            ("Ok", Ok(reached)) => Some(format!("reached {reached:?}")),
            ("Ok", Err(e)) => Some(format!("failed: {e}")),
            ("Err", Ok(reached)) => Some(format!("compiled, reaching {reached:?}")),
            ("Err", Err(e)) => {
                let code = fields.and_then(|f| f.get("code")).map(string).unwrap_or_default();
                let message = e.to_string().replace('\\', "/");
                let missing: Vec<String> = strings(fields.and_then(|f| f.get("mentions")))
                    .into_iter()
                    .filter(|m| !message.contains(m.as_str()))
                    .collect();
                let shown: Vec<String> = strings(fields.and_then(|f| f.get("hides")))
                    .into_iter()
                    .filter(|h| message.contains(h.as_str()))
                    .collect();
                match (e.code().map(|c| c.as_str()) == Some(code), missing.is_empty(), shown.is_empty()) {
                    (true, true, true) => None,
                    (false, _, _) => Some(format!("failed with {:?}, expected {code}: {message}", e.code())),
                    _ => Some(format!("{message}: doesn't mention {missing:?}, or shows {shown:?}")),
                }
            }
            (other, _) => Some(format!("an expect this runner doesn't know: {other}")),
        };
        failures.extend(failure.map(|why| format!("{name}: {why}")));
    }
    assert!(failures.is_empty(), "{} of {} cases fail:\n{}", failures.len(), cases.len(), failures.join("\n"));
    println!("rules suite: {} cases passed", cases.len());
}
