# Protobuf-lite resolves generated instance fields by the names stored in its
# message schema. R8 must neither remove nor rename those fields. Scope this
# to Espressif's provisioning messages; the app remains minified.
-keepclassmembers class espressif.** extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}
