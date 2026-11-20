plugins {
    kotlin("jvm") version "2.4.21" apply false
}

subprojects {
    group = "org.haus-fmt"
    version = "0.1.0-SNAPSHOT"

    // Java 17 bytecode and APIs, so the library runs on Android too; built
    // and tested with a newer JDK.
    plugins.withType<JavaPlugin> {
        extensions.configure<JavaPluginExtension> {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
        tasks.withType<JavaCompile>().configureEach {
            options.release.set(17)
            options.encoding = "UTF-8"
            options.compilerArgs.addAll(listOf("-Xlint:all", "-Werror"))
        }
        // The documentation is prose: parameters and results are described in it, not tagged.
        tasks.withType<Javadoc>().configureEach {
            (options as StandardJavadocDocletOptions).addStringOption("Xdoclint:all,-missing", "-quiet")
        }
        tasks.withType<Test>().configureEach {
            useJUnitPlatform()
            // The repository: the conformance suite and the shared example files.
            systemProperty("haus.root", rootDir.parentFile.absolutePath)
            testLogging {
                events("failed")
                exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
            }
        }
    }
}
