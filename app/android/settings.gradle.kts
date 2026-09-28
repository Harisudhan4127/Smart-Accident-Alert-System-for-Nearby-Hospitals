pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 8.11.1 / Kotlin 2.2.20 — the pair `flutter create` generates for
    // this Flutter SDK, and the pair its Gradle plugin is tested against.
    //
    // Flutter emits a "support will soon be dropped" warning for both, but
    // upgrading to the suggested AGP 9.0.1 / Kotlin 2.3.20 does not build:
    // AGP 9 enables `android.newDsl` by default, which retires the `android { }
    // and `kotlinOptions { }` blocks used here. Those are warnings about a
    // future Flutter release, so the versions move when the SDK templates do.
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
