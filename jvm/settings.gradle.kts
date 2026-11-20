// The JVM binding of haus: the Java core (haus), its Kotlin wrapper
// (haus-kotlin), the examples, and the differential fuzzer's runner
// (fuzz/jvm, built by fuzz/build.sh).
rootProject.name = "haus-jvm"

include("haus", "haus-kotlin", "examples", "fuzz-runner")
project(":fuzz-runner").projectDir = file("../fuzz/jvm")

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}
