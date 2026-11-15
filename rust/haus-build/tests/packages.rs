//! Schema packages are `package.haus` and `schema.haus`, and stay inside
//! their directory (spec §13.3) in the generators too: `haus-gen
//! roc-package` and `--package`.
#![cfg(unix)]

use haus::ErrorCode;
use haus_build::roc::RocConfig;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::Path;

fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[test]
fn a_package_schema_outside_the_package_is_not_read() {
    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join("secret/creds.schema.haus"), "API_TOKEN=hunter2");
    let package = dir.path().join("evil");
    write(&package.join("package.haus"), "{ name: \"@acme/evil\", version: \"1.0.0\" }");
    symlink(dir.path().join("secret/creds.schema.haus"), package.join("schema.haus")).unwrap();
    for e in [
        RocConfig::new().generate_package(&package).map(|_| ()).unwrap_err(),
        RocConfig::new()
            .package(&package, "evil")
            .generate(&dir.path().join("app.schema.haus"), "App", "app")
            .map(|_| ())
            .unwrap_err(),
    ] {
        assert_eq!(e.code(), ErrorCode::PackagePath, "{e}");
        assert!(!e.to_string().contains("API_TOKEN"), "{e}");
    }
}

#[test]
fn a_package_is_package_haus_and_schema_haus() {
    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join("package.haus"), "{ name: \"@acme/ids\", version: \"2.1.0\" }");
    write(&dir.path().join("schema.haus"), "type Id = Int");
    let (module, code) = RocConfig::new().generate_package(dir.path()).unwrap();
    assert_eq!(module, "AcmeIds");
    assert!(code.contains("@acme/ids@2#Id"), "{code}");
}

#[test]
fn a_package_schema_imports_no_files() {
    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join("package.haus"), "{ name: \"@acme/evil\", version: \"1.0.0\" }");
    write(&dir.path().join("schema.haus"), "import ../secret/pins (T)\ntype U = T");
    for e in [
        RocConfig::new().generate_package(dir.path()).map(|_| ()).unwrap_err(),
        RocConfig::new()
            .package(dir.path(), "evil")
            .generate(&dir.path().join("app.schema.haus"), "App", "app")
            .map(|_| ())
            .unwrap_err(),
    ] {
        assert_eq!(e.code(), ErrorCode::PackagePath, "{e}");
        assert!(e.to_string().contains("the schema of @acme/evil can't import files"), "{e}");
    }
}

#[test]
fn imports_name_only_major_versions() {
    for v in ["1.1", "01", "x"] {
        let text = format!("import @haus-fmt/money@{v} (Money)\ntype A = {{ m: Money }}");
        let e = haus_build::generate(&text, "app", &[], &haus_build::Packages::none()).unwrap_err();
        assert_eq!(e.code(), ErrorCode::ImportVersion, "@{v}: {e}");
        let e = haus_build::roc::generate(&text, "App", "app", &[], &haus_build::Packages::none()).unwrap_err();
        assert_eq!(e.code(), ErrorCode::ImportVersion, "@{v}: {e}");
    }
}
