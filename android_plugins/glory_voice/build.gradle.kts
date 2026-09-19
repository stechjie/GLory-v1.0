// GloryVoice 安卓桥接（docs/语音LiveKit方案.md 5.1）。
//
// 只由 build_aar.ps1 调用：它把这个目录拷到纯英文的临时目录再跑 Gradle（这台机器的 Java 工具
// 打不开带中文的路径），然后把 aar 放到 addons/glory_voice/bin/GloryVoice.aar。
//
// 版本与 android/build/config.gradle（Godot 4.7.1 安卓构建模板）一致：AGP 8.6.1、Kotlin 2.1.21、
// compileSdk 36、minSdk 24、Java 17 —— 这样出包时的 Gradle 与这里用的是同一套，已经在本机缓存里。
//
// LiveKit 只 compileOnly：插件 aar 里不带它。真正打进 APK 的那份由导出插件
// （addons/glory_voice/glory_voice_plugin.gd 的 _get_android_dependencies）交给出包时的 Gradle。
// 三处的版本号必须一样（这里、那里、GloryVoicePlugin.kt 的 LIVEKIT_VERSION），tools/voice_check 对账。
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library") version "8.6.1"
    id("org.jetbrains.kotlin.android") version "2.1.21"
}

android {
    namespace = "com.glory.voice"
    compileSdk = 36
    // 与构建模板同一个。不写的话 AGP 8.6.1 默认要 34.0.0，会在出包的电脑上自己再下载一份。
    buildToolsVersion = "36.1.0"

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("proguard.txt")
    }

    sourceSets["main"].apply {
        manifest.srcFile("AndroidManifest.xml")
        java.srcDirs("src")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // Godot 的 Java 接口：build_aar.ps1 从本机安卓构建模板的 godot-lib aar 里取出 classes.jar 传进来。
    compileOnly(files(providers.gradleProperty("godotLib").get()))
    compileOnly("io.livekit:livekit-android:2.28.2")
    // LiveKit 在运行时带协程库（1.6.0；Godot 模板那边已经解析到 1.6.4），这里只编译用。
    compileOnly("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.6.4")
}
