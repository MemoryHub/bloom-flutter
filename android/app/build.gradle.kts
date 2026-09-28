plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.bloom.bloom"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.bloom.bloom"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // Modern Android can mmap aligned native libraries directly from
            // the APK, avoiding a second extracted copy in app storage.
            useLegacyPackaging = false
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    // 原生侧也要跑同一份共享测试向量（test/vectors/carousel_vectors.json），
    // 否则「三端一致」只是一句口号。org.json 在真机由系统提供，JVM 单测需要显式依赖。
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

// 共享向量是测试的**运行时输入**，但 Gradle 看不见它：CarouselVectorsTest 用
// 相对路径 "../../test/vectors/carousel_vectors.json" 读取，这个 file 依赖
// 不会进 Gradle 的输入快照。
//
// 后果很隐蔽：只改向量文件、不改 Kotlin 时，testDebugUnitTest 会被判定为
// UP-TO-DATE 并**直接跳过**，验证脚本于是给出一个「假绿」。假绿比红危险得多，
// 因为它会让人放心地构建安装包。
//
// 显式声明成输入后，向量一变就会重跑。
tasks.withType<Test>().configureEach {
    inputs
        .file(File(rootProject.projectDir.parentFile, "test/vectors/carousel_vectors.json"))
        .withPropertyName("carouselVectors")
}
