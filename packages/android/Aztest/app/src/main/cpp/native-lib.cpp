#include <jni.h>

extern "C"
{
    void zig_init_opengl(void);
    void zig_opengl_renderFrame(void);
}

// Function to render a frame
extern "C" JNIEXPORT void JNICALL
Java_com_example_aztest_MainActivity_renderFrame(JNIEnv* env, jobject /* this */) {
    zig_opengl_renderFrame();
}

// Function to initialize OpenGL
extern "C" JNIEXPORT void JNICALL
Java_com_example_aztest_MainActivity_initOpenGL(JNIEnv* env, jobject /* this */) {
    zig_init_opengl();
}
