fn main() -> Result<(), haus_build::Error> {
    // The package's rule (its manifest's `rules`): the generated code checks it.
    haus_build::Config::new().with_rule("@haus-fmt/uuid@1#Uuid", "crate::rules::Rfc9562").package()
}
