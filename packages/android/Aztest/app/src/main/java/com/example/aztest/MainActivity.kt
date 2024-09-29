package com.example.aztest

import android.app.Activity
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import android.os.Bundle

class MainActivity : Activity() {

    private lateinit var glView: GLSurfaceView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Initialize the GLSurfaceView
        glView = GLSurfaceView(this)
        glView.setEGLContextClientVersion(3)
        glView.setRenderer(MyGLRenderer(this)) // Pass the activity
        setContentView(glView)
    }

    external fun initOpenGL()
    external fun renderFrame()

    companion object {
        init {
            System.loadLibrary("aztest")
        }
    }
}

class MyGLRenderer(private val activity: MainActivity) : GLSurfaceView.Renderer {
    override fun onSurfaceCreated(gl: javax.microedition.khronos.opengles.GL10?, config: javax.microedition.khronos.egl.EGLConfig?) {
        activity.initOpenGL() // Use the passed activity reference
    }

    override fun onDrawFrame(gl: javax.microedition.khronos.opengles.GL10?) {
        activity.renderFrame() // Use the passed activity reference
    }

    override fun onSurfaceChanged(gl: javax.microedition.khronos.opengles.GL10?, width: Int, height: Int) {
        // Set viewport size
        GLES30.glViewport(0, 0, width, height)
    }
}
