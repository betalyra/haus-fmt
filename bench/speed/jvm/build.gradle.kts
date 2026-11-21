// The JVM speed benchmark: JMH (its annotation processor, no Gradle plugin)
// and Jackson as the JSON baseline, both pinned exactly and used here only.
// `run` checks the corpus, runs JMH's Runner and writes
// bench/.out/<source>/speed-jvm.json (see Speed.java).
plugins {
    application
}

val jmh = "1.37"

dependencies {
    implementation("org.haus-fmt:haus")
    implementation("com.fasterxml.jackson.core:jackson-databind:2.20.1")
    implementation("org.openjdk.jmh:jmh-core:$jmh")
    annotationProcessor("org.openjdk.jmh:jmh-generator-annprocess:$jmh")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

tasks.withType<JavaCompile>().configureEach {
    options.release.set(17)
    options.encoding = "UTF-8"
    // -Xlint:all but processing: JMH's annotation processor claims no annotations of its own.
    options.compilerArgs.addAll(listOf("-Xlint:all,-processing", "-Werror"))
}

application {
    mainClass.set("org.hausfmt.bench.speed.Speed")
}

tasks.named<JavaExec>("run") {
    // The forks JMH starts are separate JVMs: the runner itself only needs a little.
    jvmArgs("-Xmx1g")
}
