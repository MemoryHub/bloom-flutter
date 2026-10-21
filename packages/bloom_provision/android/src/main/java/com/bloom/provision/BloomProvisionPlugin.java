package com.bloom.provision;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import android.content.pm.PackageManager;
import com.espressif.provisioning.*;
import com.espressif.provisioning.device_scanner.BleScanner;
import com.espressif.provisioning.listeners.*;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;
import org.greenrobot.eventbus.EventBus;
import org.greenrobot.eventbus.Subscribe;
import org.greenrobot.eventbus.ThreadMode;
import java.util.*;

/** No network credentials or device PoP are logged or persisted on the phone. */
public final class BloomProvisionPlugin implements FlutterPlugin, ActivityAware,
        MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {
    private MethodChannel channel;
    private Context context;
    private Activity activity;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String, BluetoothDevice> devices = new HashMap<>();
    private final Map<String, Map<String,Object>> found = new LinkedHashMap<>();
    private BleScanner scanner;
    private ESPDevice selected;
    private MethodChannel.Result pending;
    private String pendingOperation;
    private int generation;
    private static final String UUID = "021a9004-0382-4aea-bff4-6b3f1c5adfb4";

    @Override public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context=binding.getApplicationContext();
        channel=new MethodChannel(binding.getBinaryMessenger(),"bloom/provision");
        channel.setMethodCallHandler(this);
        EventBus.getDefault().register(this);
        // Local first-message check uses a dummy PoP and never touches BLE.
        try {
            byte[] request = new com.espressif.provisioning.security.Security1("bloom-local-self-check").getNextRequestInSession(null);
            android.util.Log.i("BloomProvision", "local_security1_first_request="+(request!=null && request.length>0));
        } catch(Exception e) { logSessionFailure(e); }
    }
    @Override public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        close();channel.setMethodCallHandler(null);EventBus.getDefault().unregister(this);
    }
    @Override public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity=binding.getActivity();binding.addRequestPermissionsResultListener(this);
    }
    @Override public void onDetachedFromActivity(){activity=null;close();}
    @Override public void onDetachedFromActivityForConfigChanges(){activity=null;close();}
    @Override public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding b){onAttachedToActivity(b);}

    private void finish(Object data,String error,int current) {
        main.post(()->{if(current!=generation || pending==null)return;
            MethodChannel.Result result=pending;pending=null;pendingOperation=null;
            if(error==null)result.success(data);else result.error(error,error,null);
        });
    }
    private static void logSessionFailure(Exception e) {
        android.util.Log.w("BloomProvision","session_failed type="+e.getClass().getSimpleName());
        for(StackTraceElement frame:e.getStackTrace())
            android.util.Log.w("BloomProvision","session_frame "+frame.toString());
        if(e.getCause() instanceof Exception && e.getCause()!=e)
            logSessionFailure((Exception)e.getCause());
    }
    private void close(){generation++;if(scanner!=null)scanner.stopScan();if(selected!=null)selected.disconnectDevice();selected=null;
        if(pending!=null){pending.error("cancelled","cancelled",null);pending=null;}pendingOperation=null;}
    private boolean permissions(){
        String[] required=Build.VERSION.SDK_INT>=31 ? new String[]{Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT}:
            new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
        List<String> missing=new ArrayList<>();for(String p:required)if(ContextCompat.checkSelfPermission(context,p)!=PackageManager.PERMISSION_GRANTED)missing.add(p);
        if(missing.isEmpty())return true;
        if(activity==null){finish(null,"permission_required",generation);return false;}
        ActivityCompat.requestPermissions(activity,missing.toArray(new String[0]),6714);return false;
    }
    @Override public boolean onRequestPermissionsResult(int request,String[] names,int[] grants){
        if(request!=6714)return false;
        for(int grant:grants)if(grant!=PackageManager.PERMISSION_GRANTED){finish(null,"permission_denied",generation);return true;}
        if(grants.length==0){finish(null,"permission_denied",generation);return true;}
        if("scan".equals(pendingOperation))scan();return true;
    }
    @Override public void onMethodCall(@NonNull MethodCall call,@NonNull MethodChannel.Result result){
        if(call.method.equals("sign_admin")){
            try{result.success(android.util.Base64.encodeToString(FrameAdminCrypto.sign(call.argument("message"),call.argument("key")),android.util.Base64.NO_WRAP));}
            catch(Exception e){result.error("local_admin_denied","local_admin_denied",null);}
            return;
        }
        if(call.method.equals("disconnect")){close();result.success(null);return;}
        if(call.method.equals("settings")){if(activity!=null)activity.startActivity(new Intent(Settings.ACTION_BLUETOOTH_SETTINGS));result.success(null);return;}
        if(pending!=null){result.error("busy","busy",null);return;}
        pending=result;pendingOperation=call.method;final int current=++generation;
        main.postDelayed(()->finish(null,"timeout",current),25000);
        try{
            switch(call.method){
                case "scan": if(permissions())scan();break;
                case "connect":
                    BluetoothDevice bt=devices.get(call.<String>argument("ble_name"));
                    if(bt==null){finish(null,"device_not_found",current);break;}
                    if(selected!=null)selected.disconnectDevice();
                    selected=new ESPDevice(context,ESPConstants.TransportType.TRANSPORT_BLE,ESPConstants.SecurityType.SECURITY_1);
                    selected.setProofOfPossession(call.argument("pop"));selected.connectBLEDevice(bt,UUID);break;
                case "networks":
                    if(selected==null){finish(null,"disconnected",current);break;}
                    selected.scanNetworks(new WiFiScanListener(){
                        public void onWifiListReceived(ArrayList<WiFiAccessPoint> list){
                            List<Map<String,Object>> items=new ArrayList<>();
                            for(WiFiAccessPoint ap:list){Map<String,Object> item=new HashMap<>();item.put("ssid",ap.getWifiName());item.put("rssi",ap.getRssi());item.put("auth",ap.getSecurity());items.add(item);}
                            finish(items,null,current);
                        }
                        public void onWiFiScanFailed(Exception e){finish(null,"wifi_scan_failed",current);}
                    });break;
                case "data":
                    if(selected==null){finish(null,"disconnected",current);break;}
                    selected.sendDataToCustomEndPoint("bloom-setup",call.<String>argument("json").getBytes(java.nio.charset.StandardCharsets.UTF_8),new ResponseListener(){
                        public void onSuccess(byte[] data){finish(new String(data,java.nio.charset.StandardCharsets.UTF_8),null,current);}
                        public void onFailure(Exception e){finish(null,"communication_failed",current);}
                    });break;
                default:finish(null,"unsupported_method",current);
            }
        }catch(SecurityException e){finish(null,"permission_denied",current);}catch(Exception e){finish(null,"bluetooth_unavailable",current);}
    }
    private void scan(){
        final int current=generation;found.clear();devices.clear();
        scanner=new BleScanner(context,"BLOOM_",new BleScanListener(){
            public void scanStartFailed(){finish(null,"bluetooth_off",current);}
            public void onPeripheralFound(BluetoothDevice device,ScanResult scan){
                if(current!=generation || !"scan".equals(pendingOperation))return;
                String name=scan.getScanRecord()==null?null:scan.getScanRecord().getDeviceName();
                if(name==null || !name.matches("BLOOM_[A-F0-9]{12}"))return;
                devices.put(name,device);Map<String,Object> item=new HashMap<>();item.put("ble_name",name);item.put("rssi",scan.getRssi());
                byte[] manufacturer=scan.getScanRecord().getManufacturerSpecificData(0xffff);
                item.put("busy",manufacturer!=null && manufacturer.length==1 && manufacturer[0]==1);
                found.put(name,item);
            }
            public void scanCompleted(){
                if(current!=generation || !"scan".equals(pendingOperation))return;
                android.util.Log.i("BloomProvision","scan_completed count="+found.size());
                finish(new ArrayList<>(found.values()),null,current);
            }
            public void onFailure(Exception e){finish(null,"scan_failed",current);}
        });scanner.startScan(new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build());
    }
    @Subscribe(threadMode=ThreadMode.MAIN) public void onDeviceConnection(DeviceConnectionEvent event){
        if(!"connect".equals(pendingOperation) || selected==null || !selected.ownsConnectionEvent(event))return;final int current=generation;
        if(event.getEventType()==ESPConstants.EVENT_DEVICE_CONNECTED && selected!=null){
            selected.initSession(new ResponseListener(){
                public void onSuccess(byte[] data){finish(true,null,current);}
                public void onFailure(Exception e){
                    // Only exception types and code locations: never log the
                    // message, handshake bytes, QR contents or credentials.
                    logSessionFailure(e);
                    finish(null,"identity_verification_failed",current);
                }
            });
        }else finish(null,"connection_failed",current);
    }
}
