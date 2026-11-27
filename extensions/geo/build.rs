fn main() -> Result<(), haus_build::Error> {
    // The package's rules (its manifest's `rules`): the generated code checks them.
    haus_build::Config::new()
        .with_rule("@haus-fmt/geo@1#LatLng", "crate::rules::Wgs84")
        .with_rule("@haus-fmt/geo@1#BBox", "crate::rules::Wgs84BBox")
        .package()
}
