package com.aicodingremote.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.CreationExtras
import com.aicodingremote.app.app.AppState
import com.aicodingremote.app.app.RootScreen
import com.aicodingremote.app.designsystem.RemoteCodingTheme
import com.aicodingremote.app.networking.RelayClient
import com.aicodingremote.app.networking.UpdateChecker

class MainActivity : ComponentActivity() {

    private val appState: AppState by viewModels {
        object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T {
                val store = (application as RemoteCodingApp).secureStore
                return AppState(store) as T
            }
        }
    }

    private val relay: RelayClient by viewModels()

    // AndroidViewModel:默认工厂会注入 Application,无需自定义 Factory。
    private val updater: UpdateChecker by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            RemoteCodingTheme {
                RootScreen(appState = appState, relay = relay, updater = updater)
            }
        }
    }
}
