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

        // Set EGLConfigChooser to request alpha channel
        glView.setEGLConfigChooser(8, 8, 8, 8, 16, 0) // RGBA 8-bit channels, 16-bit depth, 0 stencil

        glView.setRenderer(MyGLRenderer(this)) // Pass the activity

        glView.holder.setFormat(android.graphics.PixelFormat.TRANSLUCENT) // Enable transparency
        glView.setZOrderOnTop(true) // Set the surface to be on top of the window


        setContentView(glView)
    }

    external fun initOpenGL()
    external fun renderFrame()
    external fun resize(w: Int, h: Int)

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
        activity.resize(width, height)
        GLES30.glViewport(0, 0, width, height)
    }
}
