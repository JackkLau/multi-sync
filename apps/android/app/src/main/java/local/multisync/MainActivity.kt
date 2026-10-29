package local.multisync

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ClipDescription
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.os.PersistableBundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.journeyapps.barcodescanner.CaptureActivity
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream

class ScannerActivity : CaptureActivity()

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = Color(0xff096c74), onPrimary = Color.White,
                background = Color(0xfff4f8f9), surface = Color.White, onSurface = Color(0xff183238))) {
                MultiSyncScreen()
            }
        }
    }
}

@Composable
private fun MultiSyncScreen(model: TransferModel = viewModel()) {
    val state by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var exportTask by remember { mutableStateOf<ReceivedTask?>(null) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments(), model::importFiles)
    val qrImage = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { it?.let(model::importQRCode) }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        if (uri != null) exportTask?.let { model.export(it, uri) }
        exportTask = null
    }
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        if (result.contents != null) model.useInvitation(result.contents)
        else model.notice("扫描已取消。也可以从二维码图片识别，或主动粘贴接收码。")
    }
    var cameraExplanation by remember { mutableStateOf(false) }
    if (cameraExplanation) AlertDialog(onDismissRequest = { cameraExplanation = false },
        title = { Text("扫描接收二维码") }, text = { Text("摄像头仅用于在本机识别二维码，不录制或上传画面。请将另一台设备的接收二维码放在取景框内。") },
        confirmButton = { TextButton(onClick = {
            cameraExplanation = false
            scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setBeepEnabled(false)
                .setOrientationLocked(false).setCaptureActivity(ScannerActivity::class.java).setPrompt("扫描对方的 MultiSync 接收二维码"))
        }) { Text("开启摄像头") } }, dismissButton = { TextButton(onClick = { cameraExplanation = false }) { Text("取消") } })

    fun share(file: File, mime: String, open: Boolean = false) {
        runCatching {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
            val intent = if (open) Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime) else
                Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, uri)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.clipData = ClipData.newUri(context.contentResolver, "MultiSync", uri)
            context.startActivity(Intent.createChooser(intent, if (open) "打开接收文件" else "分享文件"))
        }.onFailure { model.notice("没有可处理此文件的应用，请尝试另存到文件。") }
    }
    fun shareQr() {
        val ticket = state.receiveTicket
        if (ticket.isBlank()) return
        scope.launch {
            runCatching {
                val file = withContext(Dispatchers.IO) {
                    val dir = File(context.cacheDir, "shared-qr").apply { mkdirs() }
                    val file = File(dir, "MultiSync-receive.png")
                    val image = QRImages.render(ticket)
                    try { FileOutputStream(file).use { image.compress(Bitmap.CompressFormat.PNG, 100, it) } }
                    finally { image.recycle() }
                    file
                }
                share(file, "image/png")
            }.onFailure { model.notice(it.message ?: "无法生成二维码图片") }
        }
    }

    Scaffold(containerColor = MaterialTheme.colorScheme.background) { insets ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(insets)) {
            val tablet = maxWidth >= 720.dp
            Row(Modifier.fillMaxSize()) {
                if (tablet) NavigationRail(containerColor = Color.White) {
                    Spacer(Modifier.height(24.dp)); Text("MultiSync", style = MaterialTheme.typography.titleLarge)
                    Spacer(Modifier.height(24.dp))
                    NavigationRailItem(selected = state.section == 0, onClick = { model.section(0) }, icon = { Text("↑") }, label = { Text("发送文件") })
                    NavigationRailItem(selected = state.section == 1, onClick = { model.section(1) }, icon = { Text("↓") }, label = { Text("接收文件") })
                }
                Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState())
                    .padding(horizontal = if (tablet) 32.dp else 18.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text("MultiSync", style = MaterialTheme.typography.headlineMedium)
                    Text("同一网络 · 保留原件", color = Color(0xff54696e))
                    if (!tablet) Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        FilterChip(selected = state.section == 0, onClick = { model.section(0) }, label = { Text("发送文件") })
                        FilterChip(selected = state.section == 1, onClick = { model.section(1) }, label = { Text("接收文件") })
                    }
                    Text("手机切到后台时收发会暂停，回来后可继续。", style = MaterialTheme.typography.bodySmall)
                    if (state.notice.isNotBlank()) Card(colors = CardDefaults.cardColors(containerColor = Color(0xffe2f0f1))) {
                        Column(Modifier.padding(16.dp)) { Text(state.notice); TextButton(onClick = { model.notice("") }) { Text("关闭提示") } }
                    }
                    if (!state.engineAvailable) Text("传输引擎未打包，无法收发。请安装完整构建的 APK。", color = MaterialTheme.colorScheme.error)
                    if (state.section == 0) {
                        SurfaceCard("连接接收设备") {
                            Text(if (state.destinationHost.isBlank()) "先扫描对方接收页的二维码" else "已识别接收设备：${state.destinationHost}")
                            Button(onClick = { cameraExplanation = true }, enabled = !state.importing && state.engineAvailable, modifier = Modifier.fillMaxWidth()) { Text("扫码连接") }
                            OutlinedButton(onClick = { qrImage.launch(arrayOf("image/*")) }, enabled = !state.importing && state.engineAvailable, modifier = Modifier.fillMaxWidth()) { Text("从二维码图片识别") }
                            TextButton(onClick = {
                                val manager = context.getSystemService(ClipboardManager::class.java)
                                val text = manager.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
                                if (text.isBlank()) model.notice("剪贴板没有接收码") else model.useInvitation(text)
                            }, enabled = !state.importing && state.engineAvailable) { Text("从剪贴板粘贴接收码（备用）") }
                        }
                        SurfaceCard("待发送文件") {
                            Text("选择照片、视频或文档。应用会准备可恢复的副本，原文件不删除。")
                            Button(onClick = { files.launch(arrayOf("*/*")) }, enabled = !state.importing && state.storageHealthy) { Text("选择文件") }
                            if (state.importing) { CircularProgressIndicator(); Text("正在准备文件或识别二维码…") }
                            if (state.outgoing.isEmpty()) Text("还没有发送任务。选择文件后会显示在这里。")
                        }
                        state.outgoing.forEach { task ->
                            SurfaceCard(task.name) {
                                Text(phaseLabel(task.phase))
                                if (task.size > 0) LinearProgressIndicator(progress = { (task.offset.toFloat() / task.size).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
                                Text("${android.text.format.Formatter.formatShortFileSize(context, task.offset)} / ${android.text.format.Formatter.formatShortFileSize(context, task.size)}", style = MaterialTheme.typography.bodySmall)
                                if (task.message.isNotBlank()) Text(task.message, color = MaterialTheme.colorScheme.error)
                                if (state.activeSend == task.id) OutlinedButton(onClick = model::pauseSend) { Text("暂停") }
                                else if (task.phase != "completed") Button(onClick = { model.startSending(task.id) }, enabled = state.activeSend == null && state.engineAvailable && state.storageHealthy) { Text(if (task.phase == "queued") "发送文件" else "继续 / 重试") }
                            }
                        }
                    } else {
                        SurfaceCard("我的接收码") {
                            Text("开启接收后自动生成，可直接扫码、复制或分享。")
                            if (!state.receiveRunning && !state.receiveStarting) {
                                if (state.addresses.isEmpty()) Text("未找到局域网地址，请连接 Wi-Fi 或热点。")
                                state.addresses.forEach { address ->
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        RadioButton(selected = address == state.address, onClick = { model.selectAddress(address) })
                                        Text(address)
                                    }
                                }
                                TextButton(onClick = model::refreshAddresses) { Text("刷新网络地址") }
                                Button(onClick = model::startReceiving, enabled = state.engineAvailable && state.address.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text("开启接收，生成接收码") }
                            } else {
                                if (state.receiveStarting) { CircularProgressIndicator(); Text("正在开启接收…") }
                                if (state.receiveTicket.isNotBlank()) {
                                    val image = remember(state.receiveTicket) { runCatching { QRImages.render(state.receiveTicket) }.getOrNull() }
                                    if (image != null) Image(image.asImageBitmap(), contentDescription = "MultiSync 接收二维码，发送设备可直接扫描", filterQuality = FilterQuality.None,
                                        modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp).aspectRatio(1f).background(Color.White))
                                    else Text("二维码生成失败，请复制接收码", color = MaterialTheme.colorScheme.error)
                                    Button(onClick = {
                                        val clip = ClipData.newPlainText("MultiSync 接收码", state.receiveTicket)
                                        clip.description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
                                        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
                                        model.notice("接收码已复制，仅分享给要向你发送文件的设备。")
                                    }, modifier = Modifier.fillMaxWidth()) { Text("复制接收码") }
                                    OutlinedButton(onClick = ::shareQr, modifier = Modifier.fillMaxWidth()) { Text("分享二维码") }
                                    Text("每份文件仍需你确认接收。", style = MaterialTheme.typography.bodySmall)
                                }
                                TextButton(onClick = model::stopReceiving) { Text("停止接收") }
                            }
                        }
                        Text("接收记录", style = MaterialTheme.typography.titleLarge)
                        if (state.incoming.isEmpty()) Text("还没有接收任务。向另一台设备展示你的接收码即可开始。")
                        state.incoming.forEach { task ->
                            SurfaceCard(task.name) {
                                Text(phaseLabel(task.state))
                                if (task.size > 0) LinearProgressIndicator(progress = { (task.offset.toFloat() / task.size).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
                                Text(android.text.format.Formatter.formatShortFileSize(context, task.size))
                                if (task.state == "pending") Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                    Button(onClick = { model.decide(task.id, true) }) { Text("接受") }
                                    OutlinedButton(onClick = { model.decide(task.id, false) }) { Text("拒绝") }
                                }
                                if (task.state == "receiving") TextButton(onClick = { model.decide(task.id, false) }) { Text("停止并拒绝") }
                                if (task.state == "completed") {
                                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                        TextButton(onClick = { model.completedFile(task)?.let { share(it, "application/octet-stream", true) } ?: model.notice("文件已被移动或无法读取") }) { Text("打开") }
                                        TextButton(onClick = { model.completedFile(task)?.let { share(it, "application/octet-stream") } ?: model.notice("文件已被移动或无法读取") }) { Text("分享") }
                                        TextButton(onClick = { exportTask = task; export.launch(task.finalName ?: task.name) }) { Text("另存为") }
                                    }
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(24.dp))
                }
            }
        }
    }
}

@Composable
private fun SurfaceCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp), colors = CardDefaults.cardColors(containerColor = Color.White)) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}
