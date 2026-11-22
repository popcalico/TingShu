package cn.tingshu.app

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 夸克网盘登录页（原生 WebView）。
 *
 * 为什么要用原生：夸克的关键 Cookie（__puus / __pus）是 HttpOnly，
 * 网页脚本读不到，只能通过原生 CookieManager 取。用系统 WebView 最省事，
 * 也不用引入体积大、还容易跟 AGP 版本打架的第三方 WebView 插件。
 *
 * 登录成功后把整条 Cookie 串回传给 Dart 侧保存。
 */
class QuarkLoginActivity : Activity() {

    private var web: WebView? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#F7F6F3"))
        }

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(12), dp(12), dp(12))
        }

        val title = TextView(this).apply {
            text = "登录夸克网盘"
            textSize = 20f
            setTextColor(Color.parseColor("#1A1A1A"))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f)
        }

        val done = Button(this).apply {
            text = "我登好了"
            textSize = 16f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#16558F"))
            setPadding(dp(18), dp(10), dp(18), dp(10))
            setOnClickListener { finishWithCookie() }
        }

        bar.addView(title)
        bar.addView(done)
        root.addView(bar, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        val tip = TextView(this).apply {
            text = "用手机号验证码登录。如果页面让你下载 App，点页面上的「密码登录 / 验证码登录」"
            textSize = 14f
            setTextColor(Color.parseColor("#55534E"))
            setPadding(dp(16), 0, dp(16), dp(10))
        }
        root.addView(tip, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        web = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.loadWithOverviewMode = true
            settings.useWideViewPort = true
            // 关键：必须用桌面版 UA。
            // 用移动端 UA 打开 pan.quark.cn，夸克会判定为手机浏览器，
            // 直接给一个"下载夸克 App"的引导页，根本没有登录入口。
            settings.userAgentString =
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
            // 桌面版页面在手机上偏小，允许双指缩放，方便老人家属看清按钮
            settings.builtInZoomControls = true
            settings.displayZoomControls = false
            settings.textZoom = 115
            webViewClient = WebViewClient()
            CookieManager.getInstance().setAcceptCookie(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            }
            loadUrl("https://pan.quark.cn/")
        }
        root.addView(web, LinearLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))

        setContentView(root)
    }

    private fun finishWithCookie() {
        val cookie = CookieManager.getInstance().getCookie("https://pan.quark.cn") ?: ""
        val hasLogin = cookie.contains("__puus=") || cookie.contains("__pus=")
        setResult(
            if (hasLogin) RESULT_OK else RESULT_CANCELED,
            Intent().putExtra("cookie", cookie),
        )
        finish()
    }

    override fun onBackPressed() {
        val w = web
        if (w != null && w.canGoBack()) {
            w.goBack()
            return
        }
        setResult(RESULT_CANCELED)
        finish()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
}
