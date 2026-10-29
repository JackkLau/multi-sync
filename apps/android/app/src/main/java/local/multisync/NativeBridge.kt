package local.multisync

object NativeBridge {
    val available: Boolean = try { System.loadLibrary("multi_sync_bridge"); true } catch (_: UnsatisfiedLinkError) { false }
    @JvmStatic external fun call(request: String): String
}
