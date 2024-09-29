#include <jni.h>
#include <GLES3/gl3.h>
#include <android/log.h>

// Logging utility
#define LOG_TAG "NativeTriangle"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

// Simple vertex and fragment shader to render a triangle
const char* vertexShaderSource = R"(#version 300 es
    layout (location = 0) in vec4 aPosition;
    void main() {
        gl_Position = aPosition;
    }
)";

const char* fragmentShaderSource = R"(#version 300 es
    precision mediump float;
    out vec4 fragColor;
    void main() {
        fragColor = vec4(1.0, 0.0, 0.0, 1.0); // Red color
    }
)";

// Triangle vertices
GLfloat vertices[] = {
        0.0f,  0.5f, 0.0f,  // Top
        -0.5f, -0.5f, 0.0f,  // Bottom left
        0.5f, -0.5f, 0.0f   // Bottom right
};

GLuint shaderProgram;
GLuint VAO;

// Function to compile a shader
GLuint compileShader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);

    // Check for compilation errors
    GLint success;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
    if (!success) {
        char infoLog[512];
        glGetShaderInfoLog(shader, 512, nullptr, infoLog);
        LOGI("Shader compilation failed: %s", infoLog);
    }
    return shader;
}

// Function to create the OpenGL program
void createProgram() {
    GLuint vertexShader = compileShader(GL_VERTEX_SHADER, vertexShaderSource);
    GLuint fragmentShader = compileShader(GL_FRAGMENT_SHADER, fragmentShaderSource);

    shaderProgram = glCreateProgram();
    glAttachShader(shaderProgram, vertexShader);
    glAttachShader(shaderProgram, fragmentShader);
    glLinkProgram(shaderProgram);

    // Check for linking errors
    GLint success;
    glGetProgramiv(shaderProgram, GL_LINK_STATUS, &success);
    if (!success) {
        char infoLog[512];
        glGetProgramInfoLog(shaderProgram, 512, nullptr, infoLog);
        LOGI("Program linking failed: %s", infoLog);
    }

    glDeleteShader(vertexShader);
    glDeleteShader(fragmentShader);

    // Create a Vertex Array Object (VAO)
    glGenVertexArrays(1, &VAO);
    GLuint VBO;
    glGenBuffers(1, &VBO);

    glBindVertexArray(VAO);

    // Bind and set vertex buffer data
    glBindBuffer(GL_ARRAY_BUFFER, VBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);

    // Set the vertex attribute pointer
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(float), (void*)0);
    glEnableVertexAttribArray(0);

    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindVertexArray(0);
}

// Function to render a frame
extern "C" JNIEXPORT void JNICALL
Java_com_example_aztest_MainActivity_renderFrame(JNIEnv* env, jobject /* this */) {
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(shaderProgram);
    glBindVertexArray(VAO);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindVertexArray(0);
}

extern "C" {
    char* zig_get_string(void);
}

// Function to initialize OpenGL
extern "C" JNIEXPORT void JNICALL
Java_com_example_aztest_MainActivity_initOpenGL(JNIEnv* env, jobject /* this */) {
    LOGI("Application started: %s", zig_get_string());
    createProgram();
}
