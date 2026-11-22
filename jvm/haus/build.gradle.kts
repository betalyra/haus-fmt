// The Java core: no dependencies at run time.
plugins {
    `java-library`
}

dependencies {
    testImplementation(platform("org.junit:junit-bom:6.1.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

// The paths that recurse once per level, at the supported depth on a 512 KiB thread (spec §7),
// interpreted: the interpreter's frames are the largest.
val smallStackTest by tasks.registering(Test::class) {
    description = "Runs the small-stack depth tests with -Xint."
    testClassesDirs = sourceSets.test.get().output.classesDirs
    classpath = sourceSets.test.get().runtimeClasspath
    jvmArgs("-Xint")
    filter {
        includeTestsMatching("org.hausfmt.SmallStackTest")
        includeTestsMatching("org.hausfmt.SchemaDepthTest")
    }
}

tasks.test {
    dependsOn(smallStackTest)
}
