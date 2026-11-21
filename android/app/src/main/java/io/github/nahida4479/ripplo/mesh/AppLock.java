package io.github.nahida4479.ripplo.mesh;

import android.app.KeyguardManager;
import android.content.Context;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.biometric.BiometricManager;
import androidx.biometric.BiometricPrompt;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.FragmentActivity;

final class AppLock {
    interface Result {
        void done(boolean ok);
    }

    private AppLock() {
    }

    private static int authenticators() {
        int bio = Build.VERSION.SDK_INT >= 30
                ? BiometricManager.Authenticators.BIOMETRIC_STRONG
                : BiometricManager.Authenticators.BIOMETRIC_WEAK;
        return bio | BiometricManager.Authenticators.DEVICE_CREDENTIAL;
    }

    static boolean biometric(Context ctx) {
        int bio = Build.VERSION.SDK_INT >= 30
                ? BiometricManager.Authenticators.BIOMETRIC_STRONG
                : BiometricManager.Authenticators.BIOMETRIC_WEAK;
        return BiometricManager.from(ctx).canAuthenticate(bio) == BiometricManager.BIOMETRIC_SUCCESS;
    }

    static boolean deviceCredential(Context ctx) {
        KeyguardManager km = (KeyguardManager) ctx.getSystemService(Context.KEYGUARD_SERVICE);
        return km != null && km.isDeviceSecure();
    }

    static boolean hasLock(Context ctx) {
        return biometric(ctx) || deviceCredential(ctx);
    }

    static void authenticate(FragmentActivity activity, String reason, Result result) {
        if (!hasLock(activity)) {
            result.done(true);
            return;
        }
        BiometricPrompt.PromptInfo info = new BiometricPrompt.PromptInfo.Builder()
                .setTitle(reason == null || reason.isEmpty() ? "Ripplo" : reason)
                .setAllowedAuthenticators(authenticators())
                .build();
        BiometricPrompt prompt = new BiometricPrompt(activity, ContextCompat.getMainExecutor(activity),
                new BiometricPrompt.AuthenticationCallback() {
                    @Override
                    public void onAuthenticationSucceeded(@NonNull BiometricPrompt.AuthenticationResult r) {
                        result.done(true);
                    }

                    @Override
                    public void onAuthenticationError(int code, @NonNull CharSequence msg) {
                        result.done(false);
                    }
                });
        prompt.authenticate(info);
    }
}
