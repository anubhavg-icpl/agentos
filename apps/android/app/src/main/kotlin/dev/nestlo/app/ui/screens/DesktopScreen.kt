package dev.nestlo.app.ui.screens

import android.annotation.SuppressLint
import android.content.pm.ActivityInfo
import android.net.http.SslCertificate
import android.net.http.SslError
import android.os.Build
import android.view.ViewGroup
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import dev.nestlo.app.data.Repository
import dev.nestlo.app.ui.components.MechButton
import dev.nestlo.app.ui.components.Status
import dev.nestlo.app.ui.components.StatusLine
import dev.nestlo.core.net.Endpoint
import dev.nestlo.core.net.PinnedTls
import dev.nestlo.core.net.Trust
import java.io.ByteArrayInputStream
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate

/** Extracts the leaf certificate of an SSL error. API 29+ has a direct accessor; older releases expose it via the saved state bundle. */
internal fun SslCertificate.toX509(): X509Certificate? {
    if (Build.VERSION.SDK_INT >= 29) return x509Certificate
    val bytes = SslCertificate.saveState(this)?.getByteArray("x509-certificate") ?: return null
    return try {
        CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(bytes)) as? X509Certificate
    } catch (_: Exception) {
        null
    }
}

/** Decides an SSL error for the WebView: only a pinned endpoint with a matching certificate may proceed. */
internal fun sslDecision(endpoint: Endpoint, fingerprint: ByteArray, error: SslError): Boolean {
    if (endpoint.trust != Trust.PINNED) return false
    val cert = error.certificate?.toX509() ?: return false
    return PinnedTls.fingerprintMatches(cert, fingerprint)
}

@SuppressLint("SetJavaScriptEnabled", "SourceLockedOrientationActivity")
@Composable
fun DesktopScreen(repo: Repository, onBack: () -> Unit) {
    val creds by repo.credentials.collectAsState()
    val c = creds ?: return
    val view = LocalView.current
    val activity = LocalContext.current as? android.app.Activity
    var status by remember { mutableStateOf<Status>(Status.Busy("LOADING DESKTOP")) }
    var landscape by remember { mutableStateOf(false) }

    BackHandler { onBack() }

    // Immersive while the desktop is on screen.
    DisposableEffect(Unit) {
        val window = activity?.window
        val controller = window?.let { WindowCompat.getInsetsController(it, view) }
        controller?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller?.hide(WindowInsetsCompat.Type.systemBars())
        view.keepScreenOn = true
        onDispose {
            controller?.show(WindowInsetsCompat.Type.systemBars())
            view.keepScreenOn = false
            activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    val url = remember(c) {
        c.endpoint.url("/desktop/").newBuilder().addQueryParameter("t", c.token).build().toString()
    }
    val host = c.endpoint.host

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                WebView(ctx).apply {
                    layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                    setBackgroundColor(android.graphics.Color.BLACK)
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.mediaPlaybackRequiresUserGesture = false
                    settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.setSupportZoom(false)
                    if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
                        WebSettingsCompat.setAlgorithmicDarkeningAllowed(settings, false)
                    }
                    webViewClient = object : WebViewClient() {
                        override fun onReceivedSslError(v: WebView, handler: SslErrorHandler, error: SslError) {
                            // WebPKI endpoints get no override. Pinned endpoints proceed only for the paired certificate.
                            if (sslDecision(c.endpoint, c.fingerprint, error)) handler.proceed() else {
                                handler.cancel()
                                status = Status.Error("CERTIFICATE REJECTED")
                            }
                        }

                        override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean =
                            !request.url.host.equals(host, ignoreCase = true)

                        override fun onPageFinished(v: WebView, u: String?) {
                            if (status is Status.Busy) status = Status.None
                        }
                    }
                    loadUrl(url)
                }
            },
            onRelease = { it.stopLoading(); it.destroy() },
        )
        Row(Modifier.align(Alignment.TopStart).padding(8.dp)) {
            MechButton("Back", onClick = onBack)
        }
        Row(Modifier.align(Alignment.TopEnd).padding(8.dp)) {
            MechButton("Rotate", onClick = {
                landscape = !landscape
                activity?.requestedOrientation =
                    if (landscape) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            })
        }
        Box(Modifier.align(Alignment.BottomCenter).padding(12.dp)) { StatusLine(status) }
    }
}
