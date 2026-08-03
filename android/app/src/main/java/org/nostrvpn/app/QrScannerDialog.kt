package org.nostrvpn.app

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

@androidx.annotation.OptIn(ExperimentalGetImage::class)
@Composable
internal fun QrScannerDialog(
    onDismiss: () -> Unit,
    allowImageImport: Boolean = false,
    onScanned: (String) -> String?,
) {
    QrScannerHost(
        onDismiss = onDismiss,
        onScanned = onScanned,
        allowImageImport = allowImageImport,
    ) { previewView, error, importImage ->
        Dialog(
            onDismissRequest = onDismiss,
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            QrScannerCamera(
                previewView = previewView,
                error = error,
                onDismiss = onDismiss,
                onImportImage = importImage,
                allowImageImport = allowImageImport,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@androidx.annotation.OptIn(ExperimentalGetImage::class)
@Composable
private fun QrScannerHost(
    onDismiss: () -> Unit,
    onScanned: (String) -> String?,
    allowImageImport: Boolean,
    content: @Composable (PreviewView, String?, () -> Unit) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var error by remember { mutableStateOf<String?>(null) }
    var hasPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    val scannerOptions =
        remember {
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build()
        }
    val cameraScanner = remember(scannerOptions) { BarcodeScanning.getClient(scannerOptions) }
    val importScanner = remember(scannerOptions) { BarcodeScanning.getClient(scannerOptions) }
    val active = remember { AtomicBoolean(true) }
    val didEmit = remember { AtomicBoolean(false) }
    val cameraInFlight = remember { AtomicBoolean(false) }
    val importInFlight = remember { AtomicBoolean(false) }

    fun reportError(message: String) {
        if (active.get()) {
            error = message
        }
    }

    fun acceptDecodedQr(raw: String) {
        if (!active.get() || !didEmit.compareAndSet(false, true)) {
            return
        }
        val errorMessage = onScanned(raw)
        if (errorMessage != null && active.get()) {
            didEmit.set(false)
            error = errorMessage
        }
    }

    val imagePicker =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri == null) {
                importInFlight.set(false)
                return@rememberLauncherForActivityResult
            }
            if (!active.get()) {
                importInFlight.set(false)
                return@rememberLauncherForActivityResult
            }
            error = null
            runCatching { InputImage.fromFilePath(context, uri) }
                .onSuccess { image ->
                    processQrImage(
                        scanner = importScanner,
                        image = image,
                        onDecoded = { raw ->
                            if (active.get() && importInFlight.get()) {
                                acceptDecodedQr(raw)
                            }
                        },
                        onEmpty = { reportError("No QR code found in that image.") },
                        onFailure = { reportError("Could not read a QR code from that image.") },
                        onComplete = { importInFlight.set(false) },
                    )
                }.onFailure {
                    importInFlight.set(false)
                    reportError("Could not open that image.")
                }
        }

    val permissionLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (!active.get()) {
                return@rememberLauncherForActivityResult
            }
            hasPermission = granted
            if (!granted) {
                error =
                    if (allowImageImport) {
                        "Camera permission is needed for live scanning. You can import an image instead."
                    } else {
                        "Camera permission is needed for live scanning."
                    }
            }
        }

    LaunchedEffect(Unit) {
        if (!hasPermission) {
            permissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    val previewView =
        remember {
            PreviewView(context).apply {
                scaleType = PreviewView.ScaleType.FILL_CENTER
            }
        }
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    var cameraProvider: ProcessCameraProvider? by remember { mutableStateOf(null) }

    DisposableEffect(Unit) {
        onDispose {
            active.set(false)
            runCatching { cameraProvider?.unbindAll() }
            runCatching { cameraScanner.close() }
            runCatching { importScanner.close() }
            runCatching { analysisExecutor.shutdown() }
        }
    }

    LaunchedEffect(hasPermission) {
        if (!hasPermission) {
            return@LaunchedEffect
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener(
            {
                runCatching { future.get() }
                    .onSuccess { provider ->
                        if (active.get()) {
                            cameraProvider = provider
                        } else {
                            runCatching { provider.unbindAll() }
                        }
                    }.onFailure { reportError("Camera scanner unavailable.") }
            },
            ContextCompat.getMainExecutor(context),
        )
    }

    LaunchedEffect(cameraProvider, hasPermission) {
        if (!hasPermission) {
            return@LaunchedEffect
        }
        val provider = cameraProvider ?: return@LaunchedEffect
        error = null
        didEmit.set(false)
        cameraInFlight.set(false)

        val preview = Preview.Builder().build()
        preview.setSurfaceProvider(previewView.surfaceProvider)

        val analysis =
            ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()

        analysis.setAnalyzer(analysisExecutor) { imageProxy ->
            if (!active.get()) {
                imageProxy.close()
                return@setAnalyzer
            }
            val mediaImage = imageProxy.image
            if (mediaImage == null) {
                imageProxy.close()
                return@setAnalyzer
            }
            if (importInFlight.get() || !cameraInFlight.compareAndSet(false, true)) {
                imageProxy.close()
                return@setAnalyzer
            }

            val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
            processQrImage(
                scanner = cameraScanner,
                image = image,
                onDecoded = { raw ->
                    if (active.get() && !importInFlight.get()) {
                        acceptDecodedQr(raw)
                    }
                },
                onComplete = {
                    cameraInFlight.set(false)
                    imageProxy.close()
                },
            )
        }

        runCatching {
            provider.unbindAll()
            provider.bindToLifecycle(
                lifecycleOwner,
                CameraSelector.DEFAULT_BACK_CAMERA,
                preview,
                analysis,
            )
        }.onFailure {
            reportError("Camera scanner unavailable.")
        }
    }

    content(
        previewView,
        error,
        {
            if (active.get() && importInFlight.compareAndSet(false, true)) {
                error = null
                runCatching { imagePicker.launch(arrayOf("image/*")) }
                    .onFailure {
                        importInFlight.set(false)
                        reportError("Could not open the image picker.")
                    }
            }
        },
    )
}

private fun processQrImage(
    scanner: BarcodeScanner,
    image: InputImage,
    onDecoded: (String) -> Unit,
    onEmpty: () -> Unit = {},
    onFailure: () -> Unit = {},
    onComplete: () -> Unit,
) {
    val task =
        runCatching { scanner.process(image) }
            .getOrElse {
                onFailure()
                onComplete()
                return
            }
    task
        .addOnSuccessListener { barcodes ->
            firstQrPayload(barcodes.map { it.rawValue })?.let(onDecoded) ?: onEmpty()
        }.addOnFailureListener {
            onFailure()
        }.addOnCompleteListener {
            onComplete()
        }
}

internal fun firstQrPayload(rawValues: Iterable<String?>): String? =
    rawValues.firstNotNullOfOrNull { value -> value?.trim()?.takeIf(String::isNotEmpty) }

@Composable
private fun QrScannerCamera(
    previewView: PreviewView,
    error: String?,
    onDismiss: () -> Unit,
    onImportImage: () -> Unit,
    allowImageImport: Boolean,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier =
            modifier
                .background(Color.Black)
                .mobileUiSelector(
                    id = "qr-scanner-camera",
                    description = "QR scanner camera",
                ),
    ) {
        AndroidView(
            factory = { previewView },
            modifier = Modifier.fillMaxSize(),
        )
        QrScannerCrosshair(modifier = Modifier.fillMaxSize())
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 4.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = onDismiss) {
                Text("Close", color = Color.White)
            }
            Text(
                text = "Scan",
                style = MaterialTheme.typography.titleLarge,
                color = Color.White,
            )
            Spacer(modifier = Modifier.weight(1f))
            if (allowImageImport) {
                TextButton(
                    onClick = onImportImage,
                    modifier =
                        Modifier.mobileUiSelector(
                            id = "join-request-import-image",
                            description = "Import QR Image",
                        ),
                ) {
                    Text("Import QR Image", color = Color.White)
                }
            }
        }
        error?.let { message ->
            Text(
                text = message,
                modifier =
                    Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(horizontal = 24.dp, vertical = 28.dp)
                        .background(Color.Black.copy(alpha = 0.62f), RoundedCornerShape(18.dp))
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                style = MaterialTheme.typography.bodyMedium,
                color = Color.White,
            )
        }
    }
}

@Composable
private fun QrScannerCrosshair(modifier: Modifier = Modifier) {
    val path = remember { Path() }
    Canvas(modifier = modifier) {
        val crosshairWidth = size.minDimension * 0.6f
        val lineLength = crosshairWidth * 0.125f
        val topLeft = center - Offset(crosshairWidth / 2f, crosshairWidth / 2f)
        val topRight = center + Offset(crosshairWidth / 2f, -crosshairWidth / 2f)
        val bottomRight = center + Offset(crosshairWidth / 2f, crosshairWidth / 2f)
        val bottomLeft = center + Offset(-crosshairWidth / 2f, crosshairWidth / 2f)
        path.reset()
        path.moveTo(topLeft.x, topLeft.y + lineLength)
        path.lineTo(topLeft.x, topLeft.y)
        path.lineTo(topLeft.x + lineLength, topLeft.y)
        path.moveTo(topRight.x - lineLength, topRight.y)
        path.lineTo(topRight.x, topRight.y)
        path.lineTo(topRight.x, topRight.y + lineLength)
        path.moveTo(bottomRight.x, bottomRight.y - lineLength)
        path.lineTo(bottomRight.x, bottomRight.y)
        path.lineTo(bottomRight.x - lineLength, bottomRight.y)
        path.moveTo(bottomLeft.x + lineLength, bottomLeft.y)
        path.lineTo(bottomLeft.x, bottomLeft.y)
        path.lineTo(bottomLeft.x, bottomLeft.y - lineLength)
        drawPath(
            path = path,
            color = Color.White,
            style =
                Stroke(
                    width = 3.dp.toPx(),
                    pathEffect = PathEffect.cornerPathEffect(10.dp.toPx()),
                ),
        )
    }
}
