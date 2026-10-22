// GlorySignIn 安卓桥接：用 Google 登录（docs/三方登录设计.md 第六节）。
//
// 只由 build_aar.ps1 调用：它把这个目录拷到纯英文的临时目录再跑 Gradle（这台机器的 Java 工具
// 打不开带中文的路径），然后把 aar 放到 addons/glory_signin/bin/GlorySignIn.aar。
//
// 工具链版本同 android_plugins/glory_voice（= Godot 4.7.1 安卓构建模板）：AGP 8.6.1、Kotlin 2.1.21、
// compileSdk 36、minSdk 24、Java 17。
//
// 依赖全部 compileOnly：插件 aar 里只有我们自己的类。真正打进 APK 的那份由导出插件
// （addons/glory_signin/glory_signin_plugin.gd 的 DEPENDENCIES）交给出包时的 Gradle。
// 两处的版本号必须一样，tools/account_provider_check 对账。
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library") version "8.6.1"
    id("org.jetbrains.kotlin.android") version "2.1.21"
}

android {
    namespace = "com.glory.signin"
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
    compileOnly("androidx.credentials:credentials:1.5.0")
    compileOnly("androidx.credentials:credentials-play-services-auth:1.5.0")
    compileOnly("com.google.android.libraries.identity.googleid:googleid:1.1.1")
    // GoogleApiAvailability。运行时由上面的 play-services-auth 带进来，这里只编译用。
    compileOnly("com.google.android.gms:play-services-base:18.5.0")
    compileOnly("androidx.core:core:1.13.1")
}
