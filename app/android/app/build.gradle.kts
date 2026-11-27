import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

fun signingProp(envName: String, propName: String): String? {
    val envVal = System.getenv(envName)?.trim()
    if (!envVal.isNullOrEmpty()) return envVal
    val propVal = keystoreProperties.getProperty(propName)?.trim()
    return if (propVal.isNullOrEmpty()) null else propVal
}

val releaseStorePath = signingProp("ANDROID_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = signingProp("ANDROID_STORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingProp("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingProp("ANDROID_KEY_PASSWORD", "keyPassword")
val hasReleaseSigning = !releaseStorePath.isNullOrEmpty() &&
    !releaseStorePassword.isNullOrEmpty() &&
    !releaseKeyAlias.isNullOrEmpty() &&
    !releaseKeyPassword.isNullOrEmpty() &&
    file(releaseStorePath).exists()
val requireReleaseSigning = (project.findProperty("requireReleaseSigning")?.toString() == "true") ||
    (System.getenv("REQUIRE_RELEASE_SIGNING") == "true")

android {
    namespace = "dev.grassbag.grassbag"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "dev.grassbag.grassbag"
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // Bundled Ubuntu rootfs, Node 24, tawcroot & PRoot are arm64-v8a only.
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (requireReleaseSigning && !hasReleaseSigning) {
                throw GradleException(
                    "Release signing is required (-PrequireReleaseSigning=true) but keystore env/key.properties are incomplete."
                )
            }
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        jniLibs {
            // Required on Android 10+ (W^X) so libproot.so & libproot_loader.so
            // are extracted into applicationInfo.nativeLibraryDir with exec permission.
            useLegacyPackaging = true
        }
    }

    androidResources {
        noCompress += listOf("gbag", "gz", "xz")
    }
}

flutter {
    source = "../.."
}
