//! The official packages, built in (packages.md §2, "Tools"; §3): their
//! files and the implementations of their rules, from their crates. A schema
//! imports them by name, and nothing gives them; a package given with one of
//! their names must be byte for byte the built-in one.

use haus_schema::{Package, PackageRule};

/// The official packages, as values.
pub(crate) fn packages() -> Vec<Package> {
    [
        (haus_money::MANIFEST, haus_money::SCHEMA),
        (haus_geo::MANIFEST, haus_geo::SCHEMA),
        (haus_uuid::MANIFEST, haus_uuid::SCHEMA),
    ]
    .into_iter()
    .map(|(manifest, schema)| Package::make(manifest, schema).expect("an official package is valid"))
    .collect()
}

/// The implementations of the official packages' rules.
pub(crate) fn rules() -> Vec<PackageRule> {
    vec![
        PackageRule::of::<haus_money::rules::Iso>(),
        PackageRule::of::<haus_geo::rules::Wgs84>(),
        PackageRule::of::<haus_geo::rules::Wgs84BBox>(),
        PackageRule::of::<haus_uuid::rules::Rfc9562>(),
    ]
}

#[cfg(test)]
mod tests {
    /// Every rule the official manifests name is built in.
    #[test]
    fn every_official_rule_is_built_in() {
        let rules = super::rules();
        for package in super::packages() {
            let id = package.manifest().id();
            for (ty, rule) in package.manifest().rules().unwrap() {
                let built_in = rules.iter().find(|r| r.id == format!("{id}#{ty}"));
                assert_eq!(built_in.map(|r| r.name.as_str()), Some(rule.as_str()), "{id}#{ty}");
            }
        }
    }
}
