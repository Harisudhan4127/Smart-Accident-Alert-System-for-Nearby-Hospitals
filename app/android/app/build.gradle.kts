plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.saas.smart_accident_alert"

    // Tracks the Flutter SDK's default (36), which is the highest level any
    // plugin in the current dependency graph needs — the outlier was
    // permission_handler_android 14.x, which compiles against 37. It was removed
    // because nothing in lib/ imported it; see the note in pubspec.yaml.
    //
    // If a future plugin needs more, this line is where to raise it, and the
    // override that caused the conflict is worth checking first — an unused
    // dependency should not be able to dictate the project's SDK level.
    compileSdk = flutter.compileSdkVersion

    ndkVersion = flutter.ndkVersion

    compileOptions {
        // 17 rather than the template's 11. Bluetooth permissions, the
        // notification full-screen-intent API and the BLE stack are all
        // exercised against modern Android, and a 17 bytecode target costs
        // nothing on any device that can install the app (minSdk 24 above).
        // AGP 8 itself runs fine on JDK 17; the toolchain here is JDK 21.
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17

        // REQUIRED by flutter_local_notifications.
        //
        // The plugin uses `java.time` (and other java.util APIs added after
        // Android 8) to schedule and render alarms. Without desugaring those
        // APIs are absent on the minSdk 24 devices this app supports, and the
        // release build fails at AAR-metadata validation with:
        //
        //   "Dependency ':flutter_local_notifications' requires core library
        //    desugaring to be enabled"
        //
        // Desugaring back-ports them at the bytecode level, so the app keeps
        // minSdk 24 instead of being forced up to 26 to get java.time natively.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "dev.saas.smart_accident_alert"
        // 24 rather than `flutter.minSdkVersion`: BLE scanning with the modern
        // Android APIs, and background location, both need 23+; 24 is the first
        // level where the runtime-permission model is fully in force.
        minSdk = 24
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Signed with the debug key so `flutter build apk --release`
            // produces an installable artifact for testing and demos.
            //
            // This is NOT a publishable build. A real release needs a keystore
            // and a `signingConfigs` entry here, with the credentials supplied
            // from `key.properties` — which is gitignored. See
            // docs/11-deployment.md#release-builds.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    // The runtime half of core library desugaring. The version is pinned to the
    // one the Android Gradle Plugin validates against; a mismatch is a build
    // error, not a warning.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
