import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The examples, in Java and Kotlin, on the shared files in ../../examples:
// ./gradlew :examples:quickstart, :examples:order (Java) and
// :examples:quickstartKotlin, :examples:orderKotlin.
plugins {
    kotlin("jvm")
    java
}

dependencies {
    implementation(project(":haus-kotlin"))
    testImplementation(platform("org.junit:junit-bom:6.1.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        allWarningsAsErrors.set(true)
        // Parameter names, which typed codecs map data classes by.
        javaParameters.set(true)
    }
}

for ((task, main) in listOf(
    "quickstart" to "org.hausfmt.examples.Quickstart",
    "order" to "org.hausfmt.examples.Order",
    "quickstartKotlin" to "org.hausfmt.examples.quickstart.QuickstartKt",
    "orderKotlin" to "org.hausfmt.examples.order.OrderKt",
)) {
    tasks.register<JavaExec>(task) {
        group = "examples"
        classpath = sourceSets["main"].runtimeClasspath
        mainClass.set(main)
    }
}
