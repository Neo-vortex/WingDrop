# The C++ engine calls these by name through JNI (see src/main/cpp/jni.cpp);
# R8 cannot see those calls, so keep the class and all of its members as-is.
-keep class ir.neovortex.wingdrop.NativeEngine { *; }
