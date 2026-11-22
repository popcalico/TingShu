package cn.tingshu.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.provider.MediaStore
import android.util.Log
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 听评书的主 Activity。
 *
 * 只保留三件老人真正用得上的原生能力：
 * 1. 音频焦点：来电话、导航播报时自动暂停，打断结束自动续播；
 * 2. 拔耳机/蓝牙断开自动暂停（AUDIO_BECOMING_NOISY）；
 * 3. 存储空间查询 + 电池优化白名单，保证锁屏后不被系统杀掉。
 */
class MainActivity : AudioServiceActivity() {

    private var audioManager: AudioManager? = null
    private var focusCallback: EventChannel.EventSink? = null
    private var focusRequest: AudioFocusRequest? = null

    /// 正在等待登录结果的 Dart 调用
    private var pendingLogin: MethodChannel.Result? = null

    /// 正在等待通知权限结果的 Dart 调用
    private var pendingNotify: MethodChannel.Result? = null

    /// 登录页返回：把 Cookie 交回 Dart 侧
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_QUARK_LOGIN) return
        val cookie = data?.getStringExtra("cookie")
        pendingLogin?.success(
            if (resultCode == android.app.Activity.RESULT_OK) cookie else null
        )
        pendingLogin = null
    }

    /// Android 13+ 的通知权限回调。没这个回调，Dart 侧会一直以为"已授权"，
    /// 于是永远不去引导用户打开通知，通知栏就一直是空的。
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFY) {
            pendingNotify?.success(hasNotifyPermission())
            pendingNotify = null
        }
    }

    private fun hasNotifyPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return checkSelfPermission("android.permission.POST_NOTIFICATIONS") ==
            PackageManager.PERMISSION_GRANTED
    }

    private companion object {
        const val REQ_QUARK_LOGIN = 1001
        const val REQ_NOTIFY = 1002

        /** 必须和 main.dart 里 AudioServiceConfig 的 channelId 完全一致 */
        const val CHANNEL_AUDIO = "cn.tingshu.audio.v2"

        /** 旧渠道（audio_service 用 LOW 建的），升级后废弃 */
        const val CHANNEL_AUDIO_OLD = "cn.tingshu.audio"

        const val TAG = "TingShu"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureAudioChannel()
    }

    /// 抢在 audio_service 之前把播放通知的渠道建好。
    ///
    /// 插件内部固定用 `IMPORTANCE_LOW` 建渠道，而 LOW 在小米/华为/OPPO 上
    /// 会被当成"次要通知"：锁屏不显示、通知栏不给按钮。用户看到的
    /// 就是"媒体控件不好使"。插件建渠道前会先查有没有同名渠道，
    /// 有就跳过，所以这里先建好就能顶掉它的 LOW。
    ///
    /// 从老版本升上来的手机，渠道已经是 LOW 了——而 Android 不允许改已有渠道的重要性
    /// （用户设置优先），删掉重建也会被系统记住"这个 ID 被删过"而不恢复。
    /// 所以直接换一个新的渠道 ID（v2），旧渠道顺手删掉，免得设置里看到两条。
    private fun ensureAudioChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.deleteNotificationChannel(CHANNEL_AUDIO_OLD)
            val channel = NotificationChannel(
                CHANNEL_AUDIO,
                "评书播放",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "正在播放的评书，可暂停、上一回、下一回"
                setShowBadge(false)
                // 播放控制不该"叮"一声，也不该震；重要性靠 DEFAULT 保住锁屏可见
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(channel)
        } catch (_: Exception) {
            // 渠道建不起来不致命，插件会退回它自己的 LOW
        }
    }

    /** 拔耳机 / 蓝牙断开：系统广播，通知 Dart 侧暂停 */
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                focusCallback?.success("noisy")
            }
        }
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> focusCallback?.success("gained")
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> focusCallback?.success("interrupted")
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> focusCallback?.success("ducked")
            AudioManager.AUDIOFOCUS_LOSS -> focusCallback?.success("lost")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        try {
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(noisyReceiver, filter)
            }
        } catch (_: Exception) {
            // 个别 ROM 限制注册，忽略
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tingshu/focus")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> result.success(requestFocus())
                    "abandon" -> {
                        abandonFocus(); result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "tingshu/focus_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    focusCallback = events
                }

                override fun onCancel(arguments: Any?) {
                    focusCallback = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tingshu/quark_login")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "login" -> {
                        if (pendingLogin != null) {
                            pendingLogin?.error("busy", "登录页已经打开了", null)
                        }
                        pendingLogin = result
                        try {
                            startActivityForResult(
                                Intent(this, QuarkLoginActivity::class.java),
                                REQ_QUARK_LOGIN,
                            )
                        } catch (e: Exception) {
                            pendingLogin = null
                            result.error("launch_failed", "${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tingshu/app_info")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> {
                        try {
                            val pm = packageManager
                            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                pm.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
                            } else {
                                @Suppress("DEPRECATION")
                                pm.getPackageInfo(packageName, 0)
                            }
                            @Suppress("DEPRECATION")
                            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                info.longVersionCode.toInt()
                            } else {
                                info.versionCode
                            }
                            result.success(mapOf("versionCode" to code, "versionName" to info.versionName))
                        } catch (e: Exception) {
                            result.error("info_failed", "${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 清除全部数据（模拟新机）：
        // 家属在设置页用。清完立刻重启进程，回到"第一次打开"的样子。
        // 只清本应用自己的数据，不动系统授权（通知/后台/安装权限还在）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tingshu/wipe")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "clearAll" -> {
                        try {
                            wipeAllData()
                            result.success(true)
                            // 这里只负责"把磁盘上的东西删掉"。
                            // 界面怎么回到新机状态交给 Dart 侧：
                            // 重建 Activity / 杀进程重启在 Android 10+ 都会被
                            // 后台启动限制或引擎生命周期坑到（实测停在桌面，
                            // 用户会以为闪退）。Dart 侧清空内存状态后直接跳首次配置页，
                            // 是唯一稳定可控的路。
                        } catch (e: Exception) {
                            result.error("wipe_failed", "${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 书架/设置的自动备份。
        //
        // 为什么放到公共目录，而不是应用私有目录：
        // 更新尤其是鸿蒙"卓易通"这类容器里更新，可能整包重装、私有数据全清，
        // 私有目录里的备份会跟着一起没。公共下载目录能活下来。
        // 只备份书架、进度和设置——**不备份夸克 Cookie**，那是账号凭证，
        // 落到公共目录等于把账号摆在明面上。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tingshu/backup")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "write" -> {
                        val text = call.argument<String>("text") ?: ""
                        result.success(writeBackup(text))
                    }
                    "read" -> result.success(readBackup())
                    "info" -> result.success(backupInfo())
                    "delete" -> result.success(deleteBackup())
                    else -> result.notImplemented()
                }
            }

        // 安装下载好的新版本 APK
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tingshu/installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(canRequestInstall())
                    "openInstallPermission" -> {
                        openInstallPermission()
                        result.success(true)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "缺少安装包路径", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(path)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("install_failed", "${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tingshu/notify")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "has" -> result.success(hasNotifyPermission())
                    // 媒体控件自检：通知栏/锁屏不显示播放控制时，
                    // 到底是权限没给、总开关被关，还是"评书播放"这个类别被关了，
                    // 一次查清，别再靠猜。
                    "diagnose" -> {
                        try {
                            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            val channel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                nm.getNotificationChannel(CHANNEL_AUDIO)
                            } else null
                            result.success(
                                mapOf(
                                    "permission" to hasNotifyPermission(),
                                    "enabled" to nm.areNotificationsEnabled(),
                                    "channelExists" to (channel != null),
                                    "channelImportance" to (channel?.importance ?: -1),
                                    "sdk" to Build.VERSION.SDK_INT,
                                    "brand" to Build.BRAND,
                                    "model" to Build.MODEL,
                                )
                            )
                        } catch (e: Exception) {
                            result.error("diagnose_failed", "${e.message}", null)
                        }
                    }
                    "request" -> {
                        if (hasNotifyPermission()) {
                            result.success(true)
                        } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                            result.success(true)
                        } else {
                            pendingNotify = result
                            requestPermissions(
                                arrayOf("android.permission.POST_NOTIFICATIONS"),
                                REQ_NOTIFY
                            )
                        }
                    }
                    // 发一条普通通知，用播放通知同一个渠道。
                    // 用户能在通知栏看到 → 权限和渠道都没问题，问题在媒体会话那边；
                    // 看不到 → 就是通知被系统/ROM 拦了，不用再折腾播放逻辑。
                    "test" -> {
                        try {
                            ensureAudioChannel()
                            val n = androidx.core.app.NotificationCompat.Builder(this, CHANNEL_AUDIO)
                                .setSmallIcon(R.drawable.ic_stat_tingshu)
                                .setContentTitle("通知能看见")
                                .setContentText("说明通知权限和渠道都正常")
                                .setStyle(
                                    androidx.core.app.NotificationCompat.BigTextStyle()
                                        .bigText("说明通知权限和渠道都正常。如果这条能看到，但播放时没有媒体控件，那就是系统把媒体卡片藏起来了。")
                                )
                                .setPriority(androidx.core.app.NotificationCompat.PRIORITY_DEFAULT)
                                .setAutoCancel(true)
                                .build()
                            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            nm.notify(9911, n)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("test_failed", "${e.message}", null)
                        }
                    }
                    // 用户拒过之后系统不再弹框，只能引导去设置页手动打开
                    "openSettings" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tingshu/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "freeBytes" -> {
                        try {
                            val path = call.argument<String>("path")
                            val stat = if (path.isNullOrBlank()) StatFs(filesDir.absolutePath) else StatFs(path)
                            result.success(stat.availableBytes)
                        } catch (_: Exception) {
                            result.success(-1L)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tingshu/battery")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isIgnoring" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestIgnore" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName"),
                                ),
                            )
                        } catch (_: Exception) {
                            try {
                                startActivity(Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS))
                            } catch (_: Exception) {
                            }
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ---------- 书架备份（公共下载目录） ----------

    private fun backupDirName(): String = "听评书"

    private fun backupFileName(): String = "听评书-备份.json"

    /// 主备份位置：`/sdcard/Android/media/<包名>/听评书/`。
    ///
    /// 这个目录应用**可以直读直写**、不需要任何权限，而且清除应用数据时
    /// 通常不会被删（它在"共享媒体目录"下，不属于 Android/data 那种私有目录）。
    /// 用它当主备份，比 MediaStore 记录更可靠——`pm clear` 之后
    /// MediaStore 里那条记录会消失，文件却还在，结果就是"备份在、查不到"。
    private fun mediaBackupFile(): File? {
        return try {
            val base = externalMediaDirs?.firstOrNull() ?: return null
            val dir = File(base, backupDirName())
            File(dir, backupFileName())
        } catch (_: Exception) {
            null
        }
    }

    /// 副备份：公共下载目录（家属能在文件管理器里看到，也方便拷到新手机）
    private fun legacyBackupFile(): File? {
        return try {
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                backupDirName(),
            )
            File(dir, backupFileName())
        } catch (_: Exception) {
            null
        }
    }

    private fun findBackupUri(): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val projection = arrayOf(MediaStore.Downloads._ID)
            val selection = "${MediaStore.Downloads.DISPLAY_NAME}=?"
            contentResolver.query(
                collection, projection, selection, arrayOf(backupFileName()), null
            )?.use { c ->
                if (c.moveToFirst()) ContentUris.withAppendedId(collection, c.getLong(0)) else null
            }
        } catch (e: Exception) {
            Log.w(TAG, "查询下载目录备份失败: ${e.message}")
            null
        }
    }

    private fun writeBackup(text: String): Boolean {
        val bytes = text.toByteArray(Charsets.UTF_8)
        var ok = false

        // 1) 主备份：Android/media/<包名>，直读直写
        try {
            val f = mediaBackupFile()
            if (f != null) {
                f.parentFile?.mkdirs()
                f.writeBytes(bytes)
                ok = true
            }
        } catch (e: Exception) {
            Log.w(TAG, "写主备份失败: ${e.message}")
        }

        // 2) 副备份：下载/听评书（给家属看、方便迁移）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val existing = findBackupUri()
                if (existing != null) {
                    contentResolver.openOutputStream(existing, "wt")?.use { it.write(bytes) }
                } else {
                    val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
                    val values = ContentValues().apply {
                        put(MediaStore.Downloads.DISPLAY_NAME, backupFileName())
                        put(MediaStore.Downloads.MIME_TYPE, "application/json")
                        put(
                            MediaStore.Downloads.RELATIVE_PATH,
                            "${Environment.DIRECTORY_DOWNLOADS}/${backupDirName()}"
                        )
                        put(MediaStore.Downloads.IS_PENDING, 1)
                    }
                    val uri = contentResolver.insert(collection, values)
                    if (uri != null) {
                        contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                        val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
                        contentResolver.update(uri, done, null, null)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "写副备份失败: ${e.message}")
            }
        } else {
            try {
                val f = legacyBackupFile()
                if (f != null) {
                    f.parentFile?.mkdirs()
                    f.writeBytes(bytes)
                }
            } catch (_: Exception) {
            }
        }

        Log.i(TAG, "备份写入 ${if (ok) "成功" else "失败"}（${bytes.size} 字节）")
        return ok
    }

    private fun readBackup(): String? {
        // 1) 主备份
        try {
            val f = mediaBackupFile()
            if (f != null && f.exists() && f.length() > 0) {
                return f.readText()
            }
        } catch (e: Exception) {
            Log.w(TAG, "读主备份失败: ${e.message}")
        }

        // 2) 公共下载目录里的那份（MediaStore 记录可能已经没了，直接按路径读）
        try {
            val f = legacyBackupFile()
            if (f != null && f.exists() && f.length() > 0) {
                return f.readText()
            }
        } catch (e: Exception) {
            Log.w(TAG, "读下载目录备份失败: ${e.message}")
        }

        // 3) 最后再走一次 MediaStore（Android 10+ 且记录还在时）
        return try {
            val uri = findBackupUri() ?: return null
            contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore 读备份失败: ${e.message}")
            null
        }
    }

    private fun backupInfo(): Map<String, Any> {
        val f = try {
            mediaBackupFile()?.takeIf { it.exists() } ?: legacyBackupFile()?.takeIf { it.exists() }
        } catch (_: Exception) {
            null
        }
        if (f != null) {
            return mapOf("exists" to true, "modified" to f.lastModified())
        }
        // 再看 MediaStore（文件被挪动过的情况）
        return try {
            val uri = findBackupUri() ?: return mapOf("exists" to false, "modified" to 0L)
            var modified = 0L
            contentResolver.query(
                uri, arrayOf(MediaStore.Downloads.DATE_MODIFIED), null, null, null
            )?.use { c ->
                if (c.moveToFirst()) modified = c.getLong(0) * 1000L
            }
            mapOf("exists" to true, "modified" to modified)
        } catch (_: Exception) {
            mapOf("exists" to false, "modified" to 0L)
        }
    }

    private fun deleteBackup(): Boolean {
        var ok = true
        try {
            mediaBackupFile()?.delete()
        } catch (_: Exception) {
            ok = false
        }
        try {
            legacyBackupFile()?.delete()
        } catch (_: Exception) {
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val uri = findBackupUri()
                if (uri != null) contentResolver.delete(uri, null, null)
            }
        } catch (_: Exception) {
        }
        return ok
    }

    /// 清掉本应用的全部本地数据。
    ///
    /// 覆盖四处：
    /// 1. `shared_prefs` —— 书架、听到哪儿、夸克登录、更新设置（插件都写在这里）
    /// 2. `databases` —— 目前没用到，防御性清理
    /// 3. 内部 `files` / `cache`
    /// 4. 外部私有目录 —— 音频缓存 `ting_audio`、下载的安装包 `update`
    ///
    /// 不删目录本身，删完再 mkdirs 一次：有些系统组件会在目录消失后写失败。
    private fun wipeAllData() {
        File(dataDir, "shared_prefs").deleteRecursively()
        File(dataDir, "databases").deleteRecursively()
        filesDir?.deleteRecursively()
        cacheDir?.deleteRecursively()
        getExternalFilesDir(null)?.deleteRecursively()

        filesDir?.mkdirs()
        cacheDir?.mkdirs()
        getExternalFilesDir(null)?.mkdirs()

        // 公共目录里的备份也要删：否则下次启动发现"数据是空的"，
        // 会立刻把刚清掉的书架恢复回来，用户会以为清除没生效。
        deleteBackup()
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(noisyReceiver)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    /// 是否已允许"安装未知来源应用"（Android 8.0+）
    private fun canRequestInstall(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /// 跳到系统的"允许安装未知应用"开关页
    private fun openInstallPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ),
            )
        } catch (_: Exception) {
        }
    }

    /// 调起系统安装器。新 APK 必须用 FileProvider 暴露，直接给 file:// 在 7.0+ 会抛异常。
    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) throw IllegalStateException("安装包不见了，请重新下载")
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun requestFocus(): Boolean {
        val am = audioManager ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener)
                .setAcceptsDelayedFocusGain(true)
                .build()
            focusRequest = request
            val r = am.requestAudioFocus(request)
            r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED || r == AudioManager.AUDIOFOCUS_REQUEST_DELAYED
        } else {
            val r = am.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
            r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonFocus() {
        val am = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest ?: return
            am.abandonAudioFocusRequest(request)
            focusRequest = null
        } else {
            am.abandonAudioFocus(focusListener)
        }
    }
}
