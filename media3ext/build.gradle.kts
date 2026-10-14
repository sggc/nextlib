import com.android.build.gradle.internal.tasks.factory.dependsOn
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.androidLibrary)
    alias(libs.plugins.mavenPublish)
}

android {
    namespace = "io.github.anilbeesetti.nextlib.media3ext"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    ndkVersion = libs.versions.ndk.get()

    defaultConfig {

        minSdk = 23
        consumerProguardFiles("consumer-rules.pro")
        externalNativeBuild {
            cmake {
                cppFlags("")
            }
        }

        ndk {
            // 必须与 ffmpeg/setup.sh 的 ANDROID_ABIS 保持一致！
            // setup.sh 只产出这两个 ABI 的 ffmpeg/uavs3d 静态库；
            // 若这里多写 ABI（如 x86），CMake 会找不到对应 libavcodec.a 而失败。
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget = JvmTarget.JVM_17
        }
    }

    externalNativeBuild {
        cmake {
            path("src/main/cpp/CMakeLists.txt")
            version = libs.versions.cmake.get()
        }
    }
}

// Gradle task to setup ffmpeg
val ffmpegSetup by tasks.registering(Exec::class) {
    workingDir = file("../ffmpeg")
    // export ndk path and run bash script
    environment("ANDROID_SDK_HOME", androidComponents.sdkComponents.sdkDirectory.get().asFile.absolutePath)
    environment("ANDROID_NDK_HOME", androidComponents.sdkComponents.ndkDirectory.get().asFile.absolutePath)
    environment("ANDROID_CMAKE_VERSION", libs.versions.cmake.get())
    commandLine("bash", "setup.sh")
}

tasks.preBuild.dependsOn(ffmpegSetup)

dependencies {
    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.google.errorprone.annotations)
    implementation(libs.androidx.annotation)
    compileOnly(libs.checker.qual)
    compileOnly(libs.kotlin.annotations.jvm)
}