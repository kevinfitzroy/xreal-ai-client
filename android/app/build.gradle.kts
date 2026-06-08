import java.util.Properties
import java.io.FileInputStream

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

// release 签名:口令在 android/keystore.properties(gitignored,绝不进 git)。
// 缺文件时下面 signingConfig 回退到 debug,别的机器/CI 无 keystore 也能 build。
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply { if (keystorePropsFile.exists()) load(FileInputStream(keystorePropsFile)) }

android {
    namespace = "io.github.kevinfitzroy.xrealclient"
    compileSdk = 34

    defaultConfig {
        applicationId = "io.github.kevinfitzroy.xrealclient"
        minSdk = 34
        targetSdk = 34
        versionCode = 4
        versionName = "0.4.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        create("release") {
            if (keystorePropsFile.exists()) {
                storeFile = file(keystoreProps["storeFile"] as String)
                storePassword = keystoreProps["storePassword"] as String
                keyAlias = keystoreProps["keyAlias"] as String
                keyPassword = keystoreProps["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (keystorePropsFile.exists()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isDebuggable = true
        }
    }

    buildFeatures {
        buildConfig = true   // 供 BuildConfig.DEBUG 门控调试输入直通(DebugInputServer)
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true   // 让 JVM 单测里未 mock 的 android.util.Log 返回默认值而非抛
    }

    packaging {
        resources {
            // sshj / BouncyCastle 常带这些 META-INF 重复文件
            excludes += setOf(
                "META-INF/AL2.0",
                "META-INF/LGPL2.1",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "META-INF/INDEX.LIST",
                "META-INF/io.netty.versions.properties",
            )
        }
    }
}

dependencies {
    implementation(libs.androidx.activity.ktx)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.webkit)
    implementation(libs.kotlinx.coroutines.android)

    // SSH-over-443 隧道(可选):xray-bridge 的 gomobile 产物(从官方 xray-core 自建,见 xray-bridge/build.sh)。
    // 缺 aar 也能编译(fileTree 命中 0 个文件)→ 未 build 隧道功能时不阻塞普通构建。
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar", "*.jar"))))

    // SSH(0.2):sshj 主推,sshlib 是 Stage A.2 fallback
    implementation(libs.sshj)
    implementation(libs.bouncycastle.prov)
    implementation(libs.bouncycastle.pkix)
    implementation(libs.eddsa)
    implementation(libs.slf4j.android)

    // HTTP(B.3 豆包 ASR)
    implementation(libs.okhttp)

    // JVM 单测(S.3:AgentStatusDetector parser,不依赖 emulator/device)
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20231013")   // 单测用真 org.json(android.jar 里的是会抛的 stub)
}
