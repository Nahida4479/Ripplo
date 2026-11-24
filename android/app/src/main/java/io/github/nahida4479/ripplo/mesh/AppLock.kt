package io.github.nahida4479.ripplo.mesh

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

internal object AppLock {
    fun interface Result {
        fun done(ok: Boolean)
    }

    private fun biometricStrength(): Int =
        if (Build.VERSION.SDK_INT >= 30) BiometricManager.Authenticators.BIOMETRIC_STRONG
        else BiometricManager.Authenticators.BIOMETRIC_WEAK

    private fun authenticators(): Int =
        biometricStrength() or BiometricManager.Authenticators.DEVICE_CREDENTIAL

    @JvmStatic
    fun biometric(ctx: Context): Boolean =
        BiometricManager.from(ctx).canAuthenticate(biometricStrength()) == BiometricManager.BIOMETRIC_SUCCESS

    @JvmStatic
    fun deviceCredential(ctx: Context): Boolean {
        val km = ctx.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager?
        return km != null && km.isDeviceSecure
    }

    @JvmStatic
    fun hasLock(ctx: Context): Boolean = biometric(ctx) || deviceCredential(ctx)

    @JvmStatic
    fun authenticate(activity: FragmentActivity, reason: String?, result: Result) {
        if (!hasLock(activity)) {
            result.done(true)
            return
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(if (reason.isNullOrEmpty()) "Ripplo" else reason)
            .setAllowedAuthenticators(authenticators())
            .build()
        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult) {
                    result.done(true)
                }

                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    result.done(false)
                }
            }
        )
        prompt.authenticate(info)
    }
}
