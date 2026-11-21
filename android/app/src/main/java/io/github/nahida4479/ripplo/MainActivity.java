package io.github.nahida4479.ripplo;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;
import io.github.nahida4479.ripplo.mesh.RipploMeshPlugin;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(RipploMeshPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
