package mpvuiexample.module

import android.app.Application
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import skip.foundation.ProcessInfo
import skip.ui.*

class AndroidAppMain : Application() {
    override fun onCreate() {
        super.onCreate()
        ProcessInfo.launch(applicationContext)
    }
}

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        UIApplication.launch(this)
        enableEdgeToEdge()
        setContent {
            PresentationRoot(defaultColorScheme = ColorScheme.dark, context = ComposeContext()) { context ->
                Box(modifier = Modifier.fillMaxSize()) {
                    MPVUIExampleRootView().Compose(context = context.content())
                }
            }
        }
    }
}
