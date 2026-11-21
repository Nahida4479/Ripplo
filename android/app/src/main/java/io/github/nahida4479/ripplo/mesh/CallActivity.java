package io.github.nahida4479.ripplo.mesh;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import io.github.nahida4479.ripplo.MainActivity;
import io.github.nahida4479.ripplo.R;
import java.lang.ref.WeakReference;

public class CallActivity extends Activity {
    static final String EXTRA_TITLE = "title";
    static final String EXTRA_CALL = "callId";
    static final String EXTRA_PEER = "peer";
    static final String EXTRA_TOKEN = "token";
    private static WeakReference<CallActivity> current;
    private String callId;
    private String peer;
    private String token;

    static void dismiss() {
        CallActivity a = current == null ? null : current.get();
        if (a != null) a.finish();
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        current = new WeakReference<>(this);
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true);
            setTurnScreenOn(true);
        } else {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);
        }
        Intent in = getIntent();
        callId = in.getStringExtra(EXTRA_CALL);
        peer = in.getStringExtra(EXTRA_PEER);
        token = in.getStringExtra(EXTRA_TOKEN);
        String title = in.getStringExtra(EXTRA_TITLE);
        if (callId == null || peer == null || token == null) {
            finish();
            return;
        }
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setBackgroundColor(Color.parseColor("#101418"));
        int pad = (int) (24 * getResources().getDisplayMetrics().density);
        root.setPadding(pad, pad * 3, pad, pad * 2);
        TextView name = new TextView(this);
        name.setText(title == null ? getString(R.string.app_name) : title);
        name.setTextColor(Color.WHITE);
        name.setTextSize(30);
        name.setGravity(Gravity.CENTER);
        TextView sub = new TextView(this);
        sub.setText(R.string.incoming_call);
        sub.setTextColor(Color.parseColor("#9AA4AE"));
        sub.setTextSize(16);
        sub.setGravity(Gravity.CENTER);
        sub.setPadding(0, pad / 2, 0, 0);
        View gap = new View(this);
        LinearLayout.LayoutParams grow = new LinearLayout.LayoutParams(0, 0, 1f);
        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setGravity(Gravity.CENTER);
        Button decline = button(R.string.call_decline, "#D93F3F");
        Button answer = button(R.string.call_answer, "#2E9E5B");
        LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams(0, (int) (56 * getResources().getDisplayMetrics().density), 1f);
        bp.setMargins(pad / 2, 0, pad / 2, 0);
        buttons.addView(decline, bp);
        buttons.addView(answer, bp);
        root.addView(name);
        root.addView(sub);
        root.addView(gap, grow);
        root.addView(buttons, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));
        setContentView(root);
        decline.setOnClickListener(v -> declineCall());
        answer.setOnClickListener(v -> answerCall());
    }

    private Button button(int text, String color) {
        Button b = new Button(this);
        b.setText(text);
        b.setTextColor(Color.WHITE);
        b.setAllCaps(false);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.parseColor(color));
        bg.setCornerRadius(999f);
        b.setBackground(bg);
        return b;
    }

    private void declineCall() {
        Ringer.stop();
        Notifier.cancelCall(this);
        Opener.forgetRinging();
        MeshEngine.get(this).dropCall(callId);
        finish();
    }

    private void launchMain() {
        startActivity(new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(Notifier.EXTRA_CHAT, peer)
                .putExtra(Notifier.EXTRA_ANSWER, token));
        finish();
    }

    private void answerCall() {
        launchMain();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (current != null && current.get() == this) current = null;
    }
}
