plugins {
    kotlin("jvm") version "2.4.21" apply false
}

/** The libraries published to Maven Central (PUBLISHING.md), as org.haus-fmt:<name>. */
val published = mapOf(
    "haus" to "haus: the haus data format for Java (parser, writer, schemas, codecs)",
    "haus-kotlin" to "haus for Kotlin: the Java library's Kotlin API",
)

subprojects {
    group = "org.haus-fmt"
    version = "0.1.0"

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

    // A release for Maven Central: each library with its sources, its javadoc
    // (empty for Kotlin, which Central accepts) and a POM, into a staging
    // repository in build/staging that scripts/central-upload.sh uploads.
    // `-Prelease` signs every file: in memory with the armored key in
    // SIGNING_KEY and its passphrase in SIGNING_PASSWORD (given by `op run`,
    // PUBLISHING.md), else with the local gpg (signing.gnupg.keyName in
    // ~/.gradle/gradle.properties). Without it nothing is signed, to check the
    // layout.
    published[name]?.let { summary ->
        apply(plugin = "maven-publish")
        apply(plugin = "signing")
        plugins.withType<JavaPlugin> {
            extensions.configure<JavaPluginExtension> {
                withSourcesJar()
                withJavadocJar()
            }
        }
        afterEvaluate {
            extensions.configure<PublishingExtension> {
                publications.create<MavenPublication>("maven") {
                    from(components["java"])
                    pom {
                        name.set(project.name)
                        description.set(summary)
                        url.set("https://haus-fmt.org")
                        licenses {
                            license {
                                name.set("MIT License")
                                url.set("https://opensource.org/license/mit")
                            }
                        }
                        developers {
                            developer {
                                id.set("betalyra")
                                name.set("Betalyra")
                                organizationUrl.set("https://github.com/betalyra")
                            }
                        }
                        scm {
                            url.set("https://github.com/betalyra/haus-fmt")
                            connection.set("scm:git:https://github.com/betalyra/haus-fmt.git")
                            developerConnection.set("scm:git:ssh://git@github.com/betalyra/haus-fmt.git")
                        }
                    }
                }
                repositories {
                    maven {
                        name = "staging"
                        url = uri(rootProject.layout.buildDirectory.dir("staging"))
                    }
                }
            }
            if (providers.gradleProperty("release").isPresent) {
                extensions.configure<SigningExtension> {
                    val key = providers.environmentVariable("SIGNING_KEY")
                    if (key.isPresent) {
                        useInMemoryPgpKeys(key.get(), providers.environmentVariable("SIGNING_PASSWORD").orNull)
                    } else {
                        useGpgCmd()
                    }
                    sign(extensions.getByType<PublishingExtension>().publications)
                }
            }
        }
    }
}
