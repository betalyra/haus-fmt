// The speed benchmark of the JVM binding: a build of its own, outside jvm/
// (so jvm/'s build and its CI never build it), with the binding from the
// checkout through a composite build: org.haus-fmt:haus is jvm/'s :haus.
rootProject.name = "haus-bench-speed-jvm"

includeBuild("../../../jvm")

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}
