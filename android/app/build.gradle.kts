plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.happygoluckycodeeditor.japanodict.japanodict"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.happygoluckycodeeditor.japanodict.japanodict"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // Required by the OCR screen, and it has to live here rather than in the
    // plugin: google_mlkit_text_recognition bundles only the Latin recogniser
    // and declares every other script `compileOnly`. Without this line the
    // plugin still builds and analyzes clean, but asking it for
    // TextRecognitionScript.japanese throws at runtime on a device.
    //
    // This is a bundled model (~4MB in the APK), not a Play-services download
    // — unlike the handwriting ink model, OCR works offline on first launch
    // and on non-Play-Store emulator images.
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
}

flutter {
    source = "../.."
}
