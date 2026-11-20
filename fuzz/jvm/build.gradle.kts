// The JVM runner of the differential fuzzers (fuzz/README.md), built by
// fuzz/build.sh into fuzz/.build/jvm-runner (bin/jvm-runner).
plugins {
    application
}

dependencies {
    implementation(project(":haus"))
}

application {
    applicationName = "jvm-runner"
    mainClass.set("org.hausfmt.fuzz.Runner")
}

tasks.named<Sync>("installDist") {
    destinationDir = file("../.build/jvm-runner")
}
