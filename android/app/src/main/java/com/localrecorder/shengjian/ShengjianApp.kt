package com.localrecorder.shengjian

import android.app.Application

class ShengjianApp : Application() {
    lateinit var controller: SessionController
        private set

    override fun onCreate() {
        super.onCreate()
        controller = SessionController(this)
    }
}
