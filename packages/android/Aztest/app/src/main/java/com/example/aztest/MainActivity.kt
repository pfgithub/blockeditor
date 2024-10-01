package com.example.aztest

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.opengl.GLSurfaceView
import android.os.Bundle
import android.text.InputType
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.view.inputmethod.TextAttribute


class MainActivity : Activity() {

    private lateinit var glView: GLSurfaceView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Initialize the GLSurfaceView
        glView = MyGLSurfaceView(this)
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
    }
}

class MyGLSurfaceView(context: Activity) : GLSurfaceView(context) {

    init {
        // Request focus initially
        isFocusable = true
        isFocusableInTouchMode = true
        requestFocus()
    }

    // Our view contains a custom UI, so this lint isn't helpful.
    // Eventually, we will need to add proper screen reader support to the
    // view by having beui maintain an accessibility tree and sending it
    // to the view or something.
    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        // x: event.x, y: event.y, pointer_id: event.getPointerId(event.actionIndex)?

        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                // var button_state = event.buttonState
                // ^ if the pointer is a mouse, this will tell you if it's a right click / middle click

                val inputMethodManager = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                inputMethodManager.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
            }
            MotionEvent.ACTION_UP -> {}
            MotionEvent.ACTION_MOVE -> {}

            // it was determined that this touch event does not belong to us
            MotionEvent.ACTION_CANCEL -> {}
        }
        return true
    }

    override fun onCheckIsTextEditor(): Boolean {
        // says to automatically open a keyboard
        return true
    }


    // IME docs:
    // https://developer.android.com/reference/android/view/inputmethod/InputConnection#implementing-an-ime-or-an-editor
    // our editor needs to handle this to get nice stuff like swipe typing, drag delete, and support for other languages that use IMEs
    // override fun onCreateInputConnection(outAttrs: EditorInfo?): InputConnection {
    //     // sets the keyboard type to be text, which allows swipe typing and regular input
    //     // in the future, beui should be able to configure this
    //     val editorInfo = outAttrs ?: EditorInfo()
    //     editorInfo.inputType = InputType.TYPE_CLASS_TEXT
    //     return CustomInputConnection(this, false)
    // }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        // some key events are only sent through these fns? and some are sent through these
        // fns but actually are ime events and these should be ignored???
        Log.d("CustomInputConnection", "keyDown: $keyCode, $event")
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        Log.d("CustomInputConnection", "keyUp: $keyCode, $event")
        return super.onKeyUp(keyCode, event)
    }
}
