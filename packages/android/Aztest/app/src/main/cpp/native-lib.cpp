#include <jni.h>
#include <android/log.h>

static int redirectStdoutToLogcat();

extern "C"
{
    void zig_init_opengl(void);
    void zig_opengl_renderFrame(void);
    void zig_resize(int32_t w, int32_t h);
    bool zig_wantShowKeyboard();
}

// Function to render a frame
extern "C" JNIEXPORT void JNICALL
Java_com_example_aztest_MainActivity_renderFrame(JNIEnv* env, jobject /* this */) {
    __android_log_write(ANDROID_LOG_ERROR, "Tag", "renderFrame call");//Or ANDROID_LOG_INFO, ...
    zig_opengl_renderFrame();
}

// Function to initialize OpenGL
extern "C" JNIEXPORT void JNICALL
Java_com_example_aztest_MainActivity_initOpenGL(JNIEnv* env, jobject /* this */) {
    redirectStdoutToLogcat();
    zig_init_opengl();
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_aztest_MainActivity_resize(JNIEnv* env, jobject /* this */, jint w, jint h) {
    zig_resize(w, h);
}

#include <pthread.h>
#include <unistd.h>
#include <cstdio>

static int pfd[2];
static pthread_t loggingThread;
static const char *LOG_TAG = "YOU APP LOG TAG";

static void *loggingFunction(void*) {
    ssize_t readSize;
    char buf[128];

    while((readSize = read(pfd[0], buf, sizeof buf - 1)) > 0) {
        if(buf[readSize - 1] == '\n') {
            --readSize;
        }

        buf[readSize] = 0;  // add null-terminator

        __android_log_write(ANDROID_LOG_DEBUG, LOG_TAG, buf); // Set any log level you want
    }

    return nullptr;
}

static int redirectStdoutToLogcat() { // run this function to redirect your output to android log
    setvbuf(stdout, nullptr, _IOLBF, 0); // make stdout line-buffered
    setvbuf(stderr, nullptr, _IONBF, 0); // make stderr unbuffered

    /* create the pipe and redirect stdout and stderr */
    pipe(pfd);
    dup2(pfd[1], 1);
    dup2(pfd[1], 2);

    /* spawn the logging thread */
    if(pthread_create(&loggingThread, 0, loggingFunction, 0) != 0) {
        return -1;
    }

    pthread_detach(loggingThread);

    return 0;
}
