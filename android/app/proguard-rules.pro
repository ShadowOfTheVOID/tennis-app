# LiteRT-LM is called from native code and uses reflection for JSON.
-keep class com.google.ai.edge.litertlm.** { *; }
-dontwarn com.google.ai.edge.litertlm.**
# Serialized history/coach models.
-keep class com.servecoach.analysis.** { *; }
