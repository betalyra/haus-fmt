import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The Kotlin wrapper: depends on the Java core and kotlin-stdlib only.
plugins {
    kotlin("jvm")
    `java-library`
}

dependencies {
    api(project(":haus"))
    testImplementation(platform("org.junit:junit-bom:6.1.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testImplementation(kotlin("test"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

kotlin {
    explicitApi()
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        allWarningsAsErrors.set(true)
    }
}
