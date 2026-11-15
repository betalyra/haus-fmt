//! Print the error for each file given, with its code (spec §17):
//! `cargo run --example errors -- FILE…`; with `--json`, its JSON form.

fn main() {
    let json = std::env::args().any(|a| a == "--json");
    for path in std::env::args().skip(1).filter(|a| a != "--json") {
        let name = std::path::Path::new(&path).file_stem().unwrap().to_string_lossy().into_owned();
        match haus::parse_bytes(&std::fs::read(&path).unwrap()) {
            Ok(_) => println!("{name}: ok"),
            Err(e) if json => println!("{}", e.to_json()),
            Err(e) => println!("{name}: [{}] {e}", e.code),
        }
    }
}
