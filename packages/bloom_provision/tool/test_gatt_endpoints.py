#!/usr/bin/env python3
"""Execute the production BLETransport against queued Android GATT callbacks."""
from pathlib import Path
import os, shutil, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
vendor = root / 'vendor/android/java/com/espressif/provisioning'
java_home = os.environ.get('JAVA_HOME')
javac = str(Path(java_home) / 'bin/javac') if java_home else shutil.which('javac')
java = str(Path(java_home) / 'bin/java') if java_home else shutil.which('java')
stubs = {
'android/content/Context.java': 'package android.content; public class Context {}',
'android/util/Log.java': 'package android.util; public class Log {}',
'android/os/Bundle.java': 'package android.os; public class Bundle {}',
'android/os/Build.java': 'package android.os; public class Build { public static class VERSION { public static int SDK_INT=35; } public static class VERSION_CODES { public static int M=23; }}',
'android/bluetooth/BluetoothProfile.java': 'package android.bluetooth; public interface BluetoothProfile { int STATE_CONNECTED=2, STATE_DISCONNECTED=0; }',
'android/bluetooth/BluetoothGattCallback.java': r"""package android.bluetooth;
public class BluetoothGattCallback {
 public void onConnectionStateChange(BluetoothGatt g,int s,int n){}
 public void onServicesDiscovered(BluetoothGatt g,int s){}
 public void onDescriptorRead(BluetoothGatt g,BluetoothGattDescriptor d,int s){}
 public void onDescriptorWrite(BluetoothGatt g,BluetoothGattDescriptor d,int s){}
 public void onMtuChanged(BluetoothGatt g,int m,int s){}
 public void onCharacteristicChanged(BluetoothGatt g,BluetoothGattCharacteristic c){}
 public void onCharacteristicRead(BluetoothGatt g,BluetoothGattCharacteristic c,int s){}
 public void onCharacteristicWrite(BluetoothGatt g,BluetoothGattCharacteristic c,int s){}
}""",
'android/bluetooth/BluetoothGattDescriptor.java': r"""package android.bluetooth;
import java.util.UUID;
public class BluetoothGattDescriptor {
 public final BluetoothGattCharacteristic c; public byte[] value;
 public BluetoothGattDescriptor(BluetoothGattCharacteristic c,String name){this.c=c;value=name.getBytes(java.nio.charset.StandardCharsets.UTF_8);}
 public UUID getUuid(){return UUID.fromString("00002901-0000-1000-8000-00805f9b34fb");}
 public BluetoothGattCharacteristic getCharacteristic(){return c;}
 public byte[] getValue(){return value;}
}""",
'android/bluetooth/BluetoothGattCharacteristic.java': r"""package android.bluetooth;
import java.util.*;
public class BluetoothGattCharacteristic {
 public static final int WRITE_TYPE_DEFAULT=2; final UUID id; byte[] value;
 public final ArrayList<BluetoothGattDescriptor> descriptors=new ArrayList<>();
 public BluetoothGattCharacteristic(String id,String name){this.id=UUID.fromString(id); if(name!=null)descriptors.add(new BluetoothGattDescriptor(this,name));}
 public UUID getUuid(){return id;}
 public List<BluetoothGattDescriptor> getDescriptors(){return descriptors;}
 public void setWriteType(int n){}
 public boolean setValue(byte[] b){value=b;return true;}
 public boolean setValue(String s){return setValue(s.getBytes(java.nio.charset.StandardCharsets.UTF_8));}
 public byte[] getValue(){return value;}
}""",
'android/bluetooth/BluetoothGattService.java': r"""package android.bluetooth;
import java.util.*;
public class BluetoothGattService {
 public final List<BluetoothGattCharacteristic> chars=new ArrayList<>();
 public List<BluetoothGattCharacteristic> getCharacteristics(){return chars;}
 public BluetoothGattCharacteristic getCharacteristic(UUID id){for(BluetoothGattCharacteristic c:chars)if(c.getUuid().equals(id))return c;return null;}
}""",
'android/bluetooth/BluetoothGatt.java': r"""package android.bluetooth;
import java.util.*;
public class BluetoothGatt {
 public static final int GATT_SUCCESS=0,GATT_FAILURE=257;
 public BluetoothGattCallback cb; public BluetoothGattService service=new BluetoothGattService();
 public final ArrayDeque<Runnable> queued=new ArrayDeque<>();
 public int descriptorReads=0,writes=0,reads=0; public boolean rejectRead=false,rejectWrite=false,closed=false; public int descriptorStatus=0;
 public BluetoothGattCharacteristic written;
 public BluetoothGattService getService(UUID id){return service;}
 public boolean requestMtu(int n){queued.add(()->cb.onMtuChanged(this,500,0));return true;}
 public boolean discoverServices(){queued.add(()->cb.onServicesDiscovered(this,0));return true;}
 public boolean readDescriptor(BluetoothGattDescriptor d){descriptorReads++;if(rejectRead)return false;queued.add(()->cb.onDescriptorRead(this,d,descriptorStatus));return true;}
 public boolean writeCharacteristic(BluetoothGattCharacteristic c){writes++;written=c;if(rejectWrite)return false;queued.add(()->cb.onCharacteristicWrite(this,c,0));return true;}
 public boolean readCharacteristic(BluetoothGattCharacteristic c){reads++;if(writes==1)c.setValue("{} ");queued.add(()->cb.onCharacteristicRead(this,c,0));return true;}
 public void disconnect(){} public void close(){closed=true;}
 public void refresh(){}
 public void drain(){for(int n=0;!queued.isEmpty();n++){if(n>50)throw new AssertionError("callback loop");queued.remove().run();}}
}""",
'android/bluetooth/BluetoothDevice.java': r"""package android.bluetooth;
import android.content.Context;
public class BluetoothDevice {
 public static final int TRANSPORT_LE=2; public final BluetoothGatt gatt=new BluetoothGatt();
 public BluetoothGatt connectGatt(Context c,boolean a,BluetoothGattCallback cb,int t){gatt.cb=cb;return gatt;}
 public BluetoothGatt connectGatt(Context c,boolean a,BluetoothGattCallback cb){return connectGatt(c,a,cb,2);}
}""",
'org/greenrobot/eventbus/EventBus.java': r"""package org.greenrobot.eventbus;
import java.util.*;
public class EventBus {static final EventBus bus=new EventBus();public final List<Object> events=new ArrayList<>();public static EventBus getDefault(){return bus;}public void post(Object o){events.add(o);}}""",
'org/json/JSONException.java': 'package org.json; public class JSONException extends Exception {}',
'org/json/JSONArray.java': 'package org.json; public class JSONArray {public int length(){return 0;} public String getString(int i)throws JSONException{return "";}}',
'org/json/JSONObject.java': 'package org.json; public class JSONObject {public JSONObject(String s)throws JSONException{} public JSONObject getJSONObject(String k)throws JSONException{return this;} public String getString(String k)throws JSONException{return "v1.1";} public JSONArray getJSONArray(String k)throws JSONException{return new JSONArray();}}',
}
harness = r"""import android.bluetooth.*;
import android.content.Context;
import com.espressif.provisioning.*;
import com.espressif.provisioning.transport.BLETransport;
import org.greenrobot.eventbus.EventBus;
public class CheckGatt {
 static final String SERVICE="021a9004-0382-4aea-bff4-6b3f1c5adfb4";
 static String id(int i){return String.format("0000ff%02x-0000-1000-8000-00805f9b34fb",i);}
 static void expect(boolean b,String text){if(!b)throw new AssertionError(text);System.out.println("PASS "+text);}
 static Object[] setup(String...names){
  EventBus.getDefault().events.clear();
  BluetoothDevice d=new BluetoothDevice();int i=80;
  for(String n:names)d.gatt.service.chars.add(new BluetoothGattCharacteristic(id(i++),n));
  BLETransport t=new BLETransport(new Context());t.connect(d,java.util.UUID.fromString(SERVICE));
  return new Object[]{t,d.gatt};
 }
 static void run(BluetoothGatt g){g.cb.onConnectionStateChange(g,0,2);g.drain();}
 static boolean event(short type,Object owner){for(Object o:EventBus.getDefault().events){DeviceConnectionEvent e=(DeviceConnectionEvent)o;if(e.getEventType()==type&&e.getSource()==owner)return true;}return false;}
 public static void main(String[] args){
  Object[] p=setup("bloom-setup","proto-ver","prov-config","prov-scan","prov-session");BluetoothGatt g=(BluetoothGatt)p[1];
  run(g);expect(g.descriptorReads==5,"all actual endpoint descriptions are read");
  expect(g.writes==1&&g.reads==1,"protocol version exchange follows descriptor completion");
  expect(event(ESPConstants.EVENT_DEVICE_CONNECTED,p[0]),"ready event belongs to the current transport");
  p=setup(null,"proto-ver","prov-session");g=(BluetoothGatt)p[1];run(g);expect(g.descriptorReads==2&&event(ESPConstants.EVENT_DEVICE_CONNECTED,p[0]),"unrelated characteristic without descriptor does not stall setup");
  p=setup("proto-ver");g=(BluetoothGatt)p[1];g.rejectRead=true;run(g);expect(g.closed&&event(ESPConstants.EVENT_DEVICE_CONNECTION_FAILED,p[0]),"Android refusing descriptor read fails immediately");
  p=setup("proto-ver");g=(BluetoothGatt)p[1];g.descriptorStatus=5;run(g);expect(g.closed&&!event(ESPConstants.EVENT_DEVICE_CONNECTED,p[0]),"failed descriptor callback cannot report ready");
  p=setup("prov-session");g=(BluetoothGatt)p[1];run(g);expect(g.closed&&event(ESPConstants.EVENT_DEVICE_CONNECTION_FAILED,p[0]),"missing protocol endpoint fails without null UUID or timeout");
  p=setup("proto-ver");g=(BluetoothGatt)p[1];g.rejectWrite=true;run(g);expect(g.closed&&event(ESPConstants.EVENT_DEVICE_CONNECTION_FAILED,p[0]),"refused protocol write fails immediately");
  p=setup("proto-ver");g=(BluetoothGatt)p[1];g.cb.onServicesDiscovered(g,0);Runnable late=g.queued.remove();((BLETransport)p[0]).disconnect();late.run();expect(g.writes==0,"late descriptor callback after disconnect is ignored");
 }
}
"""
with tempfile.TemporaryDirectory(prefix='bloom-gatt-endpoints-') as directory:
 p = Path(directory)
 for name, text in stubs.items():
  f=p/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(text)
 for name in ['transport/BLETransport.java','transport/Transport.java','listeners/ResponseListener.java','ESPConstants.java','DeviceConnectionEvent.java']:
  f=p/'com/espressif/provisioning'/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text((vendor/name).read_text())
 (p/'CheckGatt.java').write_text(harness)
 subprocess.run([javac,'-d',str(p),*[str(f) for f in p.rglob('*.java')]],check=True)
 subprocess.run([java,'-cp',str(p),'CheckGatt'],check=True)
