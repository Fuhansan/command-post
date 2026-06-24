# Default ProGuard rules. Compose / OkHttp / kotlinx.serialization ship their own.
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**

# Keep @Serializable models
-keepclassmembers class * {
    @kotlinx.serialization.SerialName <fields>;
}
